// ─────────────────────────────────────────────────────────────────────────
// Mega.nz native streaming proxy.
//
// Mega embeds (mega.nz/embed/<id>!<key>) serve AES-128-CTR-encrypted
// chunks behind a per-request `g` download URL obtained from
// `https://g.api.mega.co.nz/cs`. Browsers normally decrypt these in JS
// with Mega's full SDK. We replicate the bare minimum here:
//
//   1. Parse `<file_id>` + `<file_key_b64url>` from the embed URL.
//   2. POST `[{a:"g", g:1, ssl:1, n:<file_id>}]` to the cs endpoint to
//      get the ciphertext URL `g` and total `s` (size).
//   3. Bind a loopback HttpServer; for each incoming GET / HEAD with a
//      Range header, forward the same Range to Mega's `g` URL, AES-CTR
//      decrypt the response stream with the IV adjusted to the byte
//      offset, and pipe plaintext bytes back to the player.
//
// media_kit hits `http://127.0.0.1:<port>/v/<token>.mp4`, sees a normal
// Range-capable MP4 server, and plays the file as if it were local.
// ─────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

class MegaProxy {
  MegaProxy._();
  static final MegaProxy instance = MegaProxy._();

  HttpServer? _server;
  final Map<String, _MegaFile> _files = {};
  int _seq = 0;

