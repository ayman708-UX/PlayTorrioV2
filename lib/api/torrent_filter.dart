import 'package:flutter/foundation.dart';
import '../models/torrent_result.dart';

class TorrentFilter {
  static String normalizeTitle(String title) {
    if (title.isEmpty) return '';
    return title.toLowerCase()
        .replaceAll(RegExp(r'[",.:!?;_+\-\[\]\(\)]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Map<String, dynamic> parseSceneInfo(String title) {
    final t = title.toLowerCase();
    
    int? season;
    int? episode;
    bool isMultiEpisode = false;
    bool isSeasonPack = false;
    bool isMultiSeason = false;
    int matchIndex = -1;

    // Multi-season check
    if (RegExp(r's(\d+)\s*-\s*s?(\d+)', caseSensitive: false).hasMatch(t) || 
        RegExp(r'season\s*\d+\s*-\s*\d+', caseSensitive: false).hasMatch(t) || 
        RegExp(r'complete\s+series', caseSensitive: false).hasMatch(t) || 
        t.contains('collection') || 
        t.contains('anthology')) {
      isMultiSeason = true;
    }

    // Multi-episode check
    final multiSxE = RegExp(r's(\d{1,2})[ ._-]*e(\d{1,3})[ ._-]*-[ ._-]*e?(\d{1,3})', caseSensitive: false);
    final multiX = RegExp(r'(\d{1,2})x(\d{1,3})[ ._-]*-[ ._-]*x?(\d{1,3})', caseSensitive: false);

    if (multiSxE.hasMatch(t) || multiX.hasMatch(t)) {
      isMultiEpisode = true;
    }

    // Standard SxxExx
    final sXe = RegExp(r's(\d{1,2})[ ._-]*e(\d{1,3})', caseSensitive: false);
    final x = RegExp(r'\b(\d{1,2})x(\d{1,3})\b', caseSensitive: false);
    final written = RegExp(r'season\s*(\d{1,2})\s*episode\s*(\d{1,3})', caseSensitive: false);

    var match = sXe.firstMatch(t);
    if (match != null) {
      season = int.tryParse(match.group(1)!);
      episode = int.tryParse(match.group(2)!);
      matchIndex = match.start;
    } else {
      match = x.firstMatch(t);
      if (match != null) {
        season = int.tryParse(match.group(1)!);
        episode = int.tryParse(match.group(2)!);
        matchIndex = match.start;
      } else {
        match = written.firstMatch(t);
        if (match != null) {
          season = int.tryParse(match.group(1)!);
          episode = int.tryParse(match.group(2)!);
          matchIndex = match.start;
        }
      }
    }

    // Season only
    if (season == null) {
      final sOnly = RegExp(r'\bs(\d{1,2})\b', caseSensitive: false);
      final sWritten = RegExp(r'season\s*(\d{1,2})\b', caseSensitive: false);
      
      var sMatch = sOnly.firstMatch(t);
      if (sMatch != null) {
        season = int.tryParse(sMatch.group(1)!);
        isSeasonPack = true;
        matchIndex = sMatch.start;
      } else {
        sMatch = sWritten.firstMatch(t);
        if (sMatch != null) {
          season = int.tryParse(sMatch.group(1)!);
          isSeasonPack = true;
          matchIndex = sMatch.start;
        }
      }
    }

    if (t.contains('complete') || t.contains('season pack') || t.contains('batch')) {
      if (season != null && episode == null) isSeasonPack = true;
      if (season != null && episode != null) isMultiEpisode = true; 
    }
    
    if (season != null && episode == null && !isSeasonPack) {
      isSeasonPack = true;
    }

    return {
      'season': season,
      'episode': episode,
      'isSeasonPack': isSeasonPack,
      'isMultiEpisode': isMultiEpisode,
      'isMultiSeason': isMultiSeason,
      'matchIndex': matchIndex,
    };
  }

  static bool isVideoFile(String fileName) {
    final t = fileName.toLowerCase();
    const videoExtensions = [
      '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', 
      '.m4v', '.mpg', '.mpeg', '.m2ts', '.ts', '.vob', '.ogv', 
      '.3gp', '.3g2', '.f4v', '.asf', '.rm', '.rmvb', '.divx'
    ];
    return videoExtensions.any((ext) => t.endsWith(ext));
  }

  static bool isFileMatch(String fileName, int season, int episode) {
    final t = fileName.toLowerCase();
    
    if (!isVideoFile(t)) return false;
    
    // Strict SXXEYY match
    final sXe = RegExp('s0*$season[ ._-]*e0*$episode\\b', caseSensitive: false);
    final anySxE = RegExp(r's\d+[ ._-]*e\d+\b', caseSensitive: false);
    
    if (anySxE.hasMatch(t)) {
      return sXe.hasMatch(t); // If it has SxxEyy format, it MUST match the requested season/episode exactly.
    }

    // Strict [S]x[E] match (e.g. 1x01)
    final xMatch = RegExp('\\b0*$season[ ._-]*x[ ._-]*0*$episode\\b', caseSensitive: false);
    final anyXMatch = RegExp(r'\b\d+[ ._-]*x[ ._-]*\d+\b', caseSensitive: false);

    if (anyXMatch.hasMatch(t)) {
      return xMatch.hasMatch(t);
    }

    // Check for "season 2" when we want season 1
    final wrongSeason = RegExp('\\bseason[ ._-]*(?!0*$season\\b)\\d+\\b', caseSensitive: false);
    final rightSeason = RegExp('\\bseason[ ._-]*0*$season\\b', caseSensitive: false);
    if (wrongSeason.hasMatch(t) && !rightSeason.hasMatch(t)) {
      return false; // Explicitly in a different season's folder or named wrong season
    }

    // Fallbacks if no explicit season/episode format is found.
    final eOnly = RegExp('\\be[ ._-]*0*$episode\\b', caseSensitive: false);
    if (eOnly.hasMatch(t)) return true;

    final epOnlyStr = RegExp('\\bep(isode)?[ ._-]*0*$episode\\b', caseSensitive: false);
    if (epOnlyStr.hasMatch(t)) return true;

    final epOnly = RegExp('\\b0*$episode\\b');
    if (epOnly.hasMatch(t)) return true;

    return false;
  }

  // Wrapper for background compute
  static Future<List<TorrentResult>> filterTorrentsAsync(
    List<TorrentResult> items, 
    String showTitle, 
    {int? requiredSeason, int? requiredEpisode}
  ) async {
    return await compute(_filterTorrentsWorker, {
      'items': items,
      'showTitle': showTitle,
      'requiredSeason': requiredSeason,
      'requiredEpisode': requiredEpisode,
    });
  }

  static List<TorrentResult> _filterTorrentsWorker(Map<String, dynamic> params) {
    return filterTorrents(
      params['items'] as List<TorrentResult>,
      params['showTitle'] as String,
      requiredSeason: params['requiredSeason'] as int?,
      requiredEpisode: params['requiredEpisode'] as int?,
    );
  }

  static List<TorrentResult> filterTorrents(
    List<TorrentResult> items, 
    String showTitle, 
    {int? requiredSeason, int? requiredEpisode}
  ) {
    if (items.isEmpty) return [];
    if (showTitle.isEmpty) return items;

    final normShowTitle = normalizeTitle(showTitle);
    
    return items.where((item) {
      String cleanTitle = item.name.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');
      
      final info = parseSceneInfo(cleanTitle);
      String titlePart;
      
      if (info['matchIndex'] > -1) {
        titlePart = cleanTitle.substring(0, info['matchIndex']);
      } else {
        titlePart = cleanTitle;
      }

      final normTitlePart = normalizeTitle(titlePart);
      
      if (!normTitlePart.startsWith(normShowTitle)) return false;
      
      if (requiredSeason != null) {
        String suffix = normTitlePart.substring(normShowTitle.length).trim();
        
        final noiseWords = ['complete', 'series', 'season', 'multi', 'bluray', 'webrip', 'web', 'dl', 'hdtv', 'x264', 'x265', 'h264', 'h265', 'hevc', '1080p', '720p', '4k', 'uhd'];
        for (var word in noiseWords) {
          suffix = suffix.replaceAll(word, '').trim();
        }

        if (suffix.isNotEmpty) {
          final yearMatch = RegExp(r'^\d{4}$').hasMatch(suffix);
          if (!yearMatch && suffix.isNotEmpty) return false; 
        }
      }

      if (requiredSeason != null && requiredEpisode != null) {
        if (info['season'] != requiredSeason) return false;
        if (info['episode'] != requiredEpisode) return false;
        return true;
      }
      
      if (requiredSeason != null && requiredEpisode == null) {
        if (info['season'] != null && info['season'] != requiredSeason) {
          final rangeMatch = RegExp(r's(\d+)\s*-\s*s?(\d+)', caseSensitive: false).firstMatch(cleanTitle.toLowerCase());
          if (rangeMatch != null) {
            int start = int.parse(rangeMatch.group(1)!);
            int end = int.parse(rangeMatch.group(2)!);
            if (requiredSeason < start || requiredSeason > end) return false;
          } else {
            return false;
          }
        }
        return info['isSeasonPack'] || info['isMultiSeason'] || (info['season'] != null && info['episode'] == null);
      }
      
      return true;
    }).toList();
  }

  /// Sorts torrents in a background isolate to prevent UI lag
  static Future<List<TorrentResult>> sortTorrentsAsync(List<TorrentResult> items, String preference) async {
    return compute(_sortWorker, {'items': items, 'preference': preference});
  }

  static List<TorrentResult> _sortWorker(Map<String, dynamic> params) {
    final List<TorrentResult> items = params['items'] as List<TorrentResult>;
    final String preference = params['preference'] as String;
    
    switch (preference) {
      case 'Seeders (High to Low)':
        items.sort((a, b) => _parseSeeds(b.seeders).compareTo(_parseSeeds(a.seeders)));
        break;
      case 'Seeders (Low to High)':
        items.sort((a, b) => _parseSeeds(a.seeders).compareTo(_parseSeeds(b.seeders)));
        break;
      case 'Quality (High to Low)':
        items.sort((a, b) {
          final qCmp = _getQualityScore(b.name).compareTo(_getQualityScore(a.name));
          if (qCmp != 0) return qCmp;
          return _parseSeeds(b.seeders).compareTo(_parseSeeds(a.seeders));
        });
        break;
      case 'Quality (Low to High)':
        items.sort((a, b) {
          final qCmp = _getQualityScore(a.name).compareTo(_getQualityScore(b.name));
          if (qCmp != 0) return qCmp;
          return _parseSeeds(b.seeders).compareTo(_parseSeeds(a.seeders));
        });
        break;
      case 'Size (High to Low)':
        items.sort((a, b) => b.sizeInBytes.compareTo(a.sizeInBytes));
        break;
      case 'Size (Low to High)':
        items.sort((a, b) => a.sizeInBytes.compareTo(b.sizeInBytes));
        break;
    }
    return items;
  }

  static int _parseSeeds(String seeds) {
    return int.tryParse(seeds.replaceAll(',', '')) ?? 0;
  }

  static int _getQualityScore(String name) {
    name = name.toLowerCase();
    if (name.contains('2160p') || name.contains('4k') || name.contains('uhd')) return 400;
    if (name.contains('1080p') || name.contains('fhd')) return 300;
    if (name.contains('720p') || name.contains('hd')) return 200;
    if (name.contains('480p') || name.contains('sd')) return 100;
    return 0;
  }
}
