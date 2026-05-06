import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'local_server_service.dart';
import 'mysubs_service.dart';
import 'settings_service.dart';
import 'stremio_service.dart';
import 'subtitlecat_service.dart';

class SubtitleApi {
  // Legacy method for backward compatibility if needed
  static Future<List<Map<String, dynamic>>> fetchSubtitles({
    required int tmdbId,
    String? imdbId,
    int? season,
    int? episode,
    String? title,
    int? year,
  }) async {
    final stream = fetchSubtitlesStream(
      tmdbId: tmdbId,
      imdbId: imdbId,
      season: season,
      episode: episode,
      title: title,
      year: year,
    );
    
    List<Map<String, dynamic>> finalSubs = [];
    await for (final subs in stream) {
      finalSubs = subs;
    }
    return finalSubs;
  }

  // New Stream-based method for real-time updates
  static Stream<List<Map<String, dynamic>>> fetchSubtitlesStream({
    required int tmdbId,
    String? imdbId,
    int? season,
    int? episode,
    String? title,
    int? year,
  }) async* {
    final List<Map<String, dynamic>> allSubs = [];
    final stremio = StremioService();

    final List<Future<List<Map<String, dynamic>>>> tasks = [];

    // Wyzie
    tasks.add(_fetchWyzie(tmdbId, season, episode));

    // Levrx
    tasks.add(_fetchLevrx(tmdbId, season, episode));

    // SubtitleCat (scraping + on-demand Google translation)
    if (title != null && title.trim().isNotEmpty) {
      tasks.add(_fetchSubtitleCat(
        title: title,
        year: year,
        season: season,
        episode: episode,
      ));
      tasks.add(_fetchMysubs(
        title: title,
        year: year,
        season: season,
        episode: episode,
      ));
    }

    // Stremio addon subtitles
    if (imdbId != null) {
      final subAddons = await SettingsService().getStremioAddons();
      final relevantAddons = subAddons.where((a) {
        final resources = a['manifest']['resources'] as List;
        return resources.any((r) => 
          (r is String && r == 'subtitles') || 
          (r is Map && r['name'] == 'subtitles')
        );
      }).toList();

      if (relevantAddons.isNotEmpty) {
        final String resourceId = (season != null && episode != null) 
            ? '$imdbId:$season:$episode' 
            : imdbId;
        final String type = (season != null && episode != null) ? 'series' : 'movie';

        for (var addon in relevantAddons) {
          tasks.add(stremio.getSubtitles(
            baseUrl: addon['baseUrl'], 
            type: type, 
            id: resourceId,
            addonName: addon['name'],
          ));
        }
      }
    }

    // Emit updated list as each source completes
    final int totalTasks = tasks.length;
    int completedTasks = 0;
    
    final controller = StreamController<List<Map<String, dynamic>>>();
    
    for (var task in tasks) {
      task.then((subs) {
        allSubs.addAll(subs);
        
        // English first, then alphabetical by display
        allSubs.sort((a, b) {
          final aLang = (a['language'] ?? '').toString().toLowerCase();
          final bLang = (b['language'] ?? '').toString().toLowerCase();
          final aIsEn = aLang == 'en' || aLang == 'eng' || aLang.contains('english');
          final bIsEn = bLang == 'en' || bLang == 'eng' || bLang.contains('english');
          if (aIsEn && !bIsEn) return -1;
          if (!aIsEn && bIsEn) return 1;
          return (a['display'] ?? '').compareTo(b['display'] ?? '');
        });

        controller.add(List.from(allSubs));
        completedTasks++;
        if (completedTasks == totalTasks) controller.close();
      }).catchError((e) {
        debugPrint('Subtitle task error: $e');
        completedTasks++;
        if (completedTasks == totalTasks) controller.close();
      });
    }

    yield* controller.stream;
  }

