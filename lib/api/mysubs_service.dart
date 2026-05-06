import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Subtitle source: my-subs.co (HTML scraper).
///
/// Flow:
///  1. `search.php?key=<title>` → list of `/film-versions-…` (movies) or
///     `/versions-{showId}-{ep}-{season}-{slug}` (shows).
///  2. Pick the best match, then for shows rebuild the URL for the requested
///     season/episode.
///  3. Scrape the versions page → list of `/downloads/{token}` gate links
///     each with a language flag + release-name label.
///  4. For each entry, fetch the gate page and extract the real
///     `/download/{film|series}-{id}.srt` URL from the embedded JS.
class MysubsService {
  MysubsService._();
  static final MysubsService instance = MysubsService._();

  static const _base = 'https://my-subs.co';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  Map<String, String> get _headers => {
        'User-Agent': _ua,
        'Accept': 'text/html,*/*',
        'Referer': '$_base/',
      };

  Future<List<Map<String, dynamic>>> fetchAll({
    required String title,
    int? year,
    int? season,
    int? episode,
  }) async {
    if (title.trim().isEmpty) return [];
    try {
      final isSeries = season != null && episode != null;
      final versionsPath = await _resolveVersionsPath(
        title: title.trim(),
        year: year,
        isSeries: isSeries,
        season: season,
        episode: episode,
      );
      if (versionsPath == null) return [];

      final entries = await _scrapeVersionsPage(versionsPath);
      if (entries.isEmpty) return [];

      // Resolve gate pages → real direct download URLs in parallel batches.
      const batchSize = 6;
      final resolved = <Map<String, dynamic>>[];
      for (var i = 0; i < entries.length; i += batchSize) {
        final batch = entries.skip(i).take(batchSize).toList();
        final results = await Future.wait(batch.map(_resolveGate));
        for (final r in results) {
          if (r != null) resolved.add(r);
        }
      }

      // Numbered display names per language. Append release tag when known.
      final totals = <String, int>{};
      for (final e in resolved) {
        final name = (e['language'] ?? 'Unknown').toString();
        totals[name] = (totals[name] ?? 0) + 1;
      }
      final seen = <String, int>{};
      for (final e in resolved) {
        final name = (e['language'] ?? 'Unknown').toString();
        seen[name] = (seen[name] ?? 0) + 1;
        final n = seen[name]!;
        final release = (e['release'] ?? '').toString().trim();
        final base = totals[name]! > 1 ? '$name $n' : name;
        e['display'] =
            release.isEmpty ? '$base - mysubs' : '$base [$release] - mysubs';
      }
      return resolved;
    } catch (e) {
      debugPrint('mysubs error: $e');
      return [];
    }
  }

  // ── 1+2: resolve title → versions page path ───────────────────────────────

