// ignore_for_file: avoid_print
//
// Production-grade Nuvio scraper runtime.
//
// Mirrors the architecture of the official Nuvio reference implementation
// (NuvioMedia/NuvioMobile → composeApp/.../plugins/PluginRuntime.kt) on top
// of `flutter_js`'s QuickJS (Android/Windows/Linux) and JavaScriptCore
// (iOS/macOS) backends.
//
// Design summary:
//   * `flutter_js`'s built-in xhr/fetch is **disabled** — we route every
//     network call through our own Dart-side bridge (`__native_fetch`)
//     using `package:http`, with full header / body / status / redirect URL
//     fidelity. This is what the upstream Nuvio host does and is the only
//     way the third-party scrapers reliably resolve TMDB metadata.
//   * No use of `flutter_js`'s `handlePromise` — its 20 ms polling loop
//     builds a recursive `Future.delayed` chain that stack-overflows on
//     long-running scrapers. Instead we drive the QuickJS event loop
//     ourselves with a non-recursive `executePendingJob` pump and capture
//     the final result via a sync `__capture_result` bridge.
//   * Polyfills installed once at runtime init (NOT per scraper) and shared
//     across all scrapers via `__nuvioRequire`:
//       - `globalThis.global / window / self`
//       - `URL`, `URLSearchParams`
//       - `AbortController`, `AbortSignal`
//       - `atob`, `btoa`
//       - `Array.prototype.flat / flatMap`,
//         `Object.entries / fromEntries`,
//         `String.prototype.replaceAll`
//       - Full `CryptoJS` façade (MD5/SHA1/SHA256/SHA512 + HMAC variants,
//         enc.Hex / enc.Utf8 / enc.Base64), backed by Dart `package:crypto`
//       - Real cheerio (browserified UMD bundle in
//         `assets/nuvio/cheerio.bundle.js`) exposed under `cheerio`,
//         `cheerio-without-node-native`, and `react-native-cheerio`
//   * Per-invocation `globalThis.SCRAPER_ID` and `globalThis.SCRAPER_SETTINGS`
//     are set immediately before `getStreams(...)` runs so providers that
//     read settings see the right values.
//   * `getStreams` is resolved from `module.exports.getStreams ||
//     globalThis.getStreams` — many community scrapers attach to the global.
//
// Public API (unchanged from the previous version, so `nuvio_service.dart`
// keeps working without changes):
//   * `NuvioRuntime.instance.loadScraper(scraperId, code)`
//   * `NuvioRuntime.instance.isLoaded(scraperId)`
//   * `NuvioRuntime.instance.getStreams(...)` → `List<Map<String,dynamic>>`

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

class NuvioRuntime {
  NuvioRuntime._();
  static final NuvioRuntime instance = NuvioRuntime._();

  // --- runtime state ------------------------------------------------------
  JavascriptRuntime? _runtime;
  bool _ready = false;
  Completer<void>? _initCompleter;
  final Set<String> _loadedScraperIds = {};

  // --- per-call coordination ---------------------------------------------
  int _callSeq = 0;
  final Map<int, Completer<String>> _pendingResults = {};

  // --- per-fetch coordination --------------------------------------------
  final Map<int, http.Client> _activeFetches = {};

  // --- per-timer coordination --------------------------------------------
  int _timerSeq = 0;
  final Map<int, Timer> _activeTimers = {};

  // Single shared http client – reuses connections, much faster than
  // spawning a fresh client per request.
  final http.Client _http = http.Client();

  // ─── bootstrap ─────────────────────────────────────────────────────────

  Future<void> _ensureInit() async {
    if (_ready) return;
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<void>();
    try {
      // Disable the built-in xhr/fetch — we install our own native bridge
      // below. Bigger stack so recursive parser code in cheerio doesn't blow.
      final rt = getJavascriptRuntime(
        xhr: false,
        extraArgs: const {'stackSize': 4 * 1024 * 1024},
      );
      _runtime = rt;
      _registerBridges(rt);
      _installPolyfills(rt);
      await _loadCheerioBundle(rt);
      _ready = true;
      _initCompleter!.complete();
    } catch (e, st) {
      _initCompleter!.completeError(e, st);
      _initCompleter = null;
      rethrow;
    }
  }

  // ─── Dart ↔ JS bridges ─────────────────────────────────────────────────

