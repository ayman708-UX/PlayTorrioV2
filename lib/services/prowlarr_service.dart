import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/torrent_result.dart';

/// A tag defined in Prowlarr
class ProwlarrTag {
  final int id;
  final String label;

  const ProwlarrTag({required this.id, required this.label});
}

/// Result of a Prowlarr connection test
class ConnectionTestResult {
  final bool success;
  final String message;
  final String? version;

  ConnectionTestResult({
    required this.success,
    required this.message,
    this.version,
  });
}

/// Service for searching torrents via Prowlarr
class ProwlarrService {
  final http.Client _client = http.Client();
  static const Duration _timeout = Duration(seconds: 30);

  /// Top-level categories only — sub-categories (5030, 5040, etc.) cause
  /// indexers that don't explicitly advertise them to be excluded from the
  /// search pool, triggering the "all indexers unavailable" 400 error.
  /// Prowlarr automatically searches sub-categories when the parent is used.
  static const List<int> _categories = [2000, 5000];

  /// Search for torrents using Prowlarr.
  /// If [indexerIds] is provided and non-empty, only those indexers are queried.
  /// Pass null or an empty list to search all torrent indexers (indexerIds=-2).
  Future<List<TorrentResult>> search(
    String baseUrl,
    String apiKey,
    String query, {
    List<int>? indexerIds,
  }) async {
    try {
      final normalizedUrl = _normalizeBaseUrl(baseUrl);
      debugPrint('🔍 Prowlarr Search Starting...');
      debugPrint('   Base URL: $normalizedUrl');
      debugPrint('   Query: "$query"');
      debugPrint('   API Key: ${apiKey.substring(0, 8)}...');

      // indexerIds=-2 means ALL torrent indexers.
      // indexerIds=-1 means ALL USENET indexers — wrong for torrents!
      // When specific indexer IDs are provided (from tag filtering), use those instead.
      //
      // Categories: only pass top-level (2000=Movies, 5000=TV).
      // Sub-categories like 5030/5040 cause Prowlarr to exclude indexers
      // that don't explicitly advertise those caps, causing 400 errors.
      // Prowlarr automatically includes sub-categories of a parent.
      //
      // Repeated query keys are required — not comma-separated.
      final categoriesQuery = _categories.map((c) => 'categories=$c').join('&');
      final indexerIdsQuery = (indexerIds != null && indexerIds.isNotEmpty)
          ? indexerIds.map((id) => 'indexerIds=$id').join('&')
          : 'indexerIds=-2';
      debugPrint('   Indexer filter: $indexerIdsQuery');
      final fullQuery =
          'query=${Uri.encodeQueryComponent(query)}'
          '&$indexerIdsQuery'
          '&type=search'
          '&$categoriesQuery';

      final uri = Uri.parse('$normalizedUrl/api/v1/search?$fullQuery');
      debugPrint('   Full URL: $uri');

      final response = await _client.get(
        uri,
        headers: {'X-Api-Key': apiKey},
      ).timeout(_timeout);

      debugPrint('   Response Status: ${response.statusCode}');
      debugPrint('   Response Length: ${response.body.length} bytes');

      if (response.statusCode == 401) {
        throw Exception('❌ Wrong API key (401). Check your API key in Settings.');
      }
      if (response.statusCode == 400) {
        debugPrint('   ❌ Bad Request Body: ${response.body}');
        if (response.body.contains('all selected indexers being unavailable')) {
          throw Exception(
            '❌ No torrent indexers available in Prowlarr. '
            'Go to Prowlarr → Indexers and ensure at least one torrent indexer is configured and tested successfully.',
          );
        }
        throw Exception('❌ Bad request (400). Response: ${response.body}');
      }
      if (response.statusCode == 403) {
        throw Exception('❌ Access denied (403). Check your Prowlarr API key and server configuration.');
      }
      if (response.statusCode == 500) {
        debugPrint('   ❌ Server Error Body: ${response.body}');
        throw Exception('❌ Prowlarr server error (500). Check the Prowlarr logs.');
      }
      if (response.statusCode != 200) {
        throw Exception('❌ Prowlarr returned HTTP ${response.statusCode}');
      }

      final results = _parseJsonResults(response.body);
      debugPrint('   ✅ Parsed ${results.length} results');
      return results;
    } on http.ClientException catch (e) {
      debugPrint('   ❌ ClientException: $e');
      throw Exception('⚠️ Cannot connect to Prowlarr. Is it running? Check your Base URL in Settings.');
    } catch (e) {
      debugPrint('   ❌ Error: $e');
      if (e.toString().contains('TimeoutException')) {
        throw Exception('⚠️ Prowlarr timed out. It may be overloaded or the URL is wrong.');
      }
      if (e is Exception) rethrow;
      throw Exception('⚠️ Unexpected error: $e');
    }
  }

