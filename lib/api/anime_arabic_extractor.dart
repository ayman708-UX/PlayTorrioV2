// ─────────────────────────────────────────────────────────────────────────
// AnimeSlayer (animeslayer.to) FULLY-NATIVE extractor.
//
// Replicates the page's obfuscated AJAX flow in pure Dart — no WebView,
// no JS engine, no headless browser. Same code path the site itself
// uses, just lifted out of obfuscation:
//
//   1. GET https://patrimoines-en-mouvement.org/lib/flare/v3.php
//        → { first: <apiFirstUrl>, sec: <apiSecUrl> }
//   2. POST apiFirst   pe=<lastSeg>&hash=<frag>
//        → { a, b, c, d, … }
//   3. POST apiSec     keyn=<d>&name=…&pe=<c>&bool=no&id=<a>&info=<b>
//                       &san=…&mwsem=…
//        → { servers: { wit:enc, rift:enc, … }, auto, data }
//      Each value is XOR(base64) with key `AQWXZSCED@@POIUYTRR159`.
//   4. Each decrypted URL is a player iframe (p_wit.php, v3rb.php, …)
//      whose HTML contains
//      `var videos = [{ src: 'http…mp4', label: …, res: … }]`.
//      We GET the iframe, regex-extract every `src:` entry, and return
//      one `StreamSource` per (server × quality) tuple.
//
// flare config + first-call response are cached (10-minute TTL) so
// re-watch / next-episode flows don't hammer the upstream every time.
// ─────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/stream_source.dart';
import '../services/mega_proxy.dart';
import 'anime_arabic_service.dart';

/// One server slug + the iframe URL the page would have embedded.
class ArabicResolvedServer {
  final String name;
  final String displayName;
  final String iframeUrl;

  const ArabicResolvedServer({
    required this.name,
    required this.displayName,
    required this.iframeUrl,
  });
}

/// One playable variant scraped from a server iframe.
class ArabicResolvedStream {
  final ArabicResolvedServer server;
  final String url;
  final String quality; // "1080p" / "720p" / "" (raw label from iframe)
  final String type;    // "hls" | "video"
  final Map<String, String> headers;

  const ArabicResolvedStream({
    required this.server,
    required this.url,
    required this.quality,
    required this.type,
    required this.headers,
  });
}

class AnimeArabicExtractor {
  // ─── Constants pulled directly from ep.html ─────────────────────────
  static const String _flareUrl =
      'https://patrimoines-en-mouvement.org/lib/flare/v3.php';
  static const String _xorKey = 'AQWXZSCED@@POIUYTRR159';

  /// Fallback constants — used only if the live page parse fails.
  /// The real values are show-specific and parsed at runtime from the
  /// `/e/<slug>#<frag>` page (`const name = "..."`, etc.). Hard-coding
  /// these to a single show's values caused most episodes to return
  /// `servers: []` from the upstream API.
  static const String _fallbackName =
      'KwQdDUVLRBELIQgCEhY=';
  static const String _fallbackBool = 'no';
  static const String _fallbackSan =
      'KwQdDUVLRBELIQgCEhY=';
  static const String _fallbackMwsem =
      'U29yY2VyeSBGaWdodCxKdWp1dHN1IEthaXNlbixKSks=';

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

  /// Friendly labels for server slugs the page exposes.
  static const Map<String, String> _displayNames = {
    'wit': 'Zen-2',
    'rift': 'Zen',
    'riftv2': 'Zen V2',
    'shof': 'Shof',
    'blkom': 'Blkom',
    'animeify': 'Animeify',
    'topcinema': 'TopCinema',
    'kuudere': 'Kuudere',
  };

  // ─── Module-level cache for flare config ────────────────────────────
  static String? _cachedApiFirst;
  static String? _cachedApiSec;
  static DateTime? _flareCachedAt;
  static const Duration _flareTtl = Duration(minutes: 10);

