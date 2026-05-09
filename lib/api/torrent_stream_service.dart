import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'settings_service.dart';
import 'torrent_filter.dart';

/// Rich torrent statistics object.
class TorrentStats {
  final double speedMbps;
  final int activePeers;
  final int totalPeers;
  final double cachePercent;
  final int loadedBytes;
  final int totalBytes;
  final String hash;
  final bool isConnected;

  const TorrentStats({
    required this.speedMbps,
    required this.activePeers,
    required this.totalPeers,
    required this.cachePercent,
    required this.loadedBytes,
    required this.totalBytes,
    required this.hash,
    required this.isConnected,
  });

  double get speedKbps => speedMbps * 1024;
  String get speedLabel => speedMbps >= 1.0
      ? '${speedMbps.toStringAsFixed(2)} MB/s'
      : '${speedKbps.toStringAsFixed(0)} KB/s';
  String get peersLabel => '$activePeers / $totalPeers';
  String get cacheLabel => '${cachePercent.toStringAsFixed(1)}%';
}

/// Engine lifecycle states.
enum EngineState { stopped, starting, ready, error }

/// Drop-in replacement for TorrServerService using libtorrent_flutter.
///
/// Same public API:
///   start(), streamTorrent(), removeTorrent(), getTorrentStats(),
///   statsStream(), stop(), cleanup()
class TorrentStreamService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final TorrentStreamService _instance = TorrentStreamService._internal();
  factory TorrentStreamService() => _instance;
  TorrentStreamService._internal();

  // ── State ──────────────────────────────────────────────────────────────────
  EngineState _state = EngineState.stopped;
  EngineState get state => _state;

  void Function(EngineState state)? onStateChanged;
  void Function(String line)? onLogLine;

  /// Active torrent IDs keyed by info-hash for cleanup.
  final Map<String, int> _activeTorrents = {};

  /// Active stream IDs keyed by info-hash for cleanup.
  final Map<String, int> _activeStreams = {};

  /// Track disposed torrent/stream IDs to prevent double-dispose native crash.
  final Set<int> _disposedTorrentIds = {};
  final Set<int> _disposedStreamIds = {};

  StreamSubscription? _torrentUpdatesSub;

  /// Latest torrent update snapshots keyed by torrent ID.
  final Map<int, TorrentInfo> _latestUpdates = {};

  final SettingsService _settings = SettingsService();

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  /// Initialises the libtorrent engine. Safe to call multiple times.
  Future<bool> start() async {
    if (_state == EngineState.ready) return true;
    if (_state == EngineState.starting) {
      // Wait for init to finish
      for (int i = 0; i < 50; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_state == EngineState.ready) return true;
        if (_state == EngineState.error) return false;
      }
      return false;
    }

    _setState(EngineState.starting);
    try {
      await LibtorrentFlutter.init(
        fetchTrackers: true,
        pollInterval: const Duration(milliseconds: 200),
      );

      try {
        final engine = LibtorrentFlutter.instance;
        final connLimit = await _settings.getTorrentConnectionsLimit();
        engine.configureSession(engine.getDefaultConfig().copyWith(
          connectionsLimit: connLimit,
          forceEncrypt: false,
          disableDht: false,
          downloadRateLimit: 0,
          uploadRateLimit: 0,
        ));
        _log('Session configured: conns=$connLimit');
      } catch (e) {
        _log('configureSession failed (non-fatal): $e');
      }

      _torrentUpdatesSub = LibtorrentFlutter.instance.torrentUpdates.listen((updates) {
        _latestUpdates.addAll(updates);
      });
      _setState(EngineState.ready);
      _log('Engine ready (libtorrent_flutter)');
      return true;
    } catch (e, st) {
      _log('Failed to start engine: $e\n$st');
      _setState(EngineState.error);
      return false;
    }
  }

  /// Live-update the per-torrent peer connection limit. Persists the new
  /// value and reconfigures the running session immediately.
  Future<void> applyConnectionsLimit(int limit) async {
    final clamped = limit.clamp(5, 200);
    await _settings.setTorrentConnectionsLimit(clamped);
    if (_state != EngineState.ready) return;
    try {
      final engine = LibtorrentFlutter.instance;
      engine.configureSession(engine.getDefaultConfig().copyWith(
        connectionsLimit: clamped,
        forceEncrypt: false,
        disableDht: false,
        downloadRateLimit: 0,
        uploadRateLimit: 0,
      ));
      _log('Connections limit updated: $clamped');
    } catch (e) {
      _log('applyConnectionsLimit failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Stream a torrent — main entry point
  // ─────────────────────────────────────────────────────────────────────────

  /// Adds a magnet, waits for metadata, selects the right file, starts an
  /// HTTP stream, and returns the stream URL.
  ///
  /// Matches the old TorrServerService.streamTorrent() signature exactly.
  Future<String?> streamTorrent(
    String magnetLink, {
    int? season,
    int? episode,
    int? fileIdx,
  }) async {
    if (_state != EngineState.ready) {
      final started = await start();
      if (!started) {
        _log('Cannot stream: engine failed to start.');
        return null;
      }
    }

    final hash = _extractHash(magnetLink);

    // Dispose previous torrent with same hash if any
    if (hash != null && _activeTorrents.containsKey(hash)) {
      try {
        final oldId = _activeTorrents[hash]!;
        if (_activeStreams.containsKey(hash)) {
          _safeStopStream(_activeStreams[hash]!);
          _activeStreams.remove(hash);
        }
        _safeDisposeTorrent(oldId);
        _activeTorrents.remove(hash);
      } catch (e) {
        _log('Cleanup old torrent error: $e');
      }
    }

    try {
      // Step 1: Read cache settings
      final cacheType = await _settings.getTorrentCacheType();
      final ramCacheMb = await _settings.getTorrentRamCacheMb();
      final saveToRam = cacheType == 'ram';

      // Step 2: Add the magnet
      final torrentId = LibtorrentFlutter.instance.addMagnet(magnetLink, null, saveToRam);
      if (hash != null) {
        _activeTorrents[hash] = torrentId;
      }
      _log('Added magnet, torrentId=$torrentId');

      // Step 3: Wait for metadata
      final files = await _waitForMetadata(torrentId);
      if (files == null || files.isEmpty) {
        _log('No files found in torrent');
        return null;
      }

      // Step 4: Select the right file
      final selectedIndex = _selectFile(files, season: season, episode: episode, preferredIdx: fileIdx);
      if (selectedIndex == null) {
        _log('No suitable video file found');
        return null;
      }

      _log('Selected file index $selectedIndex: ${files.firstWhere((f) => f.index == selectedIndex).name}');

      // Step 5: Start the stream.
      // maxCacheBytes controls the sliding RAM window — pass the user's
      // configured value when using RAM cache, otherwise let the engine
      // use its default (0 = engine default ~128MB).
      final maxCacheBytes = saveToRam ? (ramCacheMb * 1024 * 1024) : 0;
      final streamInfo = LibtorrentFlutter.instance.startStream(
        torrentId,
        fileIndex: selectedIndex,
        maxCacheBytes: maxCacheBytes,
      );

      if (hash != null) {
        _activeStreams[hash] = streamInfo.id;
      }

      _log('Stream started: ${streamInfo.url}');
      return streamInfo.url;
    } catch (e) {
      _log('streamTorrent error: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Metadata polling
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<FileInfo>?> _waitForMetadata(int torrentId, {Duration timeout = const Duration(seconds: 30)}) async {
    final completer = Completer<List<FileInfo>?>();
    StreamSubscription? sub;

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _log('Metadata timeout after ${timeout.inSeconds}s');
        sub?.cancel();
        completer.complete(null);
      }
    });

    sub = LibtorrentFlutter.instance.torrentUpdates.listen((updates) {
      if (completer.isCompleted) return;
      if (updates.containsKey(torrentId)) {
        final info = updates[torrentId]!;
        if (info.hasMetadata) {
          timer.cancel();
          sub?.cancel();
          final files = LibtorrentFlutter.instance.getFiles(torrentId);
          completer.complete(files);
        }
      }
    });

    // Also check if metadata is already available
    try {
      final files = LibtorrentFlutter.instance.getFiles(torrentId);
      if (files.isNotEmpty) {
        timer.cancel();
        sub.cancel();
        if (!completer.isCompleted) {
          completer.complete(files);
        }
      }
    } catch (_) {
      // Not ready yet, wait for updates
    }

    return completer.future;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // File selection — same logic as old TorrServerService
  // ─────────────────────────────────────────────────────────────────────────

  int? _selectFile(List<FileInfo> files, {int? season, int? episode, int? preferredIdx}) {
    // Filter to streamable video files
    final videoFiles = files.where((f) => f.isStreamable && TorrentFilter.isVideoFile(f.name)).toList();
    if (videoFiles.isEmpty) {
      // Fallback: any streamable file
      final streamable = files.where((f) => f.isStreamable).toList();
      if (streamable.isEmpty) return null;
      streamable.sort((a, b) => b.size.compareTo(a.size));
      return streamable.first.index;
    }

    // 1. Season/episode match
    if (season != null && episode != null) {
      final episodeMatches = videoFiles
          .where((f) => TorrentFilter.isFileMatch(f.name, season, episode))
          .toList();
      if (episodeMatches.isNotEmpty) {
        episodeMatches.sort((a, b) => b.size.compareTo(a.size));
        return episodeMatches.first.index;
      }
    }

    // 2. Preferred index from Stremio addon (if valid video)
    if (preferredIdx != null) {
      final match = videoFiles.where((f) => f.index == preferredIdx).toList();
      if (match.isNotEmpty) {
        return match.first.index;
      }
    }

    // 3. Largest video file
    videoFiles.sort((a, b) => b.size.compareTo(a.size));
    return videoFiles.first.index;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Torrent management
  // ─────────────────────────────────────────────────────────────────────────

  /// Removes/disposes a torrent and stops its streams.
  void removeTorrent(String magnetOrHash) {
    final hash = _extractHash(magnetOrHash);
    final key = hash ?? magnetOrHash;

    // Stop stream
    if (_activeStreams.containsKey(key)) {
      _safeStopStream(_activeStreams[key]!);
      _activeStreams.remove(key);
    }

    // Dispose torrent
    if (_activeTorrents.containsKey(key)) {
      final torrentId = _activeTorrents[key]!;
      _safeDisposeTorrent(torrentId);
      _activeTorrents.remove(key);
      _latestUpdates.remove(torrentId);
      _log('Removed torrent $key');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Statistics
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns stats for a torrent, or null if unavailable.
  TorrentStats? getTorrentStats(String magnetOrHash) {
    final hash = _extractHash(magnetOrHash);
    final key = hash ?? magnetOrHash;
    final torrentId = _activeTorrents[key];
    if (torrentId == null) return null;

    final info = _latestUpdates[torrentId];
    if (info == null) return null;

    final speedMbps = info.downloadRate / 1024 / 1024;

    return TorrentStats(
      speedMbps: speedMbps,
      activePeers: info.numPeers,
      totalPeers: info.numPeers,
      cachePercent: info.progress * 100,
      loadedBytes: info.totalDone,
      totalBytes: info.totalWanted,
      hash: key,
      isConnected: info.numPeers > 0,
    );
  }

  /// Streams stats at [interval] for a torrent.
  Stream<TorrentStats> statsStream(
    String magnetOrHash, {
    Duration interval = const Duration(seconds: 1),
  }) {
    final controller = StreamController<TorrentStats>();
    Timer? timer;

    controller.onListen = () {
      timer = Timer.periodic(interval, (_) {
        final stats = getTorrentStats(magnetOrHash);
        if (stats != null && !controller.isClosed) {
          controller.add(stats);
        }
      });
    };

    controller.onCancel = () {
      timer?.cancel();
      controller.close();
    };

    return controller.stream;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Stop / cleanup
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    for (final streamId in _activeStreams.values) {
      _safeStopStream(streamId);
    }
    _activeStreams.clear();

    for (final torrentId in _activeTorrents.values) {
      _safeDisposeTorrent(torrentId);
    }
    _activeTorrents.clear();
    _latestUpdates.clear();

    _log('All torrents stopped.');
  }

  Future<void> cleanup() async {
    await stop();
    _torrentUpdatesSub?.cancel();
    _torrentUpdatesSub = null;
    _disposedTorrentIds.clear();
    _disposedStreamIds.clear();
    _setState(EngineState.stopped);
    _log('Engine cleaned up.');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Safely stop a stream, preventing double-stop native crash.
  void _safeStopStream(int streamId) {
    if (_disposedStreamIds.contains(streamId)) return;
    _disposedStreamIds.add(streamId);
    try {
      LibtorrentFlutter.instance.stopStream(streamId);
    } catch (e) {
      _log('Stop stream error: $e');
    }
  }

  /// Safely dispose a torrent, preventing double-dispose native crash.
  void _safeDisposeTorrent(int torrentId) {
    if (_disposedTorrentIds.contains(torrentId)) return;
    _disposedTorrentIds.add(torrentId);
    try {
      LibtorrentFlutter.instance.disposeTorrent(torrentId);
    } catch (e) {
      _log('Dispose torrent error: $e');
    }
  }

  static final _hashRegExp = RegExp(r'[0-9a-fA-F]{40}');

  String? _extractHash(String magnetOrHash) {
    final match = _hashRegExp.firstMatch(magnetOrHash);
    return match?.group(0)?.toLowerCase();
  }

  void _setState(EngineState s) {
    if (_state == s) return;
    _state = s;
    onStateChanged?.call(s);
  }

  void _log(String message) {
    debugPrint('[TorrentStream] $message');
    onLogLine?.call(message);
  }
}