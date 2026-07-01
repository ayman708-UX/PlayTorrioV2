import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/trakt_service.dart';
import '../api/simkl_service.dart';

/// Lightweight service to track which episodes the user has manually
/// marked as "done watching". Persisted via SharedPreferences so the
/// state is shared across *all* detail screens (torrent & streaming).
///
/// Syncs to Trakt and Simkl when toggling watched state.
class EpisodeWatchedService {
  static final EpisodeWatchedService _instance = EpisodeWatchedService._();
  factory EpisodeWatchedService() => _instance;
  EpisodeWatchedService._();

  static const String _key = 'episodes_watched';

  // In-memory cache: "tmdbId_S{season}_E{episode}" → true
  Map<String, bool>? _cache;

  Future<Map<String, bool>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      _cache = decoded.map((k, v) => MapEntry(k, v == true));
    } else {
      _cache = {};
    }
    return _cache!;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, json.encode(_cache));
  }

  String _id(int tmdbId, int season, int episode) =>
      '${tmdbId}_S${season}_E$episode';

  Future<bool> isWatched(int tmdbId, int season, int episode) async {
    final map = await _load();
    return map[_id(tmdbId, season, episode)] == true;
  }

  Future<Set<String>> getWatchedSet(int tmdbId) async {
    final map = await _load();
    return map.keys.where((k) => k.startsWith('${tmdbId}_') && map[k] == true).toSet();
  }

  Future<void> toggle(int tmdbId, int season, int episode) async {
    final map = await _load();
    final id = _id(tmdbId, season, episode);
    final current = map[id] == true;
    map[id] = !current;
    await _save();
    debugPrint('[EpisodeWatched] ${!current ? "Marked" : "Unmarked"} $id');
    // Sync to tracking services in background
    _syncEpisodeState(tmdbId, season, episode, !current);
  }

  Future<void> setWatched(int tmdbId, int season, int episode, bool watched) async {
    final map = await _load();
    final id = _id(tmdbId, season, episode);
    map[id] = watched;
    await _save();
    // Sync to tracking services in background
    _syncEpisodeState(tmdbId, season, episode, watched);
  }

  /// Set watched without triggering external sync (used during import).
  Future<void> setWatchedLocal(int tmdbId, int season, int episode, bool watched) async {
    final map = await _load();
    final id = _id(tmdbId, season, episode);
    map[id] = watched;
    await _save();
  }

  /// Set watched with a timestamp, without triggering external sync (used during import).
  Future<void> setWatchedLocalWithTimestamp(
      int tmdbId, int season, int episode, bool watched, String? watchedAt) async {
    final map = await _load();
    final id = _id(tmdbId, season, episode);
    map[id] = watched;
    await _save();
    // Store timestamp separately
    if (watchedAt != null && watched) {
      await _saveTimestamp(id, watchedAt);
    }
  }

  static const String _timestampKey = 'episodes_watched_timestamps';
  Map<String, String>? _timestampCache;

  Future<Map<String, String>> _loadTimestamps() async {
    if (_timestampCache != null) return _timestampCache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_timestampKey);
    if (raw != null) {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      _timestampCache = decoded.map((k, v) => MapEntry(k, v.toString()));
    } else {
      _timestampCache = {};
    }
    return _timestampCache!;
  }

  Future<void> _saveTimestamp(String id, String watchedAt) async {
    final map = await _loadTimestamps();
    map[id] = watchedAt;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_timestampKey, json.encode(map));
  }

  Future<String?> getTimestamp(int tmdbId, int season, int episode) async {
    final map = await _loadTimestamps();
    return map[_id(tmdbId, season, episode)];
  }

  /// Get all stored timestamps. Used by Trakt export for deduplication.
  Future<Map<String, String>> getAllTimestamps() async {
    return await _loadTimestamps();
  }

  // ── Sync to Trakt & Simkl ──────────────────────────────────────────────
  void _syncEpisodeState(int tmdbId, int season, int episode, bool watched) {
    // Trakt
    TraktService().isLoggedIn().then((loggedIn) {
      if (!loggedIn) return;
      if (watched) {
        TraktService().addToHistory(
          tmdbId: tmdbId,
          mediaType: 'tv',
          season: season,
          episode: episode,
        );
      } else {
        TraktService().removeFromHistory(
          tmdbId: tmdbId,
          mediaType: 'tv',
          season: season,
          episode: episode,
        );
      }
    });

    // Simkl
    SimklService().isLoggedIn().then((loggedIn) {
      if (!loggedIn) return;
      if (watched) {
        SimklService().addToHistory(shows: [
          {
            'ids': {'tmdb': tmdbId},
            'seasons': [
              {
                'number': season,
                'episodes': [
                  {'number': episode}
                ]
              }
            ]
          }
        ]);
      } else {
        SimklService().removeFromHistory(shows: [
          {
            'ids': {'tmdb': tmdbId},
            'seasons': [
              {
                'number': season,
                'episodes': [
                  {'number': episode}
                ]
              }
            ]
          }
        ]);
      }
    });
  }
}
