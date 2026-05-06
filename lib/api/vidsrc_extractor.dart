// Vidsrc / vsembed.ru extractor.
//
// vsembed.ru serves an outer embed page whose only useful payload is an
// iframe pointing at `//cloudnestra.com/rcp/<long_b64>`. Cloudnestra has
// THREE levels:
//   * /rcp/<b64>      → JS bootstrap, contains  src: '/prorcp/<id>'
//   * /prorcp/<id>    → JWPlayer page, contains  file: "<m3u8 OR ...>"
//   * The m3u8 URL is embedded in the HTML as a literal — no WebView,
//     no JS exec needed. The `{vN}` placeholders in the URL substitute
//     to `cloudnestra.com` (the default host, per the page's own
//     `pass_path = "//tmstr4.cloudnestra.com/rt_ping.php"`).
//
// So this extractor is THREE HTTP gets, no WebView:
//
//   1. GET https://vsembed.ru/embed/...   → regex `<iframe id="player_iframe">`
//   2. GET <rcp_url>                      → regex `src:'/prorcp/...'`
//   3. GET <prorcp_url>                   → regex `file:"<url>"`, pick first
//      OR-separated variant, replace `{vN}` with `cloudnestra.com`.
//
// URL formats:
//   movie -> https://vsembed.ru/embed/movie/{tmdbId}
//   tv    -> https://vsembed.ru/embed/tv/{tmdbId}/{season}-{episode}
// (note: TV uses {s}-{e} with a hyphen, NOT a slash.)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'stream_extractor.dart' show ExtractedMedia;

class VidsrcExtractor {
  static const String _embedHost = 'https://vsembed.ru';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36';
  // Default substitution for {v1}-{vN} placeholders in the m3u8 URL.
  static const String _defaultHost = 'cloudnestra.com';

  /// Builds the outer embed URL for a given TMDB id.
  static String buildEmbedUrl({
    required String tmdbId,
    required bool isMovie,
    int? season,
    int? episode,
  }) {
    if (isMovie) return '$_embedHost/embed/movie/$tmdbId';
    return '$_embedHost/embed/tv/$tmdbId/${season ?? 1}-${episode ?? 1}';
  }

  Future<ExtractedMedia?> extract({
    required String tmdbId,
    required bool isMovie,
    int? season,
    int? episode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final embedUrl = buildEmbedUrl(
      tmdbId: tmdbId,
      isMovie: isMovie,
      season: season,
      episode: episode,
    );

    // ── 1. Fetch outer embed page and find the inner rcp iframe URL.
    final String rcpUrl;
    try {
      final res = await http.get(
        Uri.parse(embedUrl),
        headers: const {
          'User-Agent': _userAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200 || res.body.isEmpty) {
        debugPrint('[Vidsrc] Embed fetch failed: ${res.statusCode}');
        return null;
      }

      final extracted = _findIframeSrc(res.body);
      if (extracted == null) {
        debugPrint('[Vidsrc] No player_iframe src in $embedUrl');
        return null;
      }
      rcpUrl = extracted;
      debugPrint('[Vidsrc] Resolved rcp iframe → $rcpUrl');
    } catch (e) {
      debugPrint('[Vidsrc] Embed fetch error: $e');
      return null;
    }

    // ── 2. Fetch the rcp page and dig out the prorcp player URL.
    //      Cloudnestra's rcp page is just a JS bootstrap; the real
    //      player lives at /prorcp/<id>.
    final String prorcpUrl;
    try {
      final res = await http.get(
        Uri.parse(rcpUrl),
        headers: {
          'User-Agent': _userAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Referer': '$_embedHost/',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200 || res.body.isEmpty) {
        debugPrint('[Vidsrc] rcp fetch HTTP ${res.statusCode}');
        return null;
      }
      final m = RegExp(r'''src:\s*['"](/prorcp/[^'"]+)['"]''')
          .firstMatch(res.body);
      if (m == null) {
        debugPrint('[Vidsrc] No prorcp src in rcp body');
        return null;
      }
      prorcpUrl = 'https://cloudnestra.com${m.group(1)}';
      debugPrint('[Vidsrc] Resolved prorcp player → $prorcpUrl');
    } catch (e) {
      debugPrint('[Vidsrc] rcp fetch error: $e');
      return null;
    }

    // ── 3. Fetch the prorcp page and pull the m3u8 directly out of
    //      the inline `file:` JWPlayer config. The URL contains
    //      `{v1}`/`{v2}`/... placeholders — we substitute the default
    //      `cloudnestra.com` host (matches the page's own pass_path).
    try {
      final res = await http.get(
        Uri.parse(prorcpUrl),
        headers: {
          'User-Agent': _userAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Referer': rcpUrl,
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200 || res.body.isEmpty) {
        debugPrint('[Vidsrc] prorcp fetch HTTP ${res.statusCode}');
        return null;
      }
      final m3u8 = _findM3u8(res.body);
      if (m3u8 == null) {
        debugPrint('[Vidsrc] No m3u8 in prorcp body');
        return null;
      }
      debugPrint('[Vidsrc] ✅ Extracted m3u8: $m3u8');

      // Cloudnestra m3u8 endpoints require a Referer from cloudnestra
      // for the playlist + segments. The player will use these headers.
      final headers = <String, String>{
        'User-Agent': _userAgent,
        'Referer': 'https://cloudnestra.com/',
        'Origin': 'https://cloudnestra.com',
      };
      return ExtractedMedia(url: m3u8, headers: headers, provider: 'vidsrc');
    } catch (e) {
      debugPrint('[Vidsrc] prorcp fetch error: $e');
      return null;
    }
  }

  /// Pull the first valid m3u8 URL out of the prorcp HTML's `file:` literal
  /// and substitute `{vN}` placeholders with the default cloudnestra host.
  ///
  /// The `file:` value looks like:
  ///   "https://tmstr4.`{v1}`/pl/`<b64>`/master.m3u8 or
  ///    https://tmstr4.`{v2}`/pl/`<b64>`/master.m3u8 or
  ///    https://app2.`{v5}`/cdnstr/`<b64>`/list.m3u8"
  static String? _findM3u8(String html) {
    final fileMatch =
        RegExp(r'''file\s*:\s*"([^"]+\.m3u8[^"]*)"''').firstMatch(html);
    if (fileMatch == null) return null;
    final raw = fileMatch.group(1)!;
    // Split on " or " separators and take the first variant that looks ok.
    final variants = raw.split(RegExp(r'\s+or\s+', caseSensitive: false));
    for (final v in variants) {
      final candidate = v.trim().replaceAll(RegExp(r'\{v\d+\}'), _defaultHost);
      if (candidate.startsWith('http') && candidate.contains('.m3u8')) {
        return candidate;
      }
    }
    return null;
  }

  /// Returns the absolute URL of the `<iframe id="player_iframe">` in
  /// [html], or null if none found. Handles protocol-relative `//host/…`
  /// and root-relative `/…` srcs.
  static String? _findIframeSrc(String html) {
    final m = RegExp(
      r'''<iframe[^>]*id=["']player_iframe["'][^>]*src=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (m == null) return null;
    final raw = m.group(1)!.trim();
    if (raw.startsWith('http')) return raw;
    if (raw.startsWith('//')) return 'https:$raw';
    if (raw.startsWith('/')) return '$_embedHost$raw';
    return raw;
  }
}
