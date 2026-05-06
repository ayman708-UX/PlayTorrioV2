import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import '../../utils/language_display.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../api/subtitle_api.dart';
import '../../services/watch_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api/trakt_service.dart';
import '../../api/simkl_service.dart';
import '../../api/torrent_stream_service.dart';
import '../../api/stream_extractor.dart';
import '../../api/videasy_extractor.dart';
import '../../api/nuvio_service.dart';
import '../../api/vidsrc_extractor.dart';
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
import '../../models/movie.dart';
import '../../models/stream_source.dart';
import '../../utils/hls_master_parser.dart';
import '../player_screen.dart';
import 'utils.dart';
import 'menus.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  GLASS PRIMITIVES  (mobile — press feedback only, no hover)
// ─────────────────────────────────────────────────────────────────────────────

// ── _SolidGlass ──────────────────────────────────────────────────────────────
// Used for ALL buttons/pills. No BackdropFilter — zero extra GPU layers.
// Slightly higher base opacity (0.72) so it reads clearly on black without
// needing blur to give it body.
class _SolidGlass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final bool pressed;

  const _SolidGlass({
    required this.child,
    this.radius = 12,
    this.padding,
    this.tint,
    this.pressed = false,
  });

  @override
  Widget build(BuildContext context) {
    final base = tint ?? const Color(0xFF1C1C1E);
    final fillOpacity = pressed ? 0.88 : 0.72;
    final borderOpacity = pressed ? 0.32 : 0.18;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base.withValues(alpha: fillOpacity),
            base.withValues(alpha: fillOpacity - 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: borderOpacity),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ── _BlurGlass ───────────────────────────────────────────────────────────────
// Used ONLY for large/decorative elements (title pill, play button, tooltip,
// side indicators) — at most 2-3 on screen at once, so cost is acceptable.
class _BlurGlass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  const _BlurGlass({
    required this.child,
    this.radius = 12,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 0.8,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Glass icon button — touch-friendly 44px default, press animation.
class _GlassIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final Color? iconColor;
  final bool active;

  const _GlassIconButton({
    required this.icon,
    required this.onPressed,
    this.size = 44,
    this.iconSize = 20,
    this.iconColor,
    this.active = false,
  });

  @override
  State<_GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<_GlassIconButton> {
  bool _pressed = false;

  Color get _tint {
    if (widget.active) return const Color(0xFF6A0DAD);
    if (_pressed) return const Color(0xFF2A2A2E);
    return const Color(0xFF1C1C1E);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.86 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: _SolidGlass(                          // ← no blur
          radius: widget.size / 2,
          tint: _tint,
          pressed: _pressed,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: widget.iconColor ??
                  (widget.active
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.85)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass pill button — used for HW badge and aspect ratio label.
class _GlassPillButton extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  final Color? accent;

  const _GlassPillButton({
    required this.text,
    required this.onTap,
    this.accent,
  });

  @override
  State<_GlassPillButton> createState() => _GlassPillButtonState();
}

class _GlassPillButtonState extends State<_GlassPillButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: _SolidGlass(                          // ← no blur
          radius: 20,
          tint: widget.accent ?? const Color(0xFF1C1C1E),
          pressed: _pressed,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            widget.text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: _pressed ? 1.0 : 0.88),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Center play/pause button with press animation.
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
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.isBuffering) {
      return _BlurGlass(                             // ← blur OK, only 1 on screen
        radius: 40,
        child: const SizedBox(
          width: 80,
          height: 80,
          child: Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2.5),
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: _BlurGlass(                           // ← blur OK, only 1 on screen
          radius: 40,
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
    );
  }
}

/// Gradient vignette at top / bottom edges.
class _OverlayGradient extends StatelessWidget {
  final bool isTop;
  const _OverlayGradient({required this.isTop});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: isTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: isTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.75),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HARDWARE DECODE MODE  (3-mode cycle)
// ─────────────────────────────────────────────────────────────────────────────

enum _HwDecMode { autoSafe, autoCopy, software }

extension _HwDecModeX on _HwDecMode {
  /// The mpv property value for this mode.
  String get mpvValue => switch (this) {
        _HwDecMode.autoSafe => 'auto-safe',
        _HwDecMode.autoCopy => 'auto-copy',
        _HwDecMode.software => 'no',
      };

  /// Short label shown on the badge pill.
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
        _HwDecMode.software => const Color(0xFF3A3A3C),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
//  MOBILE PLAYER SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class MobilePlayerScreen extends StatefulWidget {
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

  const MobilePlayerScreen({
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
  State<MobilePlayerScreen> createState() => _MobilePlayerScreenState();
}

class _MobilePlayerScreenState extends State<MobilePlayerScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── Player ──────────────────────────────────────────────────────────────
  late final Player _player;
  late final VideoController _controller;
  bool _disposed = false;
  bool _historySaved = false;
  bool _hasError = false;
  String _errorMessage = '';

  // ── UI State ─────────────────────────────────────────────────────────────
  bool _showControls = true;
  bool _isLocked = false;
  Timer? _hideTimer;
  BoxFit _videoFit = BoxFit.contain;

  // ── Resume ────────────────────────────────────────────────────────────────
  bool _hasInitialSeek = false;

  // ── Stream Subscriptions ──────────────────────────────────────────────────
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Tracks>? _tracksSub;
  bool _autoTracksAppliedForSource = false;

  // ── Value Notifiers ───────────────────────────────────────────────────────
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _bufferedNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isBufferingNotifier = ValueNotifier(false);

  // ── Gesture State ─────────────────────────────────────────────────────────
  double _volume = 50.0;       // 0–150 (mpv supports >100%)
  double _brightness = 0.5;    // 0.0..1.0 (screen brightness)
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  Timer? _indicatorHideTimer;

  // ── Double-tap ripple ─────────────────────────────────────────────────────
  late final AnimationController _rippleController;
  late final Animation<double> _rippleScale;
  late final Animation<double> _rippleOpacity;
  bool _showRipple = false;
  bool _isForward = true;
  Offset _ripplePosition = Offset.zero;

  // ── Subtitles ─────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _externalSubtitles = [];

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
  bool _isFetchingSubs = false;
  String? _selectedExternalSubUrl;
  /// Currently opened language-folder key in the subtitle picker, or null
  /// when the picker shows the folder list. Persists across menu open/close.
  String? _subsMenuFolder;

  // ── Feature State ─────────────────────────────────────────────────────────
  _HwDecMode _hwDecMode = _HwDecMode.autoSafe;
  bool _loopEnabled = false;
  double _subtitleDelay = 0.0;
  double _subtitleSize = 24.0;
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
  String? _activeSkipLabel;
  Duration? _activeSkipTarget;
  bool _skipDismissed = false;

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

    // ── Lifecycle Observer ───────────────────────────────────────────────
    WidgetsBinding.instance.addObserver(this);

    // ── System UI ────────────────────────────────────────────────────────
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Orientation is set in addPostFrameCallback below — after the
    // first frame renders — to avoid fighting the portrait lock while
    // the widget tree is still building.
    WakelockPlus.enable();

    // ── Player ───────────────────────────────────────────────────────────
    _player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        // libass disabled — Flutter renders subtitles via SubtitleViewConfiguration
        libass: false,
      ),
    );

    // androidAttachSurfaceAfterVideoParameters: false fixes a blank-screen
    // race condition on some Android devices where the surface is attached
    // before mpv has negotiated video dimensions.
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );

    // ── Ripple animation ─────────────────────────────────────────────────
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _rippleScale = Tween<double>(begin: 0.4, end: 1.6).animate(
      CurvedAnimation(parent: _rippleController, curve: Curves.easeOut),
    );
    _rippleOpacity = Tween<double>(begin: 0.55, end: 0.0).animate(
      CurvedAnimation(parent: _rippleController, curve: Curves.easeOut),
    );
    _rippleController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) setState(() => _showRipple = false);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Lock to landscape and wait for the rotation to physically
      // complete before starting heavy media work.  Starting codec
      // initialization while the surface is still rotating causes
      // BLASTBufferQueue saturation and orientation ping-pong.
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      // Let Android finish the rotation & surface resize.
      // MediaTek/Transsion devices need a longer wait — the
      // fbcNotifyBufferUX storm can last several seconds.
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;

      _loadSubtitlePrefs();
      _initPlayback();
      _startHideTimer();
      _fetchSubtitles();
      // Initialize brightness from current screen level
      ScreenBrightness().application.then((b) {
        if (mounted) setState(() => _brightness = b);
      }).catchError((_) {
        ScreenBrightness().system.then((b) {
          if (mounted) setState(() => _brightness = b);
        }).catchError((_) {});
      });
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
    _saveWatchHistory();

    // Restore screen brightness to system default
    try { ScreenBrightness().resetApplicationScreenBrightness(); } catch (_) {}

    // Don't set orientation here — _exitPlayer() already locks portrait
    // BEFORE popping.  Changing orientation during dispose while
    // media_kit's surface is being torn down causes BLASTBufferQueue
    // errors and hundreds of dropped frames.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _indicatorHideTimer?.cancel();
    _rippleController.dispose();

    _positionSub?.cancel();
    _durationSub?.cancel();
    _bufferSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();

    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _bufferedNotifier.dispose();
    _isPlayingNotifier.dispose();
    _isBufferingNotifier.dispose();
    _hlsQualitiesNotifier.dispose();

    _player.dispose();

    // Remove torrent from engine on player exit (use magnetLink for hash,
    // fall back to mediaPath which may be a stream URL).
    final torrentId = widget.magnetLink ?? widget.mediaPath;
    TorrentStreamService().removeTorrent(torrentId);

    // Tear down the 111477 proxy and delete its on-disk cache.
    if (site111477_proxy.is111477ProxyRunning) {
      // Fire-and-forget — dispose() can't be async.
      site111477_proxy.stop111477Proxy();
    }

    WakelockPlus.disable();

    super.dispose();
  }

  /// Rotate back to portrait & restore system UI BEFORE popping,
  /// so the details page never sees stale landscape dimensions.
  Future<void> _exitPlayer() async {
    _saveWatchHistory();
    // Unlock orientation so the rest of the app follows system settings.
    await SystemChrome.setPreferredOrientations([]);
    // Let the rotation finish before popping — avoids BLASTBufferQueue
    // errors from media_kit surface teardown during an active rotation.
    await Future.delayed(const Duration(milliseconds: 300));
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (mounted) Navigator.of(context).pop(_positionNotifier.value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Save local history + send scrobblePause (not stop — user may return)
      _saveWatchHistory(isBgPause: true);
    } else if (state == AppLifecycleState.resumed) {
      // Tell Trakt we're back
      _historySaved = false; // allow re-save on next exit
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
    if (_historySaved && !isBgPause) return; // prevent double stop
    _historySaved = true;
    final pos = _positionNotifier.value.inMilliseconds;
    final dur = _durationNotifier.value.inMilliseconds;

    // External progress hook (anime / arabic flows persist their own
    // per-source history). Always fire while we have a real position so
    // the resume rail picks up where we left off.
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
        // App backgrounded — pause, don't stop (user may return)
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
      for (int i = 0; i < list.length; i++) {
        final entry = jsonDecode(list[i]) as Map<String, dynamic>;
        // Match by title which contains the anime name + episode
        // The most recent entry (index 0) is the one currently playing
        if (i == 0) {
          entry['position'] = posMs;
          entry['duration'] = durMs;
          list[i] = jsonEncode(entry);
          prefs.setStringList('anime_watch_history', list);
          break;
        }
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
          final srcHeaders = source.headers ?? widget.headers;

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

          await _player.open(Media(openUrl, httpHeaders: srcHeaders));
          // Update mpv referrer for this specific source
          if (source.headers != null && _player.platform is NativePlayer) {
            final ref = source.headers!['Referer'] ?? source.headers!['referer'];
            if (ref != null) await (_player.platform as NativePlayer).setProperty('referrer', ref);
          }
          _player.setVolume(_volume);
          _detectHlsQualities(openUrl, srcHeaders);
          setState(() {
            _currentUrl = openUrl;
          });
          return; // Opened successfully (might still error out during buffering)
        } catch (e) {
          debugPrint('[Player] Source $i catch error: $e');
          _currentFallbackSourceIndex++;
        }
      }
      
      // If we finished the loop, all sources in current provider failed
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
          _player.setVolume(_volume);
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
    _errorSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();
    _autoTracksAppliedForSource = false;

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

    _durationSub = _player.stream.duration.listen((dur) {
      if (_disposed) return;
      _durationNotifier.value = dur;
      if (!_hasInitialSeek &&
          dur.inSeconds > 0 &&
          widget.startPosition != null) {
        _hasInitialSeek = true;
        // mpv 'start' property handles the initial seek natively (set in
        // _configureMpvProperties). Fire a deferred seek as a safety net in
        // case the property was ignored (e.g. live streams, non-seekable src).
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_disposed) return;
          final currentPos = _positionNotifier.value;
          // Only seek if the player didn't already land near the target
          // (i.e. the 'start' property worked).
          final target = widget.startPosition!;
          if ((currentPos - target).abs() > const Duration(seconds: 5)) {
            _player.seek(target);
          }
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Resumed from ${formatDuration(widget.startPosition!)}'),
            duration: const Duration(seconds: 2),
          ));
        }
      }
    });

    _bufferSub = _player.stream.buffer.listen((buf) {
      if (_disposed) return;
      _bufferedNotifier.value = buf;
    });

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

    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (_disposed) return;
      _isBufferingNotifier.value = buffering;
    });

    // Surface only fatal errors — transient network blips are handled by mpv
    _errorSub = _player.stream.error.listen((err) {
      if (_disposed || err.isEmpty) return;
      
      // Ignore non-fatal audio errors (video continues playing)
      if (err.contains('Error decoding audio') ||
          err.contains('Failed to initialize a decoder for codec')) {
        return;
      }
      
      debugPrint('🔴 [MobilePlayer] $err');
      
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

    _completedSub = _player.stream.completed.listen((completed) {
      if (_disposed || !completed) return;
      // Show controls when playback finishes so user can navigate away
      if (mounted) setState(() => _showControls = true);
    });

    _tracksSub = _player.stream.tracks.listen((tracks) {
      if (_disposed || _autoTracksAppliedForSource) return;
      // Only run once we have at least one real audio track to choose from.
      final hasAudio = tracks.audio.any((t) => t.id != 'no' && t.id != 'auto');
      if (!hasAudio) return;
      _autoTracksAppliedForSource = true;
      // Defer slightly so mpv has finished probing all tracks/metadata.
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
      debugPrint('[Player] track auto-select failed: $e');
    }
  }

  Future<void> _configureMpvProperties() async {
    if (_player.platform is! NativePlayer) return;
    final mpv = _player.platform as NativePlayer;

    // ── Decoding ─────────────────────────────────────────────────────────
    // auto-safe on mobile: uses MediaCodec (Android) / VideoToolbox (iOS),
    // whitelisted to formats each platform reliably supports.
    await mpv.setProperty('hwdec', _hwDecMode.mpvValue);

    // Zero-copy direct rendering — decoder writes straight to GPU texture.
    // Big win on mobile for battery + throughput on H.265/4K content.
    await mpv.setProperty('vd-lavc-dr', 'yes');

    // Auto thread count (0 = let mpv decide). On mobile 4–8 cores typical.
    await mpv.setProperty('vd-lavc-threads', '0');

    // ── Audio Codec Fallback ──────────────────────────────────────────────
    // Continue playback even if audio codec is unsupported (e.g., TrueHD).
    // User can switch to alternate audio track from the menu.
    await mpv.setProperty('ad-lavc-downmix', 'no');
    await mpv.setProperty('audio-fallback-to-null', 'yes');

    // Flutter renders subtitles — kill mpv's own OSD overlay.
    await mpv.setProperty('sub-visibility', 'no');
    await mpv.setProperty('sub-auto', 'all');

    // ── Video Sync ────────────────────────────────────────────────────────
    // On mobile we use audio sync (not display-resample).
    // display-resample requires a stable vsync signal from the display driver
    // which is unreliable on Android and drains battery unnecessarily.
    // audio sync gives smooth playback tied to the audio clock instead.
    await mpv.setProperty('video-sync', 'audio');

    // ── Adaptive Streaming (HLS/DASH) ─────────────────────────────────────
    // Always pick the highest bitrate variant in multi-quality playlists.
    await mpv.setProperty('hls-bitrate', 'max');

    // ── Network / Cache ───────────────────────────────────────────────────
    await mpv.setProperty('network-timeout', '30');
    await mpv.setProperty('tls-verify', 'no');

    final isTorrent = widget.magnetLink != null;
    if (isTorrent) {
      // Torrent engine feeds bytes from disk as pieces complete — a small
      // forward window is enough and keeps memory pressure low. We also
      // disable cache-pause so playback keeps moving when the demuxer
      // briefly drains while waiting on the next piece.
      await mpv.setProperty('cache', 'yes');
      await mpv.setProperty('cache-secs', '5');
      await mpv.setProperty('cache-pause-wait', '1');
      await mpv.setProperty('cache-pause-initial', 'no');
      await mpv.setProperty('cache-pause', 'no');
      await mpv.setProperty('demuxer-readahead-secs', '2');
      await mpv.setProperty('demuxer-max-bytes', '64MiB');
      await mpv.setProperty('demuxer-max-back-bytes', '16MiB');
      await mpv.setProperty('network-timeout', '15');
      await mpv.setProperty('force-seekable', 'yes');
      await mpv.setProperty('hr-seek', 'yes');
      await mpv.setProperty('hr-seek-framedrop', 'no');
    } else {
      // 150 MiB forward cache (less than desktop's 300 MiB — spare mobile RAM).
      await mpv.setProperty('cache', 'yes');
      await mpv.setProperty('cache-secs', '120');
      await mpv.setProperty('demuxer-max-bytes', '150MiB');
      await mpv.setProperty('demuxer-readahead-secs', '120');

      // 30 MiB back-buffer so backward seeks don't require a full rebuffer.
      await mpv.setProperty('demuxer-max-back-bytes', '30MiB');
    }

    // We supply our own URL — no yt-dlp needed.
    await mpv.setProperty('ytdl', 'no');

    // Allow volume boosting up to 150% for quiet sources.
    await mpv.setProperty('volume-max', '150');

    // ── External Audio ────────────────────────────────────────────────────
    if (widget.audioUrl != null) {
      await mpv.setProperty('audio-file', widget.audioUrl!);
    }

    // ── HTTP Headers ──────────────────────────────────────────────────────
    if (widget.headers != null) {
      final referer =
          widget.headers!['Referer'] ?? widget.headers!['referer'];
      if (referer != null) await mpv.setProperty('referrer', referer);

      final ua =
          widget.headers!['User-Agent'] ?? widget.headers!['user-agent'];
      if (ua != null) await mpv.setProperty('user-agent', ua);
    }

    // ── Resume Position ──────────────────────────────────────────────────
    // Set mpv's native 'start' property so it begins playback at the saved
    // position. This is far more reliable on Android than seeking after open,
    // because the post-open seek can be silently dropped before the demuxer
    // is fully initialised.
    if (widget.startPosition != null && !_hasInitialSeek) {
      final secs = widget.startPosition!.inMilliseconds / 1000.0;
      await mpv.setProperty('start', '+${secs.toStringAsFixed(3)}');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  HW DECODE CYCLE
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
  //  UI HIDE TIMER
  // ─────────────────────────────────────────────────────────────────────────

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (!_isPlayingNotifier.value) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_disposed) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideTimer();
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
      _showControls = !_isLocked;
    });
    if (!_isLocked) _startHideTimer();
  }

  void _toggleRotation() async {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
    }
    // Wait for the rotation to settle before triggering a rebuild.
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    // Force a rebuild so controls adjust to the new orientation.
    setState(() {});
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  GESTURE HANDLERS
  // ─────────────────────────────────────────────────────────────────────────

  void _handleDoubleTap(TapDownDetails details, bool isRight) {
    if (_isLocked) return;
    setState(() {
      _showRipple = true;
      _isForward = isRight;
      _ripplePosition = details.localPosition;
    });
    _rippleController.forward(from: 0.0);
    
    // Calculate new position and clamp to valid range
    final currentPos = _positionNotifier.value;
    final duration = _durationNotifier.value;
    final delta = isRight ? const Duration(seconds: 10) : const Duration(seconds: -10);
    var newPos = currentPos + delta;
    
    // Clamp to valid range [0, duration]
    if (newPos < Duration.zero) {
      newPos = Duration.zero;
    } else if (newPos > duration) {
      newPos = duration;
    }
    
    _player.seek(newPos);
    _startHideTimer();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double width) {
    if (_isLocked) return;

    final isRight = details.localPosition.dx > width / 2;
    // delta is inverted: drag up = positive = increase
    final delta = -details.primaryDelta! / 3;

    if (isRight) {
      _volume = (_volume + delta).clamp(0.0, 150.0);
      _player.setVolume(_volume);
      setState(() {
        _showVolumeIndicator = true;
        _showBrightnessIndicator = false;
      });
    } else {
      _brightness = (_brightness + delta / 300).clamp(0.0, 1.0);
      try {
        ScreenBrightness().setApplicationScreenBrightness(_brightness);
      } catch (_) {}
      setState(() {
        _showBrightnessIndicator = true;
        _showVolumeIndicator = false;
      });
    }

    _indicatorHideTimer?.cancel();
    _indicatorHideTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() {
          _showVolumeIndicator = false;
          _showBrightnessIndicator = false;
        });
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  ASPECT RATIO
  // ─────────────────────────────────────────────────────────────────────────

  String get _videoFitLabel => switch (_videoFit) {
        BoxFit.contain => 'FIT',
        BoxFit.cover => 'CROP',
        BoxFit.fill => 'FILL',
        _ => 'FIT',
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
  //  SUBTITLES
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
      // Many subtitle CDNs (megacloud, vid-cdn, etc.) gate on a browser UA
      // and the embed-host Referer (NOT the sub URL's own host). Prefer the
      // referer/origin the extractor passed through; otherwise fall back to
      // the sub URL's own origin.
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
      _player.setSubtitleTrack(SubtitleTrack.uri(
        uri,
        title: s['display'],
        language: s['language'],
      ));
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

  /// Subtitle auto-pick was removed (the user explicitly disabled the
  /// preferred-subtitle setting). Kept as a no-op so existing call sites
  /// don't have to be re-plumbed.
  Future<void> _maybeAutoPickExternalSubtitle() async {}

  void _showSubtitlesMenu() {
    String searchQuery = '';
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          final current = _player.state.track.subtitle;
          final inFolder = _subsMenuFolder != null;

          // Embedded tracks (only at root view).
          final embedded =
              _player.state.tracks.subtitle.where((t) {
            final isExternal = t.id.startsWith('http');
            final isKnownExternal = _externalSubtitles
                .any((s) => s['display'] == t.title && s['language'] == t.language);
            final matchesSearch = searchQuery.isEmpty ||
                (t.title?.toLowerCase().contains(searchQuery.toLowerCase()) ??
                    false) ||
                (t.language?.toLowerCase().contains(searchQuery.toLowerCase()) ??
                    false);
            return t.id != 'no' && !isExternal && !isKnownExternal && matchesSearch;
          }).toList();

          // Group online subs by language.
          final Map<String, List<Map<String, dynamic>>> byLang = {};
          for (final s in _externalSubtitles) {
            final key = languageGroupKey(s['language'] as String?);
            byLang.putIfAbsent(key, () => []).add(s);
          }
          final folderKeys = byLang.keys.toList()..sort(compareLanguageCodes);

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
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  ),
                  onChanged: (v) => setModalState(() => searchQuery = v),
                ),
              ),
              if (_isFetchingSubs)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                          ? const Icon(Icons.check, color: Color(0xFF7C3AED))
                          : null,
                      onTap: () {
                        _selectedExternalSubUrl = null;
                        _player.setSubtitleTrack(SubtitleTrack.no());
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
                          _selectedExternalSubUrl = null;
                          _player.setSubtitleTrack(SubtitleTrack.data(
                              content, title: name, language: 'und'));
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
                            _selectedExternalSubUrl = null;
                            _player.setSubtitleTrack(t);
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
                        final hasSelected = list.any(
                            (s) => s['url'] == _selectedExternalSubUrl);
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
                            _selectedExternalSubUrl = s['url'];
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
      builder: (context) {
        final screenW = MediaQuery.of(context).size.width;
        final dialogW = (screenW * 0.9).clamp(280.0, 420.0);
        return StatefulBuilder(builder: (context, setDialog) {
          return Dialog(
            backgroundColor: const Color(0xFF121212),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: dialogW, maxHeight: MediaQuery.of(context).size.height * 0.8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(children: [
                    const Icon(Icons.tune_rounded, color: Color(0xFF7C3AED), size: 20),
                    const SizedBox(width: 8),
                    const Text('Subtitle Settings', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        SettingsService().setSubSize(_subtitleSize);
                        SettingsService().setSubBgOpacity(_subtitleBgOpacity);
                        SettingsService().setSubBottomPadding(_subtitleBottomPadding);
                        Navigator.pop(context);
                      },
                      child: const Icon(Icons.close, color: Colors.white38, size: 20),
                    ),
                  ]),
                ),
                const Divider(color: Colors.white10, height: 1),
                // Content
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Size
                      _subSlider('Size', _subtitleSize, 10, 50, '${_subtitleSize.toInt()}', (v) {
                        setDialog(() => _subtitleSize = v); setState(() {});
                      }),
                      const SizedBox(height: 8),

                      // Delay
                      Row(children: [
                        const Text('Delay', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.remove, color: Colors.white70, size: 20),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final v = _subtitleDelay - 0.1;
                            setDialog(() => _subtitleDelay = double.parse(v.toStringAsFixed(1)));
                            if (_player.platform is NativePlayer) {
                              (_player.platform as NativePlayer).setProperty('sub-delay', _subtitleDelay.toString());
                            }
                          },
                        ),
                        SizedBox(
                          width: 54,
                          child: Text('${_subtitleDelay.toStringAsFixed(1)}s',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add, color: Colors.white70, size: 20),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final v = _subtitleDelay + 0.1;
                            setDialog(() => _subtitleDelay = double.parse(v.toStringAsFixed(1)));
                            if (_player.platform is NativePlayer) {
                              (_player.platform as NativePlayer).setProperty('sub-delay', _subtitleDelay.toString());
                            }
                          },
                        ),
                      ]),
                      const SizedBox(height: 12),

                      // Text Color
                      const Text('Text Color', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 10, runSpacing: 10, children: colorOptions.entries.map((e) {
                        final selected = _subtitleColor.toARGB32() == e.value.toARGB32();
                        return GestureDetector(
                          onTap: () {
                            setDialog(() => _subtitleColor = e.value);
                            setState(() {});
                            SettingsService().setSubColor(e.value.toARGB32());
                          },
                          child: Container(
                            width: 34, height: 34,
                            decoration: BoxDecoration(
                              color: e.value,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected ? const Color(0xFF7C3AED) : Colors.white24,
                                width: selected ? 3 : 1,
                              ),
                            ),
                            child: selected ? const Icon(Icons.check, size: 16, color: Color(0xFF7C3AED)) : null,
                          ),
                        );
                      }).toList()),
                      const SizedBox(height: 16),

                      // BG Opacity
                      _subSlider('BG Opacity', _subtitleBgOpacity, 0.0, 1.0, '${(_subtitleBgOpacity * 100).toInt()}%', (v) {
                        setDialog(() => _subtitleBgOpacity = v); setState(() {});
                      }),
                      const SizedBox(height: 8),

                      // Position
                      _subSlider('Position', _subtitleBottomPadding, 0, 120, '${_subtitleBottomPadding.toInt()}', (v) {
                        setDialog(() => _subtitleBottomPadding = v); setState(() {});
                      }),
                      const SizedBox(height: 8),

                      // Bold
                      Row(children: [
                        const Text('Bold', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const Spacer(),
                        Switch(
                          value: _subtitleBold,
                          activeThumbColor: const Color(0xFF7C3AED),
                          onChanged: (v) { setDialog(() => _subtitleBold = v); setState(() {}); SettingsService().setSubBold(v); },
                        ),
                      ]),
                      const SizedBox(height: 8),

                      // Font
                      const Text('Font', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, children: fonts.map((f) {
                        final selected = _subtitleFont == f;
                        return GestureDetector(
                          onTap: () { setDialog(() => _subtitleFont = f); setState(() {}); SettingsService().setSubFont(f); },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: selected ? const Color(0xFF7C3AED).withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: selected ? const Color(0xFF7C3AED) : Colors.white12),
                            ),
                            child: Text(f, style: TextStyle(color: selected ? Colors.white : Colors.white54, fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
                          ),
                        );
                      }).toList()),
                    ]),
                  ),
                ),
              ]),
            ),
          );
        });
      },
    );
  }

  Widget _subSlider(String label, double value, double min, double max, String trailing, ValueChanged<double> onChanged) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const Spacer(),
        Text(trailing, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
      SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          activeTrackColor: const Color(0xFF7C3AED),
          inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
          thumbColor: const Color(0xFF7C3AED),
        ),
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
    ]);
  }

  Future<void> _loadSubtitlePrefs() async {
    final s = SettingsService();
    final size = await s.getSubSize();
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

  TextStyle _buildSubtitleTextStyle() {
    final base = TextStyle(
      height: 1.4,
      fontSize: _subtitleSize,
      letterSpacing: 0.0,
      wordSpacing: 0.0,
      color: _subtitleColor,
      fontWeight: _subtitleBold ? FontWeight.bold : FontWeight.normal,
      backgroundColor: Colors.black.withValues(alpha: _subtitleBgOpacity),
      shadows: const [
        Shadow(blurRadius: 10, color: Colors.black, offset: Offset.zero),
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
  //  AUDIO MENU
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
                  title: Text(t.title ?? t.language ?? 'Track ${t.id}',
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
    // If the user just picked a variant from the same master, keep the list.
    final existing = _hlsQualitiesNotifier.value;
    if (existing != null && existing.any((q) => q.url == url)) return;

    // New stream — clear any prior quality state immediately so the gear
    // doesn't expose stale variants while the new master loads.
    _hlsMasterUrl = url;
    _hlsMasterHeaders = headers;
    _hlsQualitiesNotifier.value = null;
    fetchHlsQualities(url, headers: headers).then((qs) {
      if (_disposed) return;
      // Only apply if a newer URL didn't take over while we were fetching.
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
                        // Normal direct switch — use per-source headers if available
                        final srcHeaders = source.headers ?? widget.headers;
                        if (source.headers != null && _player.platform is NativePlayer) {
                          final ref = source.headers!['Referer'] ?? source.headers!['referer'];
                          if (ref != null) await (_player.platform as NativePlayer).setProperty('referrer', ref);
                        }
                        await _player.open(
                          Media(source.url, httpHeaders: srcHeaders),
                        );
                        setState(() {
                          _currentUrl = source.url;
                          _currentFallbackSourceIndex = 0;
                          _hasError = false;
                          _errorMessage = '';
                        });
                        _detectHlsQualities(source.url, srcHeaders);
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
  //  MISC
  // ─────────────────────────────────────────────────────────────────────────

  void _toggleLoop() {
    setState(() => _loopEnabled = !_loopEnabled);
    _player.setPlaylistMode(
        _loopEnabled ? PlaylistMode.single : PlaylistMode.none);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Loop: ${_loopEnabled ? "ON" : "OFF"}'),
        duration: const Duration(seconds: 1)));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  SKIP SEGMENTS (IntroDB)
  // ─────────────────────────────────────────────────────────────────────────

  void _updateActiveSkipSegment(Duration pos) {
    if (_introDbData == null) return;

    final posMs = pos.inMilliseconds;
    String? label;
    Duration? target;

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

    if (label != _activeSkipLabel) {
      setState(() {
        _activeSkipLabel = label;
        _activeSkipTarget = target;
        _skipDismissed = false;
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

  // ─────────────────────────────────────────────────────────────────────────
  //  NEXT EPISODE
  // ─────────────────────────────────────────────────────────────────────────

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

    // Anime / external resolver path — the caller knows how to fetch the
    // next episode and will navigate themselves. Save history first so the
    // current position isn't lost.
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
        // ── Stremio addon: re-fetch streams for next episode ──────────
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

  // ─────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        _exitPlayer();
      },
      child: Theme(
        data: ThemeData.dark(),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // ── 1. Video ─────────────────────────────────────────────────
              Video(
                controller: _controller,
                controls: NoVideoControls,
                fit: _videoFit,
                fill: Colors.black,
                subtitleViewConfiguration: const SubtitleViewConfiguration(
                  visible: false,
                ),
              ),

              // ── 1b. Custom subtitle overlay ─────────────────────────────
              StreamBuilder<List<String>>(
                stream: _player.stream.subtitle,
                initialData: _player.state.subtitle,
                builder: (context, snap) {
                  final lines = snap.data ?? [];
                  final text = lines.where((l) => l.trim().isNotEmpty).join('\n');
                  if (text.isEmpty) return const SizedBox.shrink();
                  return Positioned(
                    left: 24, right: 24,
                    bottom: _subtitleBottomPadding,
                    child: IgnorePointer(
                      child: Text(
                        text,
                        style: _buildSubtitleTextStyle(),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                },
              ),

              // ── 2. Gesture layer ─────────────────────────────────────────
              LayoutBuilder(builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                  onDoubleTapDown: (d) {
                    _handleDoubleTap(
                        d, d.localPosition.dx > constraints.maxWidth / 2);
                  },
                  onVerticalDragUpdate: (d) =>
                      _onVerticalDragUpdate(d, constraints.maxWidth),
                  onLongPressStart: (_) {
                    if (!_isLocked) _player.setRate(2.0);
                  },
                  onLongPressEnd: (_) {
                    if (!_isLocked) _player.setRate(1.0);
                  },
                  child: Container(color: Colors.transparent),
                );
              }),

              // ── 3. Double-tap ripple ──────────────────────────────────────
              if (_showRipple)
                Positioned(
                  left: _isForward
                      ? null
                      : _ripplePosition.dx - 50,
                  right: _isForward
                      ? (MediaQuery.of(context).size.width -
                              _ripplePosition.dx) -
                          50
                      : null,
                  top: _ripplePosition.dy - 50,
                  child: IgnorePointer(
                    child: FadeTransition(
                      opacity: _rippleOpacity,
                      child: ScaleTransition(
                        scale: _rippleScale,
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              _isForward ? '+10s' : '-10s',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // ── 4. Controls overlay ───────────────────────────────────────
              AnimatedOpacity(
                opacity: (_showControls && !_isLocked) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !(_showControls && !_isLocked),
                  child: _buildControlsOverlay(),
                ),
              ),

              // ── 5. Lock button (always visible when locked + controls shown)
              if (_isLocked)
                Positioned(
                  bottom:
                      MediaQuery.of(context).padding.bottom + 72,
                  left: 12,
                  child: AnimatedOpacity(
                    opacity: _showControls ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: _GlassIconButton(
                      icon: Icons.lock_rounded,
                      onPressed: _toggleLock,
                      iconColor: Colors.amber,
                    ),
                  ),
                ),

              // ── 6. Volume indicator ───────────────────────────────────────
              if (_showVolumeIndicator)
                Positioned(
                  right: 20,
                  top: 0, bottom: 0,
                  child: Center(
                      child: _SideIndicator(
                          icon: Icons.volume_up_rounded,
                          value: _volume / 150.0)),
                ),

              // ── 7. Brightness indicator ───────────────────────────────────
              if (_showBrightnessIndicator)
                Positioned(
                  left: 20,
                  top: 0, bottom: 0,
                  child: Center(
                      child: _SideIndicator(
                          icon: Icons.light_mode_rounded,
                          value: _brightness)),
                ),

              // ── 7.5 Skip Segment Overlay (IntroDB) ─────────────────────
              if (_activeSkipLabel != null && !_skipDismissed)
                Positioned(
                  bottom: _showNextEpButton ? 170 : 120,
                  right: 16,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _performSkip,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.skip_next_rounded,
                              color: Colors.white, size: 18),
                        ]),
                      ),
                    ),
                  ),
                ),

              // ── 8. Next Episode Overlay ──────────────────────────────
              if (_showNextEpButton)
                Positioned(
                  bottom: 120,
                  right: 16,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _isLoadingNextEp ? null : _nextEpisode,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (_isLoadingNextEp)
                            const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                            )
                          else
                            const Text(
                              'Next Episode',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_forward_rounded,
                              color: Colors.white, size: 18),
                        ]),
                      ),
                    ),
                  ),
                ),

              // ── 9. Embedded Error Overlay ───────────────────────────────
              if (_hasError) _buildEmbeddedError(),
              ],
              ),
              ),
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
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              const Text(
              'Playback Failed',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              ),
              const SizedBox(height: 8),
              Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GlassPillButton(
                    text: 'Retry',
                    onTap: _initPlayback,
                  ),
                  if (_currentProvider == 'arabic' && _currentSources != null && _currentSources!.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    _GlassPillButton(
                      text: 'Switch Source',
                      onTap: _showSourcesMenu,
                    ),
                  ],
                  const SizedBox(width: 12),
                  _GlassPillButton(
                    text: 'Switch Provider',
                    onTap: _showProviderMenu,
                  ),
                ],
              ),              ],
              ),
              ),
              );
              }

  Widget _buildControlsOverlay() {
    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final btnSize = isPortrait ? 34.0 : 40.0;
    final iconSz = isPortrait ? 16.0 : 18.0;
    final gap = isPortrait ? 4.0 : 6.0;

    return Stack(children: [
      // ── Gradients ────────────────────────────────────────────────────────
      const Positioned(
          top: 0, left: 0, right: 0,
          child: _OverlayGradient(isTop: true)),
      const Positioned(
          bottom: 0, left: 0, right: 0,
          child: _OverlayGradient(isTop: false)),

      // ── TOP BAR ──────────────────────────────────────────────────────────
      Positioned(
        top: 0, left: 0, right: 0,
        child: SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              _GlassIconButton(
                icon: Icons.arrow_back_ios_new_rounded,
                onPressed: _exitPlayer,
                size: btnSize, iconSize: iconSz,
              ),
              SizedBox(width: isPortrait ? 6 : 10),
              // Title pill
              Expanded(
                child: _BlurGlass(               // ← blur OK, only 1
                  radius: 20,
                  padding: EdgeInsets.symmetric(
                      horizontal: isPortrait ? 10 : 14, vertical: 8),
                  child: Text(
                    widget.title,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: isPortrait ? 12 : 13,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              SizedBox(width: gap),
              // HW mode badge
              if (!isPortrait)
                _GlassPillButton(
                  text: _hwDecMode.label,
                  onTap: _cycleHwDec,
                  accent: _hwDecMode.accent,
                ),
              if (!isPortrait) SizedBox(width: gap),
              _GlassIconButton(
                icon: Icons.music_note_outlined,
                onPressed: _showAudioMenu,
                size: btnSize, iconSize: iconSz,
              ),
              SizedBox(width: gap),
              _GlassIconButton(
                icon: Icons.subtitles_outlined,
                onPressed: _showSubtitlesMenu,
                size: btnSize, iconSize: iconSz,
              ),
              // Quality selector — only when the playing stream is a master
              // HLS playlist with 2+ variants.
              ValueListenableBuilder<List<HlsQuality>?>(
                valueListenable: _hlsQualitiesNotifier,
                builder: (ctx, qs, _) {
                  if (qs == null || qs.length < 2) return const SizedBox.shrink();
                  return Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: gap),
                    _GlassIconButton(
                      icon: Icons.video_settings_outlined,
                      onPressed: _showQualityMenu,
                      size: btnSize, iconSize: iconSz,
                    ),
                  ]);
                },
              ),
              // Show sources button for providers with multiple sources
              if (_currentSources != null && _currentSources!.length > 1) ...[
                SizedBox(width: gap),
                _GlassIconButton(
                  icon: Icons.video_library_outlined,
                  onPressed: _showSourcesMenu,
                  size: btnSize, iconSize: iconSz,
                ),
              ],
            ]),
          ),
        ),
      ),

      // ── CENTER PLAY/PAUSE ─────────────────────────────────────────────────
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
                playing ? _player.pause() : _player.play();
                _startHideTimer();
              },
            ),
          ),
        ),
      ),

      // ── BOTTOM SECTION ────────────────────────────────────────────────────
      Positioned(
        bottom: 0, left: 0, right: 0,
        child: SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child:
                Column(mainAxisSize: MainAxisSize.min, children: [
              // ── Icon row ─────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Left: lock / speed / loop (+ HW badge in portrait)
                  Row(children: [
                    _GlassIconButton(
                      icon: _isLocked
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      onPressed: _toggleLock,
                      active: _isLocked,
                      size: btnSize, iconSize: iconSz,
                    ),
                    SizedBox(width: gap),
                    _GlassIconButton(
                      icon: Icons.screen_rotation_rounded,
                      onPressed: _toggleRotation,
                      size: btnSize, iconSize: iconSz,
                    ),
                    SizedBox(width: gap),
                    _GlassIconButton(
                      icon: Icons.speed_outlined,
                      onPressed: () => showSpeedMenu(
                          context,
                          _player.state.rate,
                          (s) => _player.setRate(s)),
                      size: btnSize, iconSize: iconSz,
                    ),
                    SizedBox(width: gap),
                    _GlassIconButton(
                      icon: _loopEnabled
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                      onPressed: _toggleLoop,
                      active: _loopEnabled,
                      size: btnSize, iconSize: iconSz,
                    ),
                    if (isPortrait) ...[
                      SizedBox(width: gap),
                      _GlassPillButton(
                        text: _hwDecMode.label,
                        onTap: _cycleHwDec,
                        accent: _hwDecMode.accent,
                      ),
                    ],
                  ]),

                  // Right: copy URL / subtitle settings / aspect ratio / provider switcher
                  Row(children: [
                    // Show provider switcher only when providers are available and not using torrent/stremio
                    if (widget.providers != null && widget.providers!.isNotEmpty && 
                        widget.magnetLink == null && widget.activeProvider != 'stremio_direct') ...[
                      _GlassIconButton(
                        icon: Icons.swap_horiz_rounded,
                        onPressed: _isSwitchingProvider ? () {} : _showProviderMenu,
                        size: btnSize, iconSize: iconSz,
                      ),
                      SizedBox(width: gap),
                    ],
                    _GlassIconButton(
                      icon: Icons.link_rounded,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: widget.mediaPath));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Stream URL copied to clipboard')),
                          );
                        }
                      },
                      size: btnSize, iconSize: iconSz,
                    ),
                    SizedBox(width: gap),
                    // Aspect ratio pill — shows current mode
                    _GlassPillButton(
                      text: _videoFitLabel,
                      onTap: _cycleAspectRatio,
                    ),
                  ]),
                ],
              ),
              const SizedBox(height: 8),

              // ── Seekbar row ───────────────────────────────────────────
              Row(children: [
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
                            _MobileSeekbar(
                          duration: duration,
                          position: position,
                          bufferedPosition: buffered,
                          onSeek: (t) {
                            _player.seek(t);
                            _startHideTimer();
                          },
                          onDragStart: () => _hideTimer?.cancel(),
                          onDragEnd: _startHideTimer,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
            ]),
          ),
        ),
      ),
    ]);
  }

}