  Future<int> _ensureServer() async {
    if (_server != null) return _server!.port;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle, onError: (e, st) {
      debugPrint('[MegaProxy] listen error: $e');
    });
    _server = s;
    debugPrint('[MegaProxy] bound on 127.0.0.1:${s.port}');
    return s.port;
  }

  /// Resolves a `mega.nz/embed/<id>!<key>` URL to a local proxy URL
  /// playable by media_kit. Returns `null` if the URL cannot be parsed
  /// or the Mega API call fails.
  Future<MegaResolved?> resolve(String embedUrl) async {
    try {
      final parsed = _parseEmbed(embedUrl);
      if (parsed == null) {
        debugPrint('[MegaProxy] could not parse embed: $embedUrl');
        return null;
      }
      final (fileId, keyBytes) = parsed;

      // Mega file key is 256 bits split into 8x 32-bit words [k0..k7].
      // AES-128 key = first 4 words XOR last 4 words.
      // CTR nonce  = bytes [16..24].
      final aesKey = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        aesKey[i] = keyBytes[i] ^ keyBytes[i + 16];
      }
      final nonce = Uint8List(8);
      for (var i = 0; i < 8; i++) {
        nonce[i] = keyBytes[i + 16];
      }

      final api = await _megaApi(fileId);
      if (api == null) return null;
      final size = (api['s'] as num?)?.toInt() ?? 0;
      final dlUrl = api['g']?.toString() ?? '';
      if (size <= 0 || dlUrl.isEmpty) {
        debugPrint('[MegaProxy] api missing g/s: $api');
        return null;
      }

      final port = await _ensureServer();
      final token = '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
      _files[token] = _MegaFile(
        dlUrl: dlUrl,
        size: size,
        aesKey: aesKey,
        nonce: nonce,
      );
      final url = 'http://127.0.0.1:$port/v/$token.mp4';
      return MegaResolved(url: url, size: size);
    } catch (e, st) {
      debugPrint('[MegaProxy] resolve failed: $e\n$st');
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // Mega API
  // ────────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>?> _megaApi(String fileId) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final url = 'https://g.api.mega.co.nz/cs?id=${_seq++}';
      // Public file links (mega.nz/file/<id>!<key> and the equivalent
      // /embed/ form) must be fetched with `p` (public handle). The
      // `n` field is only for node handles inside an authenticated
      // session, and returns -9 (ENOENT) for public files.
      final body = jsonEncode([
        {'a': 'g', 'g': 1, 'ssl': 1, 'p': fileId},
      ]);
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType('application', 'json');
      req.write(body);
      final res = await req.close();
      final raw = await res.transform(utf8.decoder).join();
      final j = jsonDecode(raw);
      if (j is List && j.isNotEmpty) {
        final first = j.first;
        if (first is Map) return Map<String, dynamic>.from(first);
        // Numeric error code (e.g. -9 ENOENT)
        debugPrint('[MegaProxy] api error: $first');
      }
      return null;
    } catch (e) {
      debugPrint('[MegaProxy] api failed: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // Loopback HTTP handler
  // ────────────────────────────────────────────────────────────────────
  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.pathSegments;
      if (path.length < 2 || path[0] != 'v') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final token = path[1].split('.').first;
      final f = _files[token];
      if (f == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      // Parse Range request.
      int start = 0;
      int end = f.size - 1;
      final rangeHdr = req.headers.value(HttpHeaders.rangeHeader);
      final hasRange = rangeHdr != null && rangeHdr.startsWith('bytes=');
      if (hasRange) {
        final parts = rangeHdr.substring(6).split('-');
        start = int.tryParse(parts[0]) ?? 0;
        if (parts.length > 1 && parts[1].isNotEmpty) {
          end = int.tryParse(parts[1]) ?? end;
        }
      }
      if (start < 0) start = 0;
      if (end >= f.size) end = f.size - 1;
      if (start > end) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${f.size}');
        await req.response.close();
        return;
      }
      final length = end - start + 1;

      // Common response headers.
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers
          .set(HttpHeaders.contentLengthHeader, length.toString());
      if (hasRange) {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${f.size}',
        );
      } else {
        req.response.statusCode = HttpStatus.ok;
      }

      if (req.method == 'HEAD') {
        await req.response.close();
        return;
      }

      // Forward Range to Mega and stream-decrypt.
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final dlReq = await client.getUrl(Uri.parse(f.dlUrl));
        dlReq.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
        final dlRes = await dlReq.close();
        if (dlRes.statusCode >= 400) {
          throw HttpException('mega g → ${dlRes.statusCode}');
        }

        // Build CTR cipher initialised at the byte offset `start`.
        final cipher = _buildCipher(f.aesKey, f.nonce, start);
        final leadingSkip = start % 16;
        if (leadingSkip > 0) {
          // Process throwaway bytes so the keystream lines up with the
          // first ciphertext byte we'll actually receive.
          final skip = Uint8List(leadingSkip);
          cipher.processBytes(skip, 0, leadingSkip, skip, 0);
        }

        await for (final chunk in dlRes) {
          final cipherBytes =
              chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          final plain = Uint8List(cipherBytes.length);
          cipher.processBytes(
              cipherBytes, 0, cipherBytes.length, plain, 0);
          req.response.add(plain);
        }
        await req.response.close();
      } catch (e) {
        debugPrint('[MegaProxy] stream error: $e');
        try {
          await req.response.close();
        } catch (_) {}
      } finally {
        client.close(force: true);
      }
    } catch (e, st) {
      debugPrint('[MegaProxy] handle threw: $e\n$st');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  StreamCipher _buildCipher(
    Uint8List aesKey,
    Uint8List nonce,
    int byteStart,
  ) {
    // CTR IV = nonce(8 bytes) || counter(8 bytes BE).
    final blockIndex = byteStart ~/ 16;
    final iv = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      iv[i] = nonce[i];
    }
    var c = blockIndex;
    for (var i = 15; i >= 8; i--) {
      iv[i] = c & 0xff;
      c >>= 8;
    }
    final cipher = CTRStreamCipher(AESEngine());
    cipher.init(false, ParametersWithIV(KeyParameter(aesKey), iv));
    return cipher;
  }

  // ────────────────────────────────────────────────────────────────────
  // Embed URL parsing
  // ────────────────────────────────────────────────────────────────────
  (String, Uint8List)? _parseEmbed(String url) {
    // Handles:
    //   https://mega.nz/embed/<id>!<key>
    //   https://mega.nz/embed/<id>#<key>     (rare)
    //   https://mega.nz/file/<id>#<key>
    //   https://mega.nz/#!<id>!<key>         (legacy)
    final re = RegExp(
      r'mega\.nz/(?:embed|file)/([^!#?/]+)[!#]([A-Za-z0-9_-]+)',
      caseSensitive: false,
    );
    var m = re.firstMatch(url);
    if (m == null) {
      final legacy = RegExp(
        r'mega\.nz/#!([^!#?/]+)!([A-Za-z0-9_-]+)',
        caseSensitive: false,
      ).firstMatch(url);
      if (legacy == null) return null;
      m = legacy;
    }
    final id = m.group(1)!;
    final keyB64 = m.group(2)!;
    final keyBytes = _b64UrlDecode(keyB64);
    if (keyBytes.length != 32) return null;
    return (id, keyBytes);
  }

  Uint8List _b64UrlDecode(String s) {
    var x = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll(',', '');
    while (x.length % 4 != 0) {
      x += '=';
    }
    return base64.decode(x);
  }
}

class MegaResolved {
  final String url;
  final int size;
  const MegaResolved({required this.url, required this.size});
}

class _MegaFile {
  final String dlUrl;
  final int size;
  final Uint8List aesKey;
  final Uint8List nonce;
  _MegaFile({
    required this.dlUrl,
    required this.size,
    required this.aesKey,
    required this.nonce,
  });
}