  void _registerBridges(JavascriptRuntime rt) {
    // Helper: setupBridge's static signature is `void Function(dynamic args)`,
    // but the underlying flutter_js runtime actually returns the closure's
    // return value to JS. Dart's function subtype rules let us pass an
    // `Object? Function(dynamic)` where `void Function(dynamic)` is expected
    // (a non-void return widens to void). This helper exists purely to make
    // that conversion happen at a single, explicit point.
    void br(String name, Object? Function(dynamic args) fn) {
      rt.setupBridge(name, fn);
    }

    // console.{log,info,warn,error,debug}
    br('NuvioConsole', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final level = (m['level'] ?? 'log').toString();
        final msg = (m['msg'] ?? '').toString();
        debugPrint('[Nuvio:$level] $msg');
      } catch (_) {}
      return null;
    });

    // crypto.digest(algo, utf8) → hex
    br('NuvioCryptoDigest', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        return _digestHex(
            (m['algo'] ?? 'SHA256').toString(), (m['data'] ?? '').toString());
      } catch (_) {
        return '';
      }
    });

    // crypto.hmac(algo, key, data) → hex
    br('NuvioCryptoHmac', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        return _hmacHex(
          (m['algo'] ?? 'SHA256').toString(),
          (m['key'] ?? '').toString(),
          (m['data'] ?? '').toString(),
        );
      } catch (_) {
        return '';
      }
    });

    // base64 encode / decode  (utf8 ⇄ base64)
    br('NuvioCryptoB64Enc', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        return base64.encode(utf8.encode((m['data'] ?? '').toString()));
      } catch (_) {
        return '';
      }
    });
    br('NuvioCryptoB64Dec', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final raw = (m['data'] ?? '').toString();
        // Be lenient with padding.
        final padded = raw + ('=' * ((4 - raw.length % 4) % 4));
        final bytes = base64.decode(padded);
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return '';
      }
    });

    // utf8 ⇄ hex helpers (used by CryptoJS façade)
    br('NuvioCryptoUtf8ToHex', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final bytes = utf8.encode((m['data'] ?? '').toString());
        final sb = StringBuffer();
        for (final b in bytes) {
          sb.write(b.toRadixString(16).padLeft(2, '0'));
        }
        return sb.toString();
      } catch (_) {
        return '';
      }
    });
    br('NuvioCryptoHexToUtf8', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final hex = (m['data'] ?? '').toString();
        final bytes = <int>[];
        for (var i = 0; i + 1 < hex.length; i += 2) {
          final v = int.tryParse(hex.substring(i, i + 2), radix: 16);
          if (v != null) bytes.add(v);
        }
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return '';
      }
    });

    // URL parse → component map
    br('NuvioParseUrl', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        return _parseUrl((m['url'] ?? '').toString());
      } catch (_) {
        return _emptyUrlParts();
      }
    });

    // Async fetch start. Returns immediately; the response is delivered
    // back to JS by Dart calling `__nuvioFetchResolve(id, envelope)`.
    br('NuvioFetchStart', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final id = (m['id'] as num).toInt();
        final url = (m['url'] ?? '').toString();
        final method = (m['method'] ?? 'GET').toString().toUpperCase();
        final headers = <String, String>{};
        final hRaw = m['headers'];
        if (hRaw is Map) {
          hRaw.forEach((k, v) => headers[k.toString()] = v.toString());
        }
        final body = (m['body'] ?? '').toString();
        // Fire and forget; the request runs on its own scheduling.
        unawaited(_dispatchFetch(
            id: id, url: url, method: method, headers: headers, body: body));
      } catch (_) {}
      return null;
    });

    // Final result capture from the per-call IIFE.
    br('NuvioCaptureResult', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final id = (m['id'] as num).toInt();
        final body = (m['body'] ?? '[]').toString();
        final c = _pendingResults.remove(id);
        if (c != null && !c.isCompleted) c.complete(body);
      } catch (_) {}
      return null;
    });

    // setTimeout / setInterval — backed by real Dart Timer.
    br('NuvioTimerSchedule', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final ms = ((m['ms'] as num?) ?? 0).toInt().clamp(0, 600000);
        final repeat = m['repeat'] == true;
        final id = ++_timerSeq;
        if (repeat) {
          _activeTimers[id] = Timer.periodic(Duration(milliseconds: ms == 0 ? 1 : ms), (_) {
            _fireTimer(id, repeat: true);
          });
        } else {
          _activeTimers[id] = Timer(Duration(milliseconds: ms), () {
            _fireTimer(id, repeat: false);
          });
        }
        return id;
      } catch (_) {
        return 0;
      }
    });
    br('NuvioTimerCancel', (args) {
      try {
        final m = args is Map ? args : <String, dynamic>{};
        final id = (m['id'] as num).toInt();
        final t = _activeTimers.remove(id);
        t?.cancel();
      } catch (_) {}
      return null;
    });
  }

  void _fireTimer(int id, {required bool repeat}) {
    final rt = _runtime;
    if (rt == null) return;
    if (!repeat) _activeTimers.remove(id);
    try {
      rt.evaluate('try { globalThis.__nuvioTimerFire($id); } catch (e) {}',
          sourceUrl: 'nuvio://timer/$id');
    } catch (_) {}
  }

  // ─── JS-side polyfills ────────────────────────────────────────────────

  void _installPolyfills(JavascriptRuntime rt) {
    final res = rt.evaluate(_polyfillsJs, sourceUrl: 'nuvio://polyfills');
    if (res.isError) {
      throw StateError('Nuvio polyfill install failed: ${res.stringResult}');
    }
  }

  Future<void> _loadCheerioBundle(JavascriptRuntime rt) async {
    try {
      final code = await rootBundle.loadString('assets/nuvio/cheerio.bundle.js');
      final wrapped = '''
(function(){
  var module = { exports: {} };
  var exports = module.exports;
  try {
    $code
    var c = (module.exports && Object.keys(module.exports).length > 0)
      ? module.exports
      : (typeof globalThis.CheerioBundle !== 'undefined' ? globalThis.CheerioBundle : null);
    if (c) {
      globalThis.__nuvioModules['cheerio'] = c;
      globalThis.__nuvioModules['cheerio-without-node-native'] = c;
      globalThis.__nuvioModules['react-native-cheerio'] = c;
    } else {
      sendMessage('NuvioConsole', JSON.stringify({level:'error',msg:'[NuvioRuntime] cheerio bundle produced no export'}));
    }
  } catch(e) {
    sendMessage('NuvioConsole', JSON.stringify({level:'error',msg:'[NuvioRuntime] cheerio bundle load failed: ' + (e && e.message ? e.message : e)}));
  }
})();
''';
      final res = rt.evaluate(wrapped, sourceUrl: 'nuvio://cheerio-bundle');
      if (res.isError) {
        debugPrint('[NuvioRuntime] cheerio bundle eval error: ${res.stringResult}');
      } else {
        debugPrint('[NuvioRuntime] cheerio bundle loaded (${code.length} bytes)');
      }
    } catch (e) {
      debugPrint('[NuvioRuntime] cheerio asset load failed: $e');
    }
  }

  // ─── public API ───────────────────────────────────────────────────────

  Future<void> loadScraper({
    required String scraperId,
    required String code,
  }) async {
    await _ensureInit();
    final rt = _runtime!;
    final wrapped = '''
(function(){
  var module = { exports: {} };
  var exports = module.exports;
  var require = globalThis.__nuvioRequire;
  // Fresh global getStreams slot per load — so we can detect whether the
  // scraper attached to it without picking up a previous scraper's value.
  globalThis.getStreams = undefined;
  try {
    $code
  } catch (e) {
    sendMessage('NuvioConsole', JSON.stringify({level:'error',msg:'[NuvioLoader:$scraperId] ' + (e && e.message ? e.message : e)}));
    throw e;
  }
  // Snapshot the resolved entrypoint at load-time. Many community scrapers
  // attach getStreams to globalThis instead of module.exports.
  var fn = (module.exports && module.exports.getStreams) || globalThis.getStreams;
  globalThis.__nuvioRegistry[${jsonEncode(scraperId)}] = {
    getStreams: fn,
    exports: module.exports
  };
})();
''';
    final res = rt.evaluate(wrapped, sourceUrl: 'nuvio://$scraperId');
    if (res.isError) {
      throw Exception('Nuvio scraper load failed ($scraperId): ${res.stringResult}');
    }
    _loadedScraperIds.add(scraperId);
  }

  bool isLoaded(String scraperId) => _loadedScraperIds.contains(scraperId);

  Future<List<Map<String, dynamic>>> getStreams({
    required String scraperId,
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    Map<String, dynamic>? scraperSettings,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ensureInit();
    if (!_loadedScraperIds.contains(scraperId)) {
      throw StateError('Scraper $scraperId not loaded');
    }
    final rt = _runtime!;
    final callId = ++_callSeq;
    final completer = Completer<String>();
    _pendingResults[callId] = completer;

    final args = mediaType == 'movie'
        ? '${jsonEncode(tmdbId)}, "movie", undefined, undefined'
        : '${jsonEncode(tmdbId)}, "tv", ${season ?? 1}, ${episode ?? 1}';
    final settingsJson = jsonEncode(scraperSettings ?? const {});

    final invoker = '''
(function(){
  globalThis.SCRAPER_ID = ${jsonEncode(scraperId)};
  globalThis.SCRAPER_SETTINGS = $settingsJson;
  var entry = globalThis.__nuvioRegistry[${jsonEncode(scraperId)}];
  var fn = entry && entry.getStreams;
  if (typeof fn !== 'function') {
    sendMessage('NuvioCaptureResult', JSON.stringify({id:$callId, body:'[]'}));
    return;
  }
  Promise.resolve()
    .then(function(){ return fn($args); })
    .then(function(r){
      try { sendMessage('NuvioCaptureResult', JSON.stringify({id:$callId, body: JSON.stringify(r == null ? [] : r)})); }
      catch (e) { sendMessage('NuvioCaptureResult', JSON.stringify({id:$callId, body:'[]'})); }
    })
    .catch(function(e){
      var msg = (e && e.message) ? e.message : (e ? String(e) : 'unknown');
      sendMessage('NuvioConsole', JSON.stringify({level:'error',msg:'[NuvioInvoker:'+${jsonEncode(scraperId)}+'] '+msg}));
      sendMessage('NuvioCaptureResult', JSON.stringify({id:$callId, body:'[]'}));
    });
})();
''';

    final r = rt.evaluate(invoker);
    if (r.isError) {
      _pendingResults.remove(callId);
      debugPrint('[NuvioRuntime] invoker eval error: ${r.stringResult}');
      return [];
    }

    // Drive the QuickJS event loop ourselves until the capture bridge
    // resolves (or we time out).
    final stopwatch = Stopwatch()..start();
    while (!completer.isCompleted &&
        stopwatch.elapsedMilliseconds < timeout.inMilliseconds) {
      try {
        rt.executePendingJob();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    if (!completer.isCompleted) {
      _pendingResults.remove(callId);
      debugPrint('[NuvioRuntime] $scraperId timed out after ${timeout.inSeconds}s');
      return [];
    }

    final body = (await completer.future).trim();
    if (body.isEmpty || body == 'null' || body == 'undefined') return [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('[NuvioRuntime] result parse failed for $scraperId: $e\n$body');
      return [];
    }
  }

  void dispose() {
    for (final t in _activeTimers.values) {
      try {
        t.cancel();
      } catch (_) {}
    }
    _activeTimers.clear();
    for (final c in _activeFetches.values) {
      try {
        c.close();
      } catch (_) {}
    }
    _activeFetches.clear();
    try {
      _http.close();
    } catch (_) {}
    _runtime?.dispose();
    _runtime = null;
    _ready = false;
    _loadedScraperIds.clear();
    _initCompleter = null;
  }

  // ─── fetch implementation ──────────────────────────────────────────────

  Future<void> _dispatchFetch({
    required int id,
    required String url,
    required String method,
    required Map<String, String> headers,
    required String body,
  }) async {
    Map<String, dynamic> envelope;
    try {
      // Default UA — many CDNs reject the empty/Dart UA.
      headers.putIfAbsent('User-Agent',
          () => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36');

      final uri = Uri.parse(url);
      final req = http.Request(method, uri);
      req.followRedirects = true;
      req.maxRedirects = 8;
      req.headers.addAll(headers);
      if (body.isNotEmpty &&
          method != 'GET' &&
          method != 'HEAD' &&
          method != 'OPTIONS') {
        req.body = body;
      }

      final streamed = await _http
          .send(req)
          .timeout(const Duration(seconds: 25));
      final bytes = await streamed.stream.toBytes();
      String text;
      try {
        text = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        text = String.fromCharCodes(bytes);
      }
      // Cap response body at 1 MiB to protect QuickJS from absurd payloads.
      const maxLen = 1024 * 1024;
      if (text.length > maxLen) {
        text = text.substring(0, maxLen);
      }
      final respHeaders = <String, dynamic>{};
      streamed.headers.forEach((k, v) => respHeaders[k.toLowerCase()] = v);
      envelope = {
        'ok': streamed.statusCode >= 200 && streamed.statusCode < 300,
        'status': streamed.statusCode,
        'statusText': streamed.reasonPhrase ?? '',
        'url': streamed.request?.url.toString() ?? url,
        'body': text,
        'headers': respHeaders,
      };
    } catch (e) {
      envelope = {
        'ok': false,
        'status': 0,
        'statusText': e.toString(),
        'url': url,
        'body': '',
        'headers': <String, dynamic>{},
      };
    }
    _resolveFetch(id, envelope);
  }

  void _resolveFetch(int id, Map<String, dynamic> envelope) {
    final rt = _runtime;
    if (rt == null) return;
    // Embed the envelope as a JS object literal — jsonEncode produces
    // a valid JS expression for any JSON-encodable value.
    final js =
        'try { globalThis.__nuvioFetchResolve($id, ${jsonEncode(envelope)}); } catch (e) {}';
    try {
      rt.evaluate(js, sourceUrl: 'nuvio://fetch-resolve/$id');
    } catch (_) {}
  }

  // ─── crypto helpers (Dart side) ────────────────────────────────────────

  String _digestHex(String algo, String utf8Str) {
    final bytes = utf8.encode(utf8Str);
    final hash = _hashFor(algo).convert(bytes);
    return hash.toString();
  }

  String _hmacHex(String algo, String key, String data) {
    final h = dart_crypto.Hmac(_hashFor(algo), utf8.encode(key));
    return h.convert(utf8.encode(data)).toString();
  }

  dart_crypto.Hash _hashFor(String algo) {
    switch (algo.toUpperCase()) {
      case 'MD5':
        return dart_crypto.md5;
      case 'SHA1':
        return dart_crypto.sha1;
      case 'SHA512':
        return dart_crypto.sha512;
      case 'SHA256':
      default:
        return dart_crypto.sha256;
    }
  }

  // ─── url parser ────────────────────────────────────────────────────────

  Map<String, dynamic> _parseUrl(String input) {
    try {
      final u = Uri.parse(input);
      final scheme = u.scheme.isEmpty ? 'https' : u.scheme;
      final host = u.host;
      final port = u.hasPort ? u.port.toString() : '';
      final search = u.query.isEmpty ? '' : '?${u.query}';
      final fragment = u.fragment.isEmpty ? '' : '#${u.fragment}';
      final pathname = u.path.isEmpty ? '/' : u.path;
      return {
        'protocol': '$scheme:',
        'host': port.isEmpty ? host : '$host:$port',
        'hostname': host,
        'port': port,
        'pathname': pathname,
        'search': search,
        'hash': fragment,
      };
    } catch (_) {
      return _emptyUrlParts();
    }
  }

  Map<String, dynamic> _emptyUrlParts() => {
        'protocol': '',
        'host': '',
        'hostname': '',
        'port': '',
        'pathname': '/',
        'search': '',
        'hash': '',
      };
}

// ──────────────────────────────────────────────────────────────────────────
// Polyfill JS — kept as a single string literal for atomic install.
// Mirrors the `buildPolyfillCode` in NuvioMedia/NuvioMobile's
// `PluginRuntime.kt` and adds `__native_fetch` glue + the cheerio shim.
// ──────────────────────────────────────────────────────────────────────────
const String _polyfillsJs = r'''
(function(){
  // ── globals ─────────────────────────────────────────────────────────────
  if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
  if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
  if (typeof globalThis.self   === 'undefined') globalThis.self   = globalThis;

  // ── console (route through native bridge) ───────────────────────────────
  function _stringifyArgs(args){
    try {
      return Array.prototype.slice.call(args).map(function(a){
        if (a == null) return String(a);
        if (typeof a === 'string') return a;
        try { return JSON.stringify(a); } catch (e) { return String(a); }
      }).join(' ');
    } catch (e) { return ''; }
  }
  function _send(level, args){
    try { sendMessage('NuvioConsole', JSON.stringify({level: level, msg: _stringifyArgs(args)})); } catch (e) {}
  }
  globalThis.console = {
    log:   function(){ _send('log',   arguments); },
    info:  function(){ _send('info',  arguments); },
    warn:  function(){ _send('warn',  arguments); },
    error: function(){ _send('err',   arguments); },
    debug: function(){ _send('log',   arguments); },
    trace: function(){ _send('log',   arguments); },
  };

  // ── ES2019+ shims ──────────────────────────────────────────────────────
  if (!Array.prototype.flat) {
    Array.prototype.flat = function(depth){
      depth = depth === undefined ? 1 : Math.floor(depth);
      if (depth < 1) return Array.prototype.slice.call(this);
      return (function flatten(arr, d){
        return d > 0
          ? arr.reduce(function(acc, val){ return acc.concat(Array.isArray(val) ? flatten(val, d-1) : val); }, [])
          : arr.slice();
      })(this, depth);
    };
  }
  if (!Array.prototype.flatMap) {
    Array.prototype.flatMap = function(cb, thisArg){ return this.map(cb, thisArg).flat(); };
  }
  if (!Object.entries) {
    Object.entries = function(o){
      var r = [];
      for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) r.push([k, o[k]]);
      return r;
    };
  }
  if (!Object.fromEntries) {
    Object.fromEntries = function(entries){
      var r = {};
      for (var i = 0; i < entries.length; i++) r[entries[i][0]] = entries[i][1];
      return r;
    };
  }
  if (!String.prototype.replaceAll) {
    String.prototype.replaceAll = function(s, r){
      if (s instanceof RegExp) {
        if (!s.global) throw new TypeError('replaceAll must be called with a global RegExp');
        return this.replace(s, r);
      }
      return this.split(s).join(r);
    };
  }

  // ── atob / btoa ────────────────────────────────────────────────────────
  var _b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  if (typeof atob === 'undefined') {
    globalThis.atob = function(input){
      var str = String(input).replace(/=+$/, '');
      if (str.length % 4 === 1) throw new Error('InvalidCharacterError');
      var output = '', bc = 0, bs = 0, buffer, idx = 0;
      while ((buffer = str.charAt(idx++))) {
        buffer = _b64Chars.indexOf(buffer);
        if (buffer === -1) continue;
        bs = bc % 4 ? bs * 64 + buffer : buffer;
        if (bc++ % 4) output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
      }
      return output;
    };
  }
  if (typeof btoa === 'undefined') {
    globalThis.btoa = function(input){
      var str = String(input), output = '', map = _b64Chars, block, charCode, idx = 0;
      for (; str.charAt(idx | 0) || (map = '=', idx % 1);
           output += map.charAt(63 & (block >> (8 - (idx % 1) * 8)))) {
        charCode = str.charCodeAt(idx += 3 / 4);
        if (charCode > 0xFF) throw new Error('InvalidCharacterError');
        block = (block << 8) | charCode;
      }
      return output;
    };
  }

  // ── AbortController / AbortSignal ──────────────────────────────────────
  if (typeof AbortSignal === 'undefined') {
    var AbortSignal = function(){ this.aborted = false; this.reason = undefined; this._listeners = []; };
    AbortSignal.prototype.addEventListener = function(t, l){ if (t === 'abort' && typeof l === 'function') this._listeners.push(l); };
    AbortSignal.prototype.removeEventListener = function(t, l){ if (t === 'abort') this._listeners = this._listeners.filter(function(x){ return x !== l; }); };
    AbortSignal.prototype.dispatchEvent = function(ev){
      if (!ev || ev.type !== 'abort') return true;
      for (var i = 0; i < this._listeners.length; i++) { try { this._listeners[i].call(this, ev); } catch (e) {} }
      return true;
    };
    globalThis.AbortSignal = AbortSignal;
  }
  if (typeof AbortController === 'undefined') {
    var AbortController = function(){ this.signal = new AbortSignal(); };
    AbortController.prototype.abort = function(reason){
      if (this.signal.aborted) return;
      this.signal.aborted = true;
      this.signal.reason = reason;
      this.signal.dispatchEvent({ type: 'abort' });
    };
    globalThis.AbortController = AbortController;
  }

  // ── URL / URLSearchParams ──────────────────────────────────────────────
  globalThis.URLSearchParams = function(init){
    this._params = {};
    var self = this;
    if (init && typeof init === 'object' && !Array.isArray(init)) {
      Object.keys(init).forEach(function(k){ self._params[k] = String(init[k]); });
    } else if (typeof init === 'string') {
      init.replace(/^\?/, '').split('&').forEach(function(pair){
        if (!pair) return;
        var i = pair.indexOf('=');
        var k = i < 0 ? pair : pair.substring(0, i);
        var v = i < 0 ? '' : pair.substring(i + 1);
        try { self._params[decodeURIComponent(k)] = decodeURIComponent(v); }
        catch (e) { self._params[k] = v; }
      });
    }
  };
  globalThis.URLSearchParams.prototype.toString = function(){
    var self = this;
    return Object.keys(this._params).map(function(k){
      return encodeURIComponent(k) + '=' + encodeURIComponent(self._params[k]);
    }).join('&');
  };
  globalThis.URLSearchParams.prototype.get    = function(k){ return Object.prototype.hasOwnProperty.call(this._params, k) ? this._params[k] : null; };
  globalThis.URLSearchParams.prototype.set    = function(k, v){ this._params[k] = String(v); };
  globalThis.URLSearchParams.prototype.append = function(k, v){ this._params[k] = String(v); };
  globalThis.URLSearchParams.prototype.has    = function(k){ return Object.prototype.hasOwnProperty.call(this._params, k); };
  globalThis.URLSearchParams.prototype.delete = function(k){ delete this._params[k]; };
  globalThis.URLSearchParams.prototype.keys   = function(){ return Object.keys(this._params); };
  globalThis.URLSearchParams.prototype.values = function(){ var s = this; return Object.keys(this._params).map(function(k){ return s._params[k]; }); };
  globalThis.URLSearchParams.prototype.entries = function(){ var s = this; return Object.keys(this._params).map(function(k){ return [k, s._params[k]]; }); };
  globalThis.URLSearchParams.prototype.forEach = function(cb){ var s = this; Object.keys(this._params).forEach(function(k){ cb(s._params[k], k, s); }); };
  globalThis.URLSearchParams.prototype.getAll  = function(k){ return Object.prototype.hasOwnProperty.call(this._params, k) ? [this._params[k]] : []; };
  globalThis.URLSearchParams.prototype.sort    = function(){ var s = {}; var t = this; Object.keys(this._params).sort().forEach(function(k){ s[k] = t._params[k]; }); this._params = s; };

  globalThis.URL = function(urlString, base){
    var fullUrl = urlString;
    if (base && !/^[a-z][a-z0-9+\-.]*:\/\//i.test(urlString)) {
      var b = typeof base === 'string' ? base : base.href;
      if (urlString.charAt(0) === '/') {
        var m = b.match(/^([a-z][a-z0-9+\-.]*:\/\/[^\/]+)/i);
        fullUrl = m ? m[1] + urlString : urlString;
      } else {
        fullUrl = b.replace(/\/[^\/]*$/, '/') + urlString;
      }
    }
    var data = sendMessage('NuvioParseUrl', JSON.stringify({url: fullUrl}));
    this.href = fullUrl;
    this.protocol = data.protocol;
    this.host = data.host;
    this.hostname = data.hostname;
    this.port = data.port;
    this.pathname = data.pathname;
    this.search = data.search;
    this.hash = data.hash;
    this.origin = data.protocol + '//' + data.host;
    this.searchParams = new URLSearchParams(data.search || '');
  };
  globalThis.URL.prototype.toString = function(){ return this.href; };

  // ── CommonJS shim + scraper registry ───────────────────────────────────
  globalThis.__nuvioRegistry = globalThis.__nuvioRegistry || {};
  globalThis.__nuvioModules  = globalThis.__nuvioModules  || {};

  globalThis.__nuvioRequire = function(name){
    var mods = globalThis.__nuvioModules || {};
    if (mods[name]) return mods[name];
    if (name === 'cheerio' || name === 'cheerio-without-node-native' || name === 'react-native-cheerio') {
      return mods['cheerio'] || mods['cheerio-without-node-native'] || mods['react-native-cheerio'] || {};
    }
    if (name === 'crypto-js') return globalThis.CryptoJS;
    throw new Error("Module '" + name + "' is not available in NuvioRuntime");
  };

  // ── async fetch (Dart-backed) ──────────────────────────────────────────
  globalThis.__nuvioFetchPending = {};
  globalThis.__nuvioFetchSeq     = 0;
  globalThis.__nuvioFetchResolve = function(id, envelope){
    var p = globalThis.__nuvioFetchPending[id];
    if (p) { delete globalThis.__nuvioFetchPending[id]; p(envelope); }
  };
  globalThis.fetch = function(url, options){
    options = options || {};
    var method  = (options.method || 'GET').toString().toUpperCase();
    var headers = options.headers || {};
    if (headers && typeof headers.entries === 'function' && !Array.isArray(headers)) {
      // Headers-like object
      var flat = {};
      try {
        var arr = Array.from(headers.entries());
        for (var i = 0; i < arr.length; i++) flat[arr[i][0]] = arr[i][1];
      } catch (e) {}
      headers = flat;
    }
    var bodyOut = '';
    if (options.body != null) {
      if (typeof options.body === 'string') bodyOut = options.body;
      else if (typeof options.body === 'object') {
        try { bodyOut = JSON.stringify(options.body); } catch (e) { bodyOut = String(options.body); }
      } else bodyOut = String(options.body);
    }
    return new Promise(function(resolve){
      var id = ++globalThis.__nuvioFetchSeq;
      globalThis.__nuvioFetchPending[id] = function(env){
        // Build a Response-shaped object compatible with what the
        // community scrapers expect.
        var lowered = {};
        if (env.headers) for (var k in env.headers) if (Object.prototype.hasOwnProperty.call(env.headers, k)) lowered[String(k).toLowerCase()] = String(env.headers[k]);
        var body = env.body == null ? '' : String(env.body);
        resolve({
          ok: !!env.ok,
          status: env.status | 0,
          statusText: env.statusText || '',
          url: env.url || url,
          headers: {
            get: function(name){ return lowered[String(name).toLowerCase()] || null; },
            has: function(name){ return Object.prototype.hasOwnProperty.call(lowered, String(name).toLowerCase()); },
            forEach: function(cb){ Object.keys(lowered).forEach(function(k){ cb(lowered[k], k); }); },
            entries: function(){ return Object.keys(lowered).map(function(k){ return [k, lowered[k]]; }); },
            keys: function(){ return Object.keys(lowered); },
            values: function(){ return Object.keys(lowered).map(function(k){ return lowered[k]; }); }
          },
          text: function(){ return Promise.resolve(body); },
          json: function(){
            try {
              if (!body) return Promise.resolve(null);
              return Promise.resolve(JSON.parse(body));
            } catch (e) { return Promise.resolve(null); }
          },
          arrayBuffer: function(){
            // Minimal stub: returns the bytes as a Uint8Array buffer.
            var len = body.length, buf = new ArrayBuffer(len), view = new Uint8Array(buf);
            for (var i = 0; i < len; i++) view[i] = body.charCodeAt(i) & 0xff;
            return Promise.resolve(buf);
          },
          blob: function(){ return Promise.resolve({ size: body.length, type: lowered['content-type'] || '', text: function(){ return Promise.resolve(body); } }); },
          clone: function(){ return this; }
        });
      };
      sendMessage('NuvioFetchStart', JSON.stringify({
        id: id, url: String(url), method: method, headers: headers, body: bodyOut
      }));
    });
  };

  // Minimal XMLHttpRequest shim — built on top of fetch — so any scraper
  // using the older API still works.
  globalThis.XMLHttpRequest = function(){
    this.readyState = 0;
    this.status = 0;
    this.statusText = '';
    this.responseText = '';
    this.response = '';
    this._headers = {};
    this._method = 'GET';
    this._url = '';
    this.onreadystatechange = null;
    this.onload = null;
    this.onerror = null;
  };
  globalThis.XMLHttpRequest.prototype.open = function(method, url){
    this._method = String(method || 'GET').toUpperCase();
    this._url = String(url);
    this.readyState = 1;
  };
  globalThis.XMLHttpRequest.prototype.setRequestHeader = function(k, v){ this._headers[k] = v; };
  globalThis.XMLHttpRequest.prototype.getResponseHeader = function(k){ return (this._respHeaders || {})[String(k).toLowerCase()] || null; };
  globalThis.XMLHttpRequest.prototype.send = function(body){
    var self = this;
    fetch(self._url, { method: self._method, headers: self._headers, body: body || '' })
      .then(function(r){
        self.status = r.status;
        self.statusText = r.statusText;
        self._respHeaders = {};
        try { r.headers.forEach(function(v, k){ self._respHeaders[k] = v; }); } catch (e) {}
        return r.text().then(function(t){
          self.responseText = t;
          self.response = t;
          self.readyState = 4;
          if (typeof self.onreadystatechange === 'function') { try { self.onreadystatechange(); } catch (e) {} }
          if (typeof self.onload === 'function') { try { self.onload(); } catch (e) {} }
        });
      })
      .catch(function(e){
        self.status = 0;
        self.readyState = 4;
        if (typeof self.onerror === 'function') { try { self.onerror(e); } catch (_) {} }
      });
  };

  // ── timers (Dart-backed) ───────────────────────────────────────────────
  globalThis.__nuvioTimers = globalThis.__nuvioTimers || {};
  globalThis.__nuvioTimerFire = function(id){
    var entry = globalThis.__nuvioTimers[id];
    if (!entry) return;
    if (!entry.repeat) delete globalThis.__nuvioTimers[id];
    try { entry.fn.apply(null, entry.args); } catch (e) {
      try { sendMessage('NuvioConsole', JSON.stringify({level:'err', msg: '[timer] ' + (e && e.message ? e.message : e)})); } catch(_) {}
    }
  };
  globalThis.setTimeout = function(fn, ms){
    var args = Array.prototype.slice.call(arguments, 2);
    var id = sendMessage('NuvioTimerSchedule', JSON.stringify({ms: ms|0, repeat: false}));
    globalThis.__nuvioTimers[id] = { fn: typeof fn === 'function' ? fn : function(){ try { eval(String(fn)); } catch(_){} }, args: args, repeat: false };
    return id;
  };
  globalThis.setInterval = function(fn, ms){
    var args = Array.prototype.slice.call(arguments, 2);
    var id = sendMessage('NuvioTimerSchedule', JSON.stringify({ms: ms|0, repeat: true}));
    globalThis.__nuvioTimers[id] = { fn: typeof fn === 'function' ? fn : function(){ try { eval(String(fn)); } catch(_){} }, args: args, repeat: true };
    return id;
  };
  globalThis.clearTimeout = function(id){
    if (id == null) return;
    delete globalThis.__nuvioTimers[id];
    try { sendMessage('NuvioTimerCancel', JSON.stringify({id: id|0})); } catch(_) {}
  };
  globalThis.clearInterval = globalThis.clearTimeout;
  // queueMicrotask shim (uses Promise.resolve)
  if (typeof globalThis.queueMicrotask === 'undefined') {
    globalThis.queueMicrotask = function(cb){ Promise.resolve().then(cb); };
  }

  // ── axios shim (built on top of fetch) ─────────────────────────────────
  function _axiosCore(config){
    config = config || {};
    var url = config.url;
    if (config.baseURL && !/^[a-z][a-z0-9+\-.]*:\/\//i.test(url || '')) {
      url = String(config.baseURL).replace(/\/$/, '') + '/' + String(url || '').replace(/^\//, '');
    }
    if (config.params) {
      var qs = new URLSearchParams(config.params).toString();
      if (qs) url += (url.indexOf('?') >= 0 ? '&' : '?') + qs;
    }
    var method = (config.method || 'GET').toString().toUpperCase();
    var headers = Object.assign({}, config.headers || {});
    var body;
    if (config.data != null) {
      if (typeof config.data === 'string') body = config.data;
      else {
        body = JSON.stringify(config.data);
        if (!headers['Content-Type'] && !headers['content-type']) headers['Content-Type'] = 'application/json';
      }
    }
    return fetch(url, { method: method, headers: headers, body: body }).then(function(res){
      return res.text().then(function(text){
        var data = text;
        var ct = (res.headers.get('content-type') || '').toLowerCase();
        var wantJson = config.responseType === 'json' || ct.indexOf('application/json') >= 0 || ct.indexOf('+json') >= 0;
        if (wantJson) { try { data = JSON.parse(text); } catch(_) { /* keep text */ } }
        var headersOut = {};
        try { res.headers.forEach(function(v, k){ headersOut[k] = v; }); } catch(_) {}
        var resp = { data: data, status: res.status, statusText: res.statusText, headers: headersOut, config: config, request: null };
        var validate = config.validateStatus || function(s){ return s >= 200 && s < 300; };
        if (!validate(res.status)) {
          var err = new Error('Request failed with status code ' + res.status);
          err.response = resp; err.config = config; err.isAxiosError = true;
          throw err;
        }
        return resp;
      });
    });
  }
  function _axiosWith(method){
    return function(url, dataOrConfig, maybeConfig){
      var hasBody = method === 'POST' || method === 'PUT' || method === 'PATCH';
      if (hasBody) {
        var cfg = Object.assign({}, maybeConfig || {}, { url: url, method: method, data: dataOrConfig });
        return _axiosCore(cfg);
      } else {
        var cfg2 = Object.assign({}, dataOrConfig || {}, { url: url, method: method });
        return _axiosCore(cfg2);
      }
    };
  }
  function _makeAxios(defaults){
    var fn = function(arg1, arg2){
      if (typeof arg1 === 'string') return _axiosCore(Object.assign({}, defaults, arg2 || {}, { url: arg1 }));
      return _axiosCore(Object.assign({}, defaults, arg1 || {}));
    };
    fn.defaults = Object.assign({ headers: {} }, defaults || {});
    fn.get     = _axiosWith('GET');
    fn.delete  = _axiosWith('DELETE');
    fn.head    = _axiosWith('HEAD');
    fn.options = _axiosWith('OPTIONS');
    fn.post    = _axiosWith('POST');
    fn.put     = _axiosWith('PUT');
    fn.patch   = _axiosWith('PATCH');
    fn.request = _axiosCore;
    fn.create  = function(d){ return _makeAxios(Object.assign({}, defaults || {}, d || {})); };
    fn.isAxiosError = function(e){ return !!(e && e.isAxiosError); };
    fn.interceptors = { request: { use: function(){ return 0; }, eject: function(){} }, response: { use: function(){ return 0; }, eject: function(){} } };
    fn.CancelToken = function(executor){ this.promise = new Promise(function(){}); if (typeof executor === 'function') executor(function(){}); };
    fn.isCancel = function(){ return false; };
    return fn;
  }
  globalThis.axios = _makeAxios();
  globalThis.__nuvioModules['axios'] = globalThis.axios;

  // ── CryptoJS façade (Dart-backed) ──────────────────────────────────────
  function _hexToWords(hex){
    var w = [];
    for (var i = 0; i < hex.length; i += 8) {
      var c = hex.substring(i, i + 8);
      while (c.length < 8) c += '0';
      w.push(parseInt(c, 16) | 0);
    }
    return w;
  }
  function _wordsToHex(words, sigBytes){
    var hex = '';
    for (var i = 0; i < sigBytes; i++) {
      var w = words[i >>> 2] || 0;
      var b = (w >>> (24 - (i % 4) * 8)) & 0xff;
      var p = b.toString(16); if (p.length < 2) p = '0' + p;
      hex += p;
    }
    return hex;
  }
  function _waToHex(v){
    if (!v) return '';
    if (typeof v.__hex === 'string') return v.__hex.toLowerCase();
    if (Array.isArray(v.words) && typeof v.sigBytes === 'number') return _wordsToHex(v.words, v.sigBytes);
    return sendMessage('NuvioCryptoUtf8ToHex', JSON.stringify({data: String(v)}));
  }
  function _waBuild(hex, utf8Override){
    var nh = (hex || '').toLowerCase();
    if (nh.length % 2 !== 0) nh = '0' + nh;
    var wa = {
      __hex: nh,
      __utf8: utf8Override !== undefined ? utf8Override : sendMessage('NuvioCryptoHexToUtf8', JSON.stringify({data: nh})),
      sigBytes: nh.length / 2,
      words: _hexToWords(nh),
      toString: function(enc){
        if (!enc || enc === CryptoJS.enc.Hex) return this.__hex;
        if (enc === CryptoJS.enc.Utf8) return this.__utf8;
        if (enc === CryptoJS.enc.Base64) return sendMessage('NuvioCryptoB64Enc', JSON.stringify({data: this.__utf8}));
        return this.__hex;
      },
      clamp: function(){ return this; },
      concat: function(o){
        var oh = _waToHex(o);
        this.__hex += oh;
        this.__utf8 = sendMessage('NuvioCryptoHexToUtf8', JSON.stringify({data: this.__hex}));
        this.sigBytes = this.__hex.length / 2;
        this.words = _hexToWords(this.__hex);
        return this;
      }
    };
    return wa;
  }
  function _waFromHex(h){ return _waBuild(h, undefined); }
  function _waFromUtf8(t){
    var s = (t == null) ? '' : String(t);
    return _waBuild(sendMessage('NuvioCryptoUtf8ToHex', JSON.stringify({data: s})), s);
  }
  function _waFromBase64(b){
    return _waFromUtf8(sendMessage('NuvioCryptoB64Dec', JSON.stringify({data: (b || '')})));
  }
  function _normInput(v){
    if (v && typeof v === 'object' && typeof v.__utf8 === 'string') return v.__utf8;
    if (v && typeof v === 'object' && typeof v.__hex  === 'string') return sendMessage('NuvioCryptoHexToUtf8', JSON.stringify({data: v.__hex}));
    if (v && typeof v === 'object' && Array.isArray(v.words) && typeof v.sigBytes === 'number') return sendMessage('NuvioCryptoHexToUtf8', JSON.stringify({data: _wordsToHex(v.words, v.sigBytes)}));
    if (v == null) return '';
    return String(v);
  }
  function _hashWa(algo, msg){
    var hex = sendMessage('NuvioCryptoDigest', JSON.stringify({algo: algo, data: _normInput(msg)}));
    return _waFromHex(hex);
  }
  function _hmacWa(algo, msg, key){
    var hex = sendMessage('NuvioCryptoHmac', JSON.stringify({algo: algo, key: _normInput(key), data: _normInput(msg)}));
    return _waFromHex(hex);
  }

  var CryptoJS = {
    enc: {
      Hex: {
        stringify: function(wa){ return _waToHex(wa); },
        parse: function(h){ return _waFromHex(h || ''); }
      },
      Utf8: {
        stringify: function(wa){
          if (wa && typeof wa.__utf8 === 'string') return wa.__utf8;
          if (wa && typeof wa.__hex  === 'string') return sendMessage('NuvioCryptoHexToUtf8', JSON.stringify({data: wa.__hex}));
          return _normInput(wa);
        },
        parse: function(t){ return _waFromUtf8(t); }
      },
      Base64: {
        stringify: function(wa){
          if (wa && typeof wa.__utf8 === 'string') return sendMessage('NuvioCryptoB64Enc', JSON.stringify({data: wa.__utf8}));
          return sendMessage('NuvioCryptoB64Enc', JSON.stringify({data: _normInput(wa)}));
        },
        parse: function(b){ return _waFromBase64(b); }
      },
      Latin1: {
        stringify: function(wa){ return _normInput(wa); },
        parse: function(t){ return _waFromUtf8(t); }
      }
    },
    MD5:    function(m){ return _hashWa('MD5',    m); },
    SHA1:   function(m){ return _hashWa('SHA1',   m); },
    SHA256: function(m){ return _hashWa('SHA256', m); },
    SHA512: function(m){ return _hashWa('SHA512', m); },
    HmacMD5:    function(m, k){ return _hmacWa('MD5',    m, k); },
    HmacSHA1:   function(m, k){ return _hmacWa('SHA1',   m, k); },
    HmacSHA256: function(m, k){ return _hmacWa('SHA256', m, k); },
    HmacSHA512: function(m, k){ return _hmacWa('SHA512', m, k); }
  };
  globalThis.CryptoJS = CryptoJS;

  // Default per-call context — overwritten per scrape.
  globalThis.SCRAPER_ID = '';
  globalThis.SCRAPER_SETTINGS = {};
})();
''';
