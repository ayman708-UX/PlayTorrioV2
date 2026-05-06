// Scraper + fuzzy matcher for the 111477.xyz file index.
//
// Listings (`/movies/` and `/tvs/`) are flat HTML directory indexes ~3-8 MB
// each. We download once, cache to disk for 24 h, then resolve TMDB titles
// → exact file URL via a normalized-title + year match.
//
// On HTTP 429 or Cloudflare 1015, we wait exactly 7.2 s and retry.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/stream_source.dart';

class Site111477Match {
  final String fileUrl;        // absolute https URL to the .mkv/.mp4
  final String fileName;       // filename only
  final int sizeBytes;         // -1 if unknown
  Site111477Match(this.fileUrl, this.fileName, this.sizeBytes);
}

class Site111477Service {
  static final Site111477Service _instance = Site111477Service._();
  factory Site111477Service() => _instance;
  Site111477Service._();

  static const String _baseUrl = 'https://a.111477.xyz';
  static const Duration _cacheTtl = Duration(hours: 24);
  static const Duration _rateLimitWait = Duration(milliseconds: 7200);
  static const int _maxRateLimitRetries = 6;

  final HttpClient _http = HttpClient()
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 60);

  // In-memory parsed listings (lazy).
  List<_Entry>? _movies;
  List<_Entry>? _tvs;

  // ─────────────────────────────────────────────────────────────────────────
  //  PUBLIC API
  // ─────────────────────────────────────────────────────────────────────────

  Future<Site111477Match?> findMovie({
    required String title,
    String? year,
  }) async {
    final list = await findMovieSources(title: title, year: year);
    return list.isEmpty ? null : list.first;
  }

  Future<Site111477Match?> findEpisode({
    required String showTitle,
    required int season,
    required int episode,
  }) async {
    final list = await findEpisodeSources(
        showTitle: showTitle, season: season, episode: episode);
    return list.isEmpty ? null : list.first;
  }

  /// Returns ALL files in the matched movie folder, sorted by quality
  /// (2160p > 1080p > 720p > 480p > others) then size desc.
  Future<List<Site111477Match>> findMovieSources({
    required String title,
    String? year,
  }) async {
    debugPrint('[111477] findMovieSources("$title", year=$year) — fetching index…');
    final movies = await _ensureMovies();
    debugPrint('[111477] movie index ready (${movies.length} entries)');
    final wantedTitle = _normalize(title);
    final wantedYear = year;

    _Entry? hit;
    if (wantedYear != null && wantedYear.isNotEmpty) {
      hit = movies.firstWhereOrNull(
          (e) => e.normalizedTitle == wantedTitle && e.year == wantedYear);
    }
    hit ??= movies.firstWhereOrNull((e) {
      if (e.normalizedTitle != wantedTitle) return false;
      if (wantedYear == null || wantedYear.isEmpty) return true;
      final w = int.tryParse(wantedYear);
      final y = int.tryParse(e.year ?? '');
      return w != null && y != null && (w - y).abs() <= 1;
    });
    hit ??= movies.firstWhereOrNull((e) => e.normalizedTitle == wantedTitle);

    if (hit == null) {
      debugPrint('[111477] no movie folder match for "$title" ($year)');
      return const <Site111477Match>[];
    }
    debugPrint('[111477] movie match: ${hit.rawName} → ${hit.url}');
    return _listFilesInFolder(hit.url);
  }

  /// Returns ALL files matching the requested season+episode across every
  /// candidate folder, sorted by quality then size.
  Future<List<Site111477Match>> findEpisodeSources({
    required String showTitle,
    required int season,
    required int episode,
  }) async {
    debugPrint('[111477] findEpisodeSources("$showTitle" S${season}E$episode) — fetching index…');
    final tvs = await _ensureTvs();
    debugPrint('[111477] tv index ready (${tvs.length} entries)');
    final wanted = _normalize(showTitle);

    var folders = tvs.where((e) => e.normalizedTitle == wanted).toList();
    if (folders.isEmpty) {
      folders = tvs.where((e) => e.normalizedTitle.startsWith(wanted)).toList();
    }
    if (folders.isEmpty) {
      debugPrint('[111477] no tv folder match for "$showTitle"');
      return const <Site111477Match>[];
    }

    final out = <Site111477Match>[];
    final epTag = _episodeTag(season, episode).toLowerCase();
    for (final folder in folders) {
      final seasonHref = '${folder.url}Season ${season.toString()}/';
      final seasonUrl = _normalizeUrl(seasonHref);
      List<_Entry> files;
      try {
        files = await _fetchListing(seasonUrl);
      } catch (e) {
        debugPrint('[111477] season fetch failed for $seasonUrl: $e');
        continue;
      }
      for (final f in files) {
        if (f.isDir) continue;
        if (!f.rawName.toLowerCase().contains(epTag)) continue;
        out.add(Site111477Match(
            _absolute(f.url), f.rawName, f.sizeBytes));
      }
      if (out.isNotEmpty) {
        debugPrint('[111477] tv match: ${folder.rawName} S${season}E$episode '
            '→ ${out.length} file(s)');
        break; // stop at first folder that yielded matches
      }
    }
    _sortByQuality(out);
    return out;
  }

  /// Convert a list of matches into UI-friendly StreamSource entries.
  /// title = filename, type = quality + human-readable size (shown as the
  /// menu's subtitle line).
  static List<StreamSource> toStreamSources(List<Site111477Match> matches) {
    return [
      for (final m in matches)
        StreamSource(
          url: m.fileUrl,
          title: m.fileName,
          type: _describeMatch(m),
        ),
    ];
  }

  static String _describeMatch(Site111477Match m) {
    final q = qualityTagFor(m.fileName);
    final s = m.sizeBytes > 0 ? humanSize(m.sizeBytes) : '';
    if (q.isEmpty && s.isEmpty) return '111477';
    if (q.isEmpty) return '111477 • $s';
    if (s.isEmpty) return '$q • 111477';
    return '$q • $s';
  }

  static String qualityTagFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('2160p') || n.contains('4k')) return '2160P';
    if (n.contains('1080p')) return '1080P';
    if (n.contains('720p')) return '720P';
    if (n.contains('480p')) return '480P';
    if (n.contains('360p')) return '360P';
    return '';
  }

  static String humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  INTERNALS
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<_Entry>> _ensureMovies() async {
    _movies ??= await _loadOrFetch('movies');
    return _movies!;
  }

  Future<List<_Entry>> _ensureTvs() async {
    _tvs ??= await _loadOrFetch('tvs');
    return _tvs!;
  }

  Future<List<_Entry>> _loadOrFetch(String kind) async {
    final dir = await _cacheDir();
    final cacheFile = File('${dir.path}${Platform.pathSeparator}$kind.html');
    final fresh = cacheFile.existsSync() &&
        DateTime.now().difference(cacheFile.lastModifiedSync()) < _cacheTtl;
    String html;
    if (fresh) {
      html = await cacheFile.readAsString();
    } else {
      html = await _fetchHtml('$_baseUrl/$kind/');
      try {
        await cacheFile.writeAsString(html);
      } catch (_) {}
    }
    return _parseEntries(html, '/$kind/');
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(
        '${base.path}${Platform.pathSeparator}site111477_index');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<List<Site111477Match>> _listFilesInFolder(String folderRelUrl) async {
    final url = _absolute(folderRelUrl);
    final entries = await _fetchListing(url);
    final out = <Site111477Match>[];
    for (final e in entries) {
      if (e.isDir) continue;
      out.add(Site111477Match(_absolute(e.url), e.rawName, e.sizeBytes));
    }
    _sortByQuality(out);
    return out;
  }

  void _sortByQuality(List<Site111477Match> list) {
    list.sort((a, b) {
      final qa = _qualityScore(a.fileName);
      final qb = _qualityScore(b.fileName);
      if (qa != qb) return qb - qa;
      return b.sizeBytes.compareTo(a.sizeBytes);
    });
  }

  Future<List<_Entry>> _fetchListing(String url) async {
    final html = await _fetchHtml(url);
    return _parseEntries(html, Uri.parse(url).path);
  }

  Future<String> _fetchHtml(String url) async {
    var attempt = 0;
    while (true) {
      attempt++;
      debugPrint('[111477] GET $url (attempt $attempt)');
      final req = await _http
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      req.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36');
      req.headers.set(HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8');
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 60));
      final isLimited = res.statusCode == 429 ||
          (res.statusCode >= 500 && res.statusCode < 600) ||
          // Only run the (slow) 1015 check on short bodies — a successful
          // 8 MB index page won't contain a Cloudflare error notice.
          (body.length < 65536 && _isCloudflare1015(body));
      if (!isLimited && res.statusCode >= 200 && res.statusCode < 400) {
        debugPrint('[111477] OK ${res.statusCode} (${body.length} bytes)');
        return body;
      }
      if (attempt > _maxRateLimitRetries) {
        throw HttpException(
            '111477 fetch failed (${res.statusCode}) after $attempt tries: $url');
      }
      debugPrint(
          '[111477] rate-limited (HTTP ${res.statusCode}) — waiting 7.2s …');
      await Future.delayed(_rateLimitWait);
    }
  }

  bool _isCloudflare1015(String text) {
    if (text.isEmpty) return false;
    return RegExp(r'\b(?:error\s*(?:code:?\s*)?1015)\b',
                caseSensitive: false)
            .hasMatch(text) ||
        RegExp(r'you are being rate limited', caseSensitive: false)
            .hasMatch(text);
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  PARSING
  // ─────────────────────────────────────────────────────────────────────────

  // Each row looks like:
  //   <tr data-entry="true" data-name="…" data-url="…">…</tr>
  // We extract the data-name & data-url attrs (HTML-entity-decoded) and
  // figure out from the URL whether the entry is a directory (trailing /).
  static final RegExp _rowRe = RegExp(
      r'<tr[^>]*data-entry="true"[^>]*data-name="([^"]*)"[^>]*data-url="([^"]*)"',
      caseSensitive: false);
  static final RegExp _sizeRe = RegExp(
      r'<td class="size" data-sort="(-?\d+)"',
      caseSensitive: false);

  List<_Entry> _parseEntries(String html, String pathPrefix) {
    final out = <_Entry>[];
    // Use allMatches() over the full string — *not* substring() in a loop,
    // which is O(N^2) and locks the UI isolate for minutes on the 8 MB
    // listing pages.
    for (final rowMatch in _rowRe.allMatches(html)) {
      final name = _decodeHtml(rowMatch.group(1)!);
      final url = _decodeHtml(rowMatch.group(2)!);
      // Look ahead a bounded window for the <td class="size">.
      final tailEnd = (rowMatch.end + 800).clamp(0, html.length);
      final szMatch =
          _sizeRe.firstMatch(html.substring(rowMatch.end, tailEnd));
      final size = szMatch != null ? int.parse(szMatch.group(1)!) : -1;
      final isDir = url.endsWith('/');
      out.add(_Entry(
        rawName: name,
        url: url,
        isDir: isDir,
        sizeBytes: size,
        normalizedTitle: _normalize(_stripYearAndExt(name)),
        year: _extractYear(name),
      ));
    }
    return out;
  }

  static String _decodeHtml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&#x2F;', '/');
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  NORMALIZATION  (the "fuzzy"-but-deterministic match core)
  //
  //  Examples that must collide on the same key:
  //    "365 Days: This Day"          → "365 days this day"
  //    "365 Days - This Day (2022)"  → "365 days this day"
  //    "Avengers: Endgame"           → "avengers endgame"
  //    "Spider-Man: No Way Home"     → "spider man no way home"
  //    "Mission: Impossible – DRP1"  → "mission impossible drp1"
  //    "Léon: The Professional"      → "leon the professional"
  //    "Marvel's The Avengers"       → "marvels the avengers"
  //    "M*A*S*H"                     → "m a s h"
  //    "Tom & Jerry"                 → "tom and jerry"
  // ─────────────────────────────────────────────────────────────────────────

  static const Map<String, String> _diacritics = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'Á': 'a', 'À': 'a', 'Ä': 'a', 'Â': 'a', 'Ã': 'a', 'Å': 'a', 'Ā': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'ē': 'e', 'ę': 'e',
    'É': 'e', 'È': 'e', 'Ë': 'e', 'Ê': 'e', 'Ē': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', 'ī': 'i',
    'Í': 'i', 'Ì': 'i', 'Ï': 'i', 'Î': 'i', 'Ī': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
    'Ó': 'o', 'Ò': 'o', 'Ö': 'o', 'Ô': 'o', 'Õ': 'o', 'Ø': 'o', 'Ō': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ū': 'u',
    'Ú': 'u', 'Ù': 'u', 'Ü': 'u', 'Û': 'u', 'Ū': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ñ': 'n', 'Ñ': 'n', 'ç': 'c', 'Ç': 'c',
    'ß': 'ss', 'æ': 'ae', 'Æ': 'ae', 'œ': 'oe', 'Œ': 'oe',
  };

  static String _stripDiacritics(String s) {
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      sb.write(_diacritics[ch] ?? ch);
    }
    return sb.toString();
  }

  static String _normalize(String input) {
    var s = _stripDiacritics(input).toLowerCase();
    // & → and (handle both " & " and "&amp;" remnants).
    s = s.replaceAll('&', ' and ');
    // Strip apostrophes/curly quotes outright (don't insert space).
    s = s.replaceAll(RegExp(r"['\u2018\u2019\u02BC\u201B`]"), '');
    // Replace any remaining non-alphanumeric with a space.
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    // Collapse + trim.
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static final RegExp _yearRe = RegExp(r'\((\d{4})\)\s*$');

  static String? _extractYear(String name) {
    final m = _yearRe.firstMatch(name.trim());
    return m?.group(1);
  }

  static String _stripYearAndExt(String name) {
    var s = name.trim();
    s = s.replaceFirst(_yearRe, '').trim();
    // Strip common video extensions if it's a file.
    s = s.replaceFirst(RegExp(r'\.(mkv|mp4|avi|m4v|mov|webm)$',
        caseSensitive: false), '');
    return s;
  }

  String _episodeTag(int season, int episode) {
    final ss = season.toString().padLeft(2, '0');
    final ee = episode.toString().padLeft(2, '0');
    return 'S${ss}E$ee';
  }

  // Quality preference: 2160 > 1080 > 720 > 480 > 360 > others.
  int _qualityScore(String name) {
    final n = name.toLowerCase();
    if (n.contains('2160p') || n.contains('4k')) return 4;
    if (n.contains('1080p')) return 3;
    if (n.contains('720p')) return 2;
    if (n.contains('480p')) return 1;
    return 0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  URL HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  String _absolute(String maybeRelative) {
    if (maybeRelative.startsWith('http')) return maybeRelative;
    return '$_baseUrl$maybeRelative';
  }

  String _normalizeUrl(String href) {
    // The site's links are stored URL-encoded with literal spaces in the
    // human label. For HTTP we need %20 etc.
    final uri = Uri.parse(_absolute(href));
    return uri.toString();
  }
}

class _Entry {
  final String rawName;
  final String url;
  final bool isDir;
  final int sizeBytes;
  final String normalizedTitle;
  final String? year;
  _Entry({
    required this.rawName,
    required this.url,
    required this.isDir,
    required this.sizeBytes,
    required this.normalizedTitle,
    required this.year,
  });
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
