import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../../utils/language_display.dart';

import 'utils.dart';
import 'menus.dart';

import '../../models/movie.dart';
import '../../models/stream_source.dart';
import '../../utils/hls_master_parser.dart';
import '../../api/subtitle_api.dart';
import '../../api/torrent_stream_service.dart';
import '../../api/stream_extractor.dart';
import '../../api/videasy_extractor.dart';
import '../../api/nuvio_service.dart';
import '../../api/vidsrc_extractor.dart';
import '../../services/watch_history_service.dart';
import '../../api/trakt_service.dart';
import '../../api/simkl_service.dart';
import '../../api/webstreamr_service.dart';
import '../../api/site111477_service.dart';
import '../../api/site111477_proxy.dart' as site111477_proxy;
import '../../api/arabic_service.dart';
import '../../api/stremio_service.dart';
import '../../api/stream_providers.dart';
import '../../api/settings_service.dart';
import '../../api/track_auto_select.dart';
import '../../api/debrid_api.dart';
import '../../api/torrent_api.dart';
import '../../api/torrent_filter.dart';
import '../../api/tmdb_service.dart';
import '../../api/introdb_service.dart';
import '../player_screen.dart';
import '../../services/pip_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  GLASSY WIDGET PRIMITIVES  (MPVEx-style frosted black glass)
// ─────────────────────────────────────────────────────────────────────────────

/// A rounded glassy container – the visual base for every button / chip.
/// [hovered] brightens the glass slightly for Windows hover feedback.
class _Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final bool hovered;

  const _Glass({
    required this.child,
    this.radius = 12,
    this.padding,
    this.tint,
    this.hovered = false,
  });

  @override
  Widget build(BuildContext context) {
    // Base fill: 0.55 so the glass reads clearly even on pure black.
    // On hover bump to 0.72 for a crisp lift effect.
    final fillOpacity = hovered ? 0.72 : 0.55;
    final borderOpacity = hovered ? 0.30 : 0.16;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            // Layered fill: tint + a constant white shimmer so it's never
            // invisible even when the video behind it is also black.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                (tint ?? const Color(0xFF1C1C1E)).withValues(alpha: fillOpacity),
                (tint ?? Colors.black).withValues(alpha: fillOpacity - 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: borderOpacity),
              width: 0.8,
            ),
            // Subtle box-shadow so button lifts off the background
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: hovered ? 0.55 : 0.35),
                blurRadius: hovered ? 12 : 6,
                spreadRadius: 0,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Glassy icon button with hover + press feedback (Windows-friendly).
class GlassIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final Color? iconColor;
  final bool active;

  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 38,
    this.iconSize = 18,
    this.iconColor,
    this.active = false,
  });

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  Color get _tint {
    if (widget.active) return const Color(0xFF6A0DAD);
    if (_pressed)      return const Color(0xFF2A2A2E);
    return const Color(0xFF1C1C1E);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() { _hovered = false; _pressed = false; }),
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp:   (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.88 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: _Glass(
            radius: widget.size / 2,
            tint: _tint,
            hovered: _hovered,
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: widget.iconColor ??
                    (widget.active
                        ? Colors.white
                        : _hovered
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.80)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassy pill / chip button with hover + press feedback.
class GlassPillButton extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  final Color? accent;

  const GlassPillButton({
    super.key,
    required this.text,
    required this.onTap,
    this.accent,
  });

  @override
  State<GlassPillButton> createState() => _GlassPillButtonState();
}

class _GlassPillButtonState extends State<GlassPillButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() { _hovered = false; _pressed = false; }),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown:   (_) => setState(() => _pressed = true),
        onTapUp:     (_) => setState(() => _pressed = false),
        onTapCancel: ()  => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.90 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: _Glass(
            radius: 20,
            tint: widget.accent ?? const Color(0xFF1C1C1E),
            hovered: _hovered,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              widget.text,
              style: TextStyle(
                color: widget.accent != null
                    ? Colors.white
                    : _hovered
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.80),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Center play/pause big button with hover + press feedback.
class _GlassPlayPause extends StatefulWidget {
  final bool isPlaying;
  final bool isBuffering;
  final VoidCallback onPressed;

  const _GlassPlayPause({
    required this.isPlaying,
    required this.isBuffering,
    required this.onPressed,
  });

  @override
  State<_GlassPlayPause> createState() => _GlassPlayPauseState();
}

class _GlassPlayPauseState extends State<_GlassPlayPause> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.isBuffering) {
      return _Glass(
        radius: 40,
        hovered: false,
        child: const SizedBox(
          width: 80,
          height: 80,
          child: Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.5,
              ),
            ),
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() { _hovered = false; _pressed = false; }),
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown:   (_) => setState(() => _pressed = true),
        onTapUp:     (_) => setState(() => _pressed = false),
        onTapCancel: ()  => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.88 : (_hovered ? 1.08 : 1.0),
          duration: const Duration(milliseconds: 100),
          child: _Glass(
            radius: 40,
            hovered: _hovered,
            child: SizedBox(
              width: 80,
              height: 80,
              child: Icon(
                widget.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 44,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gradient overlay at top or bottom of the video
class _OverlayGradient extends StatelessWidget {
  final bool isTop;
  const _OverlayGradient({required this.isTop});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: isTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: isTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.72),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HARDWARE DECODE MODE
// ─────────────────────────────────────────────────────────────────────────────

enum _HwDecMode {
  /// auto-safe: whitelisted GPU decoders, safe fallback chain. Best for most users.
  autoSafe,

  /// auto-copy: GPU decodes → copies back to RAM. Compatible with video filters.
  autoCopy,

  /// no: pure software/CPU decoding. Always works, highest CPU, most compatible.
  software,
}

extension _HwDecModeX on _HwDecMode {
  String get mpvValue => switch (this) {
        _HwDecMode.autoSafe => 'auto-safe',
        _HwDecMode.autoCopy => 'auto-copy',
        _HwDecMode.software => 'no',
      };

  String get label => switch (this) {
        _HwDecMode.autoSafe => 'HW+',
        _HwDecMode.autoCopy => 'COPY',
        _HwDecMode.software => 'SW',
      };

  String get description => switch (this) {
        _HwDecMode.autoSafe => 'Hardware Decoding: ON (GPU, safe)',
        _HwDecMode.autoCopy => 'Hardware Decoding: ON (copy-back)',
        _HwDecMode.software => 'Hardware Decoding: OFF (CPU)',
      };

  _HwDecMode get next => switch (this) {
        _HwDecMode.autoSafe => _HwDecMode.autoCopy,
        _HwDecMode.autoCopy => _HwDecMode.software,
        _HwDecMode.software => _HwDecMode.autoSafe,
      };

  Color get accent => switch (this) {
        _HwDecMode.autoSafe => const Color(0xFF7C3AED),
        _HwDecMode.autoCopy => const Color(0xFF0EA5E9),
        _HwDecMode.software => Colors.white24,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
//  DESKTOP PLAYER SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class DesktopPlayerScreen extends StatefulWidget {
  final String mediaPath;
  final String title;
  final String? audioUrl;
  final Map<String, String>? headers;
  final Movie? movie;
  final int? selectedSeason;
  final int? selectedEpisode;
  final String? magnetLink;
  final String? activeProvider;
  final Duration? startPosition;
  final List<StreamSource>? sources;
  final int? fileIndex;
  final List<Map<String, dynamic>>? externalSubtitles;
  final String? stremioId;
  final String? stremioAddonBaseUrl;
  final Map<String, dynamic>? providers;
  final Future<void> Function()? onNextEpisode;
  final bool hasNextEpisode;
  final Future<void> Function(Duration position, Duration duration)? onSaveProgress;

  const DesktopPlayerScreen({
    super.key,
    required this.mediaPath,
    required this.title,
    this.audioUrl,
    this.headers,
    this.movie,
    this.selectedSeason,
    this.selectedEpisode,
    this.magnetLink,
    this.activeProvider,
    this.startPosition,
    this.sources,
    this.fileIndex,
    this.externalSubtitles,
    this.stremioId,
    this.stremioAddonBaseUrl,
    this.providers,
    this.onNextEpisode,
    this.hasNextEpisode = false,
    this.onSaveProgress,
  });

  @override
  State<DesktopPlayerScreen> createState() => _DesktopPlayerScreenState();
}

class _DesktopPlayerScreenState extends State<DesktopPlayerScreen>
    with WindowListener, WidgetsBindingObserver {
  // ── Player ──────────────────────────────────────────────────────────────
  late final Player _player;
  late final VideoController _controller;
  bool _disposed = false;
  bool _historySaved = false;
  bool _hasError = false;
  String _errorMessage = '';

  // ── UI State ─────────────────────────────────────────────────────────────
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isFullscreen = false;
  BoxFit _videoFit = BoxFit.contain;
  bool _isPipMode = false;
  bool _pipHover = false;
  StreamSubscription<bool>? _pipSub;

  // ── Resume State ─────────────────────────────────────────────────────────
  bool _hasInitialSeek = false;

  // ── Stream Subscriptions ─────────────────────────────────────────────────
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _volumeSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Tracks>? _tracksSub;
  bool _autoTracksAppliedForSource = false;
  // ── Value Notifiers (rebuild only what's needed, no full setState) ────────
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _bufferedNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isBufferingNotifier = ValueNotifier(false);
  final ValueNotifier<double> _volumeNotifier = ValueNotifier(100.0);

  // ── Subtitles ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _externalSubtitles = [];
  bool _isFetchingSubs = false;
  /// When true, the current subtitle is ASS/SSA or an image-based format (PGS/VobSub).
  /// mpv renders it directly on the video frame, so the custom Flutter overlay is hidden.
  bool _isNativeSubtitle = false;
  String? _selectedExternalSubUrl;
  /// Currently opened language-folder key in the subtitle picker, or null
  /// when the picker shows the folder list. Persists across menu open/close.
  String? _subsMenuFolder;

  // ── Provider switching ────────────────────────────────────────────────────
  String? _currentProvider;
  List<StreamSource>? _currentSources;
  String? _currentUrl;
  // ── HLS Quality Selector ─────────────────────────────────────────────────
  // Populated when the playing URL is a master HLS playlist with 2+
  // variants. The gear button in the top control bar is hidden until this
  // notifier holds a non-empty list.
  final ValueNotifier<List<HlsQuality>?> _hlsQualitiesNotifier = ValueNotifier(null);
  String? _hlsMasterUrl;
  Map<String, String>? _hlsMasterHeaders;
  String? _currentQualityUrl;
  /// For provider == 'service111477', the upstream fileUrl currently playing
  /// (the menu compares against this rather than the localhost proxy URL).
  String? _current111477FileUrl;
  int _currentFallbackSourceIndex = 0;
  bool _isSwitchingProvider = false;
  bool _isInitPlaybackRunning = false;

  // ── Feature State ────────────────────────────────────────────────────────
  _HwDecMode _hwDecMode = _HwDecMode.autoSafe;
  bool _loopEnabled = false;
  double _subtitleDelay = 0.0;
  double _subtitleSize = 44.0;
  double _subtitleBottomPadding = 24.0;
  Color _subtitleColor = Colors.white;
  double _subtitleBgOpacity = 0.67;
  bool _subtitleBold = false;
  String _subtitleFont = 'Default';

  // ── Next Episode State ────────────────────────────────────────────────────
  bool _isLoadingNextEp = false;
  bool _nearEndOfEpisode = false;

  // ── Skip Segments (IntroDB) ───────────────────────────────────────────────
  IntroDbResponse? _introDbData;
  String? _activeSkipLabel;   // e.g. 'Skip Intro', 'Skip Recap', etc.
  Duration? _activeSkipTarget; // where to seek when the user taps
  bool _skipDismissed = false; // user dismissed the current segment button

  // ─────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    
    // ── Provider initialization ──────────────────────────────────────────
    _currentProvider = widget.activeProvider;
    _currentSources = widget.sources;
    _currentUrl = widget.mediaPath;
    if (_currentProvider == 'service111477' &&
        widget.sources != null &&
        widget.sources!.isNotEmpty) {
      _current111477FileUrl = widget.sources!.first.url;
    }
    
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);

    // Track desktop PiP state so we can hide all controls when active.
    _pipSub = PipService.instance.desktopPipChanges.listen((on) {
      if (!mounted) return;
      setState(() => _isPipMode = on);
    });

    // ── Create player with minimal overhead config ────────────────────────
    _player = Player(
      configuration: const PlayerConfiguration(
        // Silence noisy logs; use MPVLogLevel.warn for prod
        logLevel: MPVLogLevel.warn,
        // libass enabled so ASS/SSA subtitles render natively on the video.
        // For SRT/VTT we dynamically set sub-visibility=no so our custom
        // Flutter overlay still handles those.
        libass: true,
        // On Android, libass cannot access system fonts via fontconfig.
        // We must bundle a default font in assets and provide it here.
        libassAndroidFont: 'assets/fonts/Roboto-Regular.ttf',
        libassAndroidFontName: 'Roboto',
      ),
    );

    // ── VideoController: force hardware-accelerated texture output ─────────
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadSubtitlePrefs();
      _initPlayback();
      _startHideTimer();
      _fetchSubtitles();
      // Trakt scrobble start
      if (widget.movie != null) {
        TraktService().scrobbleStart(
          tmdbId: widget.movie!.id,
          mediaType: widget.movie!.mediaType,
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
          progressPercent: 0,
        );
        SimklService().scrobbleStart(
          tmdbId: widget.movie!.id,
          mediaType: widget.movie!.mediaType,
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
      }
      // Fetch skip segments from IntroDB
      _fetchIntroDbTimestamps();
    });
  }

  Future<void> _fetchIntroDbTimestamps() async {
    if (widget.movie == null) return;
    final data = await IntroDbService().getTimestamps(
      tmdbId: widget.movie!.id,
      season: widget.selectedSeason,
      episode: widget.selectedEpisode,
      imdbId: widget.movie!.imdbId,
    );
    if (mounted && data != null && data.hasAnySegments) {
      setState(() => _introDbData = data);
    }
  }

  @override
  void dispose() {
    // ── Save watch history before anything else ───────────────────────────
    _saveWatchHistory();

    _disposed = true;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _pipSub?.cancel();
    // If we tear down while in PiP, restore window chrome so the next
    // screen doesn't inherit a tiny frameless 480x270 window.
    if (PipService.instance.isDesktopActive) {
      PipService.instance.leave();
    }

    // Cancel all subscriptions
    _positionSub?.cancel();
    _durationSub?.cancel();
    _bufferSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _volumeSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();

    // Dispose value notifiers
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _bufferedNotifier.dispose();
    _isPlayingNotifier.dispose();
    _isBufferingNotifier.dispose();
    _hlsQualitiesNotifier.dispose();
    _volumeNotifier.dispose();

    _player.dispose();

    // Remove torrent from engine on player exit (use magnetLink for hash,
    // fall back to mediaPath which may be a stream URL).
    final torrentId = widget.magnetLink ?? widget.mediaPath;
    TorrentStreamService().removeTorrent(torrentId);

    // Tear down the 111477 proxy and delete its on-disk cache.
    if (site111477_proxy.is111477ProxyRunning) {
      site111477_proxy.stop111477Proxy();
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Save progress when app goes to background or is paused
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _saveWatchHistory(isBgPause: true);
    } else if (state == AppLifecycleState.resumed) {
      _historySaved = false;
      if (widget.movie != null && _isPlayingNotifier.value) {
        final pos = _positionNotifier.value.inMilliseconds;
        final dur = _durationNotifier.value.inMilliseconds;
        final pct = dur > 0 ? (pos / dur * 100) : 0.0;
        TraktService().scrobbleStart(
          tmdbId: widget.movie!.id,
          mediaType: widget.movie!.mediaType,
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
          progressPercent: pct,
        );
      }
    }
  }

  void _saveWatchHistory({bool isBgPause = false}) {
    if (_historySaved && !isBgPause) return;
    _historySaved = true;
    final pos = _positionNotifier.value.inMilliseconds;
    final dur = _durationNotifier.value.inMilliseconds;

    if (widget.onSaveProgress != null && pos > 5000) {
      widget.onSaveProgress!(
        Duration(milliseconds: pos),
        Duration(milliseconds: dur),
      );
    }

    // Save anime watch position
    if (widget.activeProvider != null &&
        widget.activeProvider!.startsWith('anime_') &&
        pos > 10000 && dur > 0) {
      _saveAnimeWatchPosition(pos, dur);
    }

    if (widget.movie == null) return;
    if (pos > 10000 && dur > 0) {
      final isTorrent = widget.magnetLink != null;
      final isStremioDirect = widget.activeProvider == 'stremio_direct';
      final String method;
      final String sourceId;
      if (isTorrent) {
        method = 'torrent';
        sourceId = widget.magnetLink!;
      } else if (isStremioDirect) {
        method = 'stremio_direct';
        sourceId = widget.mediaPath;
      } else if (widget.activeProvider == 'amri') {
        method = 'amri';
        sourceId = widget.mediaPath;
      } else if (widget.activeProvider != null) {
        method = 'stream';
        sourceId = widget.activeProvider!;
      } else {
        method = 'amri';
        sourceId = widget.mediaPath;
      }
      WatchHistoryService().saveProgress(
        tmdbId: widget.movie!.id,
        imdbId: widget.movie!.imdbId,
        title: widget.title,
        posterPath: widget.movie!.posterPath,
        method: method,
        sourceId: sourceId,
        position: pos,
        duration: dur,
        season: widget.selectedSeason,
        episode: widget.selectedEpisode,
        episodeTitle: widget.selectedEpisode != null
            ? 'Episode ${widget.selectedEpisode}'
            : null,
        magnetLink: widget.magnetLink,
        fileIndex: widget.fileIndex,
        streamUrl: isStremioDirect ? widget.mediaPath : null,
        stremioId: widget.stremioId,
        stremioAddonBaseUrl: widget.stremioAddonBaseUrl,
        stremioType: widget.movie!.mediaType == 'tv' ? 'series' : 'movie',
        mediaType: widget.movie!.mediaType,
      );

      // Trakt + Simkl scrobble — fire and forget
      final progressPercent = dur > 0 ? (pos / dur * 100) : 0.0;
      if (isBgPause) {
        TraktService().scrobblePause(
          tmdbId: widget.movie!.id,
          mediaType: widget.movie!.mediaType,
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
          progressPercent: progressPercent,
        );
      } else {
        TraktService().scrobbleStop(
          tmdbId: widget.movie!.id,
          mediaType: widget.movie!.mediaType,
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
          progressPercent: progressPercent,
        );
      }
      SimklService().scrobbleStop(
        tmdbId: widget.movie!.id,
        mediaType: widget.movie!.mediaType,
        season: widget.selectedSeason,
        episode: widget.selectedEpisode,
      );
    }
  }

  void _saveAnimeWatchPosition(int posMs, int durMs) {
    SharedPreferences.getInstance().then((prefs) {
      final list = prefs.getStringList('anime_watch_history') ?? [];
      // Extract animeId from the activeProvider or match by title
      // The most recent entry at index 0 is the currently playing anime
      // (addToWatchHistory inserts at 0 before playback starts)
      if (list.isNotEmpty) {
        final entry = jsonDecode(list[0]) as Map<String, dynamic>;
        entry['position'] = posMs;
        entry['duration'] = durMs;
        list[0] = jsonEncode(entry);
        prefs.setStringList('anime_watch_history', list);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  PLAYBACK INITIALIZATION
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _initPlayback() async {
    if (_disposed) return;
    if (_isInitPlaybackRunning) return; // Prevent re-entrant calls during async extraction
    _isInitPlaybackRunning = true;
    
    try {
    setState(() {
      _hasError = false;
      _errorMessage = '';
    });

    // 1. Try sources in current provider list
    if (_currentSources != null && _currentSources!.isNotEmpty) {
      while (_currentFallbackSourceIndex < _currentSources!.length) {
        final i = _currentFallbackSourceIndex;
        var source = _currentSources![i];
        debugPrint('[Player] Trying source ${i + 1}/${_currentSources!.length}: ${source.title}');

        // Arabic embed sources need on-demand extraction first
        if (_currentProvider == 'arabic' && source.type == 'arabic_embed') {
          debugPrint('[Player] Extracting arabic embed: ${source.title}');
          final result = await ArabicService.extractStreamUrl(source.url);
          if (result == null) {
            debugPrint('[Player] Arabic extract failed for ${source.title}');
            _currentFallbackSourceIndex++;
            continue;
          }
          // Update the source with the real stream URL
          source = StreamSource(
            url: result.url,
            title: source.title,
            type: result.url.contains('.m3u8') ? 'hls' : result.url.contains('.mpd') ? 'dash' : 'mp4',
          );
          _currentSources![i] = source;
        }
        
        try {
          _subscribeToStreams();
          await _configureMpvProperties();

          // For 111477 sources, source.url is the upstream file URL — we
          // must route it through the local proxy. Reuse the running proxy
          // if it's already serving this exact file, otherwise restart.
          var openUrl = source.url;
          if (_currentProvider == 'service111477') {
            if (!site111477_proxy.is111477ProxyRunning ||
                _current111477FileUrl != source.url) {
              if (site111477_proxy.is111477ProxyRunning) {
                await site111477_proxy.stop111477Proxy();
              }
              openUrl = await site111477_proxy.start111477Proxy(source.url);
              _current111477FileUrl = source.url;
            } else {
              openUrl = site111477_proxy.site111477ProxyUrl!;
            }
          }

          await _player.open(Media(openUrl, httpHeaders: source.headers ?? widget.headers));
          _player.setVolume(_volumeNotifier.value);
          _detectHlsQualities(openUrl, source.headers ?? widget.headers);
          setState(() {
            _currentUrl = openUrl;
          });
          return; // Opened successfully
        } catch (e) {
          debugPrint('[Player] Source $i catch error: $e');
          _currentFallbackSourceIndex++;
        }
      }
      
      // All sources in current provider failed
      await _autoFallbackToNextProvider();
    } else {
      // No sources list, just try the primary mediaPath
      int retryCount = 0;
      const maxRetries = 2;
      
      while (retryCount < maxRetries) {
        try {
          _subscribeToStreams();
          await _configureMpvProperties();
          await _player.open(Media(widget.mediaPath, httpHeaders: widget.headers));
          _player.setVolume(_volumeNotifier.value);
          _detectHlsQualities(widget.mediaPath, widget.headers);
          return;
        } catch (e) {
          retryCount++;
          if (retryCount >= maxRetries) {
            await _autoFallbackToNextProvider();
            return;
          }
          await Future.delayed(Duration(milliseconds: 500 * retryCount));
        }
      }
    }
    } finally {
      _isInitPlaybackRunning = false;
    }
  }

  Future<void> _autoFallbackToNextProvider() async {
    if (widget.providers == null || widget.providers!.isEmpty) {
      setState(() {
        _hasError = true;
        _errorMessage = 'All sources and providers failed.';
      });
      return;
    }

    final providerKeys = widget.providers!.keys.toList();
    int currentIndex = providerKeys.indexOf(_currentProvider ?? '');
    
    // Try the next provider in the list
    for (int i = currentIndex + 1; i < providerKeys.length; i++) {
      final nextKey = providerKeys[i];
      debugPrint('[Player] Auto-falling back to provider: $nextKey');
      
      final success = await _silentSwitchProvider(nextKey);
      if (success) return;
    }

    // If we're here, everything failed
    if (mounted) {
      setState(() {
        _hasError = true;
        _errorMessage = 'Could not find any working stream from any provider.';
      });
    }
  }

  /// Switches provider without showing full error UI on failure, returns success
  Future<bool> _silentSwitchProvider(String newProvider) async {
    try {
      final provider = widget.providers![newProvider];
      String? streamUrl;
      Map<String, String>? headers;
      List<StreamSource>? sources;

      if (newProvider == 'service111477' && widget.movie != null) {
        final svc = Site111477Service();
        List<Site111477Match> hits;
        if (widget.movie!.mediaType == 'tv') {
          hits = await svc.findEpisodeSources(
            showTitle: widget.movie!.title,
            season: widget.selectedSeason ?? 1,
            episode: widget.selectedEpisode ?? 1,
          );
        } else {
          final year = widget.movie!.releaseDate.length >= 4
              ? widget.movie!.releaseDate.substring(0, 4)
              : null;
          hits = await svc.findMovieSources(title: widget.movie!.title, year: year);
        }
        if (hits.isNotEmpty) {
          if (site111477_proxy.is111477ProxyRunning) {
            await site111477_proxy.stop111477Proxy();
          }
          streamUrl = await site111477_proxy.start111477Proxy(hits.first.fileUrl);
          sources = Site111477Service.toStreamSources(hits);
          _current111477FileUrl = hits.first.fileUrl;
        }
      } else if (newProvider == 'webstreamr' && widget.movie?.imdbId != null) {
        final webStreamr = WebStreamrService();
        final webStreamrSources = await webStreamr.getStreams(
          imdbId: widget.movie!.imdbId!,
          isMovie: widget.movie!.mediaType == 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (webStreamrSources.isNotEmpty) {
          streamUrl = webStreamrSources.first.url;
          sources = webStreamrSources;
        }
      } else if (newProvider == 'videasy' && widget.movie != null) {
        final ve = VideasyExtractor(onLog: (m) => debugPrint(m));
        final result = await ve.extract(
          tmdbId: widget.movie!.id.toString(),
          isMovie: widget.movie!.mediaType == 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (result != null && result.url.isNotEmpty) {
          streamUrl = result.url;
          headers = result.headers;
          sources = result.sources;
        }
      } else if (newProvider == 'vidsrc' && widget.movie != null) {
        final ve = VidsrcExtractor();
        final result = await ve.extract(
          tmdbId: widget.movie!.id.toString(),
          isMovie: widget.movie!.mediaType == 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (result != null && result.url.isNotEmpty) {
          streamUrl = result.url;
          headers = result.headers;
          sources = result.sources;
        }
      } else if (newProvider.startsWith('nuvio:') && widget.movie != null) {
        final scraperId = newProvider.substring(6);
        final results = await NuvioService.instance.runOneScraper(
          scraperId: scraperId,
          tmdbId: widget.movie!.id.toString(),
          type: widget.movie!.mediaType == 'tv' ? 'tv' : 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (results.isNotEmpty) {
          final first = results.first;
          streamUrl = first.url;
          headers = first.headers.isEmpty ? null : first.headers;
          sources = results.map((r) => StreamSource(
                url: r.url,
                title: r.title.isNotEmpty ? r.title : r.name,
                type: r.url.toLowerCase().contains('.m3u8')
                    ? 'hls'
                    : r.url.toLowerCase().contains('.mpd')
                        ? 'dash'
                        : 'mp4',
                headers: r.headers.isEmpty ? null : r.headers,
              )).toList();
        }
      } else if (provider['movie'] != null && provider['tv'] != null) {
        final String providerUrl;
        if (widget.movie!.mediaType == 'tv') {
          providerUrl = provider['tv'](
            widget.movie!.id.toString(),
            widget.selectedSeason,
            widget.selectedEpisode,
          );
        } else {
          providerUrl = provider['movie'](widget.movie!.id.toString());
        }
        
        final extractor = StreamExtractor();
        final result = await extractor.extract(providerUrl);
        if (result != null && result.url.isNotEmpty) {
          streamUrl = result.url;
          headers = result.headers;
          sources = result.sources;
        }
      }
      
      if (streamUrl != null && streamUrl.isNotEmpty) {
        final currentPos = _positionNotifier.value;
        // Reset any stale mpv referrer set by the previous provider/quality
        // selection — then re-apply from the new headers if present.
        if (_player.platform is NativePlayer) {
          final ref = headers?['Referer'] ?? headers?['referer'] ?? '';
          await (_player.platform as NativePlayer).setProperty('referrer', ref);
        }
        await _player.open(Media(streamUrl, httpHeaders: headers));
        if (currentPos.inSeconds > 0) await _player.seek(currentPos);
        _detectHlsQualities(streamUrl, headers);
        
        setState(() {
          _currentProvider = newProvider;
          _currentSources = sources;
          _currentUrl = streamUrl;
          _currentFallbackSourceIndex = 0; // Reset for the new provider
          _hasError = false;
          _errorMessage = '';
        });
        return true;
      }
    } catch (e) {
      debugPrint('[Player] Silent fallback to $newProvider failed: $e');
    }
    return false;
  }

  void _subscribeToStreams() {
    // Cancel any existing subscriptions to prevent duplicate listeners
    _positionSub?.cancel();
    _durationSub?.cancel();
    _bufferSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _volumeSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();
    _autoTracksAppliedForSource = false;

    // Position – drives seekbar & watch-history
    _positionSub = _player.stream.position.listen((pos) {
      if (_disposed) return;
      _positionNotifier.value = pos;

      // Near-end detection for next episode button
      if (_isNextEpisodeAvailable && !_nearEndOfEpisode) {
        final dur = _durationNotifier.value;
        if (dur.inSeconds > 0) {
          final remaining = dur - pos;
          final threshold = dur.inMinutes < 10
              ? Duration(seconds: (dur.inSeconds * 0.05).round())
              : const Duration(minutes: 2);
          if (remaining <= threshold) {
            setState(() => _nearEndOfEpisode = true);
          }
        }
      }

      // Skip segment detection (IntroDB)
      _updateActiveSkipSegment(pos);
    });

    // Duration – triggers auto-resume on first valid duration
    _durationSub = _player.stream.duration.listen((dur) {
      if (_disposed) return;
      _durationNotifier.value = dur;
      if (!_hasInitialSeek && dur.inSeconds > 0 && widget.startPosition != null) {
        _hasInitialSeek = true;
        _player.seek(widget.startPosition!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Resumed from ${formatDuration(widget.startPosition!)}'),
            duration: const Duration(seconds: 2),
          ));
        }
      }
    });

    // Buffered position – shows how far ahead is cached
    _bufferSub = _player.stream.buffer.listen((buf) {
      if (_disposed) return;
      _bufferedNotifier.value = buf;
    });

    // Playing state
    _playingSub = _player.stream.playing.listen((playing) {
      if (_disposed) return;
      _isPlayingNotifier.value = playing;
      if (playing) {
        _startHideTimer();
        // Scrobble resume
        if (widget.movie != null) {
          final pos = _positionNotifier.value.inMilliseconds;
          final dur = _durationNotifier.value.inMilliseconds;
          final pct = dur > 0 ? (pos / dur * 100) : 0.0;
          TraktService().scrobbleStart(
            tmdbId: widget.movie!.id,
            mediaType: widget.movie!.mediaType,
            season: widget.selectedSeason,
            episode: widget.selectedEpisode,
            progressPercent: pct,
          );
          SimklService().scrobbleStart(
            tmdbId: widget.movie!.id,
            mediaType: widget.movie!.mediaType,
            season: widget.selectedSeason,
            episode: widget.selectedEpisode,
          );
        }
      } else {
        // Scrobble pause
        if (widget.movie != null) {
          final pos = _positionNotifier.value.inMilliseconds;
          final dur = _durationNotifier.value.inMilliseconds;
          final pct = dur > 0 ? (pos / dur * 100) : 0.0;
          TraktService().scrobblePause(
            tmdbId: widget.movie!.id,
            mediaType: widget.movie!.mediaType,
            season: widget.selectedSeason,
            episode: widget.selectedEpisode,
            progressPercent: pct,
          );
          SimklService().scrobblePause(
            tmdbId: widget.movie!.id,
            mediaType: widget.movie!.mediaType,
            season: widget.selectedSeason,
            episode: widget.selectedEpisode,
          );
        }
      }
    });

    // Buffering spinner
    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (_disposed) return;
      _isBufferingNotifier.value = buffering;
    });

    // Volume sync (e.g. hardware media keys)
    _volumeSub = _player.stream.volume.listen((vol) {
      if (_disposed) return;
      _volumeNotifier.value = vol;
    });

    // Error recovery – log & surface to UI
    _errorSub = _player.stream.error.listen((err) {
      if (_disposed || err.isEmpty) return;
      
      // Ignore non-fatal audio errors (video continues playing)
      if (err.contains('Error decoding audio') ||
          err.contains('Failed to initialize a decoder for codec')) {
        return;
      }

      // Ignore subtitle-fetch errors (HTTP 502/404 from sub providers,
      // bad SRT, codec issues, etc.). These should NOT kill video
      // playback or rotate the video fallback chain.
      final lower = err.toLowerCase();
      final isSubError = lower.contains('subtitle') ||
          lower.contains('sub-add') ||
          lower.contains('external file') ||
          lower.contains('.srt') ||
          lower.contains('.vtt') ||
          lower.contains('.ass') ||
          lower.contains('.ssa') ||
          lower.contains('502') ||
          lower.contains('http error');
      if (isSubError) {
        debugPrint('🟡 Sub error (ignored): $err');
        return;
      }
      
      debugPrint('🔴 Player error: $err');
      
      // Only surface fatal errors to UI (connection failures are often transient)
      if (err.contains('Failed') || err.contains('No such file')) {
        // Don't retry if we've already given up or are currently retrying
        if (_hasError || _isInitPlaybackRunning) {
          if (_isInitPlaybackRunning) {
            debugPrint('[Player] Ignoring stale error — _initPlayback already running');
          }
          return;
        }
        debugPrint('[Player] Fatal error detected on source $_currentFallbackSourceIndex, progressing fallback...');
        _currentFallbackSourceIndex++;
        _initPlayback();
      }
    });

    // Completion – could trigger next-episode logic here in the future
    _completedSub = _player.stream.completed.listen((completed) {
      if (_disposed || !completed) return;
      debugPrint('✅ Playback completed');
    });

    _tracksSub = _player.stream.tracks.listen((tracks) {
      if (_disposed || _autoTracksAppliedForSource) return;
      final hasAudio = tracks.audio.any((t) => t.id != 'no' && t.id != 'auto');
      if (!hasAudio) return;
      _autoTracksAppliedForSource = true;
      Future.delayed(const Duration(milliseconds: 600), _applyTrackAutoSelect);
    });
  }

  Future<void> _applyTrackAutoSelect() async {
    if (_disposed) return;
    try {
      final settings = SettingsService();
      final audioLang = await settings.getPreferredAudioLanguage();
      final avoidUnsupported = await settings.getAvoidUnsupportedAudio();
      if (audioLang == 'None' && !avoidUnsupported) return;

      final result = computeAutoSelect(
        audioTracks: _player.state.tracks.audio,
        subtitleTracks: _player.state.tracks.subtitle,
        currentAudio: _player.state.track.audio,
        currentSubtitle: _player.state.track.subtitle,
        preferredAudioLang: audioLang,
        preferredSubtitleLang: 'None',
        avoidUnsupportedAudio: avoidUnsupported,
      );
      if (!result.hasAny) return;
      if (result.audio != null) {
        await _player.setAudioTrack(result.audio!);
      }
    } catch (e) {
      debugPrint('[DesktopPlayer] track auto-select failed: $e');
    }
  }

  /// Checks if [track] is an ASS/SSA or image-based subtitle (PGS/VobSub) and toggles mpv's
  /// `sub-visibility` accordingly. Native tracks render directly onto the video frame,
  /// so the custom Flutter overlay hides itself. For SRT/VTT, sub-visibility is turned off
  /// so only the Flutter overlay draws text.
  void _updateSubVisibility(SubtitleTrack track) {
    final codec = track.codec?.toLowerCase() ?? '';
    final isNativeCodec = codec.contains('ass') || codec.contains('ssa') ||
        codec.contains('pgs') || codec.contains('dvd') || codec.contains('dvb') || codec.contains('vobsub');
    // Also check the track title/id for .ass/.ssa extension (file picker)
    final title = (track.title ?? track.id).toLowerCase();
    final looksAss = title.endsWith('.ass') || title.endsWith('.ssa');
    final shouldUseNative = isNativeCodec || looksAss;

    if (shouldUseNative != _isNativeSubtitle) {
      setState(() => _isNativeSubtitle = shouldUseNative);
    }
    if (_player.platform is NativePlayer) {
      (_player.platform as NativePlayer)
          .setProperty('sub-visibility', shouldUseNative ? 'yes' : 'no');
    }
  }

  Future<void> _configureMpvProperties() async {
    if (_player.platform is! NativePlayer) return;
    final mpv = _player.platform as NativePlayer;

    Future<void> safeSet(String key, String val) async {
      try {
        await mpv.setProperty(key, val);
      } catch (e) {
        debugPrint('[Player] Warning: failed to set mpv property $key=$val: $e');
      }
    }

    // ── Decoding ─────────────────────────────────────────────────────────
    // auto-safe: tries whitelisted GPU decoders, falls back gracefully.
    // This is the officially recommended hwdec mode by mpv developers.
    await safeSet('hwdec', _hwDecMode.mpvValue);

    // Zero-copy direct rendering from decoder to GPU texture when possible.
    // Reduces RAM usage and improves throughput, especially on 4K/HEVC.
    await safeSet('vd-lavc-dr', 'yes');

    // Let mpv pick the optimal thread count automatically (0 = auto).
    await safeSet('vd-lavc-threads', '0');

    // ── Audio Codec Fallback ──────────────────────────────────────────────
    // Continue playback even if audio codec is unsupported (e.g., TrueHD).
    // User can switch to alternate audio track from the menu.
    await safeSet('ad-lavc-downmix', 'no');
    await safeSet('audio-fallback-to-null', 'yes');

    // Disable built-in OSD / subtitle rendering – Flutter renders them.
    await safeSet('sub-visibility', 'no');
    await safeSet('sub-auto', 'all');

    // ── Video Sync & Smoothness ───────────────────────────────────────────
    // display-resample: syncs to the monitor's refresh rate, eliminates judder.
    // This is the best sync mode for desktop displays.
    await safeSet('video-sync', 'display-resample');

    // Temporal interpolation to smooth out frame pacing between display frames.
    // Significantly reduces judder on 24fps content on 60Hz+ monitors.
    await safeSet('interpolation', 'yes');
    await safeSet('tscale', 'oversample'); // lightweight interpolation

    // ── Adaptive Streaming (HLS/DASH) ─────────────────────────────────────
    // Always pick the highest bitrate variant in multi-quality playlists.
    await safeSet('hls-bitrate', 'max');

    // ── Network / Streaming ───────────────────────────────────────────────
    await safeSet('network-timeout', '30');
    await safeSet('tls-verify', 'no'); // for self-signed / CDN certs

    final isTorrent = widget.magnetLink != null;
    if (isTorrent) {
      // Torrent engine feeds bytes from disk as pieces complete — a small
      // forward window is enough and keeps memory pressure low. We also
      // disable cache-pause so playback keeps moving when the demuxer
      // briefly drains while waiting on the next piece.
      await safeSet('cache', 'yes');
      await safeSet('network-timeout', '15');
      await safeSet('force-seekable', 'yes');
      await safeSet('hr-seek', 'yes');
      await safeSet('hr-seek-framedrop', 'no');
    } else {
      // Cache: 300 MB in memory, read 120 s ahead.
      // This dramatically reduces rebuffering on variable-bitrate streams.
      await safeSet('cache', 'yes');
      await safeSet('cache-secs', '120');
      await safeSet('demuxer-max-bytes', '300MiB');
      await safeSet('demuxer-readahead-secs', '120');

      // How far back the demuxer keeps decoded data (for backward seeks).
      await safeSet('demuxer-max-back-bytes', '50MiB');
    }

    // Prevent yt-dlp from being invoked (we supply our own URL).
    await safeSet('ytdl', 'no');

    // ── Volume ────────────────────────────────────────────────────────────
    // Allow boosting volume above 100% (up to 150%) for quiet sources.
    await safeSet('volume-max', '150');

    // ── External Audio Track ──────────────────────────────────────────────
    if (widget.audioUrl != null) {
      await safeSet('audio-file', widget.audioUrl!);
    }

    // ── HTTP Headers ──────────────────────────────────────────────────────
    if (widget.headers != null) {
      final referer =
          widget.headers!['Referer'] ?? widget.headers!['referer'];
      if (referer != null) await safeSet('referrer', referer);

      final ua =
          widget.headers!['User-Agent'] ?? widget.headers!['user-agent'];
      if (ua != null) await safeSet('user-agent', ua);
    }

    // ── Resume Position ──────────────────────────────────────────────────
    // Set mpv's native 'start' property so it begins playback at the saved
    // position. This is more reliable than seeking after open, because the
    // post-open seek can be silently dropped before the demuxer is fully
    // initialised.
    if (widget.startPosition != null && !_hasInitialSeek) {
      final secs = widget.startPosition!.inMilliseconds / 1000.0;
      await safeSet('start', '+${secs.toStringAsFixed(3)}');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  HARDWARE DECODE CYCLE
  // ─────────────────────────────────────────────────────────────────────────

  void _cycleHwDec() {
    final next = _hwDecMode.next;
    setState(() => _hwDecMode = next);

    if (_player.platform is NativePlayer) {
      (_player.platform as NativePlayer)
          .setProperty('hwdec', next.mpvValue);
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(next.description),
      duration: const Duration(seconds: 2),
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  SUBTITLE MANAGEMENT
  // ─────────────────────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────────────────────
  //  ONLINE SUBTITLE LOADER (download → temp file → SubtitleTrack.uri)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadOnlineSubtitle(Map<String, dynamic> s) async {
    final url = (s['url'] ?? '').toString();
    if (url.isEmpty) return;
    final isTranslated = s['translated'] == true ||
        url.contains('/subtitlecat-translate');

    final messenger = ScaffoldMessenger.of(context);

    // Already-local subtitle (e.g. kisskh decrypted) — feed straight to libmpv.
    if (url.startsWith('file://') || url.startsWith('/')) {
      try {
        _player.setSubtitleTrack(SubtitleTrack.uri(
          url.startsWith('file://') ? url : Uri.file(url).toString(),
          title: s['display'],
          language: s['language'],
        ));
        if (mounted) setState(() => _selectedExternalSubUrl = url);
      } catch (e) {
        if (!mounted) return;
        setState(() => _selectedExternalSubUrl = null);
        messenger.showSnackBar(
            SnackBar(content: Text('Subtitle failed: $e — tap to retry')));
      }
      return;
    }

    try {
      // Many subtitle CDNs (megacloud, vid-cdn, lostproject.club, etc.) gate
      // on a browser UA and the embed-host Referer (NOT the sub URL's own
      // host). Prefer the referer/origin the extractor passed through;
      // otherwise fall back to the sub URL's own origin.
      final subUri = Uri.parse(url);
      final selfOrigin = '${subUri.scheme}://${subUri.host}';
      final ref = (s['referer'] as String?)?.trim();
      final org = (s['origin'] as String?)?.trim();
      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Referer': (ref != null && ref.isNotEmpty) ? ref : '$selfOrigin/',
        'Origin': (org != null && org.isNotEmpty) ? org : selfOrigin,
      };
      final res = await http
          .get(subUri, headers: headers)
          .timeout(Duration(minutes: isTranslated ? 5 : 1));
      if (!mounted) return;
      if (res.statusCode != 200) {
        if (mounted) {
          setState(() => _selectedExternalSubUrl = null);
        }
        messenger.showSnackBar(SnackBar(
            content: Text('Subtitle failed (${res.statusCode}) — tap to retry')));
        return;
      }
      final dir = await getTemporaryDirectory();
      final safeLang = (s['language'] ?? 'sub')
          .toString()
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File(
          '${dir.path}/playtorrio_sub_${DateTime.now().millisecondsSinceEpoch}_$safeLang.srt');
      await file.writeAsBytes(res.bodyBytes);
      final uri = Uri.file(file.path).toString();
      final track = SubtitleTrack.uri(
        uri,
        title: s['display'],
        language: s['language'],
      );
      _player.setSubtitleTrack(track);
      _updateSubVisibility(track);
      if (mounted) {
        setState(() => _selectedExternalSubUrl = url);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _selectedExternalSubUrl = null);
      messenger.showSnackBar(
          SnackBar(content: Text('Subtitle failed: $e — tap to retry')));
    }
  }

  Future<void> _fetchSubtitles() async {
    // Pre-populate with Jellyfin subtitles if provided
    final jellyfinSubs = widget.externalSubtitles ?? [];
    if (jellyfinSubs.isNotEmpty) {
      if (mounted) setState(() => _externalSubtitles = List<Map<String, dynamic>>.from(jellyfinSubs));
    }

    if (widget.movie == null) return;
    if (mounted) setState(() => _isFetchingSubs = true);

    final stream = SubtitleApi.fetchSubtitlesStream(
      tmdbId: widget.movie!.id,
      imdbId: widget.movie!.imdbId,
      season: widget.selectedSeason,
      episode: widget.selectedEpisode,
      title: widget.movie!.title,
      year: widget.movie!.releaseDate.length >= 4
          ? int.tryParse(widget.movie!.releaseDate.substring(0, 4))
          : null,
    );

    stream.listen(
      (subs) {
        if (mounted) {
          setState(() => _externalSubtitles = [...jellyfinSubs, ...subs]);
          _maybeAutoPickExternalSubtitle();
        }
      },
      onDone: () {
        if (mounted) setState(() => _isFetchingSubs = false);
        _maybeAutoPickExternalSubtitle();
      },
    );
  }

  /// If the user has a preferred subtitle language but the embedded tracks
  /// Subtitle auto-pick was removed (the user explicitly disabled the
  /// preferred-subtitle setting). Kept as a no-op so existing call sites
  /// don't have to be re-plumbed.
  Future<void> _maybeAutoPickExternalSubtitle() async {}

  void _showSubtitlesMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8),
      builder: (context) {
        String searchQuery = '';
        return StatefulBuilder(builder: (context, setModalState) {
          final current = _player.state.track.subtitle;
          final inFolder = _subsMenuFolder != null;

          // Embedded tracks (only shown at root view).
          final embedded = _player.state.tracks.subtitle.where((t) {
            final isExternal = t.id.startsWith('http');
            final matchesSearch = searchQuery.isEmpty ||
                (t.title?.toLowerCase().contains(searchQuery.toLowerCase()) ??
                    false) ||
                (t.language?.toLowerCase().contains(searchQuery.toLowerCase()) ??
                    false);
            return t.id != 'no' && !isExternal && matchesSearch;
          }).toList();

          // Group online subs by language code.
          final Map<String, List<Map<String, dynamic>>> byLang = {};
          for (final s in _externalSubtitles) {
            final key = languageGroupKey(s['language'] as String?);
            byLang.putIfAbsent(key, () => []).add(s);
          }
          final folderKeys = byLang.keys.toList()..sort(compareLanguageCodes);

          // Currently visible online subs, depending on view + search.
          List<Map<String, dynamic>> online;
          if (inFolder) {
            online = (byLang[_subsMenuFolder!] ?? []).where((s) {
              if (searchQuery.isEmpty) return true;
              final q = searchQuery.toLowerCase();
              return (s['display'] ?? '')
                      .toString()
                      .toLowerCase()
                      .contains(q) ||
                  (s['language'] ?? '')
                      .toString()
                      .toLowerCase()
                      .contains(q);
            }).toList();
          } else {
            online = const [];
          }

          // At the root, the search box filters the folder list.
          final visibleFolders = !inFolder && searchQuery.isNotEmpty
              ? folderKeys.where((k) {
                  final q = searchQuery.toLowerCase();
                  return languageDisplayName(k).toLowerCase().contains(q) ||
                      k.contains(q);
                }).toList()
              : folderKeys;

          return SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
                child: Row(
                  children: [
                    if (inFolder)
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: Colors.white),
                        tooltip: 'Back to languages',
                        onPressed: () {
                          setModalState(() {
                            searchQuery = '';
                            _subsMenuFolder = null;
                          });
                          setState(() {});
                        },
                      )
                    else
                      const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                          inFolder
                              ? languageDisplayName(_subsMenuFolder)
                              : 'Subtitles',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7C3AED).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.4)),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.tune_rounded, color: Color(0xFF7C3AED), size: 20),
                          SizedBox(width: 4),
                          Text('Style', style: TextStyle(color: Color(0xFF7C3AED), fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                      tooltip: 'Subtitle settings',
                      onPressed: () {
                        Navigator.pop(context);
                        _showSubtitleSettings();
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: inFolder
                        ? 'Search in ${languageDisplayName(_subsMenuFolder)}...'
                        : 'Search subtitles...',
                    hintStyle: const TextStyle(color: Colors.white54),
                    prefixIcon:
                        const Icon(Icons.search, color: Colors.white54),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.08),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 0),
                  ),
                  onChanged: (v) => setModalState(() => searchQuery = v),
                ),
              ),
              if (_isFetchingSubs)
                const Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: LinearProgressIndicator(
                      color: Color(0xFF7C3AED),
                      backgroundColor: Colors.white10),
                ),
              Expanded(
                child: ListView(children: [
                  if (!inFolder) ...[
                    ListTile(
                      leading:
                          const Icon(Icons.close, color: Colors.white70),
                      title: const Text('Off',
                          style: TextStyle(color: Colors.white)),
                      trailing: current.id == 'no'
                          ? const Icon(Icons.check,
                              color: Color(0xFF7C3AED))
                          : null,
                      onTap: () {
                        _player.setSubtitleTrack(SubtitleTrack.no());
                        _updateSubVisibility(SubtitleTrack.no());
                        if (mounted) {
                          setState(() => _selectedExternalSubUrl = null);
                        }
                        Navigator.pop(context);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.file_upload_outlined,
                          color: Colors.white70),
                      title: const Text('Load from file',
                          style: TextStyle(color: Colors.white)),
                      onTap: () async {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['srt', 'ass', 'ssa', 'vtt'],
                        );
                        if (result != null &&
                            result.files.single.path != null) {
                          final file = File(result.files.single.path!);
                          final content = await file.readAsString();
                          final name = result.files.single.name;
                          final subTrack = SubtitleTrack.data(
                              content, title: name, language: 'und');
                          _player.setSubtitleTrack(subTrack);
                          // Detect ASS from file extension since data tracks have no codec
                          final isAssFile = name.toLowerCase().endsWith('.ass') ||
                              name.toLowerCase().endsWith('.ssa');
                          setState(() {
                            _selectedExternalSubUrl = null;
                            _isNativeSubtitle = isAssFile;
                          });
                          if (_player.platform is NativePlayer) {
                            (_player.platform as NativePlayer)
                                .setProperty('sub-visibility', isAssFile ? 'yes' : 'no');
                          }
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                    ),
                    if (embedded.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text('EMBEDDED',
                            style: TextStyle(
                                color: Color(0xFF7C3AED),
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ),
                      ...embedded.map((t) {
                        final sel = t.id == current.id &&
                            _selectedExternalSubUrl == null;
                        return ListTile(
                          title: Text(
                              t.title ?? t.language ?? 'Track ${t.id}',
                              style: TextStyle(
                                  color: sel
                                      ? const Color(0xFF7C3AED)
                                      : Colors.white,
                                  fontWeight: sel
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          trailing: sel
                              ? const Icon(Icons.check,
                                  color: Color(0xFF7C3AED))
                              : null,
                          onTap: () {
                            _player.setSubtitleTrack(t);
                            _updateSubVisibility(t);
                            if (mounted) {
                              setState(() => _selectedExternalSubUrl = null);
                            }
                            Navigator.pop(context);
                          },
                        );
                      }),
                    ],
                    if (visibleFolders.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text('ONLINE LANGUAGES',
                            style: TextStyle(
                                color: Color(0xFF7C3AED),
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ),
                      ...visibleFolders.map((key) {
                        final list = byLang[key]!;
                        final hasSelected = list.any((s) =>
                            s['url'] == _selectedExternalSubUrl);
                        return ListTile(
                          leading: Icon(
                            hasSelected
                                ? Icons.folder_rounded
                                : Icons.folder_outlined,
                            color: hasSelected
                                ? const Color(0xFF7C3AED)
                                : Colors.white70,
                          ),
                          title: Text(languageDisplayName(key),
                              style: TextStyle(
                                  color: hasSelected
                                      ? const Color(0xFF7C3AED)
                                      : Colors.white,
                                  fontWeight: hasSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          subtitle: Text(
                              '${list.length} subtitle${list.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          trailing: const Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white54),
                          onTap: () {
                            setModalState(() {
                              searchQuery = '';
                              _subsMenuFolder = key;
                            });
                            setState(() {});
                          },
                        );
                      }),
                    ],
                    if (embedded.isEmpty && visibleFolders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                            child: Text('No subtitles found',
                                style:
                                    TextStyle(color: Colors.white54))),
                      ),
                  ] else ...[
                    // In-folder view: list this language's subtitles only.
                    if (online.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                            child: Text('No subtitles match',
                                style:
                                    TextStyle(color: Colors.white54))),
                      )
                    else
                      ...online.map((s) {
                        final sel = s['url'] == _selectedExternalSubUrl;
                        return ListTile(
                          title: Text(s['display'] ?? 'Unknown',
                              style: TextStyle(
                                  color: sel
                                      ? const Color(0xFF7C3AED)
                                      : Colors.white,
                                  fontWeight: sel
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          subtitle: Text(
                              (s['translated'] == true
                                      ? 'Translated · '
                                      : '') +
                                  (s['sourceName']?.toString() ?? ''),
                              style: TextStyle(
                                  color: sel
                                      ? const Color(0xFF7C3AED)
                                          .withValues(alpha: 0.7)
                                      : Colors.white54,
                                  fontSize: 12)),
                          trailing: sel
                              ? const Icon(Icons.check,
                                  color: Color(0xFF7C3AED))
                              : null,
                          onTap: () async {
                            await _loadOnlineSubtitle(s);
                            if (context.mounted) Navigator.pop(context);
                          },
                        );
                      }),
                  ],
                ]),
              ),
            ]),
          );
        });
      },
    );
  }

  void _showSubtitleSettings() {
    final fonts = ['Default', 'Poppins', 'Roboto', 'Roboto Mono', 'Montserrat', 'Open Sans', 'Lato'];
    final colorOptions = <String, Color>{
      'White': Colors.white,
      'Yellow': const Color(0xFFFFEB3B),
      'Cyan': const Color(0xFF00E5FF),
      'Green': const Color(0xFF69F0AE),
      'Orange': const Color(0xFFFFAB40),
      'Pink': const Color(0xFFFF80AB),
    };

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialog) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text('Subtitle Settings',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // ── Size ─────────────────────────────────────────────
              _subRow('Size', Expanded(child: Slider(
                value: _subtitleSize, min: 20, max: 80,
                thumbColor: const Color(0xFF7C3AED),
                onChanged: (v) { setDialog(() => _subtitleSize = v); setState(() {}); },
              )), '${_subtitleSize.toInt()}'),

              // ── Delay (arrow buttons) ──────────────────────────
              _subRow('Delay', Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.remove, color: Colors.white70, size: 20),
                  onPressed: () {
                    final v = _subtitleDelay - 0.1;
                    setDialog(() => _subtitleDelay = double.parse(v.toStringAsFixed(1)));
                    if (_player.platform is NativePlayer) {
                      (_player.platform as NativePlayer).setProperty('sub-delay', _subtitleDelay.toString());
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.white70, size: 20),
                  onPressed: () {
                    final v = _subtitleDelay + 0.1;
                    setDialog(() => _subtitleDelay = double.parse(v.toStringAsFixed(1)));
                    if (_player.platform is NativePlayer) {
                      (_player.platform as NativePlayer).setProperty('sub-delay', _subtitleDelay.toString());
                    }
                  },
                ),
              ]), '${_subtitleDelay.toStringAsFixed(1)}s'),

              // ── Text Color ─────────────────────────────────────
              _subLabel('Text Color'),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 8, children: colorOptions.entries.map((e) {
                final selected = _subtitleColor.toARGB32() == e.value.toARGB32();
                return GestureDetector(
                  onTap: () {
                    setDialog(() => _subtitleColor = e.value);
                    setState(() {});
                    SettingsService().setSubColor(e.value.toARGB32());
                  },
                  child: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: e.value,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? const Color(0xFF7C3AED) : Colors.white24,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList()),
              const SizedBox(height: 12),

              // ── Background Opacity ─────────────────────────────
              _subRow('BG Opacity', Expanded(child: Slider(
                value: _subtitleBgOpacity, min: 0.0, max: 1.0,
                thumbColor: const Color(0xFF7C3AED),
                onChanged: (v) { setDialog(() => _subtitleBgOpacity = v); setState(() {}); },
              )), '${(_subtitleBgOpacity * 100).toInt()}%'),

              // ── Position (bottom padding) ──────────────────────
              _subRow('Position', Expanded(child: Slider(
                value: _subtitleBottomPadding, min: 0, max: 120,
                thumbColor: const Color(0xFF7C3AED),
                onChanged: (v) { setDialog(() => _subtitleBottomPadding = v); setState(() {}); },
              )), '${_subtitleBottomPadding.toInt()}'),

              // ── Bold ───────────────────────────────────────────
              Row(children: [
                const SizedBox(width: 70, child: Text('Bold', style: TextStyle(color: Colors.white70, fontSize: 13))),
                const Spacer(),
                Switch(
                  value: _subtitleBold,
                  activeThumbColor: const Color(0xFF7C3AED),
                  onChanged: (v) { setDialog(() => _subtitleBold = v); setState(() {}); SettingsService().setSubBold(v); },
                ),
              ]),

              // ── Font ───────────────────────────────────────────
              _subLabel('Font'),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 6, children: fonts.map((f) {
                final selected = _subtitleFont == f;
                return GestureDetector(
                  onTap: () { setDialog(() => _subtitleFont = f); setState(() {}); SettingsService().setSubFont(f); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF7C3AED).withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: selected ? const Color(0xFF7C3AED) : Colors.white12),
                    ),
                    child: Text(f, style: TextStyle(color: selected ? Colors.white : Colors.white54, fontSize: 12)),
                  ),
                );
              }).toList()),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () {
                SettingsService().setSubSize(_subtitleSize);
                SettingsService().setSubBgOpacity(_subtitleBgOpacity);
                SettingsService().setSubBottomPadding(_subtitleBottomPadding);
                Navigator.pop(context);
              },
              child: const Text('Close', style: TextStyle(color: Color(0xFF7C3AED))),
            ),
          ],
        );
      }),
    );
  }

  Widget _subRow(String label, Widget middle, String trailing) {
    return Row(children: [
      SizedBox(width: 70, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
      if (middle is Expanded) middle else middle,
      SizedBox(width: 44, child: Text(trailing, style: const TextStyle(color: Colors.white, fontSize: 12), textAlign: TextAlign.right)),
    ]);
  }

  Widget _subLabel(String label) {
    return Align(alignment: Alignment.centerLeft, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)));
  }

  Future<void> _loadSubtitlePrefs() async {
    final s = SettingsService();
    final size = await s.getSubSize(isDesktop: true);
    final color = await s.getSubColor();
    final bgOp = await s.getSubBgOpacity();
    final bold = await s.getSubBold();
    final padding = await s.getSubBottomPadding();
    final font = await s.getSubFont();
    if (mounted) {
      setState(() {
        _subtitleSize = size;
        _subtitleColor = Color(color);
        _subtitleBgOpacity = bgOp;
        _subtitleBold = bold;
        _subtitleBottomPadding = padding;
        _subtitleFont = font;
      });
    }
  }

  TextStyle _buildSubtitleTextStyle({double scale = 1.0}) {
    final base = TextStyle(
      height: 1.4,
      fontSize: _subtitleSize * scale,
      letterSpacing: 0.0,
      wordSpacing: 0.0,
      color: _subtitleColor,
      fontWeight: _subtitleBold ? FontWeight.bold : FontWeight.normal,
      backgroundColor: Colors.black.withValues(alpha: _subtitleBgOpacity),
      shadows: [
        Shadow(blurRadius: 10 * scale, color: Colors.black, offset: Offset.zero),
      ],
    );
    if (_subtitleFont == 'Default') return base;
    final fontMap = <String, TextStyle Function({TextStyle? textStyle})>{
      'Poppins': GoogleFonts.poppins,
      'Roboto': GoogleFonts.roboto,
      'Roboto Mono': GoogleFonts.robotoMono,
      'Montserrat': GoogleFonts.montserrat,
      'Open Sans': GoogleFonts.openSans,
      'Lato': GoogleFonts.lato,
    };
    final fn = fontMap[_subtitleFont];
    if (fn != null) return fn(textStyle: base);
    return base;
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  AUDIO
  // ─────────────────────────────────────────────────────────────────────────

  void _showAudioMenu() {
    final tracks =
        _player.state.tracks.audio.where((t) => t.id != 'no').toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Audio Tracks',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          if (tracks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No audio tracks found',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            ...tracks.map((t) => ListTile(
                  leading: const Icon(Icons.audiotrack,
                      color: Colors.white70),
                  title: Text(
                      t.title ?? t.language ?? 'Track ${t.id}',
                      style: const TextStyle(color: Colors.white)),
                  trailing: t.id == _player.state.track.audio.id
                      ? const Icon(Icons.check,
                          color: Color(0xFF7C3AED))
                      : null,
                  onTap: () {
                    _player.setAudioTrack(t);
                    Navigator.pop(context);
                  },
                )),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  HLS QUALITY SELECTOR
  // ─────────────────────────────────────────────────────────────────────────

  /// Probe [url] as a master HLS playlist. Populates the quality notifier
  /// when 2+ variants are present, otherwise clears it (hiding the gear).
  void _detectHlsQualities(String url, Map<String, String>? headers) {
    _currentQualityUrl = url;
    if (!url.contains('.m3u8')) {
      _hlsMasterUrl = null;
      _hlsMasterHeaders = null;
      _hlsQualitiesNotifier.value = null;
      return;
    }
    final existing = _hlsQualitiesNotifier.value;
    if (existing != null && existing.any((q) => q.url == url)) return;

    _hlsMasterUrl = url;
    _hlsMasterHeaders = headers;
    _hlsQualitiesNotifier.value = null;
    fetchHlsQualities(url, headers: headers).then((qs) {
      if (_disposed) return;
      if (_hlsMasterUrl != url) return;
      _hlsQualitiesNotifier.value = qs;
    });
  }

  void _showQualityMenu() {
    final qs = _hlsQualitiesNotifier.value;
    if (qs == null || qs.length < 2) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2)),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Quality',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: qs.length,
              itemBuilder: (context, i) {
                final q = qs[i];
                final isCurrent = q.url == _currentQualityUrl;
                return ListTile(
                  leading: Icon(
                    q.isAuto ? Icons.auto_awesome_outlined : Icons.high_quality_outlined,
                    color: isCurrent ? const Color(0xFF7C3AED) : Colors.white70,
                  ),
                  title: Text(
                    q.label,
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFF7C3AED) : Colors.white,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: q.bandwidth != null
                      ? Text(
                          '${(q.bandwidth! / 1000).round()} kbps',
                          style: TextStyle(
                            color: isCurrent
                                ? const Color(0xFF7C3AED).withValues(alpha: 0.7)
                                : Colors.white54,
                            fontSize: 11,
                          ),
                        )
                      : null,
                  trailing: isCurrent
                      ? const Icon(Icons.check, color: Color(0xFF7C3AED))
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    if (isCurrent) return;
                    final pos = _positionNotifier.value;
                    _currentQualityUrl = q.url;
                    if (mounted) setState(() {});
                    if (_hlsMasterHeaders != null && _player.platform is NativePlayer) {
                      final ref = _hlsMasterHeaders!['Referer'] ??
                          _hlsMasterHeaders!['referer'];
                      if (ref != null) {
                        await (_player.platform as NativePlayer)
                            .setProperty('referrer', ref);
                      }
                    }
                    await _player.open(
                      Media(q.url, httpHeaders: _hlsMasterHeaders),
                    );
                    if (pos.inSeconds > 0) await _player.seek(pos);
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  SOURCE SELECTION (for Amri provider)
  // ─────────────────────────────────────────────────────────────────────────

  void _showSourcesMenu() {
    if (_currentSources == null || _currentSources!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No sources available'),
        duration: Duration(seconds: 1),
      ));
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2)),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Video Sources',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _currentSources!.length,
              itemBuilder: (context, index) {
                final source = _currentSources![index];
                final isCurrent = _currentProvider == 'service111477'
                    ? source.url == _current111477FileUrl
                    : source.url == _currentUrl;
                return ListTile(
                  leading: Icon(
                    Icons.play_circle_outline,
                    color: isCurrent ? const Color(0xFF7C3AED) : Colors.white70,
                  ),
                  title: Text(
                    source.title,
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFF7C3AED) : Colors.white,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    source.type.toUpperCase(),
                    style: TextStyle(
                      color: isCurrent 
                          ? const Color(0xFF7C3AED).withValues(alpha: 0.7)
                          : Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                  trailing: isCurrent
                      ? const Icon(Icons.check, color: Color(0xFF7C3AED))
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    if (!isCurrent) {
                      // Save current position
                      final currentPos = _positionNotifier.value;
                      final messenger = ScaffoldMessenger.of(context);

                      // 111477: stop the proxy (which deletes its on-disk
                      // cache), restart it with the new upstream URL, then
                      // open the new localhost stream URL.
                      if (_currentProvider == 'service111477') {
                        messenger.showSnackBar(SnackBar(
                          content: Text('Switching to ${source.title}…'),
                          duration: const Duration(seconds: 30),
                        ));
                        try {
                          if (site111477_proxy.is111477ProxyRunning) {
                            await site111477_proxy.stop111477Proxy();
                          }
                          final newProxied =
                              await site111477_proxy.start111477Proxy(source.url);
                          if (!mounted) return;
                          messenger.hideCurrentSnackBar();
                          await _player.open(Media(newProxied));
                          setState(() {
                            _currentUrl = newProxied;
                            _current111477FileUrl = source.url;
                            _currentFallbackSourceIndex = 0;
                            _hasError = false;
                            _errorMessage = '';
                          });
                          _detectHlsQualities(newProxied, null);
                          if (currentPos.inSeconds > 0) {
                            await _player.seek(currentPos);
                          }
                          if (mounted) {
                            messenger.showSnackBar(SnackBar(
                              content: Text('Switched to ${source.title}'),
                              duration: const Duration(seconds: 2),
                            ));
                          }
                        } catch (e) {
                          if (!mounted) return;
                          messenger.hideCurrentSnackBar();
                          messenger.showSnackBar(SnackBar(
                            content: Text('Switch failed: $e'),
                            duration: const Duration(seconds: 3),
                          ));
                        }
                        return;
                      }

                      // Arabic provider: extract on-demand from embed URL
                      if (_currentProvider == 'arabic' && source.type == 'arabic_embed') {
                        messenger.showSnackBar(SnackBar(
                          content: Text('Extracting ${source.title}...'),
                          duration: const Duration(seconds: 30),
                        ));
                        final result = await ArabicService.extractStreamUrl(source.url);
                        if (!mounted) return;
                        messenger.hideCurrentSnackBar();
                        if (result == null) {
                          messenger.showSnackBar(SnackBar(
                            content: Text('Failed to extract ${source.title}'),
                            duration: const Duration(seconds: 2),
                          ));
                          return;
                        }
                        await _player.open(
                          Media(result.url, httpHeaders: result.headers),
                        );
                        // Update the source entry with the extracted stream URL
                        _currentSources![index] = StreamSource(
                          url: result.url,
                          title: source.title,
                          type: result.url.contains('.m3u8') ? 'hls' : result.url.contains('.mpd') ? 'dash' : 'mp4',
                        );
                        setState(() {
                          _currentUrl = result.url;
                          _currentFallbackSourceIndex = 0;
                          _hasError = false;
                          _errorMessage = '';
                        });
                        _detectHlsQualities(result.url, result.headers);
                      } else {
                        // Normal direct switch
                        await _player.open(
                          Media(source.url, httpHeaders: source.headers ?? widget.headers),
                        );
                        setState(() {
                          _currentUrl = source.url;
                          _currentFallbackSourceIndex = 0;
                          _hasError = false;
                          _errorMessage = '';
                        });
                        _detectHlsQualities(source.url, source.headers ?? widget.headers);
                      }
                      
                      // Seek to saved position
                      if (currentPos.inSeconds > 0) {
                        await _player.seek(currentPos);
                      }
                      
                      if (mounted) {
                        messenger.showSnackBar(SnackBar(
                          content: Text('Switched to ${source.title}'),
                          duration: const Duration(seconds: 2),
                        ));
                      }
                    }
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  MISC CONTROLS
  // ─────────────────────────────────────────────────────────────────────────

  void _toggleLoop() {
    setState(() => _loopEnabled = !_loopEnabled);
    _player.setPlaylistMode(
        _loopEnabled ? PlaylistMode.single : PlaylistMode.none);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Loop: ${_loopEnabled ? "ON" : "OFF"}'),
        duration: const Duration(seconds: 1)));
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  SKIP SEGMENTS (IntroDB)
  // ───────────────────────────────────────────────────────────────────────────

  void _updateActiveSkipSegment(Duration pos) {
    if (_introDbData == null) return;

    final posMs = pos.inMilliseconds;
    String? label;
    Duration? target;

    // Check each segment type – first match wins
    for (final seg in _introDbData!.recap) {
      final s = seg.startMs ?? 0;
      final e = seg.endMs;
      if (e != null && posMs >= s && posMs < e) {
        label = 'Skip Recap';
        target = Duration(milliseconds: e);
        break;
      }
    }
    if (label == null) {
      for (final seg in _introDbData!.intro) {
        final s = seg.startMs ?? 0;
        final e = seg.endMs;
        if (e != null && posMs >= s && posMs < e) {
          label = 'Skip Intro';
          target = Duration(milliseconds: e);
          break;
        }
      }
    }
    if (label == null) {
      for (final seg in _introDbData!.credits) {
        final s = seg.startMs;
        final e = seg.endMs;
        if (s != null && posMs >= s) {
          final end = e ?? _durationNotifier.value.inMilliseconds;
          if (posMs < end) {
            label = 'Skip Credits';
            target = Duration(milliseconds: end);
            break;
          }
        }
      }
    }
    if (label == null) {
      for (final seg in _introDbData!.preview) {
        final s = seg.startMs;
        final e = seg.endMs;
        if (s != null && posMs >= s) {
          final end = e ?? _durationNotifier.value.inMilliseconds;
          if (posMs < end) {
            label = 'Skip Preview';
            target = Duration(milliseconds: end);
            break;
          }
        }
      }
    }

    // Only setState when needed – avoid per-frame rebuilds
    if (label != _activeSkipLabel) {
      setState(() {
        _activeSkipLabel = label;
        _activeSkipTarget = target;
        _skipDismissed = false; // reset dismiss when segment changes
      });
    }
  }

  void _performSkip() {
    if (_activeSkipTarget == null) return;
    _player.seek(_activeSkipTarget!);
    setState(() {
      _activeSkipLabel = null;
      _activeSkipTarget = null;
    });
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  NEXT EPISODE
  // ───────────────────────────────────────────────────────────────────────────

  bool get _isNextEpisodeAvailable =>
      (widget.onNextEpisode != null && widget.hasNextEpisode) ||
      (widget.movie != null &&
          widget.movie!.mediaType == 'tv' &&
          widget.selectedSeason != null &&
          widget.selectedEpisode != null);

  bool get _showNextEpButton =>
      _isNextEpisodeAvailable && (_nearEndOfEpisode || _isLoadingNextEp);

  Future<void> _nextEpisode() async {
    if (!_isNextEpisodeAvailable || _isLoadingNextEp) return;

    setState(() => _isLoadingNextEp = true);

    if (widget.onNextEpisode != null) {
      try {
        _saveWatchHistory();
        await widget.onNextEpisode!();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Next episode failed: $e')),
          );
          setState(() => _isLoadingNextEp = false);
        }
      }
      return;
    }

    // ── Streaming-mode shortcut ─────────────────────────────────────────
    // When launched from streaming_details_screen (= a `providers` map
    // was passed), don't try to re-resolve the source here. Instead,
    // pop back with {nextSeason, nextEpisode} so streaming_details can
    // re-run the full provider fallback chain — same path the user
    // gets when tapping an episode card manually. Fixes "Provider X
    // does not support TV" when the active provider lacks a `tv`
    // entry but other providers in the chain would have worked.
    final isStreamingMode = widget.providers != null &&
        widget.providers!.isNotEmpty &&
        widget.movie != null &&
        widget.movie!.mediaType == 'tv' &&
        widget.selectedSeason != null &&
        widget.selectedEpisode != null;
    if (isStreamingMode) {
      try {
        final tmdb = TmdbService();
        final tvId = widget.movie!.id;
        int nextSeason = widget.selectedSeason!;
        int nextEpisode = widget.selectedEpisode! + 1;

        final seasonData = await tmdb.getTvSeasonDetails(tvId, nextSeason);
        final episodes = seasonData['episodes'] as List<dynamic>? ?? [];
        final maxEp = episodes.isNotEmpty
            ? episodes
                .map((e) => e['episode_number'] as int)
                .reduce((a, b) => a > b ? a : b)
            : 0;

        if (nextEpisode > maxEp) {
          final totalSeasons = await tmdb.getTvSeasonCount(tvId);
          if (nextSeason < totalSeasons) {
            nextSeason++;
            nextEpisode = 1;
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('No more episodes available')),
              );
              setState(() => _isLoadingNextEp = false);
            }
            return;
          }
        }

        _saveWatchHistory();
        if (!mounted) return;
        Navigator.of(context).pop({
          'nextSeason': nextSeason,
          'nextEpisode': nextEpisode,
        });
      } catch (e) {
        debugPrint('[NextEp] Streaming-mode handoff failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Next episode failed: $e')),
          );
          setState(() => _isLoadingNextEp = false);
        }
      }
      return;
    }

    try {
      final tmdb = TmdbService();
      final tvId = widget.movie!.id;
      int nextSeason = widget.selectedSeason!;
      int nextEpisode = widget.selectedEpisode! + 1;

      // Check if next episode exists in current season
      final seasonData = await tmdb.getTvSeasonDetails(tvId, nextSeason);
      final episodes = seasonData['episodes'] as List<dynamic>? ?? [];
      final maxEp = episodes.isNotEmpty
          ? episodes.map((e) => e['episode_number'] as int).reduce((a, b) => a > b ? a : b)
          : 0;

      if (nextEpisode > maxEp) {
        // Try next season
        final totalSeasons = await tmdb.getTvSeasonCount(tvId);
        if (nextSeason < totalSeasons) {
          nextSeason++;
          nextEpisode = 1;
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No more episodes available')),
            );
          }
          setState(() => _isLoadingNextEp = false);
          return;
        }
      }

      debugPrint('[NextEp] Playing S${nextSeason}E$nextEpisode');

      // Save current watch history before switching
      _saveWatchHistory();

      String? streamUrl;
      String? magnetLink;
      int? fileIndex;
      Map<String, String>? headers;
      List<StreamSource>? nextSources;
      String? activeProvider = widget.activeProvider;

      final isTorrent = widget.magnetLink != null &&
          widget.activeProvider != 'stremio_direct';
      final isStremioDirect = widget.activeProvider == 'stremio_direct';
      final isWebStreamr = widget.activeProvider == 'webstreamr';
      final isAmri = widget.activeProvider == 'amri';
      final isService111477 = widget.activeProvider == 'service111477';

      if (isStremioDirect && widget.stremioAddonBaseUrl != null) {
        // ── Stremio addon: re-fetch streams for next episode ────────────
        final stremio = StremioService();
        final stremioId = widget.stremioId ?? widget.movie!.imdbId;
        if (stremioId == null) throw Exception('No Stremio ID available');

        final epId = '$stremioId:$nextSeason:$nextEpisode';
        final streams = await stremio.getStreams(
          baseUrl: widget.stremioAddonBaseUrl!,
          type: 'series',
          id: epId,
        );

        if (streams.isEmpty) throw Exception('No streams found for S${nextSeason}E$nextEpisode');

        final stream = streams.first as Map<String, dynamic>;

        if (stream['url'] != null) {
          streamUrl = stream['url'] as String;
          final proxyHeaders = stream['behaviorHints']?['proxyHeaders']?['request'];
          if (proxyHeaders is Map) {
            headers = Map<String, String>.from(proxyHeaders);
          }
        } else if (stream['infoHash'] != null) {
          // Stremio returned a torrent hash — resolve it
          final infoHash = stream['infoHash'] as String;
          final streamTitle = (stream['title'] ?? stream['name'] ?? '').toString();
          final dn = streamTitle.isNotEmpty ? '&dn=${Uri.encodeComponent(streamTitle)}' : '';
          final sourcesList = stream['sources'];
          final trackerParams = StringBuffer();
          if (sourcesList is List) {
            for (final src in sourcesList) {
              if (src is String && src.startsWith('tracker:')) {
                trackerParams.write('&tr=${Uri.encodeComponent(src.substring(8))}');
              }
            }
          }
          magnetLink = 'magnet:?xt=urn:btih:$infoHash$dn$trackerParams';

          final settings = SettingsService();
          final useDebrid = await settings.useDebridForStreams();
          final debridService = await settings.getDebridService();

          if (useDebrid && debridService != 'None') {
            final debrid = DebridApi();
            final files = await debrid.resolveByService(
              debridService,
              magnetLink,
              season: nextSeason,
              episode: nextEpisode,
            );
            if (files.isNotEmpty) {
              fileIndex = 0;
              streamUrl = files.first.downloadUrl;
            }
          } else {
            streamUrl = await TorrentStreamService().streamTorrent(
              magnetLink,
              season: nextSeason,
              episode: nextEpisode,
            );
            if (streamUrl != null) {
              final idx = Uri.parse(streamUrl).queryParameters['index'];
              if (idx != null) fileIndex = int.tryParse(idx);
            }
          }
          activeProvider = 'torrent';
        }
      } else if (isTorrent) {
        // ── Torrent: re-search for next episode ───────────────────────
        final s = nextSeason.toString().padLeft(2, '0');
        final e = nextEpisode.toString().padLeft(2, '0');
        final query = '${widget.movie!.title} S${s}E$e';
        debugPrint('[NextEp] Searching torrents: $query');

        final torrentApi = TorrentApi();
        final results = await torrentApi.searchTorrents(query);
        final filtered = await TorrentFilter.filterTorrentsAsync(
          results,
          widget.movie!.title,
          requiredSeason: nextSeason,
          requiredEpisode: nextEpisode,
        );

        if (filtered.isEmpty) throw Exception('No torrents found for S${s}E$e');

        // Pick best result (highest seeders)
        filtered.sort((a, b) => b.seeders.compareTo(a.seeders));
        magnetLink = filtered.first.magnet;

        final settings = SettingsService();
        final useDebrid = await settings.useDebridForStreams();
        final debridService = await settings.getDebridService();

        if (useDebrid && debridService != 'None') {
          final debrid = DebridApi();
          final files = await debrid.resolveByService(
            debridService,
            magnetLink,
            season: nextSeason,
            episode: nextEpisode,
          );
          if (files.isNotEmpty) {
            fileIndex = 0;
            streamUrl = files.first.downloadUrl;
          }
        } else {
          streamUrl = await TorrentStreamService().streamTorrent(
            magnetLink,
            season: nextSeason,
            episode: nextEpisode,
          );
          if (streamUrl != null) {
            final idx = Uri.parse(streamUrl).queryParameters['index'];
            if (idx != null) fileIndex = int.tryParse(idx);
          }
        }
      } else if (isWebStreamr) {
        // ── WebStreamr: fetch next episode streams ────────────────────
        final imdbId = widget.movie!.imdbId;
        if (imdbId == null || imdbId.isEmpty) throw Exception('No IMDB ID for WebStreamr');

        final webStreamr = WebStreamrService();
        final sources = await webStreamr.getStreams(
          imdbId: imdbId,
          isMovie: false,
          season: nextSeason,
          episode: nextEpisode,
        );
        if (sources.isEmpty) throw Exception('No WebStreamr sources for S${nextSeason}E$nextEpisode');
        streamUrl = sources.first.url;
      } else if (isService111477) {
        // ── 111477.xyz: resolve next episode → restart proxy ──────────
        final svc = Site111477Service();
        final hits = await svc.findEpisodeSources(
          showTitle: widget.movie!.title,
          season: nextSeason,
          episode: nextEpisode,
        );
        if (hits.isEmpty) {
          throw Exception('No 111477 file for S${nextSeason}E$nextEpisode');
        }
        // Stop the previous proxy session before starting the new one;
        // start111477Proxy() also handles this internally but we want the
        // old cache deleted first.
        if (site111477_proxy.is111477ProxyRunning) {
          await site111477_proxy.stop111477Proxy();
        }
        streamUrl = await site111477_proxy.start111477Proxy(hits.first.fileUrl);
        nextSources = Site111477Service.toStreamSources(hits);
      } else if (isAmri) {
        // ── AMRI: re-extract for next episode ─────────────────────────
        final extractor = StreamExtractor();
        final result = await extractor.extractWithAmri(
          tmdbId: widget.movie!.id.toString(),
          isMovie: false,
          season: nextSeason,
          episode: nextEpisode,
        );
        if (result == null) throw Exception('AMRI extraction failed for S${nextSeason}E$nextEpisode');
        streamUrl = result.url;
        headers = result.headers.isNotEmpty ? result.headers : null;
      } else if (widget.activeProvider != null &&
          widget.activeProvider!.startsWith('nuvio:')) {
        // ── Nuvio scraper: re-run for next episode ────────────────────
        final scraperId = widget.activeProvider!.substring(6);
        final results = await NuvioService.instance.runOneScraper(
          scraperId: scraperId,
          tmdbId: widget.movie!.id.toString(),
          type: 'tv',
          season: nextSeason,
          episode: nextEpisode,
        );
        if (results.isEmpty) {
          throw Exception('Nuvio: no streams for S${nextSeason}E$nextEpisode');
        }
        final first = results.first;
        streamUrl = first.url;
        headers = first.headers.isNotEmpty ? first.headers : null;
        nextSources = results
            .map((r) => StreamSource(
                  url: r.url,
                  title: r.title.isNotEmpty ? r.title : r.name,
                  type: r.url.toLowerCase().contains('.m3u8')
                      ? 'hls'
                      : r.url.toLowerCase().contains('.mpd')
                          ? 'dash'
                          : 'mp4',
                  headers: r.headers.isEmpty ? null : r.headers,
                ))
            .toList();
      } else if (widget.activeProvider != null) {
        // ── Stream provider (vidlink, vixsrc, etc.) ───────────────────
        final provider = StreamProviders.providers[widget.activeProvider];
        if (provider == null || provider['tv'] == null) {
          throw Exception('Provider ${widget.activeProvider} does not support TV');
        }

        final providerUrl = provider['tv'](
          widget.movie!.id.toString(),
          nextSeason,
          nextEpisode,
        );
        final extractor = StreamExtractor();
        final result = await extractor.extract(providerUrl, timeout: const Duration(seconds: 20));
        if (result == null) throw Exception('Extraction failed for S${nextSeason}E$nextEpisode');
        streamUrl = result.url;
        headers = result.headers.isNotEmpty ? result.headers : null;
      }

      if (streamUrl == null || streamUrl.isEmpty) {
        throw Exception('Could not find stream for S${nextSeason}E$nextEpisode');
      }

      if (!mounted) return;

      // Navigate to new player with next episode
      final nextTitle = '${widget.movie!.title} - S$nextSeason E$nextEpisode';
      final navigator = Navigator.of(context);
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            streamUrl: streamUrl!,
            title: nextTitle,
            headers: headers,
            movie: widget.movie,
            selectedSeason: nextSeason,
            selectedEpisode: nextEpisode,
            magnetLink: magnetLink,
            fileIndex: fileIndex,
            activeProvider: activeProvider,
            stremioId: widget.stremioId,
            stremioAddonBaseUrl: widget.stremioAddonBaseUrl,
            providers: widget.providers,
            sources: nextSources,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[NextEp] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Next episode error: $e')),
        );
        setState(() => _isLoadingNextEp = false);
      }
    }
  }

  void _showProviderMenu() {
    if (widget.providers == null || widget.providers!.isEmpty || widget.movie == null) {
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2)),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Switch Provider',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.providers!.length,
              itemBuilder: (context, index) {
                final key = widget.providers!.keys.elementAt(index);
                final provider = widget.providers![key];
                final isCurrent = key == _currentProvider;
                return ListTile(
                  leading: Icon(
                    Icons.stream_rounded,
                    color: isCurrent ? const Color(0xFF7C3AED) : Colors.white70,
                  ),
                  title: Text(
                    provider['name'],
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFF7C3AED) : Colors.white,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: isCurrent
                      ? const Icon(Icons.check, color: Color(0xFF7C3AED))
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    if (!isCurrent) {
                      await _switchProvider(key);
                    }
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _switchProvider(String newProvider) async {
    if (_isSwitchingProvider) return;
    
    setState(() => _isSwitchingProvider = true);
    
    final currentPos = _positionNotifier.value;
    final messenger = ScaffoldMessenger.of(context);
    
    try {
      final provider = widget.providers![newProvider];
      
      messenger.showSnackBar(SnackBar(
        content: Text('Extracting from ${provider['name']}...'),
        duration: const Duration(seconds: 2),
      ));

      String? streamUrl;
      Map<String, String>? headers;
      List<StreamSource>? sources;

      if (newProvider == 'service111477' && widget.movie != null) {
        final svc = Site111477Service();
        List<Site111477Match> hits;
        if (widget.movie!.mediaType == 'tv') {
          hits = await svc.findEpisodeSources(
            showTitle: widget.movie!.title,
            season: widget.selectedSeason ?? 1,
            episode: widget.selectedEpisode ?? 1,
          );
        } else {
          final year = widget.movie!.releaseDate.length >= 4
              ? widget.movie!.releaseDate.substring(0, 4)
              : null;
          hits = await svc.findMovieSources(title: widget.movie!.title, year: year);
        }
        if (hits.isNotEmpty) {
          if (site111477_proxy.is111477ProxyRunning) {
            await site111477_proxy.stop111477Proxy();
          }
          streamUrl = await site111477_proxy.start111477Proxy(hits.first.fileUrl);
          sources = Site111477Service.toStreamSources(hits);
          _current111477FileUrl = hits.first.fileUrl;
        }
      } else if (newProvider == 'webstreamr' && widget.movie?.imdbId != null) {
        final webStreamr = WebStreamrService();
        final webStreamrSources = await webStreamr.getStreams(
          imdbId: widget.movie!.imdbId!,
          isMovie: widget.movie!.mediaType == 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (webStreamrSources.isNotEmpty) {
          streamUrl = webStreamrSources.first.url;
          sources = webStreamrSources;
        }
      } else if (newProvider == 'videasy' && widget.movie != null) {
        final ve = VideasyExtractor(onLog: (m) => debugPrint(m));
        final result = await ve.extract(
          tmdbId: widget.movie!.id.toString(),
          isMovie: widget.movie!.mediaType == 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (result != null && result.url.isNotEmpty) {
          streamUrl = result.url;
          headers = result.headers;
          sources = result.sources;
        }
      } else if (newProvider == 'vidsrc' && widget.movie != null) {
        final ve = VidsrcExtractor();
        final result = await ve.extract(
          tmdbId: widget.movie!.id.toString(),
          isMovie: widget.movie!.mediaType == 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (result != null && result.url.isNotEmpty) {
          streamUrl = result.url;
          headers = result.headers;
          sources = result.sources;
        }
      } else if (newProvider.startsWith('nuvio:') && widget.movie != null) {
        final scraperId = newProvider.substring(6);
        final results = await NuvioService.instance.runOneScraper(
          scraperId: scraperId,
          tmdbId: widget.movie!.id.toString(),
          type: widget.movie!.mediaType == 'tv' ? 'tv' : 'movie',
          season: widget.selectedSeason,
          episode: widget.selectedEpisode,
        );
        if (results.isNotEmpty) {
          final first = results.first;
          streamUrl = first.url;
          headers = first.headers.isEmpty ? null : first.headers;
          sources = results.map((r) => StreamSource(
                url: r.url,
                title: r.title.isNotEmpty ? r.title : r.name,
                type: r.url.toLowerCase().contains('.m3u8')
                    ? 'hls'
                    : r.url.toLowerCase().contains('.mpd')
                        ? 'dash'
                        : 'mp4',
                headers: r.headers.isEmpty ? null : r.headers,
              )).toList();
        }
      } else if (provider['movie'] != null && provider['tv'] != null) {
        final String providerUrl;
        if (widget.movie!.mediaType == 'tv') {
          providerUrl = provider['tv'](
            widget.movie!.id.toString(),
            widget.selectedSeason,
            widget.selectedEpisode,
          );
        } else {
          providerUrl = provider['movie'](widget.movie!.id.toString());
        }
        
        final extractor = StreamExtractor();
        final result = await extractor.extract(providerUrl);
        if (result != null && result.url.isNotEmpty) {
          streamUrl = result.url;
          headers = result.headers;
          sources = result.sources;
        }
      }
      
      if (streamUrl != null && streamUrl.isNotEmpty) {
        // Reset any stale mpv referrer set by the previous provider/quality
        // selection — then re-apply from the new headers if present.
        if (_player.platform is NativePlayer) {
          final ref = headers?['Referer'] ?? headers?['referer'] ?? '';
          await (_player.platform as NativePlayer).setProperty('referrer', ref);
        }
        await _player.open(
          Media(streamUrl, httpHeaders: headers),
        );
        
        if (currentPos.inSeconds > 0) {
          await _player.seek(currentPos);
        }
        _detectHlsQualities(streamUrl, headers);
        
        setState(() {
          _currentProvider = newProvider;
          _currentSources = sources;
          _currentUrl = streamUrl;
          _currentFallbackSourceIndex = 0; // Reset index on manual switch
          _hasError = false;
          _errorMessage = '';
        });
        
        if (mounted) {
          messenger.showSnackBar(SnackBar(
            content: Text('Switched to ${provider['name']}'),
            duration: const Duration(seconds: 2),
          ));
        }
      } else {
        if (mounted) {
          messenger.showSnackBar(SnackBar(
            content: Text('Failed to extract from ${provider['name']}'),
            duration: const Duration(seconds: 2),
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Error switching provider: $e'),
          duration: const Duration(seconds: 2),
        ));
      }
    } finally {
      if (mounted) {
        setState(() => _isSwitchingProvider = false);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  UI AUTO-HIDE
  // ─────────────────────────────────────────────────────────────────────────

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (!_isPlayingNotifier.value) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_disposed) setState(() => _showControls = false);
    });
  }

  void _onMouseMove() {
    if (!_showControls) setState(() => _showControls = true);
    _startHideTimer();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  FULLSCREEN
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _toggleFullscreen() async {
    final isFull = await windowManager.isFullScreen();
    if (!isFull && await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }
    await windowManager.setFullScreen(!isFull);
    if (mounted) setState(() => _isFullscreen = !isFull);
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  KEYBOARD SHORTCUTS
  // ─────────────────────────────────────────────────────────────────────────

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    _onMouseMove();

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.space) {
      _player.playOrPause();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final delta = HardwareKeyboard.instance.isShiftPressed
          ? const Duration(seconds: -30)
          : const Duration(seconds: -10);
      var newPos = _positionNotifier.value + delta;
      if (newPos < Duration.zero) newPos = Duration.zero;
      if (newPos > _durationNotifier.value) newPos = _durationNotifier.value;
      _player.seek(newPos);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      final delta = HardwareKeyboard.instance.isShiftPressed
          ? const Duration(seconds: 30)
          : const Duration(seconds: 10);
      var newPos = _positionNotifier.value + delta;
      if (newPos < Duration.zero) newPos = Duration.zero;
      if (newPos > _durationNotifier.value) newPos = _durationNotifier.value;
      _player.seek(newPos);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _player.setVolume((_volumeNotifier.value + 5).clamp(0, 150));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _player.setVolume((_volumeNotifier.value - 5).clamp(0, 150));
    } else if (key == LogicalKeyboardKey.keyM) {
      _player.setVolume(_volumeNotifier.value > 0 ? 0.0 : 100.0);
    } else if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape) {
      windowManager.setFullScreen(false);
      if (mounted) setState(() => _isFullscreen = false);
    } else if (key == LogicalKeyboardKey.keyL) {
      _toggleLoop();
    } else {
      return false;
    }
    return true;
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  ASPECT RATIO CYCLE
  // ─────────────────────────────────────────────────────────────────────────

  /// Short label shown on the pill button for the current fit mode.
  String get _videoFitLabel => switch (_videoFit) {
        BoxFit.contain => 'FIT',
        BoxFit.cover   => 'CROP',
        BoxFit.fill    => 'FILL',
        _              => 'FIT',
      };

  void _cycleAspectRatio() {
    setState(() {
      if (_videoFit == BoxFit.contain) {
        _videoFit = BoxFit.cover;
      } else if (_videoFit == BoxFit.cover) {
        _videoFit = BoxFit.fill;
      } else {
        _videoFit = BoxFit.contain;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Aspect Ratio: $_videoFitLabel'),
        duration: const Duration(seconds: 1)));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
        data: ThemeData.dark(),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _onMouseMove(),
            cursor: _showControls
                ? SystemMouseCursors.basic
                : SystemMouseCursors.none,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Video ────────────────────────────────────────────────
                Video(
                  controller: _controller,
                  controls: NoVideoControls,
                  fit: _videoFit,
                  fill: Colors.black,
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                ),

                // ── Custom subtitle overlay ──────────────────────────────
                // Auto-scales relative to the rendered window height so
                // the text stays readable in normal mode, fullscreen, AND
                // shrinks proportionally when in PiP (480x270).
                // Custom subtitle overlay — hidden when mpv natively handles
                // ASS/SSA or image-based subtitles (they render on the video frame instead).
                if (!_isNativeSubtitle)
                  StreamBuilder<List<String>>(
                    stream: _player.stream.subtitle,
                    initialData: _player.state.subtitle,
                    builder: (context, snap) {
                      final lines = snap.data ?? [];
                      final text = lines.where((l) => l.trim().isNotEmpty).join('\n');
                      if (text.isEmpty) return const SizedBox.shrink();
                      const refHeight = 720.0;
                      final winH = MediaQuery.of(context).size.height;
                      final scale = (winH / refHeight).clamp(0.35, 1.0);
                      final hSidePad = 24.0 * scale;
                      return Positioned(
                        left: hSidePad,
                        right: hSidePad,
                        bottom: _subtitleBottomPadding * scale,
                        child: IgnorePointer(
                          child: Text(
                            text,
                            style: _buildSubtitleTextStyle(scale: scale),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),

                // ── Controls Overlay ─────────────────────────────────────
                // Hidden entirely while PiP is active — replaced by the
                // floating revert button below.
                if (!_isPipMode)
                  AnimatedOpacity(
                    opacity: _showControls ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    child: IgnorePointer(
                      ignoring: !_showControls,
                      child: _buildControlsOverlay(),
                    ),
                  ),

                // ── PiP revert button (hover-only) ───────────────────────
                if (_isPipMode) _buildPipRevertOverlay(),

                // ── Embedded Error Overlay ───────────────────────────────
                if (_hasError) _buildEmbeddedError(),
              ],
            ),
          ),
        ),
    );
  }

  /// Floating revert button shown only while desktop PiP is active.
  /// Transparent hover region across the whole window; the button itself
  /// fades in only when the cursor is over the PiP, so the picture stays
  /// clean otherwise. Click exits PiP and restores the window chrome.
  Widget _buildPipRevertOverlay() {
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        if (mounted && !_pipHover) setState(() => _pipHover = true);
      },
      onExit: (_) {
        if (mounted && _pipHover) setState(() => _pipHover = false);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Full-window drag handle so the user can click+drag the
          // frameless PiP window around the desktop. DragToMoveArea
          // listens for primary-button drags and forwards them to the
          // OS via window_manager.
          const Positioned.fill(
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: AnimatedOpacity(
              opacity: _pipHover ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_pipHover,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () async {
                      await PipService.instance.leave();
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18),
                          width: 0.8,
                        ),
                      ),
                      child: const Icon(
                        Icons.picture_in_picture_alt_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmbeddedError() {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
            const SizedBox(height: 20),
            const Text(
              'Playback Failed',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60),
              child: Text(
                _errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassPillButton(
                  text: 'Retry',
                  onTap: _initPlayback,
                ),
                if (_currentProvider == 'arabic' && _currentSources != null && _currentSources!.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  GlassPillButton(
                    text: 'Switch Source',
                    onTap: _showSourcesMenu,
                  ),
                ],
                const SizedBox(width: 16),
                GlassPillButton(
                  text: 'Switch Provider',
                  onTap: _showProviderMenu,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    return Stack(children: [
      // ── Gradient vignettes ─────────────────────────────────────────────
      const Positioned(
          top: 0, left: 0, right: 0,
          child: _OverlayGradient(isTop: true)),
      const Positioned(
          bottom: 0, left: 0, right: 0,
          child: _OverlayGradient(isTop: false)),

      // ── TOP BAR ────────────────────────────────────────────────────────
      Positioned(
        top: 0, left: 0, right: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            GlassIconButton(
              icon: Icons.close_rounded,
              onPressed: () async {
                // Exit fullscreen if currently fullscreen
                if (_isFullscreen) {
                  await windowManager.setFullScreen(false);
                  setState(() => _isFullscreen = false);
                }
                _saveWatchHistory();
                if (mounted) Navigator.of(context).pop(_positionNotifier.value);
              },
              size: 38, iconSize: 18,
            ),
            const SizedBox(width: 10),
            // Title pill
            Expanded(
              child: _Glass(
                radius: 20,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                child: Text(
                  widget.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // HW decode mode badge
            GlassPillButton(
              text: _hwDecMode.label,
              onTap: _cycleHwDec,
              accent: _hwDecMode.accent,
            ),
            const SizedBox(width: 6),
            GlassIconButton(
              icon: Icons.music_note_outlined,
              onPressed: _showAudioMenu,
            ),
            const SizedBox(width: 6),
            GlassIconButton(
              icon: Icons.subtitles_outlined,
              onPressed: _showSubtitlesMenu,
            ),
            // Quality selector — only when the playing stream is a master
            // HLS playlist with 2+ variants.
            ValueListenableBuilder<List<HlsQuality>?>(
              valueListenable: _hlsQualitiesNotifier,
              builder: (ctx, qs, _) {
                if (qs == null || qs.length < 2) return const SizedBox.shrink();
                return Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 6),
                  GlassIconButton(
                    icon: Icons.video_settings_outlined,
                    onPressed: _showQualityMenu,
                  ),
                ]);
              },
            ),
            // Show sources button for providers with multiple sources
            if (_currentSources != null && _currentSources!.length > 1) ...[
              const SizedBox(width: 8),
              GlassIconButton(
                icon: Icons.video_library_outlined,
                onPressed: _showSourcesMenu,
              ),
            ],
          ]),
        ),
      ),

      // ── CENTER PLAY/PAUSE ──────────────────────────────────────────────
      Center(
        child: ValueListenableBuilder<bool>(
          valueListenable: _isBufferingNotifier,
          builder: (context, buffering, _) =>
              ValueListenableBuilder<bool>(
            valueListenable: _isPlayingNotifier,
            builder: (context, playing, _) => _GlassPlayPause(
              isPlaying: playing,
              isBuffering: buffering,
              onPressed: () {
                _player.playOrPause();
                _onMouseMove();
              },
            ),
          ),
        ),
      ),

      // ── SKIP SEGMENT OVERLAY (IntroDB) ─────────────────────────────────
      if (_activeSkipLabel != null && !_skipDismissed)
        Positioned(
          bottom: _showNextEpButton ? 155 : 100,
          right: 24,
          child: Material(
            color: Colors.transparent,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              InkWell(
                onTap: _performSkip,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      _activeSkipLabel!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.skip_next_rounded,
                        color: Colors.white, size: 20),
                  ]),
                ),
              ),
            ]),
          ),
        ),

      // ── NEXT EPISODE OVERLAY ──────────────────────────────────────────
      if (_showNextEpButton)
        Positioned(
          bottom: 100,
          right: 24,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isLoadingNextEp ? null : _nextEpisode,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_isLoadingNextEp)
                    const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                    )
                  else
                    const Text(
                      'Next Episode',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 20),
                ]),
              ),
            ),
          ),
        ),

      // ── BOTTOM CONTROLS ────────────────────────────────────────────────
      Positioned(
        bottom: 0, left: 0, right: 0,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // ── Icon row ───────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Left: speed / loop
                Row(children: [
                  GlassIconButton(
                    icon: Icons.speed_outlined,
                    onPressed: () => showSpeedMenu(
                        context, _player.state.rate,
                        (s) => _player.setRate(s)),
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: _loopEnabled
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    onPressed: _toggleLoop,
                    active: _loopEnabled,
                  ),
                ]),

                // Center: volume
                Row(children: [
                  ValueListenableBuilder<double>(
                    valueListenable: _volumeNotifier,
                    builder: (context, vol, _) => GlassIconButton(
                      icon: vol == 0
                          ? Icons.volume_off_rounded
                          : vol < 50
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                      onPressed: () => _player
                          .setVolume(vol > 0 ? 0.0 : 100.0),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 90,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _volumeNotifier,
                      builder: (context, vol, _) => SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 2,
                          thumbShape:
                              const RoundSliderThumbShape(
                                  enabledThumbRadius: 5.5),
                          overlayShape:
                              const RoundSliderOverlayShape(
                                  overlayRadius: 10),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Focus(
                          canRequestFocus: false,
                          descendantsAreFocusable: false,
                          child: Slider(
                            value: vol,
                            min: 0, max: 150,
                            onChanged: (v) => _player.setVolume(v),
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),

                // Right: provider switcher / copy URL / subtitle settings / aspect / fullscreen
                Row(children: [
                  // Show provider switcher only when providers are available and not using torrent/stremio
                  if (widget.providers != null && widget.providers!.isNotEmpty && 
                      widget.magnetLink == null && widget.activeProvider != 'stremio_direct') ...[
                    GlassIconButton(
                      icon: Icons.swap_horiz_rounded,
                      onPressed: _isSwitchingProvider ? () {} : _showProviderMenu,
                    ),
                    const SizedBox(width: 8),
                  ],
                  GlassIconButton(
                    icon: Icons.link_rounded,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: widget.mediaPath));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Stream URL copied to clipboard')),
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  // Aspect ratio pill – shows current mode so it's obvious
                  GlassPillButton(
                    text: _videoFitLabel,
                    onTap: _cycleAspectRatio,
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: PipService.instance.isDesktopActive
                        ? Icons.picture_in_picture_alt_rounded
                        : Icons.picture_in_picture_rounded,
                    onPressed: () async {
                      await PipService.instance.toggle();
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: _isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    onPressed: _toggleFullscreen,
                  ),
                ]),
              ],
            ),
            const SizedBox(height: 8),

            // ── Seekbar row ────────────────────────────────────────────
            Row(children: [
              // Current time
              ValueListenableBuilder<Duration>(
                valueListenable: _positionNotifier,
                builder: (context, pos, _) => SizedBox(
                  width: 56,
                  child: Text(
                    formatDuration(pos),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'monospace'),
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Seekbar
              Expanded(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: _durationNotifier,
                  builder: (context, duration, _) =>
                      ValueListenableBuilder<Duration>(
                    valueListenable: _positionNotifier,
                    builder: (context, position, _) =>
                        ValueListenableBuilder<Duration>(
                      valueListenable: _bufferedNotifier,
                      builder: (context, buffered, _) =>
                          _GlassSeekbar(
                        duration: duration,
                        position: position,
                        bufferedPosition: buffered,
                        onSeek: (t) {
                          _player.seek(t);
                          _onMouseMove();
                        },
                        onDragStart: () => _hideTimer?.cancel(),
                        onDragEnd: _startHideTimer,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),
              // Total duration
              ValueListenableBuilder<Duration>(
                valueListenable: _durationNotifier,
                builder: (context, dur, _) => SizedBox(
                  width: 56,
                  child: Text(
                    formatDuration(dur),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'monospace'),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 4),
          ]),
        ),
      ),
    ]);
  }

}

// ─────────────────────────────────────────────────────────────────────────────
//  GLASSY SEEKBAR  — hover tooltip + preview line + smooth thumb
// ─────────────────────────────────────────────────────────────────────────────

class _GlassSeekbar extends StatefulWidget {
  final Duration duration;
  final Duration position;
  final Duration bufferedPosition;
  final void Function(Duration) onSeek;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  const _GlassSeekbar({
    required this.duration,
    required this.position,
    required this.bufferedPosition,
    required this.onSeek,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  State<_GlassSeekbar> createState() => _GlassSeekbarState();
}

class _GlassSeekbarState extends State<_GlassSeekbar> {
  bool   _isDragging  = false;
  bool   _hovering    = false;
  double _dragFrac    = 0.0; // 0..1 fraction while dragging
  double _hoverFrac   = 0.0; // 0..1 fraction of cursor position
  double _trackWidth  = 0.0; // cached from LayoutBuilder

  // ── Fractions ───────────────────────────────────────────────────────────
  double get _playFrac {
    final total = widget.duration.inMilliseconds.toDouble();
    if (total <= 0) return 0;
    if (_isDragging) return _dragFrac;
    return (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  double get _bufFrac {
    final total = widget.duration.inMilliseconds.toDouble();
    if (total <= 0) return 0;
    return (widget.bufferedPosition.inMilliseconds / total).clamp(0.0, 1.0);
  }

  // ── Time at hover position ───────────────────────────────────────────────
  Duration get _hoverTime {
    final total = widget.duration.inMilliseconds.toDouble();
    return Duration(milliseconds: (_hoverFrac * total).round());
  }

  // ── Helpers ──────────────────────────────────────────────────────────────
  double _fracFromLocal(double dx) =>
      (dx / _trackWidth).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final active = _hovering || _isDragging;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (e) => setState(() {
        _hovering  = true;
        _hoverFrac = _fracFromLocal(e.localPosition.dx);
      }),
      onHover: (e) => setState(() {
        _hoverFrac = _fracFromLocal(e.localPosition.dx);
      }),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          widget.onDragStart();
          setState(() {
            _isDragging = true;
            _dragFrac   = _fracFromLocal(d.localPosition.dx);
            _hoverFrac  = _dragFrac;
          });
        },
        onHorizontalDragUpdate: (d) => setState(() {
          _dragFrac  = _fracFromLocal(d.localPosition.dx);
          _hoverFrac = _dragFrac;
        }),
        onHorizontalDragEnd: (_) {
          final total = widget.duration.inMilliseconds.toDouble();
          widget.onSeek(Duration(milliseconds: (_dragFrac * total).round()));
          widget.onDragEnd();
          setState(() => _isDragging = false);
        },
        onTapUp: (d) {
          final total = widget.duration.inMilliseconds.toDouble();
          final frac  = _fracFromLocal(d.localPosition.dx);
          widget.onSeek(Duration(milliseconds: (frac * total).round()));
        },
        // Extra vertical hit area so the thin bar is easy to grab
        child: SizedBox(
          height: 28,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: 20,
              child: LayoutBuilder(builder: (context, constraints) {
                _trackWidth = constraints.maxWidth;

                // ── track height animates from 3 → 6 on active ────────────
                final trackH = active ? 6.0 : 3.0;
                // ── thumb radius: 0 → 7 on active, centred on playhead ────
                final thumbR = active ? 7.0 : 0.0;
                // ── playhead + hover pixel positions ─────────────────────
                final playPx  = (_playFrac  * _trackWidth).clamp(0.0, _trackWidth);
                final hoverPx = (_hoverFrac * _trackWidth).clamp(0.0, _trackWidth);

                // ── Tooltip horizontal clamp so it never overflows ─────────
                const tipW     = 72.0;
                final tipLeft  = (hoverPx - tipW / 2).clamp(0.0, _trackWidth - tipW);

                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerLeft,
                  children: [
                    // ── Background track ────────────────────────────────
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      height: trackH,
                      width: _trackWidth,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(trackH),
                      ),
                    ),

                    // ── Buffered ─────────────────────────────────────────
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      height: trackH,
                      width: (_bufFrac * _trackWidth).clamp(0.0, _trackWidth),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(trackH),
                      ),
                    ),

                    // ── Played ───────────────────────────────────────────
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      curve: Curves.easeOut,
                      height: trackH,
                      width: playPx,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(trackH),
                      ),
                    ),

                    // ── Hover preview line (ghosted, thin) ───────────────
                    if (active)
                      Positioned(
                        left: hoverPx - 1,
                        child: AnimatedOpacity(
                          opacity: active ? 0.45 : 0.0,
                          duration: const Duration(milliseconds: 120),
                          child: Container(
                            width: 1.5,
                            height: trackH + 4,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                      ),

                    // ── Playhead thumb dot ───────────────────────────────
                    Positioned(
                      left: playPx - thumbR,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOut,
                        width:  thumbR * 2,
                        height: thumbR * 2,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: active
                              ? [BoxShadow(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  blurRadius: 6,
                                )]
                              : [],
                        ),
                      ),
                    ),

                    // ── Hover tooltip: glassy pill above cursor ──────────
                    if (active && widget.duration.inMilliseconds > 0)
                      Positioned(
                        top: -38,
                        left: tipLeft,
                        child: AnimatedOpacity(
                          opacity: active ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 120),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                              child: Container(
                                width: tipW,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1E).withValues(alpha: 0.82),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.18),
                                    width: 0.6,
                                  ),
                                ),
                                child: Text(
                                  formatDuration(_hoverTime),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.visible,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'monospace',
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