  // ── Wyzie ──────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _fetchWyzie(int tmdbId, int? season, int? episode) async {
    try {
      const wyzieKey = 'wyzie-0321082ab89b43b9834233ee524cc725';
      String url = 'https://sub.wyzie.io/search?id=$tmdbId&key=$wyzieKey';
      if (season != null && episode != null) {
        url += '&season=$season&episode=$episode';
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        // Count how many entries share the same display/language name
        final Map<String, int> totals = {};
        for (final s in data) {
          final name = (s['display'] ?? s['language'] ?? 'Unknown').toString();
          totals[name] = (totals[name] ?? 0) + 1;
        }

        // Rebuild with numbered display + source suffix
        final Map<String, int> seen = {};
        return data.map((s) {
          final entry = Map<String, dynamic>.from(s as Map);
          final name = (entry['display'] ?? entry['language'] ?? 'Unknown').toString();
          seen[name] = (seen[name] ?? 0) + 1;
          final n = seen[name]!;
          entry['display'] = totals[name]! > 1 ? '$name $n - wyzie' : '$name 1 - wyzie';
          entry['sourceName'] = 'wyzie';
          // Append API key to download URLs as well
          if (entry['url'] != null) {
            final dlUrl = entry['url'].toString();
            if (dlUrl.contains('wyzie.io') || dlUrl.contains('wyzie.ru')) {
              entry['url'] = '$dlUrl${dlUrl.contains('?') ? '&' : '?'}key=$wyzieKey';
            }
          }
          return entry;
        }).toList();
      }
    } catch (e) {
      debugPrint('Wyzie error: $e');
    }
    return [];
  }

  // ── Levrx ──────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _fetchLevrx(int tmdbId, int? season, int? episode) async {
    try {
      // Shows: ?id=tmdbId/season/episode  |  Movies: ?id=tmdbId
      final idParam = (season != null && episode != null)
          ? '$tmdbId/$season/$episode'
          : '$tmdbId';
      final uri = Uri.parse('https://api.levrx.de/search?id=$idParam');

      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final subtitles = data['subtitles'] as List<dynamic>? ?? [];
        final result = <Map<String, dynamic>>[];

        for (final sub in subtitles) {
          final category = (sub['category'] as String? ?? 'Unknown');
          final urls = (sub['urls'] as List<dynamic>? ?? []).cast<String>();
          for (var i = 0; i < urls.length; i++) {
            result.add({
              'url': urls[i],
              'display': '$category ${i + 1} - levrx',
              'language': _levrxLanguageCode(category),
              'sourceName': 'levrx',
            });
          }
        }
        return result;
      }
    } catch (e) {
      debugPrint('Levrx error: $e');
    }
    return [];
  }

  static String _levrxLanguageCode(String category) {
    const map = {
      'Arabic': 'ar', 'Brazilian': 'pt-BR', 'Bulgarian': 'bg',
      'Chinese': 'zh', 'Czech': 'cs', 'Danish': 'da', 'Dutch': 'nl',
      'English': 'en', 'Finnish': 'fi', 'French': 'fr', 'German': 'de',
      'Greek': 'el', 'Hebrew': 'he', 'Hungarian': 'hu', 'Indonesian': 'id',
      'Italian': 'it', 'Japanese': 'ja', 'Korean': 'ko', 'Norwegian': 'no',
      'Persian': 'fa', 'Polish': 'pl', 'Portuguese': 'pt', 'Romanian': 'ro',
      'Russian': 'ru', 'Serbian': 'sr', 'Slovak': 'sk', 'Spanish': 'es',
      'Swedish': 'sv', 'Thai': 'th', 'Turkish': 'tr', 'Ukrainian': 'uk',
      'Vietnamese': 'vi',
    };
    return map[category] ?? category.toLowerCase().substring(0, category.length.clamp(2, 2));
  }

  // ── SubtitleCat ────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> _fetchMysubs({
    required String title,
    int? year,
    int? season,
    int? episode,
  }) async {
    try {
      return await MysubsService.instance.fetchAll(
        title: title,
        year: year,
        season: season,
        episode: episode,
      );
    } catch (e) {
      debugPrint('mysubs fetch error: $e');
      return [];
    }
  }
  static Future<List<Map<String, dynamic>>> _fetchSubtitleCat({
    required String title,
    int? year,
    int? season,
    int? episode,
  }) async {
    try {
      // Translation entries route through the local proxy server so the
      // player can fetch a translated SRT on demand.
      final localPort = LocalServerService().port;
      final translateBase =
          localPort > 0 ? 'http://localhost:$localPort' : null;

      return await SubtitleCatService.instance.fetchAll(
        title: title,
        year: year,
        season: season,
        episode: episode,
        translateBaseUrl: translateBase,
      );
    } catch (e) {
      debugPrint('SubtitleCat error: $e');
      return [];
    }
  }
}