  // ────────────────────────────────────────────────────────────────────
  // PUBLIC ENTRY POINT
  // ────────────────────────────────────────────────────────────────────
  Future<List<ArabicResolvedStream>> resolveEpisode(
    ArabicEpisode episode, {
    Duration discoverTimeout = const Duration(seconds: 25),
    Duration sniffTimeout = const Duration(seconds: 25),
    Duration graceWindow = const Duration(seconds: 4),
    void Function(String phase, String detail)? onProgress,
  }) async {
    onProgress?.call('discover', 'Cracking server map…');

    final servers = await discoverServers(
      episode,
      timeout: discoverTimeout,
      onProgress: onProgress,
    );
    if (servers.isEmpty) {
      onProgress?.call('error', 'No servers exposed by API');
      return const [];
    }

    onProgress?.call(
      'sniff',
      '${servers.length} server(s): ${servers.map((s) => s.name).join(', ')}',
    );

    return _scrapeAll(
      servers,
      timeout: sniffTimeout,
      graceWindow: graceWindow,
      onProgress: onProgress,
    );
  }

  // ────────────────────────────────────────────────────────────────────
  // STAGE 1 — Native flare → first → sec → decrypt
  // ────────────────────────────────────────────────────────────────────
  Future<List<ArabicResolvedServer>> discoverServers(
    ArabicEpisode episode, {
    Duration timeout = const Duration(seconds: 25),
    void Function(String phase, String detail)? onProgress,
  }) async {
    final client = HttpClient()
      ..userAgent = _userAgent
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      // 0. Parse pe (last hyphen seg of pathname) and hash (URL fragment).
      final watchPath = episode.watchPath; // e.g. /e/some-slug-XYZ#tok
      final hashIdx = watchPath.indexOf('#');
      final path = hashIdx >= 0 ? watchPath.substring(0, hashIdx) : watchPath;
      final frag = hashIdx >= 0 ? watchPath.substring(hashIdx + 1) : '';
      if (frag.isEmpty) {
        onProgress?.call('error', 'Episode missing hash token');
        return const [];
      }
      final segs = path.split('-');
      final pe = segs.length > 1 ? segs.last : '';
      if (pe.isEmpty) {
        onProgress?.call('error', 'Episode missing pe segment');
        return const [];
      }

      // 1. Flare config (cached).
      final flare =
          await _getFlare(client, timeout: timeout, onProgress: onProgress);
      if (flare == null) return const [];
      final apiFirst = flare.$1;
      final apiSec = flare.$2;

      // 1b. Pull the show-specific request constants from the live /e/ page.
      // The site declares `const name`, `const san`, `const mwsem`, `const bool`
      // inline in the page — and they differ per show. Hard-coding one
      // show's values caused upstream to return `servers: []` for every
      // other show.
      String name = _fallbackName;
      String san = _fallbackSan;
      String mwsem = _fallbackMwsem;
      String boolStr = _fallbackBool;
      try {
        final pageHtml = await _get(
          client,
          '${AnimeArabicService.baseUrl}$path',
        ).timeout(timeout);
        String? pluck(String key) {
          final re = RegExp(
            'const\\s+$key\\s*=\\s*"([^"]*)"',
          );
          final m = re.firstMatch(pageHtml);
          return m?.group(1);
        }
        final n = pluck('name');
        final s = pluck('san');
        final m = pluck('mwsem');
        final b = pluck('bool');
        if (n != null && n.isNotEmpty) name = n;
        if (s != null && s.isNotEmpty) san = s;
        if (m != null && m.isNotEmpty) mwsem = m;
        if (b != null && b.isNotEmpty) boolStr = b;
      } catch (e) {
        debugPrint(
            '[ArabicExtractor] page-token parse failed, using fallback: $e');
      }

      // 2. First call.
      onProgress?.call('discover', 'Handshake…');
      final r1 = await _post(
        client,
        apiFirst,
        body: 'pe=${Uri.encodeComponent(pe)}'
            '&hash=${Uri.encodeComponent(frag)}',
      ).timeout(timeout);
      Map<String, dynamic> j1;
      try {
        j1 = jsonDecode(r1) as Map<String, dynamic>;
      } catch (e) {
        onProgress?.call('error', 'apiFirst returned non-JSON');
        debugPrint('[ArabicExtractor] apiFirst body=$r1');
        return const [];
      }
      final aid = j1['a']?.toString() ?? '';
      final binfo = j1['b']?.toString() ?? '';
      final cep = j1['c']?.toString() ?? '';
      final dkeyn = j1['d']?.toString() ?? '';
      if (dkeyn.isEmpty || aid.isEmpty || binfo.isEmpty) {
        onProgress?.call(
          'error',
          'apiFirst missing required fields (a/b/d): ${j1.keys.toList()}',
        );
        return const [];
      }

      // 3. Second call.
      onProgress?.call('discover', 'Fetching servers…');
      final secBody = <String, String>{
        'keyn': dkeyn,
        'name': name,
        'pe': cep,
        'bool': boolStr,
        'id': aid,
        'info': binfo,
        'san': san,
        'mwsem': mwsem,
      };
      final secEncoded = secBody.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final r2 = await _post(client, apiSec, body: secEncoded).timeout(timeout);
      Map<String, dynamic> j2;
      try {
        j2 = jsonDecode(r2) as Map<String, dynamic>;
      } catch (_) {
        onProgress?.call('error', 'apiSec returned non-JSON');
        debugPrint('[ArabicExtractor] apiSec body=$r2');
        return const [];
      }

      final rawServers = j2['servers'];
      final servers = <String, dynamic>{};
      if (rawServers is Map) {
        servers.addAll(rawServers.cast<String, dynamic>());
      } else if (rawServers is List) {
        // Some episodes ship `servers` as a list of {name, enc} or {key, value}
        // instead of a keyed map. Coerce both shapes.
        for (var i = 0; i < rawServers.length; i++) {
          final entry = rawServers[i];
          if (entry is Map) {
            final name = (entry['name'] ??
                    entry['key'] ??
                    entry['server'] ??
                    entry['id'])
                ?.toString();
            final enc = (entry['enc'] ??
                    entry['value'] ??
                    entry['url'] ??
                    entry['data'])
                ?.toString();
            if (name != null && enc != null) {
              servers[name] = enc;
            } else if (entry.length == 1) {
              final k = entry.keys.first.toString();
              servers[k] = entry[entry.keys.first]?.toString() ?? '';
            }
          } else if (entry is String) {
            servers['srv$i'] = entry;
          }
        }
      }
      if (servers.isEmpty) {
        onProgress?.call('error', 'apiSec returned empty server map');
        debugPrint('[ArabicExtractor] apiSec body=$r2');
        return const [];
      }

      final out = <ArabicResolvedServer>[];
      servers.forEach((name, enc) {
        final encStr = enc?.toString() ?? '';
        if (encStr.isEmpty) return;
        final url = decryptXorBase64(encStr);
        if (url == null || !url.startsWith('http')) return;
        out.add(ArabicResolvedServer(
          name: name,
          displayName: _displayNames[name] ?? _titleCase(name),
          iframeUrl: url,
        ));
      });

      return out;
    } catch (e, st) {
      debugPrint('[ArabicExtractor] discoverServers error: $e\n$st');
      onProgress?.call('error', 'Discover failed: $e');
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // STAGE 2 — Scrape every server iframe in parallel, race for the
  // fastest hit, keep the rest as fallbacks for the in-player switcher.
  // ────────────────────────────────────────────────────────────────────
  Future<List<ArabicResolvedStream>> _scrapeAll(
    List<ArabicResolvedServer> servers, {
    required Duration timeout,
    required Duration graceWindow,
    void Function(String phase, String detail)? onProgress,
  }) async {
    final hits = <ArabicResolvedStream>[];
    final completer = Completer<List<ArabicResolvedStream>>();
    var settled = 0;
    final total = servers.length;
    Timer? grace;

    void finalizeIfDone() {
      if (completer.isCompleted) return;
      if (settled >= total) {
        grace?.cancel();
        completer.complete(List.of(hits));
      }
    }

    for (final s in servers) {
      _scrapeOne(s, timeout: timeout).then((variants) {
        settled++;
        if (variants.isNotEmpty) {
          hits.addAll(variants);
          if (hits.isNotEmpty &&
              !completer.isCompleted &&
              grace == null &&
              settled < total) {
            grace = Timer(graceWindow, () {
              if (!completer.isCompleted) {
                completer.complete(List.of(hits));
              }
            });
          }
        }
        onProgress?.call(
          'sniff',
          '$settled / $total checked · ${hits.length} ready',
        );
        finalizeIfDone();
      }).catchError((e, st) {
        debugPrint('[ArabicExtractor] scrape ${s.name} threw: $e\n$st');
        settled++;
        finalizeIfDone();
      });
    }

    // Hard timeout to make sure we never hang.
    Timer(timeout, () {
      if (!completer.isCompleted) {
        debugPrint(
            '[ArabicExtractor] hard timeout — returning ${hits.length}');
        completer.complete(List.of(hits));
      }
    });

    return completer.future;
  }

  /// Hits one player iframe, parses its `var videos = [...]` and returns
  /// every quality variant.
  Future<List<ArabicResolvedStream>> _scrapeOne(
    ArabicResolvedServer server, {
    required Duration timeout,
  }) async {
    // Mega.nz embeds (animeify) are AES-CTR encrypted; decrypt-on-the-fly
    // through a local loopback proxy so media_kit can consume plain MP4.
    final iframeHost =
        Uri.tryParse(server.iframeUrl)?.host.toLowerCase() ?? '';
    if (iframeHost.contains('mega.nz') || iframeHost.contains('mega.co.nz')) {
      try {
        final mega = await MegaProxy.instance
            .resolve(server.iframeUrl)
            .timeout(timeout);
        if (mega == null) {
          debugPrint('[ArabicExtractor] mega proxy returned null for '
              '${server.name}');
          return const [];
        }
        return [
          ArabicResolvedStream(
            server: server,
            url: mega.url,
            quality: '',
            type: 'video',
            // Loopback proxy serves raw bytes; no upstream headers needed.
            headers: const {},
          ),
        ];
      } catch (e) {
        debugPrint('[ArabicExtractor] mega proxy failed ${server.name}: $e');
        return const [];
      }
    }

    final client = HttpClient()
      ..userAgent = _userAgent
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final html = await _get(
        client,
        server.iframeUrl,
        headers: {
          'Referer': '${AnimeArabicService.baseUrl}/',
          'Accept': 'text/html,*/*',
        },
      ).timeout(timeout);
      return _parseVideos(server, html);
    } catch (e) {
      debugPrint('[ArabicExtractor] scrape ${server.name} failed: $e');
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// Extract every `src: '<url>'` block from the iframe HTML, paired
  /// with the nearest `label` / `res` for quality tagging.
  List<ArabicResolvedStream> _parseVideos(
    ArabicResolvedServer server,
    String html,
  ) {
    final iframeOrigin = Uri.tryParse(server.iframeUrl)?.origin ?? '';
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': '$iframeOrigin/',
      if (iframeOrigin.isNotEmpty) 'Origin': iframeOrigin,
    };

    final out = <ArabicResolvedStream>[];

    // Match each block:  src: '<url>' ... ( label: '...' )?  ( res: '...' )?
    // Quotes can be ' or "; whitespace varies; label/res may be absent.
    final blockRe = RegExp(
      r'''src\s*:\s*['"]([^'"]+)['"](?:[^{}]*?label\s*:\s*['"]([^'"]*)['"])?(?:[^{}]*?res\s*:\s*['"]?([0-9a-zA-Z]+)['"]?)?''',
      multiLine: true,
      dotAll: true,
    );
    final seen = <String>{};
    for (final m in blockRe.allMatches(html)) {
      final url = m.group(1)?.trim() ?? '';
      if (url.isEmpty || !url.startsWith('http')) continue;
      if (!seen.add(url)) continue;
      final label = (m.group(2) ?? '').trim();
      final res = (m.group(3) ?? '').trim();
      final quality =
          label.isNotEmpty ? label : (res.isNotEmpty ? '${res}p' : '');
      final lower = url.toLowerCase();
      final type = lower.contains('.m3u8') ? 'hls' : 'video';
      out.add(ArabicResolvedStream(
        server: server,
        url: url,
        quality: quality,
        type: type,
        headers: headers,
      ));
    }

    // Sort highest quality first inside each server.
    out.sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    return out;
  }

  static int _qualityRank(String q) {
    final m = RegExp(r'(\d{3,4})').firstMatch(q);
    if (m == null) return 0;
    return int.tryParse(m.group(1)!) ?? 0;
  }

  // ────────────────────────────────────────────────────────────────────
  // Helpers — flare config cache + low-level HTTP
  // ────────────────────────────────────────────────────────────────────
  Future<(String, String)?> _getFlare(
    HttpClient client, {
    required Duration timeout,
    void Function(String phase, String detail)? onProgress,
  }) async {
    final now = DateTime.now();
    if (_cachedApiFirst != null &&
        _cachedApiSec != null &&
        _flareCachedAt != null &&
        now.difference(_flareCachedAt!) < _flareTtl) {
      return (_cachedApiFirst!, _cachedApiSec!);
    }
    try {
      final raw = await _get(client, _flareUrl, headers: {
        'Referer': '${AnimeArabicService.baseUrl}/',
        'Accept': 'application/json,*/*',
      }).timeout(timeout);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final first = j['first']?.toString();
      final sec = j['sec']?.toString();
      if (first == null || sec == null || first.isEmpty || sec.isEmpty) {
        onProgress?.call('error', 'Flare config missing first/sec');
        return null;
      }
      _cachedApiFirst = first;
      _cachedApiSec = sec;
      _flareCachedAt = now;
      return (first, sec);
    } catch (e) {
      onProgress?.call('error', 'Flare failed: $e');
      return null;
    }
  }

  Future<String> _get(
    HttpClient client,
    String url, {
    Map<String, String>? headers,
  }) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    if (headers != null) headers.forEach(req.headers.set);
    final res = await req.close();
    if (res.statusCode >= 400) {
      throw HttpException('GET $url → ${res.statusCode}');
    }
    return res.transform(utf8.decoder).join();
  }