  /// Test connection to Prowlarr
  Future<ConnectionTestResult> testConnection(
    String baseUrl,
    String apiKey,
  ) async {
    try {
      final normalizedUrl = _normalizeBaseUrl(baseUrl);
      final uri = Uri.parse('$normalizedUrl/api/v1/system/status');

      final response = await _client.get(
        uri,
        headers: {'X-Api-Key': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 401) {
        return ConnectionTestResult(success: false, message: '❌ Wrong API key (401)');
      }

      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final version = data['version'] as String?;
          return ConnectionTestResult(
            success: true,
            message: version != null ? '✅ Connected — Prowlarr v$version' : '✅ Connected',
            version: version,
          );
        } catch (_) {
          return ConnectionTestResult(success: true, message: '✅ Connected');
        }
      }

      return ConnectionTestResult(success: false, message: '❌ HTTP ${response.statusCode}');
    } on http.ClientException {
      return ConnectionTestResult(success: false, message: '❌ Cannot connect to Prowlarr');
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        return ConnectionTestResult(success: false, message: '❌ Connection timed out');
      }
      return ConnectionTestResult(success: false, message: '❌ Error: $e');
    }
  }

  /// Parse JSON response from Prowlarr
  List<TorrentResult> _parseJsonResults(String jsonBody) {
    try {
      debugPrint('   📦 Parsing JSON response...');
      final List<dynamic> data = jsonDecode(jsonBody) as List<dynamic>;
      debugPrint('   📦 Total items in response: ${data.length}');
      final results = <TorrentResult>[];

      for (final item in data) {
        try {
          final map = item as Map<String, dynamic>;

          // Filter out usenet results (shouldn't appear with indexerIds=-2 but be safe)
          final protocol = map['protocol'] as String?;
          if (protocol == 'usenet') {
            debugPrint('   ⏭️  Skipping usenet result');
            continue;
          }

          final title = map['title'] as String? ?? 'Unknown';
          final size = map['size'] as int? ?? 0;
          final seeders = map['seeders'] as int?;
          final indexer = map['indexer'] as String? ?? 'Prowlarr';
          final shortTitle = title.length > 50 ? '${title.substring(0, 50)}...' : title;

          // Get download link with priority:
          // 1. magnetUrl  (best — already resolved)
          // 2. downloadUrl (Prowlarr proxy — works but requires a follow-up download)
          // 3. infoHash   (construct magnet manually)
          String? downloadLink;

          final magnetUrl = map['magnetUrl'] as String?;
          if (magnetUrl != null && magnetUrl.isNotEmpty && magnetUrl.startsWith('magnet:')) {
            downloadLink = magnetUrl;
            debugPrint('   ✅ magnetUrl for: $shortTitle');
          }

          if (downloadLink == null) {
            final dlUrl = map['downloadUrl'] as String?;
            if (dlUrl != null && dlUrl.isNotEmpty) {
              downloadLink = dlUrl;
              debugPrint('   ⚠️  downloadUrl for: $shortTitle');
            }
          }

          if (downloadLink == null) {
            final infoHash = map['infoHash'] as String?;
            if (infoHash != null && infoHash.isNotEmpty) {
              downloadLink = 'magnet:?xt=urn:btih:$infoHash&dn=${Uri.encodeComponent(title)}';
              debugPrint('   🔗 infoHash magnet for: $shortTitle');
            }
          }

          if (downloadLink != null && downloadLink.isNotEmpty) {
            results.add(TorrentResult(
              name: title,
              magnet: downloadLink,
              seeders: seeders?.toString() ?? '?',
              size: _formatSize(size),
              source: indexer,
            ));
          } else {
            debugPrint('   ❌ No download link for: $shortTitle');
          }
        } catch (e) {
          debugPrint('   ❌ Error parsing item: $e');
          continue;
        }
      }

      debugPrint('   ✅ Successfully parsed ${results.length} torrent results');

      // Sort by seeders descending (unknowns to bottom)
      results.sort((a, b) {
        final aSeeds = int.tryParse(a.seeders.replaceAll(RegExp(r'[^0-9]'), ''));
        final bSeeds = int.tryParse(b.seeders.replaceAll(RegExp(r'[^0-9]'), ''));
        if (aSeeds == null && bSeeds == null) return 0;
        if (aSeeds == null) return 1;
        if (bSeeds == null) return -1;
        return bSeeds.compareTo(aSeeds);
      });

      return results;
    } catch (e) {
      debugPrint('   ❌ JSON parsing error: $e');
      throw Exception('⚠️ Unexpected response from Prowlarr. The server may be misconfigured.');
    }
  }

  /// Format bytes to human-readable string
  String _formatSize(int bytes) {
    if (bytes <= 0) return 'Unknown';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Fetch all tags configured in Prowlarr.
  Future<List<ProwlarrTag>> fetchTags(String baseUrl, String apiKey) async {
    final normalizedUrl = _normalizeBaseUrl(baseUrl);
    final uri = Uri.parse('$normalizedUrl/api/v1/tag');
    final response = await _client.get(
      uri,
      headers: {'X-Api-Key': apiKey},
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch Prowlarr tags (HTTP ${response.statusCode})');
    }
    final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) {
      final m = e as Map<String, dynamic>;
      return ProwlarrTag(id: m['id'] as int, label: m['label'] as String);
    }).toList();
  }

  /// Resolve a list of tag IDs to the indexer IDs that have at least one
  /// of those tags. Returns an empty list if no indexers match, in which
  /// case the caller should fall back to searching all indexers.
  Future<List<int>> resolveTagIndexerIds(
    String baseUrl,
    String apiKey,
    List<int> tagIds,
  ) async {
    if (tagIds.isEmpty) return [];
    final normalizedUrl = _normalizeBaseUrl(baseUrl);
    final uri = Uri.parse('$normalizedUrl/api/v1/indexer');
    final response = await _client.get(
      uri,
      headers: {'X-Api-Key': apiKey},
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch Prowlarr indexers (HTTP ${response.statusCode})');
    }
    final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
    final tagSet = tagIds.toSet();
    final result = <int>[];
    for (final item in data) {
      final m = item as Map<String, dynamic>;
      final protocol = m['protocol'] as String?;
      if (protocol == 'usenet') continue; // skip usenet indexers
      final tags = (m['tags'] as List<dynamic>?)?.map((t) => t as int).toList() ?? [];
      if (tags.any((t) => tagSet.contains(t))) {
        result.add(m['id'] as int);
      }
    }
    debugPrint('🏷️  Tag filter: tags=$tagIds → indexerIds=$result');
    return result;
  }

  /// Normalize base URL — remove trailing slashes
  String _normalizeBaseUrl(String url) {
    return url.trimRight().replaceAll(RegExp(r'/+$'), '');
  }

  void dispose() {
    _client.close();
  }
}