  Future<String?> _resolveVersionsPath({
    required String title,
    int? year,
    required bool isSeries,
    int? season,
    int? episode,
  }) async {
    final searchUrl =
        '$_base/search.php?key=${Uri.encodeQueryComponent(title)}';
    final res = await http.get(Uri.parse(searchUrl), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final html = res.body;

    if (isSeries) {
      // Search results for shows look like:
      //   <a href='/showlistsubtitles-{showId}-{slug}' >Show Name<
      // (The /versions- links on the same page are unrelated sidebar items.)
      final re = RegExp(
        "href=['\"]/showlistsubtitles-(\\d+)-([a-z0-9-]+)['\"]",
        caseSensitive: false,
      );
      final wantSlug = _slug(title);
      String? bestShowId;
      String? bestSlug;
      int bestScore = -1 << 30;
      for (final m in re.allMatches(html)) {
        final showId = m.group(1)!;
        final slug = m.group(2)!;
        final score = _slugScore(slug, wantSlug);
        if (score > bestScore) {
          bestScore = score;
          bestShowId = showId;
          bestSlug = slug;
        }
      }
      if (bestShowId == null || bestSlug == null) return null;
      return '/versions-$bestShowId-$episode-$season-$bestSlug-subtitles';
    } else {
      // Movies: <a … href='/film-versions-{id}-{slug}-subtitles' …>(Title (YEAR))
      final re = RegExp(
        "href=['\"](/film-versions-\\d+-[a-z0-9-]+-subtitles)['\"][^>]*>([^<]+)<",
        caseSensitive: false,
      );
      final wantSlug = _slug(title);
      String? bestPath;
      int bestScore = -1 << 30;
      for (final m in re.allMatches(html)) {
        final path = m.group(1)!;
        final label = m.group(2)!;
        final slugMatch =
            RegExp(r'/film-versions-\d+-([a-z0-9-]+)-subtitles').firstMatch(path);
        final slug = slugMatch?.group(1) ?? '';
        var score = _slugScore(slug, wantSlug);
        if (year != null && label.contains('($year)')) score += 100;
        if (score > bestScore) {
          bestScore = score;
          bestPath = path;
        }
      }
      return bestPath;
    }
  }

  // ── 3: scrape versions page for (gateUrl, language, release) ──────────────

  Future<List<Map<String, dynamic>>> _scrapeVersionsPage(String path) async {
    final res = await http.get(Uri.parse('$_base$path'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return [];
    final html = res.body;

    // Index every "Version: <i>NAME</i>" header so each download row can be
    // tagged with the most recent preceding release name.
    final versionRe = RegExp(
      r"<b>\s*Version\s*:\s*</b>\s*<i>\s*([^<]*?)\s*</i>",
      caseSensitive: false,
    );
    final versions = versionRe.allMatches(html).toList();

    String releaseFor(int rowIndex) {
      String name = '';
      for (final v in versions) {
        if (v.start < rowIndex) {
          name = v.group(1) ?? '';
        } else {
          break;
        }
      }
      return name;
    }

    // Each row contains:
    //   <div class='lang'><b>Language :</b>
    //     <span class="flag-icon flag-icon-{cc}" title="{X}"></span>
    //     <i>{LangName}</i>
    //   </div>
    //   …
    //   <a … href='/downloads/{token}'>
    final rowRe = RegExp(
      r'<b>\s*Language\s*:\s*</b>\s*'
      r'<span class="flag-icon flag-icon-([a-z]{2,3})"\s+title="([^"]+)"[^>]*></span>\s*'
      r'<i>\s*([^<]+?)\s*</i>'
      r"[\s\S]{0,2000}?href='(/downloads/[^']+)'",
      caseSensitive: false,
    );

    final out = <Map<String, dynamic>>[];
    for (final m in rowRe.allMatches(html)) {
      final cc = m.group(1)!.toLowerCase();
      final flagTitle = m.group(2)!.trim();
      final langName = m.group(3)!.trim();
      final gate = m.group(4)!;
      final language = langName.isNotEmpty ? langName : flagTitle;
      out.add({
        'gate': gate,
        'language': _titleCase(language),
        'languageCode': _flagToCode(cc, language),
        'release': releaseFor(m.start),
      });
    }
    return out;
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  // ── 4: resolve gate page → real direct download URL ───────────────────────

  Future<Map<String, dynamic>?> _resolveGate(Map<String, dynamic> entry) async {
    try {
      final gate = entry['gate'] as String;
      final res = await http
          .get(Uri.parse('$_base$gate'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final m = RegExp(r'REAL_URL\s*=\s*"((?:\\/|/)[^"]+)"')
          .firstMatch(res.body);
      if (m == null) return null;
      final realPath = m.group(1)!.replaceAll(r'\/', '/');
      final url = realPath.startsWith('http') ? realPath : '$_base$realPath';
      return {
        'url': url,
        'language': entry['languageCode'],
        'display': entry['language'],
        'release': entry['release'],
        'sourceName': 'mysubs',
      };
    } catch (_) {
      return null;
    }
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp("[`'\u2019\"]"), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// Cheap token-overlap score so "game-of-thrones" beats "game" when
  /// searching for "game of thrones".
  int _slugScore(String candidate, String want) {
    if (candidate == want) return 1000;
    final cTokens = candidate.split('-').toSet();
    final wTokens = want.split('-').toSet();
    final overlap = cTokens.intersection(wTokens).length;
    final extra = cTokens.length - overlap;
    // Reward overlap, lightly penalise extra tokens.
    return overlap * 10 - extra;
  }

  /// Map flag-icon code → ISO-639-1 language code where they differ.
  String _flagToCode(String flag, String langName) {
    const map = {
      'gb': 'en', 'us': 'en', 'sa': 'ar', 'fr': 'fr', 'es': 'es',
      'de': 'de', 'it': 'it', 'pt': 'pt', 'br': 'pt-BR', 'ru': 'ru',
      'jp': 'ja', 'kr': 'ko', 'cn': 'zh', 'tw': 'zh', 'hk': 'zh',
      'nl': 'nl', 'pl': 'pl', 'tr': 'tr', 'gr': 'el', 'cz': 'cs',
      'dk': 'da', 'fi': 'fi', 'no': 'no', 'se': 'sv', 'hu': 'hu',
      'ro': 'ro', 'bg': 'bg', 'rs': 'sr', 'hr': 'hr', 'sk': 'sk',
      'si': 'sl', 'ua': 'uk', 'il': 'he', 'ir': 'fa', 'th': 'th',
      'vn': 'vi', 'id': 'id', 'my': 'ms', 'in': 'hi', 'pk': 'ur',
    };
    final hit = map[flag.toLowerCase()];
    if (hit != null) return hit;
    // Fall back to first 2 letters of language name.
    final n = langName.toLowerCase();
    if (n.length >= 2) return n.substring(0, 2);
    return flag;
  }
}