// ─────────────────────────────────────────────────────────────────────────────
//  MOBILE SEEKBAR  — touch-friendly, no tooltip (no hover on mobile)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileSeekbar extends StatefulWidget {
  final Duration duration;
  final Duration position;
  final Duration bufferedPosition;
  final void Function(Duration) onSeek;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  const _MobileSeekbar({
    required this.duration,
    required this.position,
    required this.bufferedPosition,
    required this.onSeek,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  State<_MobileSeekbar> createState() => _MobileSeekbarState();
}

class _MobileSeekbarState extends State<_MobileSeekbar> {
  bool _isDragging = false;
  double _dragFrac = 0.0;
  double _trackWidth = 0.0;

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

  Duration get _dragTime {
    final total = widget.duration.inMilliseconds.toDouble();
    return Duration(milliseconds: (_dragFrac * total).round());
  }

  double _fracFromLocal(double dx) =>
      (dx / _trackWidth).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (d) {
        widget.onDragStart();
        setState(() {
          _isDragging = true;
          _dragFrac = _fracFromLocal(d.localPosition.dx);
        });
      },
      onHorizontalDragUpdate: (d) => setState(() {
        _dragFrac = _fracFromLocal(d.localPosition.dx);
      }),
      onHorizontalDragEnd: (_) {
        final total = widget.duration.inMilliseconds.toDouble();
        widget.onSeek(
            Duration(milliseconds: (_dragFrac * total).round()));
        widget.onDragEnd();
        setState(() => _isDragging = false);
      },
      onTapUp: (d) {
        final total = widget.duration.inMilliseconds.toDouble();
        widget.onSeek(Duration(
            milliseconds:
                (_fracFromLocal(d.localPosition.dx) * total).round()));
      },
      // 32px tall hit area — much easier to grab on touch
      child: SizedBox(
        height: 32,
        child: Align(
          alignment: Alignment.center,
          child: LayoutBuilder(builder: (context, constraints) {
            _trackWidth = constraints.maxWidth;

            final trackH = _isDragging ? 6.0 : 3.5;
            final thumbR = _isDragging ? 8.0 : 5.5;
            final playPx =
                (_playFrac * _trackWidth).clamp(0.0, _trackWidth);

            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                // Background
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  height: trackH,
                  width: _trackWidth,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.20),
                    borderRadius: BorderRadius.circular(trackH),
                  ),
                ),
                // Buffered
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: trackH,
                  width: (_bufFrac * _trackWidth).clamp(0.0, _trackWidth),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.32),
                    borderRadius: BorderRadius.circular(trackH),
                  ),
                ),
                // Played
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
                // Thumb dot
                Positioned(
                  left: playPx - thumbR,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 130),
                    curve: Curves.easeOut,
                    width: thumbR * 2,
                    height: thumbR * 2,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: _isDragging
                          ? [
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.35),
                                blurRadius: 8,
                              )
                            ]
                          : [],
                    ),
                  ),
                ),
                // Drag time label — floats above thumb while dragging
                if (_isDragging &&
                    widget.duration.inMilliseconds > 0)
                  Positioned(
                    left: (playPx - 36).clamp(
                        0.0, _trackWidth - 72),
                    top: -34,
                    child: _BlurGlass(           // ← blur OK, only while dragging
                      radius: 8,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: SizedBox(
                        width: 56,
                        child: Text(
                          formatDuration(_dragTime),
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
              ],
            );
          }),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SIDE INDICATOR  (volume / brightness vertical pill)
// ─────────────────────────────────────────────────────────────────────────────

/// Replaces VolumeBrightnessIndicator from shared_widgets — self-contained.
class _SideIndicator extends StatelessWidget {
  final IconData icon;
  final double value; // 0.0 – 1.0

  const _SideIndicator({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return _BlurGlass(                               // ← blur OK, shown 1 at a time
      radius: 20,
      child: SizedBox(
        width: 44,
        height: 160,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(height: 6),
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                child: RotatedBox(
                  quarterTurns: -1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: value.clamp(0.0, 1.0),
                      backgroundColor: Colors.white24,
                      color: Colors.white,
                      minHeight: 4,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${(value * 100).round()}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}