  Future<String> _post(
    HttpClient client,
    String url, {
    required String body,
    Map<String, String>? headers,
  }) async {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    req.headers.set(HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded; charset=UTF-8');
    req.headers.set('Origin', AnimeArabicService.baseUrl);
    req.headers.set('Referer', '${AnimeArabicService.baseUrl}/');
    req.headers
        .set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
    if (headers != null) headers.forEach(req.headers.set);
    req.write(body);
    final res = await req.close();
    if (res.statusCode >= 400) {
      final err = await res.transform(utf8.decoder).join();
      throw HttpException('POST $url → ${res.statusCode}\n$err');
    }
    return res.transform(utf8.decoder).join();
  }

  // ────────────────────────────────────────────────────────────────────
  // Public utilities
  // ────────────────────────────────────────────────────────────────────
  /// Mirror of `decryptXorBase64()` in ep.html.
  static String? decryptXorBase64(String data) {
    try {
      final decoded = base64.decode(data.trim());
      final keyBytes = utf8.encode(_xorKey);
      final out = StringBuffer();
      for (var i = 0; i < decoded.length; i++) {
        out.writeCharCode(decoded[i] ^ keyBytes[i % keyBytes.length]);
      }
      return out.toString();
    } catch (e) {
      debugPrint('[ArabicExtractor] decryptXorBase64 failed: $e');
      return null;
    }
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Build a `StreamSource` list for `PlayerScreen`, one entry per
  /// (server × quality) pair. Higher-rank servers/qualities first.
  static List<StreamSource> toSources(List<ArabicResolvedStream> hits) {
    // Server priority order (best embeds first).
    const order = [
      'wit',
      'rift',
      'riftv2',
      'shof',
      'blkom',
      'animeify',
      'kuudere',
      'topcinema',
    ];
    int rank(String name) {
      final i = order.indexOf(name);
      return i < 0 ? 999 : i;
    }

    final sorted = List<ArabicResolvedStream>.from(hits)
      ..sort((a, b) {
        final ra = rank(a.server.name);
        final rb = rank(b.server.name);
        if (ra != rb) return ra.compareTo(rb);
        return _qualityRank(b.quality).compareTo(_qualityRank(a.quality));
      });

    final out = <StreamSource>[];
    for (final h in sorted) {
      final title = h.quality.isEmpty
          ? h.server.displayName
          : '${h.server.displayName} · ${h.quality}';
      out.add(StreamSource(
        url: h.url,
        title: title,
        type: h.type,
        headers: Map<String, String>.from(h.headers),
      ));
    }
    return out;
  }

  /// External subtitles aren't exposed by this site's player iframes
  /// (subs are baked into the video file). Kept for API parity.
  static List<Map<String, dynamic>> collectSubtitles(
    List<ArabicResolvedStream> hits,
  ) =>
      const [];
}
