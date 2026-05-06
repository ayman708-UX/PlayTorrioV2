import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shimmer/shimmer.dart';
import '../api/tmdb_api.dart';
import '../api/bestsimilar_scraper.dart';
import '../api/settings_service.dart';
import '../api/stremio_service.dart';
import '../api/stream_extractor.dart';
import '../api/stream_providers.dart';
import '../api/amri_extractor.dart';
import '../api/torrent_stream_service.dart';
import '../api/debrid_api.dart';
import '../api/trakt_service.dart';
import '../api/simkl_service.dart';
import '../api/webstreamr_service.dart';
import '../services/watch_history_service.dart';
import '../services/my_list_service.dart';
import '../models/movie.dart';
import '../utils/app_theme.dart';
import 'details_screen.dart';
import 'streaming_details_screen.dart';
import 'player_screen.dart';
import 'stremio_catalog_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with AutomaticKeepAliveClientMixin {
  final TmdbApi _api = TmdbApi();
  final StremioService _stremio = StremioService();
  final PageController _heroController = PageController();
  
  late Future<List<Movie>> _trendingFuture;
  late Future<List<Movie>> _popularFuture;
  late Future<List<Movie>> _topRatedFuture;
  late Future<List<Movie>> _nowPlayingFuture;
  
  Timer? _heroTimer;
  int _heroIndex = 0;

  // Hero logo cache: movieId -> logo URL
  final Map<int, String> _heroLogos = {};

  // Stremio catalog data
  List<Map<String, dynamic>> _stremioCatalogs = [];
  final Map<String, List<Map<String, dynamic>>> _catalogItems = {};
  bool _catalogsLoaded = false;

  // Trakt personalized sections
  List<Movie> _traktRecommendations = [];
  List<Map<String, dynamic>> _traktCalendar = [];
  List<Map<String, dynamic>> _traktCalendarMovies = [];

  // Ambient backdrop colors derived from current hero poster
  Color _ambientPrimary = AppTheme.primaryColor;
  Color _ambientSecondary = AppTheme.accentColor;
  final Map<int, ({Color primary, Color secondary})> _ambientCache = {};

  // Tonight's Pick — randomized recommendation
  Movie? _tonightsPick;

  // "Because you watched ___" — randomized seed pulled from continue-watching
  // once per session, then BestSimilar.com recommendations (mapped to TMDB).
  Map<String, dynamic>? _becauseSeed; // raw history item
  Future<List<Movie>>? _becauseFuture;
  int _becausePoolSize = 0; // unique in-progress shows; controls shuffle button
  StreamSubscription<List<Map<String, dynamic>>>? _historySeedSub;

  // Mood/genre filter state
  String _selectedMood = 'mind';
  Future<List<Movie>>? _moodFuture;

  // Mood definitions (label, icon, tmdb genre IDs)
  static const List<({String id, String label, IconData icon, List<int> genres})> _moods = [
    (id: 'mind',     label: 'Mind-Bending',   icon: Icons.psychology_rounded,        genres: [878, 9648]),
    (id: 'feel',     label: 'Feel-Good',      icon: Icons.wb_sunny_rounded,          genres: [35, 10751]),
    (id: 'dark',     label: 'Dark Thrillers', icon: Icons.dark_mode_rounded,         genres: [53, 80]),
    (id: 'romance',  label: 'Romance',        icon: Icons.favorite_rounded,          genres: [10749]),
    (id: 'horror',   label: 'Horror',         icon: Icons.bedtime_rounded,           genres: [27]),
    (id: 'action',   label: 'Action',         icon: Icons.local_fire_department_rounded, genres: [28, 12]),
    (id: 'animated', label: 'Animated',       icon: Icons.brush_rounded,             genres: [16]),
    (id: 'drama',    label: 'Drama',          icon: Icons.theaters_rounded,          genres: [18]),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _trendingFuture = _api.getTrending().then((movies) {
      _fetchHeroLogos(movies.take(5).toList());
      // Pick tonight's randomized recommendation from a deeper pool
      if (movies.length > 6 && mounted) {
        final pool = movies.skip(3).toList();
        setState(() => _tonightsPick = pool[math.Random().nextInt(pool.length)]);
      }
      // Prime ambient color for the first hero
      if (movies.isNotEmpty) _extractAmbientFor(movies.first);
      return movies;
    });
    _popularFuture = _api.getPopular();
    _topRatedFuture = _api.getTopRated();
    _nowPlayingFuture = _api.getNowPlaying();
    _moodFuture = _loadMoodMovies(_selectedMood);
    
    _startHeroTimer();
    _loadStremioCatalogs();
    SettingsService.addonChangeNotifier.addListener(_onAddonsChanged);

    // Trakt auto-sync (runs once per session, no-op if not logged in)
    TraktService().fullSync();
    // Simkl auto-sync (runs once per session, no-op if not logged in)
    SimklService().fullSync();

    // Trakt personalized sections
    _loadTraktRecommendations();
    _loadTraktCalendar();
    _loadTraktCalendarMovies();

    // "Because you watched ___" — pick a random in-progress item once per
    // app session. If history isn't loaded yet, wait for the first event.
    _initBecauseYouWatched();
  }

  void _initBecauseYouWatched() {
    final svc = WatchHistoryService();
    if (!_pickBecauseSeed(svc.current)) {
      _historySeedSub = svc.historyStream.listen((items) {
        if (_pickBecauseSeed(items)) {
          _historySeedSub?.cancel();
          _historySeedSub = null;
        }
      });
    }
  }

  /// Returns true if a seed was successfully picked. Filters to in-progress
  /// items (between 2% and 90% watched) and picks one at random per session.
  bool _pickBecauseSeed(List<Map<String, dynamic>> history) {
    if (!mounted || history.isEmpty) return false;
    // Group episodes by their parent show so The Vampire Diaries doesn't get
    // picked 8 times because you watched 8 episodes of it.
    final byShow = <int, Map<String, dynamic>>{};
    for (final item in history) {
      final pos = (item['position'] as int?) ?? 0;
      final dur = (item['duration'] as int?) ?? 0;
      if (dur <= 0) continue;
      final progress = pos / dur;
      if (progress < 0.02 || progress >= 0.9) continue;
      final tmdbId = item['tmdbId'] as int?;
      if (tmdbId == null) continue;
      // Keep the most-recently-updated entry per tmdbId
      final existing = byShow[tmdbId];
      final ts = (item['updatedAt'] as int?) ?? 0;
      final existingTs = (existing?['updatedAt'] as int?) ?? -1;
      if (ts > existingTs) byShow[tmdbId] = item;
    }
    if (byShow.isEmpty) return false;
    final pool = byShow.values.toList();
    final seed = pool[math.Random().nextInt(pool.length)];
    setState(() {
      _becauseSeed = seed;
      _becausePoolSize = pool.length;
      _becauseFuture = _loadBecauseRecs(seed);
    });
    return true;
  }

  Future<List<Movie>> _loadBecauseRecs(Map<String, dynamic> seed) async {
    final title = (seed['title'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      debugPrint('[BecauseYouWatched] no title in seed');
      return const [];
    }
    final mediaType = (seed['mediaType'] as String?) ??
        (seed['season'] != null ? 'tv' : 'movie');
    final isTv = mediaType == 'tv';
    debugPrint('[BecauseYouWatched] seed="$title" isTv=$isTv');

    try {
      // 1) Autocomplete on bestsimilar; pick the closest hit (forgiving).
      final hits = await BestSimilarScraper.autocomplete(title);
      debugPrint('[BecauseYouWatched] autocomplete hits=${hits.length}');
      if (hits.isEmpty) return const [];

      final lowerTitle = title.toLowerCase();
      BSAutocompleteHit? hit;
      // Prefer same-type exact title match.
      for (final h in hits) {
        if (h.isTv == isTv && h.title.toLowerCase() == lowerTitle) {
          hit = h; break;
        }
      }
      // Then any exact title match.
      hit ??= hits.firstWhere(
        (h) => h.title.toLowerCase() == lowerTitle,
        orElse: () => hits.first,
      );
      debugPrint('[BecauseYouWatched] picked hit id=${hit.id} title="${hit.title}"');

      // 2) Detail page → similar items.
      final details =
          await BestSimilarScraper.fetchDetails(id: hit.id, slug: hit.slug);
      if (details == null || details.similar.isEmpty) {
        debugPrint('[BecauseYouWatched] no similar items returned');
        return const [];
      }
      debugPrint('[BecauseYouWatched] bestsimilar similar=${details.similar.length}');

      // 3) Resolve each BS item to a TMDB Movie (parallel) — relaxed threshold
      //    so we don't drop everything when the year is unknown.
      final lookups = details.similar.map((it) async {
        try {
          final hits = await _api.searchMulti(it.title);
          if (hits.isEmpty) return null;
          Movie? best;
          var bestScore = -1;
          for (final h in hits) {
            var s = 0;
            final ht = h.title.toLowerCase();
            final it2 = it.title.toLowerCase();
            if (ht == it2) {
              s += 5;
            } else if (ht.startsWith(it2) || it2.startsWith(ht)) {
              s += 2;
            }
            if (it.year != null && h.releaseDate.length >= 4) {
              final hy = int.tryParse(h.releaseDate.substring(0, 4));
              if (hy == it.year) {
                s += 4;
              } else if (hy != null && (hy - it.year!).abs() <= 1) {
                s += 1;
              }
            }
            if (h.posterPath.isNotEmpty) s += 1;
            if (s > bestScore) {
              bestScore = s;
              best = h;
            }
          }
          if (best == null || bestScore < 2) return null;
          if (best.posterPath.isEmpty) return null;
          return MapEntry(it.similarityPercent ?? -1, best);
        } catch (_) {
          return null;
        }
      });
      final resolved = await Future.wait(lookups);

      // 4) Sort by bestsimilar similarity % (desc), drop dupes & nulls.
      //    Items without a percentage fall to the bottom.
      final ranked = resolved.whereType<MapEntry<int, Movie>>().toList()
        ..sort((a, b) => b.key.compareTo(a.key));
      final out = <Movie>[];
      final seen = <int>{};
      for (final e in ranked) {
        if (!seen.add(e.value.id)) continue;
        out.add(e.value);
      }
      debugPrint('[BecauseYouWatched] tmdb-resolved=${out.length} (sorted by %)');
      return out;
    } catch (e) {
      debugPrint('[BecauseYouWatched] failed: $e');
      return const [];
    }
  }

  void _shuffleBecauseSeed() {
    _pickBecauseSeed(WatchHistoryService().current);
  }

  Future<void> _loadTraktRecommendations() async {
    try {
      if (!await TraktService().isLoggedIn()) return;
      // Fetch movie + show recommendations and convert via TMDB
      final movieRecs = await TraktService().getRecommendations('movies');
      final showRecs = await TraktService().getRecommendations('shows');
      final all = [...movieRecs, ...showRecs];
      final entries = all.take(20).map((rec) {
        final item = rec['movie'] ?? rec['show'];
        if (item == null) return null;
        final ids = item['ids'] as Map<String, dynamic>?;
        final tmdbId = ids?['tmdb'] as int?;
        if (tmdbId == null) return null;
        final type = rec.containsKey('show') ? 'tv' : 'movie';
        return (tmdbId: tmdbId, type: type);
      }).whereType<({int tmdbId, String type})>().toList();

      // Parallel TMDB lookups in batches of 5
      final movies = <Movie>[];
      for (var i = 0; i < entries.length; i += 5) {
        final batch = entries.skip(i).take(5);
        final results = await Future.wait(
          batch.map((e) async {
            try {
              return e.type == 'tv'
                  ? await _api.getTvDetails(e.tmdbId)
                  : await _api.getMovieDetails(e.tmdbId);
            } catch (_) { return null; }
          }),
        );
        movies.addAll(results.whereType<Movie>());
      }
      if (mounted && movies.isNotEmpty) {
        setState(() => _traktRecommendations = movies);
      }
    } catch (_) {}
  }

  Future<void> _loadTraktCalendar() async {
    try {
      if (!await TraktService().isLoggedIn()) return;
      final shows = await TraktService().getCalendarShows(days: 14);
      if (mounted && shows.isNotEmpty) {
        setState(() => _traktCalendar = shows.take(20).toList());
      }
    } catch (_) {}
  }

  Future<void> _loadTraktCalendarMovies() async {
    try {
      if (!await TraktService().isLoggedIn()) return;
      final movies = await TraktService().getCalendarMovies(days: 30);
      if (mounted && movies.isNotEmpty) {
        setState(() => _traktCalendarMovies = movies.take(20).toList());
      }
    } catch (_) {}
  }

  void _startHeroTimer() {
    if (AppTheme.isLightMode) return; // skip periodic rebuilds in light mode
    _heroTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      if (_heroController.hasClients) {
        final next = (_heroIndex + 1) % 5;
        _heroController.animateToPage(
          next,
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeInOutCubic,
        );
        setState(() => _heroIndex = next);
        _onHeroChanged(next);
      }
    });
  }

  void _onHeroChanged(int index) {
    // Extract ambient color for the new hero
    _trendingFuture.then((movies) {
      if (!mounted) return;
      final list = movies.take(5).toList();
      if (index >= 0 && index < list.length) {
        _extractAmbientFor(list[index]);
      }
    }).catchError((_) {});
  }

  Future<List<Movie>> _loadMoodMovies(String moodId) async {
    final mood = _moods.firstWhere((m) => m.id == moodId, orElse: () => _moods.first);
    try {
      final results = await _api.discoverMovies(genres: mood.genres, minRating: 6.0);
      return results;
    } catch (_) {
      return [];
    }
  }

  void _selectMood(String moodId) {
    if (moodId == _selectedMood) return;
    setState(() {
      _selectedMood = moodId;
      _moodFuture = _loadMoodMovies(moodId);
    });
  }

  Future<void> _extractAmbientFor(Movie movie) async {
    if (AppTheme.isLightMode) return;
    if (_ambientCache.containsKey(movie.id)) {
      final c = _ambientCache[movie.id]!;
      if (mounted) {
        setState(() {
          _ambientPrimary = c.primary;
          _ambientSecondary = c.secondary;
        });
      }
      return;
    }
    final src = movie.backdropPath.isNotEmpty
        ? TmdbApi.getImageUrl(movie.backdropPath)
        : (movie.posterPath.isNotEmpty ? TmdbApi.getImageUrl(movie.posterPath) : '');
    if (src.isEmpty) return;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(src),
        size: const Size(160, 90),
        maximumColorCount: 12,
      );
      final dom = pg.dominantColor?.color ?? pg.vibrantColor?.color ?? AppTheme.primaryColor;
      final vib = pg.vibrantColor?.color ??
          pg.lightVibrantColor?.color ??
          pg.mutedColor?.color ??
          AppTheme.accentColor;
      // Boost saturation slightly so dark posters still tint the page
      Color boosted(Color c) {
        final hsl = HSLColor.fromColor(c);
        return hsl
            .withSaturation((hsl.saturation + 0.25).clamp(0.0, 1.0))
            .withLightness((hsl.lightness * 0.65 + 0.18).clamp(0.05, 0.55))
            .toColor();
      }
      final primary = boosted(dom);
      final secondary = boosted(vib);
      _ambientCache[movie.id] = (primary: primary, secondary: secondary);
      if (!mounted) return;
      setState(() {
        _ambientPrimary = primary;
        _ambientSecondary = secondary;
      });
    } catch (_) {}
  }

  Future<void> _fetchHeroLogos(List<Movie> movies) async {
    for (final movie in movies) {
      if (_heroLogos.containsKey(movie.id)) continue;
      try {
        final logoPath = await _api.getLogoPath(movie.id, mediaType: movie.mediaType);
        if (logoPath.isNotEmpty && mounted) {
          setState(() => _heroLogos[movie.id] = TmdbApi.getImageUrl(logoPath));
        }
      } catch (_) {}
    }
  }

  void _onAddonsChanged() {
    // Clear stale data and schedule a rebuild so the old sliders disappear
    // immediately while the new ones load.
    setState(() {
      _stremioCatalogs = [];
      _catalogItems.clear();
      _catalogsLoaded = false;
    });
    _loadStremioCatalogs();
  }

  @override
  void dispose() {
    SettingsService.addonChangeNotifier.removeListener(_onAddonsChanged);
    _heroTimer?.cancel();
    _heroController.dispose();
    _historySeedSub?.cancel();
    super.dispose();
  }

  Widget _buildTraktCalendarSection() {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.calendar_month_rounded, color: AppTheme.primaryColor, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Upcoming Schedule', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                    const SizedBox(height: 4),
                    Container(
                      height: 2.5,
                      width: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.0)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 140,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: _traktCalendar.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final entry = _traktCalendar[index];
              final show = entry['show'] as Map<String, dynamic>? ?? {};
              final episode = entry['episode'] as Map<String, dynamic>? ?? {};
              final showTitle = show['title'] as String? ?? 'Unknown';
              final epTitle = episode['title'] as String? ?? '';
              final season = episode['season'] as int? ?? 0;
              final number = episode['number'] as int? ?? 0;
              final aired = entry['first_aired'] as String? ?? '';
              String dateLabel = '';
              if (aired.isNotEmpty) {
                try {
                  final dt = DateTime.parse(aired).toLocal();
                  final wd = weekdays[dt.weekday - 1];
                  final mo = months[dt.month - 1];
                  dateLabel = '$wd, $mo ${dt.day}';
                } catch (_) {}
              }
              final showIds = show['ids'] as Map<String, dynamic>? ?? {};
              final tmdbId = showIds['tmdb'] as int?;

              return GestureDetector(
                onTap: () async {
                  if (tmdbId == null) return;
                  try {
                    final movie = await _api.getTvDetails(tmdbId);
                    if (mounted) _openDetails(movie);
                  } catch (_) {}
                },
                child: Container(
                  width: 220,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
                    boxShadow: AppTheme.isLightMode ? null : [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(showTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text('S${season.toString().padLeft(2, '0')}E${number.toString().padLeft(2, '0')}',
                        style: TextStyle(color: AppTheme.primaryColor, fontSize: 12, fontWeight: FontWeight.w600)),
                      if (epTitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(epTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
                      ],
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.access_time_rounded, size: 13, color: Colors.white.withValues(alpha: 0.4)),
                          const SizedBox(width: 4),
                          Text(dateLabel, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTraktCalendarMoviesSection() {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.movie_filter_rounded, color: AppTheme.primaryColor, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Upcoming Movies', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                    const SizedBox(height: 4),
                    Container(
                      height: 2.5,
                      width: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.0)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 140,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: _traktCalendarMovies.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final entry = _traktCalendarMovies[index];
              final movie = entry['movie'] as Map<String, dynamic>? ?? {};
              final title = movie['title'] as String? ?? 'Unknown';
              final year = movie['year'] as int?;
              final released = entry['released'] as String? ?? '';
              String dateLabel = '';
              if (released.isNotEmpty) {
                try {
                  final dt = DateTime.parse(released);
                  final wd = weekdays[dt.weekday - 1];
                  final mo = months[dt.month - 1];
                  dateLabel = '$wd, $mo ${dt.day}';
                } catch (_) {}
              }
              final movieIds = movie['ids'] as Map<String, dynamic>? ?? {};
              final tmdbId = movieIds['tmdb'] as int?;

              return GestureDetector(
                onTap: () async {
                  if (tmdbId == null) return;
                  try {
                    final m = await _api.getMovieDetails(tmdbId);
                    if (mounted) _openDetails(m);
                  } catch (_) {}
                },
                child: Container(
                  width: 220,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
                    boxShadow: AppTheme.isLightMode ? null : [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      if (year != null) ...[
                        const SizedBox(height: 4),
                        Text('$year', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
                      ],
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.calendar_today_rounded, size: 13, color: Colors.white.withValues(alpha: 0.4)),
                          const SizedBox(width: 4),
                          Text(dateLabel, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openDetails(Movie movie) async {
    final settings = SettingsService();
    final isStreaming = await settings.isStreamingModeEnabled();
    
    if (!mounted) return;

    if (isStreaming) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => StreamingDetailsScreen(movie: movie)));
    } else {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: movie)));
    }
  }

  Future<void> _loadStremioCatalogs() async {
    try {
      final catalogs = await _stremio.getAllCatalogs();
      if (!mounted || catalogs.isEmpty) return;

      // Group non-search-required catalogs by addon, preserving order.
      final Map<String, List<Map<String, dynamic>>> byAddon = {};
      for (final c in catalogs) {
        if (c['searchRequired'] == true) continue;
        final key = c['addonBaseUrl'] as String;
        byAddon.putIfAbsent(key, () => []).add(c);
      }

      // Mark that we've started loading so the build can show shimmer / placeholders.
      if (mounted) setState(() => _catalogsLoaded = true);

      // For each addon, try catalogs in order until one returns items.
      // All addons are tried in parallel; within each addon they are tried sequentially.
      await Future.wait(byAddon.values.map((addonCatalogs) async {
        for (final cat in addonCatalogs) {
          try {
            final items = await _stremio.getCatalog(
              baseUrl: cat['addonBaseUrl'],
              type: cat['catalogType'],
              id: cat['catalogId'],
            );
            if (items.isEmpty) continue; // try next catalog for this addon

            // Tag each item with the addon that provided it
            for (final item in items) {
              item['_addonBaseUrl'] = cat['addonBaseUrl'];
              item['_addonName'] = cat['addonName'];
            }
            if (mounted) {
              final itemKey = '${cat['addonBaseUrl']}/${cat['catalogType']}/${cat['catalogId']}';
              setState(() {
                // Add the winning catalog to the list if not already present
                if (!_stremioCatalogs.any((c) =>
                    c['addonBaseUrl'] == cat['addonBaseUrl'] &&
                    c['catalogId'] == cat['catalogId'])) {
                  _stremioCatalogs = [..._stremioCatalogs, cat];
                }
                _catalogItems[itemKey] = items;
              });
            }
            return; // done for this addon
          } catch (_) {}
        }
      }));
    } catch (e) {
      debugPrint('[HomeScreen] Error loading Stremio catalogs: $e');
    }
  }

  void _openStremioCatalog(Map<String, dynamic> catalog) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StremioCatalogScreen(initialCatalog: catalog)),
    );
  }

  Future<void> _openStremioItem(Map<String, dynamic> item) async {
    final id = item['id']?.toString() ?? '';
    final type = item['type']?.toString() ?? 'movie';
    final name = item['name']?.toString() ?? 'Unknown';
    final poster = item['poster']?.toString() ?? '';
    final isCustomId = !id.startsWith('tt');
    
    // Check if this is a collection by ID prefix
    final isCollection = id.startsWith('ctmdb.') || type == 'collections';

    // IMDB ID → TMDB lookup
    if (!isCustomId && !isCollection) {
      try {
        final movie = await _api.findByImdbId(id, mediaType: type == 'series' ? 'tv' : 'movie');
        if (movie != null && mounted) {
          // Always use DetailsScreen for Stremio items
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => DetailsScreen(movie: movie, stremioItem: item),
          ));
          return;
        }
      } catch (_) {}
    }

    // For non-custom IDs that failed, try name search
    if (!isCustomId && !isCollection) {
      try {
        final results = await _api.searchMulti(name);
        if (results.isNotEmpty && mounted) {
          final match = results.firstWhere(
            (m) => m.title.toLowerCase() == name.toLowerCase(),
            orElse: () => results.first,
          );
          // Always use DetailsScreen for Stremio items
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => DetailsScreen(movie: match, stremioItem: item),
          ));
          return;
        }
      } catch (_) {}
    }

    // Custom ID, collection, or all lookups failed
    if (mounted) {
      // Override type to 'collections' if it's a collection ID
      final actualType = isCollection ? 'collections' : (type == 'series' ? 'tv' : 'movie');
      
      final movie = Movie(
        id: id.hashCode,
        imdbId: id.startsWith('tt') ? id : null,
        title: name,
        posterPath: poster,
        backdropPath: item['background']?.toString() ?? poster,
        voteAverage: double.tryParse(item['imdbRating']?.toString() ?? '') ?? 0,
        releaseDate: item['releaseInfo']?.toString() ?? '',
        overview: item['description']?.toString() ?? '',
        mediaType: actualType,
      );
      
      // Update the stremioItem type to collections if needed
      final updatedItem = Map<String, dynamic>.from(item);
      if (isCollection) {
        updatedItem['type'] = 'collections';
      }
      
      // Always use DetailsScreen for Stremio items
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => DetailsScreen(movie: movie, stremioItem: updatedItem),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: AppTheme.bgDark,
      body: Stack(
        children: [
          // ── Ambient backdrop: dynamic blobs of color extracted from current hero
          if (!AppTheme.isLightMode)
            Positioned.fill(
              child: IgnorePointer(
                child: _AmbientBackdrop(
                  primary: _ambientPrimary,
                  secondary: _ambientSecondary,
                ),
              ),
            ),
          CustomScrollView(
            cacheExtent: 500,
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Hero
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: FutureBuilder<List<Movie>>(
                    future: _trendingFuture,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return _buildHeroShimmer();
                      }
                      return _buildHeroCarousel(snapshot.data!.take(5).toList());
                    },
                  ),
                ),
              ),

              // Stats strip — derived from local watch history
              const SliverToBoxAdapter(child: RepaintBoundary(child: _StatsStrip())),

              // Continue Watching — wide cinematic hero card for the most recent
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _ContinueWatchingHero(onOpen: _openDetails),
                ),
              ),

              // Continue Watching strip (everything else)
              const SliverToBoxAdapter(child: RepaintBoundary(child: _ContinueWatchingSection())),

              // Mosaic Spotlight — Trending Now reimagined as 1 big + 4 small
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _MosaicSpotlight(
                    future: _trendingFuture,
                    onTap: _openDetails,
                  ),
                ),
              ),

              // Trending Ticker — auto-scrolling marquee with rank numbers
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _TrendingTicker(
                    future: _trendingFuture,
                    onTap: _openDetails,
                  ),
                ),
              ),

              // Tonight's Pick — randomized hand-feeling recommendation
              if (_tonightsPick != null)
                SliverToBoxAdapter(
                  child: RepaintBoundary(
                    child: _TonightsPickCard(
                      movie: _tonightsPick!,
                      onPlay: () => _openDetails(_tonightsPick!),
                      onShuffle: () {
                        _trendingFuture.then((movies) {
                          if (!mounted || movies.length < 4) return;
                          final pool = movies.skip(2).where((m) => m.id != _tonightsPick?.id).toList();
                          if (pool.isEmpty) return;
                          setState(() => _tonightsPick = pool[math.Random().nextInt(pool.length)]);
                        });
                      },
                    ),
                  ),
                ),

              // Mood / Genre chips — interactive filter
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _MoodSection(
                    moods: _moods,
                    selectedId: _selectedMood,
                    onSelect: _selectMood,
                    future: _moodFuture,
                    onMovieTap: _openDetails,
                  ),
                ),
              ),

              // "Because you watched ___" — BestSimilar.com recommendations
              // (the /recommendations endpoint, not the trash /similar one)
              if (_becauseSeed != null && _becauseFuture != null)
                SliverToBoxAdapter(
                  child: RepaintBoundary(
                    child: _BecauseYouWatchedSection(
                      seedTitle: (_becauseSeed!['title'] as String?) ?? '',
                      seedPosterPath: (_becauseSeed!['posterPath'] as String?) ?? '',
                      future: _becauseFuture!,
                      onMovieTap: _openDetails,
                      // Only allow re-rolling when there's actually more than
                      // one in-progress show to choose between.
                      onShuffle: _becausePoolSize > 1 ? _shuffleBecauseSeed : null,
                    ),
                  ),
                ),

              // Popular
              SliverToBoxAdapter(child: RepaintBoundary(child: _MovieSection(title: 'Popular', icon: Icons.movie_filter_rounded, future: _popularFuture, onMovieTap: _openDetails, isPortrait: true, showRank: true))),

              // Stremio Addon Catalogs (preserved exactly as before)
              if (_catalogsLoaded)
                ..._stremioCatalogs.map((cat) {
                  final key = '${cat['addonBaseUrl']}/${cat['catalogType']}/${cat['catalogId']}';
                  final items = _catalogItems[key];
                  if (items == null || items.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
                  return SliverToBoxAdapter(
                    child: RepaintBoundary(
                      child: _StremioCatalogSection(
                        catalog: cat,
                        items: items,
                        onItemTap: _openStremioItem,
                        onShowAll: () => _openStremioCatalog(cat),
                      ),
                    ),
                  );
                }),

              // Top Rated
              SliverToBoxAdapter(child: RepaintBoundary(child: _MovieSection(title: 'Top Rated', icon: Icons.star_rounded, future: _topRatedFuture, onMovieTap: _openDetails))),

              // Trakt Recommendations
              if (_traktRecommendations.isNotEmpty)
                SliverToBoxAdapter(child: RepaintBoundary(child: _StaticMovieSection(title: 'Recommended for You', icon: Icons.recommend_rounded, movies: _traktRecommendations, onMovieTap: _openDetails))),

              // Trakt Calendar
              if (_traktCalendar.isNotEmpty)
                SliverToBoxAdapter(child: RepaintBoundary(child: _buildTraktCalendarSection())),

              // Trakt Calendar Movies
              if (_traktCalendarMovies.isNotEmpty)
                SliverToBoxAdapter(child: RepaintBoundary(child: _buildTraktCalendarMoviesSection())),

              // New Releases
              SliverToBoxAdapter(child: RepaintBoundary(child: _MovieSection(title: 'New Releases', icon: Icons.new_releases_rounded, future: _nowPlayingFuture, onMovieTap: _openDetails, isPortrait: true))),

              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeroShimmer() {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final h = isLandscape ? MediaQuery.of(context).size.height * 0.65 : MediaQuery.of(context).size.height * 0.82;
    final placeholder = Container(height: h, color: AppTheme.bgCard);
    if (AppTheme.isLightMode) return placeholder;
    return Shimmer.fromColors(
      baseColor: AppTheme.bgCard,
      highlightColor: const Color(0xFF1E1E2F),
      child: placeholder,
    );
  }

  Widget _buildHeroCarousel(List<Movie> movies) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final height = isLandscape ? MediaQuery.of(context).size.height * 0.65 : MediaQuery.of(context).size.height * 0.82;
    final heroMovie = movies[_heroIndex];
    
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          // Background image with parallax-like crossfade
          PageView.builder(
            controller: _heroController,
            itemCount: movies.length,
            onPageChanged: (i) {
              setState(() => _heroIndex = i);
              _extractAmbientFor(movies[i]);
            },
            itemBuilder: (context, index) {
              final movie = movies[index];
              return Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: movie.backdropPath.isNotEmpty 
                        ? TmdbApi.getBackdropUrl(movie.backdropPath) 
                        : TmdbApi.getImageUrl(movie.posterPath),
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    placeholder: (c, u) => Container(color: AppTheme.bgCard),
                  ),
                  // Multi-layer gradient for depth
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          AppTheme.bgDark.withValues(alpha: 0.3),
                          AppTheme.bgDark.withValues(alpha: 0.85),
                          AppTheme.bgDark,
                        ],
                        stops: const [0.0, 0.25, 0.55, 0.8, 1.0],
                      ),
                    ),
                  ),
                  // Side vignette
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          AppTheme.bgDark.withValues(alpha: 0.65),
                          Colors.transparent,
                          Colors.transparent,
                          AppTheme.bgDark.withValues(alpha: 0.4),
                        ],
                        stops: const [0.0, 0.25, 0.75, 1.0],
                      ),
                    ),
                  ),
                  // Subtle color tint overlay (skipped in light mode)
                  if (!AppTheme.isLightMode)
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.bottomLeft,
                        radius: 1.8,
                        colors: [
                          AppTheme.primaryColor.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          
          // Top gradient for status bar
          Positioned(
            top: 0, left: 0, right: 0,
            height: MediaQuery.of(context).padding.top + 60,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          
          // Content overlay
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo or Title — cinematic size
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 600),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(animation),
                        child: child,
                      ),
                    ),
                    child: _heroLogos.containsKey(heroMovie.id) && _heroLogos[heroMovie.id]!.isNotEmpty
                        ? Padding(
                            key: ValueKey('logo_${heroMovie.id}'),
                            padding: const EdgeInsets.only(bottom: 14),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: isLandscape ? 420 : MediaQuery.of(context).size.width * 0.75,
                                maxHeight: isLandscape ? 140 : 110,
                              ),
                              child: CachedNetworkImage(
                                imageUrl: _heroLogos[heroMovie.id]!,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                placeholder: (_, _) => const SizedBox.shrink(),
                                errorWidget: (_, _, _) => _buildHeroTitle(heroMovie, isLandscape),
                              ),
                            ),
                          )
                        : Padding(
                            key: ValueKey('title_${heroMovie.id}'),
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _buildHeroTitle(heroMovie, isLandscape),
                          ),
                  ),
                  // Meta row — cinematic
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // Rating pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.amber.withValues(alpha: 0.25), Colors.amber.withValues(alpha: 0.08)],
                            ),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.2)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star_rounded, size: 14, color: Colors.amber),
                              const SizedBox(width: 4),
                              Text(heroMovie.voteAverage.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber, fontSize: 13)),
                            ],
                          ),
                        ),
                        if (heroMovie.releaseDate.isNotEmpty)
                          Text(heroMovie.releaseDate.split('-').first, style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13, fontWeight: FontWeight.w500)),
                        if (heroMovie.mediaType == 'tv')
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('SERIES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white60, letterSpacing: 0.8)),
                          ),
                        if (heroMovie.genres.isNotEmpty)
                          Text(
                            heroMovie.genres.take(3).join('  ·  '),
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                      ],
                    ),
                  ),
                  // Synopsis
                  if (heroMovie.overview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(
                        heroMovie.overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13.5,
                          height: 1.5,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  // Action buttons — cinematic glow
                  Row(
                    children: [
                      // Play button with glow
                      Flexible(
                        child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: AppTheme.isLightMode ? null : [
                            BoxShadow(color: Colors.white.withValues(alpha: 0.15), blurRadius: 20, spreadRadius: -2),
                          ],
                        ),
                        child: Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          child: InkWell(
                            onTap: () => _openDetails(heroMovie),
                            borderRadius: BorderRadius.circular(28),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow_rounded, color: Colors.black, size: 26),
                                  SizedBox(width: 6),
                                  Text('Play', style: TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      ),
                      const SizedBox(width: 12),
                      // More Info — frosted glass pill (simplified in light mode)
                      Flexible(
                        child: _buildFrostedPill(
                        onTap: () => _openDetails(heroMovie),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.info_outline_rounded, color: Colors.white.withValues(alpha: 0.85), size: 20),
                              const SizedBox(width: 8),
                              Text('More Info', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 14, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                      ),
                      const SizedBox(width: 12),
                      // My List — frosted circle (simplified in light mode)
                      _buildFrostedCircle(
                        child: _MyListButton.movie(movie: heroMovie),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Page indicator — thin cinematic bar style
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(movies.length, (i) => AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      height: 3,
                      width: i == _heroIndex ? 28 : 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        color: i == _heroIndex ? Colors.white : Colors.white.withValues(alpha: 0.2),
                        boxShadow: (i == _heroIndex && !AppTheme.isLightMode) ? [BoxShadow(color: Colors.white.withValues(alpha: 0.3), blurRadius: 8)] : null,
                      ),
                    )),
                  ),
                ],
              ),
            ),
          ),
          // Hero navigation arrows — frosted glass
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  if (_heroController.hasClients && _heroIndex > 0) {
                    _heroController.animateToPage(
                      _heroIndex - 1,
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
                child: _buildFrostedArrow(
                  icon: Icons.arrow_back_ios_new_rounded,
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  if (_heroController.hasClients && _heroIndex < movies.length - 1) {
                    _heroController.animateToPage(
                      _heroIndex + 1,
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
                child: _buildFrostedArrow(
                  icon: Icons.arrow_forward_ios_rounded,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroTitle(Movie movie, bool isLandscape) {
    return Text(
      movie.title,
      style: TextStyle(
        fontSize: isLandscape ? 48 : 36,
        fontWeight: FontWeight.w900,
        color: Colors.white,
        height: 1.0,
        letterSpacing: -1.0,
        shadows: AppTheme.isLightMode ? null : [
          const Shadow(color: Colors.black, blurRadius: 40),
          Shadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 80),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  // ── Light-mode-aware frosted glass helpers ────────────────────────

  Widget _buildFrostedPill({required VoidCallback onTap, required Widget child}) {
    final inner = Material(
      color: Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: child,
      ),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: inner,
      ),
    );
  }

  Widget _buildFrostedCircle({required Widget child}) {
    final inner = Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: child,
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: inner,
      ),
    );
  }

  Widget _buildFrostedArrow({required IconData icon}) {
    final inner = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: AppTheme.isLightMode ? 0.45 : 0.25),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.7), size: 18),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: inner,
      ),
    );
  }
}

class _MovieSection extends StatefulWidget {
  final String title;
  final IconData? icon;
  final Future<List<Movie>> future;
  final Function(Movie) onMovieTap;
  final bool isPortrait;
  final bool showRank;

  const _MovieSection({
    required this.title,
    this.icon,
    required this.future,
    required this.onMovieTap,
    this.isPortrait = false,
    this.showRank = false,
  });

  @override
  State<_MovieSection> createState() => _MovieSectionState();
}

class _MovieSectionState extends State<_MovieSection> {
  final ScrollController _scrollController = ScrollController();

  void _scrollLeft() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.offset - 600,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _scrollRight() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.offset + 600,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildSmallFrostedArrow(IconData icon) {
    final inner = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.12 : 0.08),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.6), size: 14),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: inner,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Movie>>(
      future: widget.future,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          // Shimmer placeholder while loading
          if (snapshot.connectionState == ConnectionState.waiting) {
            final shimmerChild = Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Container(height: 18, width: 140, decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(6))),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: widget.isPortrait ? 240 : 180,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: 5,
                        separatorBuilder: (_, _) => const SizedBox(width: 14),
                        itemBuilder: (_, _) => Container(
                          width: widget.isPortrait ? 150 : 280,
                          decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            if (AppTheme.isLightMode) return shimmerChild;
            return Shimmer.fromColors(
              baseColor: AppTheme.bgCard,
              highlightColor: const Color(0xFF1E1E2F),
              child: shimmerChild,
            );
          }
          return const SizedBox.shrink();
        }
        final movies = snapshot.data!;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 16),
              child: Row(
                children: [
                  if (widget.icon != null) ...[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(widget.icon, color: AppTheme.primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                        const SizedBox(height: 4),
                        Container(
                          height: 2.5,
                          width: 36,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            gradient: LinearGradient(
                              colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.0)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: _scrollLeft,
                    child: _buildSmallFrostedArrow(Icons.arrow_back_ios_new_rounded),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _scrollRight,
                    child: _buildSmallFrostedArrow(Icons.arrow_forward_ios_rounded),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: widget.isPortrait ? 290 : 210,
              child: ListView.separated(
                clipBehavior: Clip.none,
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: movies.length,
                separatorBuilder: (_, _) => SizedBox(width: widget.showRank ? 6 : 14),
                itemBuilder: (context, index) => _MovieCard(
                  movie: movies[index],
                  onTap: () => widget.onMovieTap(movies[index]),
                  isPortrait: widget.isPortrait,
                  rank: widget.showRank ? index + 1 : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StaticMovieSection extends StatefulWidget {
  final String title;
  final IconData? icon;
  final List<Movie> movies;
  final Function(Movie) onMovieTap;

  const _StaticMovieSection({
    required this.title,
    this.icon,
    required this.movies,
    required this.onMovieTap,
  });

  @override
  State<_StaticMovieSection> createState() => _StaticMovieSectionState();
}

class _StaticMovieSectionState extends State<_StaticMovieSection> {
  final ScrollController _scrollController = ScrollController();

  void _scrollLeft() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.offset - 600,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _scrollRight() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.offset + 600,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildSmallFrostedArrow(IconData icon) {
    final inner = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.12 : 0.08),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.6), size: 14),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: inner,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.movies.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 16),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(widget.icon, color: AppTheme.primaryColor, size: 18),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                    const SizedBox(height: 4),
                    Container(
                      height: 2.5,
                      width: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.0)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _scrollLeft,
                child: _buildSmallFrostedArrow(Icons.arrow_back_ios_new_rounded),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _scrollRight,
                child: _buildSmallFrostedArrow(Icons.arrow_forward_ios_rounded),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 210,
          child: ListView.separated(
            clipBehavior: Clip.none,
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: widget.movies.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) => _MovieCard(
              movie: widget.movies[index],
              onTap: () => widget.onMovieTap(widget.movies[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _MovieCard extends StatelessWidget {
  final Movie movie;
  final bool isPortrait;
  final int? rank;
  final VoidCallback onTap;

  const _MovieCard({
    required this.movie,
    this.isPortrait = false,
    this.rank,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 900;
    
    final cardWidth = isPortrait 
        ? (isDesktop ? 190.0 : 165.0) 
        : (isDesktop ? 360.0 : 300.0);
        
    final image = isPortrait ? movie.posterPath : movie.backdropPath;
    final imageUrl = image.isNotEmpty ? TmdbApi.getImageUrl(image) : '';
    final hasRank = rank != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Big rank number
        if (hasRank)
          Text(
            '$rank',
            style: TextStyle(
              fontSize: isPortrait ? 120 : 90,
              fontWeight: FontWeight.w900,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..color = Colors.white.withValues(alpha: 0.1),
              height: 0.85,
              letterSpacing: -8,
            ),
          ),
        FocusableControl(
          onTap: onTap,
          borderRadius: 14,
          scaleOnFocus: 1.05,
          child: Container(
            width: cardWidth,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
              boxShadow: AppTheme.isLightMode ? null : [
                BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(0, 8)),
                BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.05), blurRadius: 20, spreadRadius: -4),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imageUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    placeholder: (c, u) => Container(color: AppTheme.bgCard),
                    errorWidget: (c, u, e) => Container(
                      color: AppTheme.bgCard,
                      child: Center(child: Text(movie.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.white24))),
                    ),
                  )
                else
                  Container(
                    color: AppTheme.bgCard,
                    child: Center(child: Text(movie.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.white24))),
                  ),
                
                // Gradient overlay
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                        Colors.black.withValues(alpha: 0.95),
                      ],
                      stops: const [0.0, 0.45, 0.8, 1.0],
                    ),
                  ),
                ),
                
                // Rating badge (top right) — frosted glass
                if (movie.voteAverage > 0)
                  Positioned(
                    top: 8, right: 8,
                    child: _buildRatingBadge(movie.voteAverage),
                  ),

                // Bottom content
                Positioned(
                  bottom: 10, left: 10, right: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        movie.title,
                        maxLines: isPortrait ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white, 
                          fontWeight: FontWeight.bold, 
                          fontSize: isDesktop ? 14 : 13,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (movie.releaseDate.isNotEmpty)
                            Text(
                              movie.releaseDate.split('-').first,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                            ),
                          if (movie.mediaType == 'tv') ...[
                            if (movie.releaseDate.isNotEmpty) ...[
                              Text('  •  ', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
                            ],
                            Text('TV', style: TextStyle(color: AppTheme.primaryColor.withValues(alpha: 0.8), fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // My List button
                Positioned(
                  top: 8, left: 8,
                  child: _MyListButton.movie(movie: movie),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Rating badge — uses frosted glass when not in light mode.
Widget _buildRatingBadge(double voteAverage) {
  final inner = Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: AppTheme.isLightMode ? 0.55 : 0.35),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, size: 12, color: Colors.amber),
        const SizedBox(width: 3),
        Text(
          voteAverage.toStringAsFixed(1),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ],
    ),
  );
  if (AppTheme.isLightMode) return inner;
  return ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: inner,
    ),
  );
}

/// Rating badge for string ratings (Stremio) — uses frosted glass when not in light mode.
Widget _buildRatingBadgeText(String rating) {
  final content = Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: AppTheme.isLightMode ? 0.5 : 0.3),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, color: Colors.amber, size: 11),
        const SizedBox(width: 2),
        Text(rating, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
      ],
    ),
  );
  if (AppTheme.isLightMode) return content;
  return ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: content,
    ),
  );
}

class _ContinueWatchingSection extends StatefulWidget {
  const _ContinueWatchingSection();

  @override
  State<_ContinueWatchingSection> createState() => _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState extends State<_ContinueWatchingSection> {
  final ScrollController _scrollController = ScrollController();
  String? _loadingItemId;

  void _scrollLeft() {
    _scrollController.animateTo(
      _scrollController.offset - 600,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  void _scrollRight() {
    _scrollController.animateTo(
      _scrollController.offset + 600,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildCWSectionArrow(IconData icon) {
    final inner = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.12 : 0.08),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.6), size: 14),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: inner,
      ),
    );
  }

  Future<void> _resumePlayback(Map<String, dynamic> item) async {
    final uniqueId = item['uniqueId'] as String;
    if (_loadingItemId != null) return;
    
    setState(() => _loadingItemId = uniqueId);

    try {
      final method = item['method'] as String;
      final tmdbId = item['tmdbId'] as int;
      final season = item['season'] as int?;
      final episode = item['episode'] as int?;
      final title = item['title'] as String;
      final posterPath = item['posterPath'] as String; 
      final startPos = Duration(milliseconds: item['position'] as int);

      // Streaming-mode entries (stream/amri/stremio_direct) don't keep a
      // re-playable URL — extraction tokens expire. The cleanest UX is to
      // re-open the StreamingDetailsScreen which auto-runs the extraction
      // splash and then forwards startPosition to the player so it seeks
      // once the duration loads.
      final isStreamingEntry = method == 'stream' ||
          method == 'amri' ||
          method == 'stremio_direct';
      if (isStreamingEntry) {
        if (mounted) {
          final mediaType =
              item['mediaType'] as String? ?? (season != null ? 'tv' : 'movie');
          final movie = Movie(
            id: tmdbId,
            title: title,
            posterPath: posterPath,
            backdropPath: '',
            overview: '',
            releaseDate: '',
            voteAverage: 0,
            mediaType: mediaType,
            genres: [],
            imdbId: item['imdbId'],
          );
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => StreamingDetailsScreen(
                movie: movie,
                initialSeason: season,
                initialEpisode: episode,
                startPosition: startPos,
              ),
            ),
          );
        }
        return;
      }

      // Get saved magnet link and file index for torrents
      final savedMagnetLink = item['magnetLink'] as String?;
      final savedFileIndex = item['fileIndex'] as int?;

      String? streamUrl;
      String? activeProvider;
      String? magnetLink;
      int? fileIndex;
      String? stremioItemId;
      String? stremioAddonBase;

      if (method == 'stremio_direct') {
        // Direct stremio stream — try the saved URL first
        final savedUrl = item['streamUrl'] as String?;
        stremioItemId = item['stremioId'] as String?;
        stremioAddonBase = item['stremioAddonBaseUrl'] as String?;
        activeProvider = 'stremio_direct';

        if (savedUrl != null && savedUrl.isNotEmpty) {
          // Try playing the saved URL directly
          streamUrl = savedUrl;
          debugPrint('[Resume] Trying saved stremio direct URL: $savedUrl');
        }

        // If no saved URL, or if player fails, we'll fall through to the
        // "open details page" fallback below
        if (streamUrl == null && stremioItemId != null && stremioAddonBase != null) {
          // Re-fetch streams from the addon
          debugPrint('[Resume] Re-fetching stremio streams for $stremioItemId from $stremioAddonBase');
          final stremioType = item['stremioType'] as String? ?? (season != null ? 'series' : 'movie');
          final stremio = StremioService();
          try {
            final streams = await stremio.getStreams(
              baseUrl: stremioAddonBase,
              type: stremioType,
              id: stremioItemId,
            );
            if (streams.isNotEmpty) {
              final first = streams.first;
              if (first is Map<String, dynamic> && first['url'] != null) {
                streamUrl = first['url'] as String;
              }
            }
          } catch (e) {
            debugPrint('[Resume] Re-fetch stremio streams failed: $e');
          }
        }

        // If we still have nothing, open the details page
        if (streamUrl == null) {
          if (mounted) {
            final mediaType = item['mediaType'] as String? ?? (season != null ? 'tv' : 'movie');
            final movie = Movie(
              id: tmdbId,
              title: title,
              posterPath: posterPath,
              backdropPath: '',
              overview: '',
              releaseDate: '',
              voteAverage: 0,
              mediaType: mediaType,
              genres: [],
              imdbId: item['imdbId'],
            );
            Map<String, dynamic>? stremioItem;
            if (stremioItemId != null) {
              stremioItem = {
                'id': stremioItemId,
                '_addonBaseUrl': stremioAddonBase ?? '',
                'type': item['stremioType'] ?? (season != null ? 'series' : 'movie'),
                'name': title,
              };
            }
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => DetailsScreen(
                movie: movie,
                stremioItem: stremioItem,
                initialSeason: season,
                initialEpisode: episode,
                startPosition: startPos,
              ),
            ));
          }
          return; // Skip the player launch below
        }
      } else if (method == 'stream') {
        // Re-extract stream using saved sourceId (tmdbId + season + episode)
        final sourceId = item['sourceId'] as String;
        activeProvider = sourceId;
        
        if (sourceId == 'webstreamr') {
          debugPrint('[Resume] Using WebStreamrService for $title');
          final webStreamr = WebStreamrService();
          final imdbId = item['imdbId']?.toString() ?? '';
          if (imdbId.isNotEmpty) {
            final webStreamrSources = await webStreamr.getStreams(
              imdbId: imdbId,
              isMovie: season == null,
              season: season,
              episode: episode,
            );
            if (webStreamrSources.isNotEmpty) {
              streamUrl = webStreamrSources.first.url;
              if (mounted) {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlayerScreen(
                      streamUrl: streamUrl!,
                      title: title,
                      movie: Movie(
                        id: tmdbId,
                        title: title,
                        posterPath: posterPath,
                        backdropPath: '', 
                        overview: '', 
                        releaseDate: '', 
                        voteAverage: 0, 
                        mediaType: season != null ? 'tv' : 'movie', 
                        genres: [], 
                        imdbId: imdbId,
                      ),
                      selectedSeason: season,
                      selectedEpisode: episode,
                      activeProvider: 'webstreamr',
                      startPosition: startPos,
                      sources: webStreamrSources,
                    ),
                  ),
                );
                return;
              }
            }
          }
        }

        final provider = StreamProviders.providers[sourceId];
        if (provider == null) {
           throw Exception("Provider $sourceId not available");
        }

        debugPrint('[Resume] Re-extracting stream for $title (TMDB: $tmdbId, S:$season, E:$episode)');
        final url = season != null && episode != null
            ? provider['tv'](tmdbId, season, episode)
            : provider['movie'](tmdbId);
        
        final extractor = StreamExtractor();
        final result = await extractor.extract(url, timeout: const Duration(seconds: 20));
        streamUrl = result?.url;
      } else if (method == 'amri') {
        // Re-extract AMRI using tmdbId + season + episode
        activeProvider = 'AMRI';
        debugPrint('[Resume] Re-extracting AMRI for $title (TMDB: $tmdbId, S:$season, E:$episode)');
        final amriExtractor = AmriExtractor(
          onLog: (message) => debugPrint('[AMRI Resume] $message'),
        );
        
        final year = item['year']?.toString() ?? '';
        
        final sourcesData = await amriExtractor.extractSources(
          tmdbId.toString(),
          title,
          year,
          season: season,
          episode: episode,
        );
        
        if (sourcesData['sources'] != null && sourcesData['sources'].isNotEmpty) {
          final sources = sourcesData['sources'] as List;
          streamUrl = sources.first['url'] as String?;
        }
      } else if (method == 'torrent') {
        // Use saved magnet link - NEVER re-search
        magnetLink = savedMagnetLink;
        fileIndex = savedFileIndex;
        
        if (magnetLink == null || magnetLink.isEmpty) {
          throw Exception("No magnet link saved for this torrent");
        }
        
        debugPrint('[Resume] Using saved magnet link: ${magnetLink.substring(0, 60)}...');
        debugPrint('[Resume] Using saved file index: $fileIndex');

        // Check Debrid Preference
        final useDebridSetting = await SettingsService().useDebridForStreams();
        final debridService = await SettingsService().getDebridService();
        final useDebrid = useDebridSetting && debridService != 'None';

        if (useDebrid) {
          debugPrint('[Resume] Using debrid service: $debridService');
          if (debridService == 'Real-Debrid') {
             final files = await DebridApi().resolveRealDebrid(magnetLink,
                 season: season, episode: episode);
             if (files.isNotEmpty) {
               // resolveRealDebrid now returns a single, pre-picked file.
               streamUrl = files.first.downloadUrl;
               fileIndex = 0;
               debugPrint('[Resume] Picked: ${files.first.filename}');
             }
          } else if (debridService == 'TorBox') {
             final files = await DebridApi().resolveTorBox(magnetLink,
                 season: season, episode: episode);
             if (files.isNotEmpty) {
               streamUrl = files.first.downloadUrl;
               fileIndex = 0;
               debugPrint('[Resume] Picked: ${files.first.filename}');
             }
          } else {
             throw Exception("No Debrid service configured");
          }
        } else {
          // Local Torrent Engine
          debugPrint('[Resume] Using local torrent engine');
          streamUrl = await TorrentStreamService().streamTorrent(magnetLink, season: season, episode: episode, fileIdx: fileIndex);
        }
      } else if (method == 'trakt_import') {
        // Trakt-imported items have no stream source — find one automatically
        if (context.mounted) {
          final mediaType = item['mediaType'] as String? ?? (season != null ? 'tv' : 'movie');
          final movie = Movie(
            id: tmdbId,
            title: title,
            posterPath: posterPath,
            backdropPath: '',
            overview: '',
            releaseDate: '',
            voteAverage: 0,
            mediaType: mediaType,
            genres: [],
            imdbId: item['imdbId'],
          );
          final navigator = Navigator.of(context);
          final isStreaming = await SettingsService().isStreamingModeEnabled();
          navigator.push(MaterialPageRoute(
            builder: (_) => isStreaming
                ? StreamingDetailsScreen(
                    movie: movie,
                    initialSeason: season,
                    initialEpisode: episode,
                    startPosition: startPos,
                  )
                : DetailsScreen(
                    movie: movie,
                    initialSeason: season,
                    initialEpisode: episode,
                    startPosition: startPos,
                  ),
          ));
        }
        return;
      }

      if (streamUrl != null && mounted) {
        // Launch Player
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
              streamUrl: streamUrl!,
              title: title,
              movie: Movie(
                id: tmdbId,
                title: title,
                posterPath: posterPath,
                backdropPath: '', 
                overview: '', 
                releaseDate: '', 
                voteAverage: 0, 
                mediaType: season != null ? 'tv' : 'movie', 
                genres: [], 
                imdbId: item['imdbId'],
              ),
              selectedSeason: season,
              selectedEpisode: episode,
              magnetLink: magnetLink,
              fileIndex: fileIndex, // Pass file index to player
              activeProvider: activeProvider,
              startPosition: startPos,
              stremioId: stremioItemId,
              stremioAddonBaseUrl: stremioAddonBase,
            ),
          ),
        );
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Failed to load video")));
      }
    } catch (e) {
      debugPrint('[Resume] Error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    } finally {
      if (mounted) setState(() => _loadingItemId = null);
    }
  }

  Future<void> _removeItem(Map<String, dynamic> item) async {
    await WatchHistoryService().removeItem(item['uniqueId']);

    // Also remove from Trakt playback progress if logged in
    final tmdbId = item['tmdbId'] as int?;
    if (tmdbId != null) {
      final mediaType = item['mediaType']?.toString() ?? 'movie';
      final season = item['season'] as int?;
      final episode = item['episode'] as int?;
      await TraktService().removePlaybackProgress(
        tmdbId: tmdbId,
        mediaType: mediaType,
        season: season,
        episode: episode,
      );
    }
  }

  /// Opens the details page for a history item based on streaming mode and item type
  Future<void> _openHistoryItemDetails(Map<String, dynamic> item) async {
    final tmdbId = item['tmdbId'] as int;
    final title = item['title'] as String;
    final posterPath = item['posterPath'] as String;
    final season = item['season'] as int?;
    final episode = item['episode'] as int?;
    final mediaType = item['mediaType'] as String? ?? (season != null ? 'tv' : 'movie');
    
    final movie = Movie(
      id: tmdbId,
      title: title,
      posterPath: posterPath,
      backdropPath: '',
      overview: '',
      releaseDate: '',
      voteAverage: 0,
      mediaType: mediaType,
      genres: [],
      imdbId: item['imdbId'],
    );

    final isStreamingMode = await SettingsService().isStreamingModeEnabled();
    
    // Determine which screen to open based on streaming mode and item type
    if (isStreamingMode) {
      // Streaming mode ON -> always open StreamingDetailsScreen
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StreamingDetailsScreen(
              movie: movie,
              initialSeason: season,
              initialEpisode: episode,
            ),
          ),
        );
      }
    } else {
      // Streaming mode OFF
      // Check if it's a Stremio addon with custom ID
      final stremioItemId = item['stremioId'] as String?;
      final stremioAddonBase = item['stremioAddonBaseUrl'] as String?;
      final isCustomId = stremioItemId != null && 
                         stremioAddonBase != null && 
                         !stremioItemId.startsWith('tt');
      
      if (isCustomId) {
        // Stremio addon with custom ID -> open DetailsScreen (torrent mode)
        Map<String, dynamic>? stremioItem = {
          'id': stremioItemId,
          '_addonBaseUrl': stremioAddonBase,
          'type': item['stremioType'] ?? (season != null ? 'series' : 'movie'),
          'name': title,
        };
        
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DetailsScreen(
                movie: movie,
                stremioItem: stremioItem,
                initialSeason: season,
                initialEpisode: episode,
              ),
            ),
          );
        }
      } else {
        // Regular content -> open DetailsScreen (torrent mode)
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DetailsScreen(
                movie: movie,
                initialSeason: season,
                initialEpisode: episode,
              ),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: WatchHistoryService().historyStream,
      initialData: WatchHistoryService().current,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) return const SizedBox.shrink();
        // Deduplicate by tmdbId for shows — keep only the latest episode per show
        final raw = snapshot.data!;
        final seen = <dynamic>{};
        final history = <Map<String, dynamic>>[];
        for (final item in raw) {
          final key = (item['mediaType'] == 'tv' || item['season'] != null)
              ? item['tmdbId']
              : item['uniqueId'];
          if (seen.add(key)) history.add(item);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.play_circle_outline_rounded, color: AppTheme.primaryColor, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Continue Watching", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                        const SizedBox(height: 4),
                        Container(
                          height: 2.5,
                          width: 36,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            gradient: LinearGradient(
                              colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.0)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (history.isNotEmpty) ...[
                    GestureDetector(
                      onTap: _scrollLeft,
                      child: _buildCWSectionArrow(Icons.arrow_back_ios_new_rounded),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _scrollRight,
                      child: _buildCWSectionArrow(Icons.arrow_forward_ios_rounded),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              height: MediaQuery.of(context).orientation == Orientation.landscape ? 140 : 175,
              child: ListView.separated(
                clipBehavior: Clip.none,
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: history.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final historyItem = history[index];
                  final itemId = historyItem['uniqueId'] as String;
                  return _HistoryCard(
                    item: historyItem,
                    onTap: () => _resumePlayback(historyItem),
                    onRemove: () => _removeItem(historyItem),
                    onInfo: () => _openHistoryItemDetails(historyItem),
                    isLoading: _loadingItemId == itemId,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget _buildCWPlayButton() {
  final inner = Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.primaryColor.withValues(alpha: 0.7),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      boxShadow: AppTheme.isLightMode
          ? null
          : [BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 2)],
    ),
    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
  );
  if (AppTheme.isLightMode) return inner;
  return ClipRRect(
    borderRadius: BorderRadius.circular(30),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: inner,
    ),
  );
}

class _HistoryCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onInfo;
  final bool isLoading;

  const _HistoryCard({
    required this.item,
    required this.onTap,
    required this.onRemove,
    required this.onInfo,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final posterPath = item['posterPath'] as String;
    final title = item['title'] as String;
    final season = item['season'] as int?;
    final episode = item['episode'] as int?;
    final episodeTitle = item['episodeTitle'] as String?;
    final position = item['position'] as int;
    final duration = item['duration'] as int;
    
    final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final remaining = duration > 0 ? Duration(milliseconds: duration - position) : Duration.zero;
    final remainingText = remaining.inMinutes > 0 ? '${remaining.inMinutes}m left' : '';
    final imageUrl = posterPath.isNotEmpty
        ? (posterPath.startsWith('http') ? posterPath : TmdbApi.getImageUrl(posterPath))
        : '';
    
    final subtitle = season != null 
        ? 'S$season E$episode${episodeTitle != null && episodeTitle.isNotEmpty ? ' • $episodeTitle' : ''}'
        : '';

    return FocusableControl(
      onTap: isLoading ? () {} : onTap,
      borderRadius: 14,
      scaleOnFocus: 1.05,
      child: Container(
        width: 280,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
          boxShadow: AppTheme.isLightMode ? null : [
            BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(0, 6)),
            BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.06), blurRadius: 24, spreadRadius: -4),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Full bleed poster image
            if (imageUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                placeholder: (c, u) => Container(color: AppTheme.bgCard),
              )
            else
              Container(color: AppTheme.bgCard, child: const Icon(Icons.movie, color: Colors.white24, size: 40)),
            
            // Dark overlay gradient
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.1),
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.85),
                    Colors.black.withValues(alpha: 0.95),
                  ],
                  stops: const [0.0, 0.3, 0.7, 1.0],
                ),
              ),
            ),

            // Play button (center)
            Center(
              child: _buildCWPlayButton(),
            ),

            // Top-right actions
            Positioned(
              top: 6, right: 6,
              child: Column(
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: onRemove,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                        child: const Icon(Icons.close_rounded, color: Colors.white70, size: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: onInfo,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                        child: const Icon(Icons.info_outline_rounded, color: Colors.white70, size: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Bottom content: title + episode + progress
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        if (subtitle.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                            ),
                          ),
                        if (remainingText.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              remainingText,
                              style: TextStyle(color: AppTheme.primaryColor.withValues(alpha: 0.8), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Progress bar
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.white.withValues(alpha: 0.1),
                      color: AppTheme.primaryColor,
                      minHeight: 3,
                    ),
                  ),
                ],
              ),
            ),
            
            if (isLoading)
               Container(
                 decoration: BoxDecoration(
                   color: Colors.black.withValues(alpha: 0.6),
                   borderRadius: BorderRadius.circular(14),
                 ),
                 child: const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
               ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  STREMIO ADDON CATALOG SECTION
// ═══════════════════════════════════════════════════════════════════════════════

class _StremioCatalogSection extends StatefulWidget {
  final Map<String, dynamic> catalog;
  final List<Map<String, dynamic>> items;
  final Function(Map<String, dynamic>) onItemTap;
  final VoidCallback onShowAll;

  const _StremioCatalogSection({
    required this.catalog,
    required this.items,
    required this.onItemTap,
    required this.onShowAll,
  });

  @override
  State<_StremioCatalogSection> createState() => _StremioCatalogSectionState();
}

class _StremioCatalogSectionState extends State<_StremioCatalogSection> {
  final ScrollController _scrollController = ScrollController();

  void _scrollLeft() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.offset - 600,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _scrollRight() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.offset + 600,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _wrapFrosted({required double borderRadius, required Widget child}) {
    if (AppTheme.isLightMode) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: child,
      ),
    );
  }

  Widget _buildStremioArrow(IconData icon) {
    final inner = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.12 : 0.08),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.6), size: 14),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: inner,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.catalog;
    final addonName = cat['addonName'] as String;
    final catalogName = cat['catalogName'] as String;
    final addonIcon = (cat['addonIcon'] ?? '').toString();
    final isDesktop = MediaQuery.of(context).size.width > 900;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 14),
          child: Row(
            children: [
              if (addonIcon.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CachedNetworkImage(
                      imageUrl: addonIcon,
                      width: 20, height: 20,
                      errorWidget: (_, _, _) => const Icon(Icons.extension, size: 20, color: AppTheme.primaryColor),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.extension_rounded, color: AppTheme.primaryColor, size: 18),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      catalogName,
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      addonName,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: 2.5,
                      width: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.0)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              FocusableControl(
                onTap: widget.onShowAll,
                borderRadius: 20,
                child: _wrapFrosted(
                  borderRadius: 20,
                  child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Colors.white.withValues(alpha: 0.08),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Show All', style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward_ios, size: 11, color: Colors.white.withValues(alpha: 0.6)),
                        ],
                      ),
                  ),
                ),
              ),
              if (isDesktop) ...[
                const SizedBox(width: 10),
              ],
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _scrollLeft,
                child: _buildStremioArrow(Icons.arrow_back_ios_new_rounded),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _scrollRight,
                child: _buildStremioArrow(Icons.arrow_forward_ios_rounded),
              ),
            ],
          ),
        ),
        SizedBox(
          height: isDesktop ? 240 : 200,
          child: ListView.separated(
            clipBehavior: Clip.none,
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: widget.items.length.clamp(0, 20),
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return _StremioCatalogCard(
                item: item,
                onTap: () => widget.onItemTap(item),
                height: isDesktop ? 240 : 200,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _StremioCatalogCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final double height;

  const _StremioCatalogCard({required this.item, required this.onTap, this.height = 200});

  @override
  Widget build(BuildContext context) {
    final poster = item['poster']?.toString() ?? '';
    final name = item['name']?.toString() ?? 'Unknown';
    final rating = item['imdbRating']?.toString() ?? '';
    final shape = item['posterShape']?.toString() ?? 'poster';

    final double width;
    if (shape == 'landscape') {
      width = height * (16 / 9);
    } else if (shape == 'square') {
      width = height;
    } else {
      width = height * (2 / 3);
    }

    return FocusableControl(
      onTap: onTap,
      borderRadius: 14,
      scaleOnFocus: 1.05,
      child: Container(
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
          boxShadow: AppTheme.isLightMode ? null : [
            BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(0, 6)),
            BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.05), blurRadius: 20, spreadRadius: -4),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (poster.isNotEmpty)
              CachedNetworkImage(
                imageUrl: poster,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: AppTheme.bgCard),
                errorWidget: (_, _, _) => Container(
                  color: AppTheme.bgCard,
                  child: Center(child: Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.white38))),
                ),
              )
            else
              Center(child: Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.white38))),

            // Improved gradient
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.7),
                    Colors.black.withValues(alpha: 0.95),
                  ],
                  stops: const [0.0, 0.4, 0.75, 1.0],
                ),
              ),
            ),

            // Rating badge — frosted glass
            if (rating.isNotEmpty)
              Positioned(
                top: 8, right: 8,
                child: _buildRatingBadgeText(rating),
              ),

            // Name
            Positioned(
              bottom: 10, left: 10, right: 10,
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, height: 1.2),
              ),
            ),

            // My List button
            Positioned(
              top: 8, left: 8,
              child: _MyListButton.stremio(stremioItem: item),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared My List add/remove button used on movie & stremio cards
// ─────────────────────────────────────────────────────────────────────────────

class _MyListButton extends StatelessWidget {
  final Movie? movie;
  final Map<String, dynamic>? stremioItem;

  const _MyListButton.movie({required Movie this.movie}) : stremioItem = null;
  const _MyListButton.stremio({required Map<String, dynamic> this.stremioItem}) : movie = null;

  String get _uniqueId {
    if (movie != null) return MyListService.movieId(movie!.id, movie!.mediaType);
    return MyListService.stremioItemId(stremioItem!);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: MyListService.changeNotifier,
      builder: (context, _, _) {
        final inList = MyListService().contains(_uniqueId);
        return GestureDetector(
          onTap: () async {
            if (movie != null) {
              final added = await MyListService().toggleMovie(
                tmdbId: movie!.id,
                imdbId: movie!.imdbId,
                title: movie!.title,
                posterPath: movie!.posterPath,
                mediaType: movie!.mediaType,
                voteAverage: movie!.voteAverage,
                releaseDate: movie!.releaseDate,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(added ? 'Added to My List' : 'Removed from My List'),
                  duration: const Duration(seconds: 1),
                ));
              }
            } else if (stremioItem != null) {
              final added = await MyListService().toggleStremioItem(stremioItem!);
              if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(added ? 'Added to My List' : 'Removed from My List'),
                  duration: const Duration(seconds: 1),
                ));
              }
            }
          },
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
            ),
            child: Icon(
              inList ? Icons.bookmark_rounded : Icons.add_rounded,
              size: 16,
              color: inList ? AppTheme.primaryColor : Colors.white70,
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AMBIENT BACKDROP — animated color blobs derived from current hero poster
// ═══════════════════════════════════════════════════════════════════════════════

class _AmbientBackdrop extends StatelessWidget {
  final Color primary;
  final Color secondary;
  const _AmbientBackdrop({required this.primary, required this.secondary});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeOutCubic,
      builder: (context, _, _) {
        // The TweenAnimationBuilder's value is unused — the AnimatedContainer
        // children below crossfade their own colors. The outer tween simply
        // forces a rebuild when colors change so the children re-animate.
        return Stack(
          children: [
            // Top-right vibrant blob
            Positioned(
              top: -120,
              right: -120,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 1400),
                curve: Curves.easeOutCubic,
                width: 520,
                height: 520,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      primary.withValues(alpha: 0.40),
                      primary.withValues(alpha: 0.14),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
            // Bottom-left dominant blob
            Positioned(
              top: MediaQuery.of(context).size.height * 0.55,
              left: -150,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 1400),
                curve: Curves.easeOutCubic,
                width: 480,
                height: 480,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      secondary.withValues(alpha: 0.30),
                      secondary.withValues(alpha: 0.10),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
            // Mid-right subtle accent
            Positioned(
              top: MediaQuery.of(context).size.height * 1.4,
              right: -60,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 1400),
                curve: Curves.easeOutCubic,
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      primary.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // Soft veil so it never overpowers content
            Positioned.fill(
              child: Container(color: AppTheme.bgDark.withValues(alpha: 0.35)),
            ),
          ],
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  STATS STRIP — animated counters from local watch history
// ═══════════════════════════════════════════════════════════════════════════════

class _StatsStrip extends StatelessWidget {
  const _StatsStrip();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: MyListService.changeNotifier,
      builder: (context, _, _) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: WatchHistoryService().historyStream,
          initialData: WatchHistoryService().current,
          builder: (context, snapshot) {
            final history = snapshot.data ?? const <Map<String, dynamic>>[];
            final myListCount = MyListService().items.length;
            if (history.isEmpty && myListCount == 0) return const SizedBox.shrink();

            // Compute stats
            final now = DateTime.now();
            int inProgress = 0;
            Duration remaining = Duration.zero;
            final activeDays = <String>{};

            for (final item in history) {
              final pos = (item['position'] as int?) ?? 0;
              final dur = (item['duration'] as int?) ?? 0;
              if (dur > 0) {
                final progress = pos / dur;
                if (progress > 0.02 && progress < 0.9) {
                  inProgress++;
                  // Sum the time still left to watch on in-progress items.
                  remaining += Duration(milliseconds: dur - pos);
                }
              }
              final tsRaw = item['updatedAt'];
              if (tsRaw is int) {
                final dt = DateTime.fromMillisecondsSinceEpoch(tsRaw);
                activeDays.add('${dt.year}-${dt.month}-${dt.day}');
              }
            }

            // Streak: consecutive days back from today with at least one play
            int streak = 0;
            for (var i = 0; i < 60; i++) {
              final d = now.subtract(Duration(days: i));
              final key = '${d.year}-${d.month}-${d.day}';
              if (activeDays.contains(key)) {
                streak++;
              } else if (i > 0) {
                break;
              }
            }

            final hours = remaining.inMinutes / 60.0;
            final hoursLabel = hours >= 10
                ? hours.toStringAsFixed(0)
                : hours.toStringAsFixed(1);

            final tiles = <_StatTileData>[
              _StatTileData(
                icon: Icons.bookmark_rounded,
                label: 'My List',
                value: '$myListCount',
                tint: AppTheme.primaryColor,
              ),
              _StatTileData(
                icon: Icons.play_circle_outline_rounded,
                label: 'In progress',
                value: '$inProgress',
                tint: const Color(0xFF60A5FA),
              ),
              _StatTileData(
                icon: Icons.timer_outlined,
                label: 'Hours left',
                value: hoursLabel,
                tint: const Color(0xFF34D399),
              ),
              _StatTileData(
                icon: Icons.local_fire_department_rounded,
                label: 'Day streak',
                value: '$streak',
                tint: const Color(0xFFF97316),
              ),
            ];

            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 4),
              child: SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: tiles.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => _StatTile(data: tiles[i]),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _StatTileData {
  final IconData icon;
  final String label;
  final String value;
  final Color tint;
  _StatTileData({required this.icon, required this.label, required this.value, required this.tint});
}

class _StatTile extends StatelessWidget {
  final _StatTileData data;
  const _StatTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final inner = Container(
      width: 168,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.06 : 0.04),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: data.tint.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(data.icon, size: 14, color: data.tint),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  data.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: double.tryParse(data.value) ?? 0),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) {
              final isInt = !data.value.contains('.');
              final shown = isInt ? v.round().toString() : v.toStringAsFixed(1);
              return Text(
                shown,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                  height: 1.0,
                ),
              );
            },
          ),
        ],
      ),
    );
    if (AppTheme.isLightMode) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: inner,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CONTINUE WATCHING HERO — wide cinematic card for the most recent item
// ═══════════════════════════════════════════════════════════════════════════════

class _ContinueWatchingHero extends StatefulWidget {
  final Function(Movie) onOpen;
  const _ContinueWatchingHero({required this.onOpen});

  @override
  State<_ContinueWatchingHero> createState() => _ContinueWatchingHeroState();
}

class _ContinueWatchingHeroState extends State<_ContinueWatchingHero> {
  String? _backdropPath;
  int? _lastTmdbId;

  Future<void> _loadBackdrop(int tmdbId, String mediaType) async {
    if (_lastTmdbId == tmdbId && _backdropPath != null) return;
    _lastTmdbId = tmdbId;
    try {
      final m = mediaType == 'tv'
          ? await TmdbApi().getTvDetails(tmdbId)
          : await TmdbApi().getMovieDetails(tmdbId);
      if (!mounted) return;
      setState(() => _backdropPath = m.backdropPath);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: WatchHistoryService().historyStream,
      initialData: WatchHistoryService().current,
      builder: (context, snapshot) {
        final list = snapshot.data ?? const <Map<String, dynamic>>[];
        if (list.isEmpty) return const SizedBox.shrink();
        final item = list.first;

        final tmdbId = item['tmdbId'] as int?;
        final mediaType = (item['mediaType'] as String?) ??
            (item['season'] != null ? 'tv' : 'movie');
        if (tmdbId != null) _loadBackdrop(tmdbId, mediaType);

        final title = (item['title'] as String?) ?? '';
        final posterPath = (item['posterPath'] as String?) ?? '';
        final season = item['season'] as int?;
        final episode = item['episode'] as int?;
        final episodeTitle = (item['episodeTitle'] as String?) ?? '';
        final position = (item['position'] as int?) ?? 0;
        final duration = (item['duration'] as int?) ?? 0;
        final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
        final remaining = duration > 0 ? Duration(milliseconds: duration - position) : Duration.zero;
        final remainingText = remaining.inMinutes > 0 ? '${remaining.inMinutes}m left' : '';

        final subtitle = season != null
            ? 'S$season · E$episode${episodeTitle.isNotEmpty ? '  ·  $episodeTitle' : ''}'
            : (mediaType == 'movie' ? 'Movie' : 'Series');

        // Background image: prefer fetched landscape backdrop, fall back to poster
        String bgUrl = '';
        bool bgIsPoster = false;
        if (_backdropPath != null && _backdropPath!.isNotEmpty) {
          bgUrl = TmdbApi.getBackdropUrl(_backdropPath!);
        } else if (posterPath.isNotEmpty) {
          bgUrl = posterPath.startsWith('http')
              ? posterPath
              : TmdbApi.getImageUrl(posterPath);
          bgIsPoster = true;
        }

        return LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          final isWide = w > 700;
          // Scale height with width so wide screens don't crop the backdrop to a sliver.
          // Backdrops are 16:9, so a ~3:1 card ratio still feels cinematic without
          // chopping the visually interesting middle of the image away.
          final cardHeight = (w / (isWide ? 3.4 : 2.6)).clamp(190.0, 320.0);

          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  if (tmdbId == null) return;
                  final movie = Movie(
                    id: tmdbId,
                    title: title,
                    posterPath: posterPath,
                    backdropPath: _backdropPath ?? '',
                    voteAverage: 0,
                    releaseDate: '',
                    overview: '',
                    mediaType: mediaType,
                    imdbId: item['imdbId'] as String?,
                  );
                  widget.onOpen(movie);
                },
                child: Container(
                  height: cardHeight,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: AppTheme.bgCard,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                    boxShadow: AppTheme.isLightMode
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.45),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (bgUrl.isNotEmpty) ...[
                        // Blurred fill behind so portrait posters never look cropped to a sliver
                        if (bgIsPoster)
                          ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                            child: CachedNetworkImage(
                              imageUrl: bgUrl,
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                              placeholder: (_, _) => Container(color: AppTheme.bgCard),
                              errorWidget: (_, _, _) => Container(color: AppTheme.bgCard),
                            ),
                          ),
                        // Foreground image — centered, contain for portrait so we see the
                        // whole poster; cover for landscape so the card fills edge-to-edge.
                        CachedNetworkImage(
                          imageUrl: bgUrl,
                          fit: bgIsPoster ? BoxFit.contain : BoxFit.cover,
                          alignment: bgIsPoster
                              ? Alignment.centerRight
                              : const Alignment(0, -0.1),
                          placeholder: (_, _) => Container(color: AppTheme.bgCard),
                          errorWidget: (_, _, _) => Container(color: AppTheme.bgCard),
                        ),
                      ],
                      // Left-to-right gradient for text legibility — lighter on the right
                      // so more of the backdrop image stays visible.
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Colors.black.withValues(alpha: 0.78),
                              Colors.black.withValues(alpha: 0.35),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.5, 0.95],
                          ),
                        ),
                      ),
                      // Bottom gradient for the progress bar zone
                      Positioned(
                        left: 0, right: 0, bottom: 0,
                        height: 80,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.7),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Content
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Tag
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryColor.withValues(alpha: 0.22),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.4)),
                              ),
                              child: const Text(
                                'CONTINUE WATCHING',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: w * 0.7),
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: isWide ? 26 : 21,
                                  fontWeight: FontWeight.w900,
                                  height: 1.05,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.play_arrow_rounded, color: Colors.black, size: 22),
                                      SizedBox(width: 4),
                                      Text(
                                        'Resume',
                                        style: TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (remainingText.isNotEmpty)
                                  Text(
                                    remainingText,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.75),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            // Progress bar
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 4,
                                backgroundColor: Colors.white.withValues(alpha: 0.18),
                                valueColor: const AlwaysStoppedAnimation(AppTheme.primaryColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MOSAIC SPOTLIGHT — 1 big featured tile + 4 smaller tiles in a grid
// ═══════════════════════════════════════════════════════════════════════════════

class _MosaicSpotlight extends StatelessWidget {
  final Future<List<Movie>> future;
  final Function(Movie) onTap;

  const _MosaicSpotlight({required this.future, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Movie>>(
      future: future,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.length < 5) {
          return const SizedBox.shrink();
        }
        final movies = snapshot.data!;
        final featured = movies.first;
        final small = movies.skip(1).take(4).toList();

        return LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          final isWide = w > 720;
          // Adaptive horizontal padding so mobile gets more breathing room.
          final hPad = w < 380 ? 14.0 : (w < 520 ? 18.0 : 24.0);
          final headerTopPad = w < 380 ? 24.0 : 36.0;
          final headerBotPad = w < 380 ? 12.0 : 16.0;

          final header = Padding(
            padding: EdgeInsets.fromLTRB(hPad, headerTopPad, hPad, headerBotPad),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.auto_awesome_rounded, color: AppTheme.primaryColor, size: 18),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Spotlight',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                if (w >= 380)
                  Text(
                    '${movies.take(5).length} trending now',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          );

          if (isWide) {
            // Side-by-side: big tile left, 2x2 grid right
            final featuredW = (w - hPad * 2 - 14) * 0.58;
            final smallW = (w - hPad * 2 - 14) * 0.42;
            final tileH = featuredW * 0.58;
            final smallTileH = (tileH - 12) / 2;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: hPad),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: featuredW,
                        height: tileH,
                        child: _MosaicTile(movie: featured, onTap: () => onTap(featured), big: true),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: smallW,
                        height: tileH,
                        child: GridView.count(
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: (smallW / 2 - 6) / smallTileH,
                          children: small
                              .map((m) => _MosaicTile(movie: m, onTap: () => onTap(m)))
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          // Stacked: big tile on top, horizontal scroll of small below
          // Sizes scale to viewport so phones look right.
          final featuredAvail = w - hPad * 2;
          final featuredH = (featuredAvail * 0.56).clamp(170.0, 320.0);
          // Small tile width: ~62% of viewport on tiny phones (peek of next),
          // capped so tablets in narrow mode don't get giant tiles.
          final smallTileW = w < 380
              ? (w * 0.62).clamp(180.0, 240.0)
              : (w < 520 ? 200.0 : 220.0);
          final smallTileH = w < 380 ? 110.0 : 130.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              Padding(
                padding: EdgeInsets.symmetric(horizontal: hPad),
                child: SizedBox(
                  height: featuredH,
                  child: _MosaicTile(movie: featured, onTap: () => onTap(featured), big: true),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: smallTileH,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(horizontal: hPad),
                  itemCount: small.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => SizedBox(
                    width: smallTileW,
                    child: _MosaicTile(movie: small[i], onTap: () => onTap(small[i])),
                  ),
                ),
              ),
            ],
          );
        });
      },
    );
  }
}

class _MosaicTile extends StatelessWidget {
  final Movie movie;
  final VoidCallback onTap;
  final bool big;
  const _MosaicTile({required this.movie, required this.onTap, this.big = false});

  @override
  Widget build(BuildContext context) {
    final imageUrl = movie.backdropPath.isNotEmpty
        ? TmdbApi.getBackdropUrl(movie.backdropPath)
        : (movie.posterPath.isNotEmpty ? TmdbApi.getImageUrl(movie.posterPath) : '');

    return FocusableControl(
      onTap: onTap,
      borderRadius: 16,
      scaleOnFocus: 1.04,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          boxShadow: AppTheme.isLightMode
              ? null
              : [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8)),
                ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: AppTheme.bgCard),
                errorWidget: (_, _, _) => Container(color: AppTheme.bgCard),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.25),
                    Colors.black.withValues(alpha: 0.85),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
            if (big)
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  child: const Text(
                    '#1 TRENDING',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
            if (movie.voteAverage > 0)
              Positioned(
                top: 10,
                right: 10,
                child: _buildRatingBadge(movie.voteAverage),
              ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    movie.title,
                    maxLines: big ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: big ? 20 : 14,
                      height: 1.1,
                      letterSpacing: -0.3,
                      shadows: AppTheme.isLightMode
                          ? null
                          : const [Shadow(color: Colors.black54, blurRadius: 8)],
                    ),
                  ),
                  if (big && movie.overview.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      movie.overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  TRENDING TICKER — auto-scrolling marquee with rank numbers
// ═══════════════════════════════════════════════════════════════════════════════

class _TrendingTicker extends StatefulWidget {
  final Future<List<Movie>> future;
  final Function(Movie) onTap;
  const _TrendingTicker({required this.future, required this.onTap});

  @override
  State<_TrendingTicker> createState() => _TrendingTickerState();
}

class _TrendingTickerState extends State<_TrendingTicker> {
  final ScrollController _ctrl = ScrollController();
  Timer? _timer;
  bool _userScrolling = false;
  Timer? _resumeTimer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_ctrl.hasClients || _userScrolling) return;
      final pos = _ctrl.position;
      final next = pos.pixels + 0.5;
      if (next >= pos.maxScrollExtent - 1) {
        _ctrl.jumpTo(0);
      } else {
        _ctrl.jumpTo(next);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _resumeTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _pause() {
    _userScrolling = true;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _userScrolling = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Movie>>(
      future: widget.future,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) return const SizedBox.shrink();
        final list = snapshot.data!.take(10).toList();
        // Repeat list to give marquee breathing room
        final loop = [...list, ...list];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.local_fire_department_rounded, color: AppTheme.primaryColor, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Top 10 Right Now',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(color: Color(0xFFEF4444), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 110,
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is ScrollStartNotification && n.dragDetails != null) _pause();
                  return false;
                },
                child: ListView.separated(
                  controller: _ctrl,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: loop.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final movie = loop[i];
                    final rank = (i % list.length) + 1;
                    return _TickerItem(
                      movie: movie,
                      rank: rank,
                      onTap: () => widget.onTap(movie),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TickerItem extends StatelessWidget {
  final Movie movie;
  final int rank;
  final VoidCallback onTap;
  const _TickerItem({required this.movie, required this.rank, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final imageUrl = movie.posterPath.isNotEmpty ? TmdbApi.getImageUrl(movie.posterPath) : '';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Big stroked rank number
            SizedBox(
              width: 60,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 80,
                  height: 1.0,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -6,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 2
                    ..color = (rank <= 3
                        ? AppTheme.primaryColor.withValues(alpha: 0.7)
                        : Colors.white.withValues(alpha: 0.18)),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              width: 70,
              height: 100,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppTheme.bgCard,
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: imageUrl.isNotEmpty
                  ? CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  TONIGHT'S PICK — randomized hand-feeling recommendation card
// ═══════════════════════════════════════════════════════════════════════════════

class _TonightsPickCard extends StatelessWidget {
  final Movie movie;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  const _TonightsPickCard({required this.movie, required this.onPlay, required this.onShuffle});

  @override
  Widget build(BuildContext context) {
    final hasBackdrop = movie.backdropPath.isNotEmpty;
    final imageUrl = hasBackdrop
        ? TmdbApi.getBackdropUrl(movie.backdropPath)
        : (movie.posterPath.isNotEmpty ? TmdbApi.getImageUrl(movie.posterPath) : '');
    final bgIsPoster = !hasBackdrop && imageUrl.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.nights_stay_rounded, color: AppTheme.primaryColor, size: 18),
                ),
                const SizedBox(width: 10),
                const Text(
                  "Tonight's Pick",
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                ),
                const Spacer(),
                Material(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: onShuffle,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shuffle_rounded, size: 14, color: Colors.white.withValues(alpha: 0.7)),
                          const SizedBox(width: 6),
                          Text(
                            'Shuffle',
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            final isWide = w > 700;
            // Scale with width so the 16:9 backdrop has room to actually breathe.
            // Cap so very large screens don't get a wall of poster.
            final cardHeight = (w / (isWide ? 2.6 : 1.9)).clamp(260.0, 420.0);

            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onPlay,
                child: Container(
                  height: cardHeight,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                    boxShadow: AppTheme.isLightMode
                        ? null
                        : [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 10)),
                            BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.10), blurRadius: 32, spreadRadius: -8),
                          ],
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (imageUrl.isNotEmpty) ...[
                        // Blurred fill so portrait-poster fallbacks don't look cropped to a sliver
                        if (bgIsPoster)
                          ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                            child: CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover),
                          ),
                        CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: bgIsPoster ? BoxFit.contain : BoxFit.cover,
                          // Pull the focal point slightly above center \u2014 backdrops
                          // usually frame faces in the upper third, and our text
                          // overlays the bottom third.
                          alignment: bgIsPoster
                              ? Alignment.topRight
                              : const Alignment(0, -0.15),
                        ),
                      ],
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomLeft,
                            end: Alignment.topRight,
                            colors: [
                              Colors.black.withValues(alpha: 0.92),
                              Colors.black.withValues(alpha: 0.55),
                              Colors.black.withValues(alpha: 0.10),
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Row(
                              children: [
                                if (movie.voteAverage > 0) ...[
                                  Icon(Icons.star_rounded, size: 16, color: Colors.amber.withValues(alpha: 0.9)),
                                  const SizedBox(width: 4),
                                  Text(
                                    movie.voteAverage.toStringAsFixed(1),
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                if (movie.releaseDate.isNotEmpty)
                                  Text(
                                    movie.releaseDate.split('-').first,
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13, fontWeight: FontWeight.w500),
                                  ),
                                if (movie.genres.isNotEmpty) ...[
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: Text(
                                      movie.genres.take(2).join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              movie.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: isWide ? 28 : 22,
                                fontWeight: FontWeight.w900,
                                height: 1.05,
                                letterSpacing: -0.5,
                              ),
                            ),
                            if (movie.overview.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: w * 0.85),
                                child: Text(
                                  movie.overview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    fontSize: 13,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow_rounded, color: Colors.black, size: 22),
                                  SizedBox(width: 4),
                                  Text(
                                    'Play Now',
                                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MOOD SECTION — chip filter + result row
// ═══════════════════════════════════════════════════════════════════════════════

class _MoodSection extends StatefulWidget {
  final List<({String id, String label, IconData icon, List<int> genres})> moods;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final Future<List<Movie>>? future;
  final Function(Movie) onMovieTap;

  const _MoodSection({
    required this.moods,
    required this.selectedId,
    required this.onSelect,
    required this.future,
    required this.onMovieTap,
  });

  @override
  State<_MoodSection> createState() => _MoodSectionState();
}

class _MoodSectionState extends State<_MoodSection> {
  final ScrollController _resultsCtrl = ScrollController();

  void _scrollResults(double delta) {
    if (!_resultsCtrl.hasClients) return;
    final target = (_resultsCtrl.offset + delta)
        .clamp(0.0, _resultsCtrl.position.maxScrollExtent);
    _resultsCtrl.animateTo(target,
        duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _resultsCtrl.dispose();
    super.dispose();
  }

  Widget _arrow(IconData icon, VoidCallback onTap) {
    final inner = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.12 : 0.08),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.6), size: 14),
    );
    final wrapped = AppTheme.isLightMode
        ? inner
        : ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: inner,
            ),
          );
    return GestureDetector(onTap: onTap, child: wrapped);
  }

  @override
  Widget build(BuildContext context) {
    final moods = widget.moods;
    final selectedId = widget.selectedId;
    final onSelect = widget.onSelect;
    final future = widget.future;
    final onMovieTap = widget.onMovieTap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.mood_rounded, color: AppTheme.primaryColor, size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  "What's your mood?",
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                ),
              ),
              _arrow(Icons.arrow_back_ios_new_rounded, () => _scrollResults(-600)),
              const SizedBox(width: 6),
              _arrow(Icons.arrow_forward_ios_rounded, () => _scrollResults(600)),
            ],
          ),
        ),
        // Chip strip
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: moods.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final m = moods[i];
              final isSelected = m.id == selectedId;
              return Material(
                color: isSelected
                    ? AppTheme.primaryColor.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => onSelect(m.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.primaryColor.withValues(alpha: 0.7)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          m.icon,
                          size: 14,
                          color: isSelected
                              ? AppTheme.primaryColor
                              : Colors.white.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          m.label,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.75),
                            fontSize: 12.5,
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        // Results row
        FutureBuilder<List<Movie>>(
          future: future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return SizedBox(
                height: 230,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: 5,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, _) => Container(
                    width: 150,
                    decoration: BoxDecoration(
                      color: AppTheme.bgCard,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              );
            }
            final movies = snap.data!;
            if (movies.isEmpty) {
              return SizedBox(
                height: 80,
                child: Center(
                  child: Text(
                    'No matches for this mood',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13),
                  ),
                ),
              );
            }
            return SizedBox(
              height: 290,
              child: ListView.separated(
                clipBehavior: Clip.none,
                controller: _resultsCtrl,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: movies.length.clamp(0, 20),
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, i) => _MovieCard(
                  movie: movies[i],
                  onTap: () => onMovieTap(movies[i]),
                  isPortrait: true,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BECAUSE YOU WATCHED — BestSimilar.com recommendations seeded from CW history
// ═══════════════════════════════════════════════════════════════════════════════

class _BecauseYouWatchedSection extends StatefulWidget {
  final String seedTitle;
  final String seedPosterPath;
  final Future<List<Movie>> future;
  final Function(Movie) onMovieTap;
  final VoidCallback? onShuffle;

  const _BecauseYouWatchedSection({
    required this.seedTitle,
    required this.seedPosterPath,
    required this.future,
    required this.onMovieTap,
    required this.onShuffle,
  });

  @override
  State<_BecauseYouWatchedSection> createState() => _BecauseYouWatchedSectionState();
}

class _BecauseYouWatchedSectionState extends State<_BecauseYouWatchedSection> {
  final ScrollController _ctrl = ScrollController();

  void _scroll(double delta) {
    if (!_ctrl.hasClients) return;
    final target =
        (_ctrl.offset + delta).clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(target,
        duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _frostedAction(IconData icon, VoidCallback? onTap, {String? tooltip}) {
    if (onTap == null) return const SizedBox.shrink();
    final inner = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: AppTheme.isLightMode ? 0.12 : 0.08),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Icon(icon, color: Colors.white.withValues(alpha: 0.6), size: 14),
    );
    final wrapped = AppTheme.isLightMode
        ? inner
        : ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: inner,
            ),
          );
    final tappable = GestureDetector(onTap: onTap, child: wrapped);
    return tooltip != null ? Tooltip(message: tooltip, child: tappable) : tappable;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Movie>>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          // Quiet placeholder; the section just hides until ready below.
          return const SizedBox(height: 0);
        }
        final movies = snap.data ?? const <Movie>[];
        if (movies.isEmpty) return const SizedBox.shrink();

        final posterUrl = widget.seedPosterPath.isNotEmpty
            ? TmdbApi.getImageUrl(widget.seedPosterPath)
            : '';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with mini seed poster + "Because you watched <title>"
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Glowing mini-poster of the seed
                  Container(
                    width: 36,
                    height: 50,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: AppTheme.bgCard,
                      border: Border.all(
                        color: AppTheme.primaryColor.withValues(alpha: 0.5),
                        width: 1.2,
                      ),
                      boxShadow: AppTheme.isLightMode
                          ? null
                          : [
                              BoxShadow(
                                color: AppTheme.primaryColor.withValues(alpha: 0.35),
                                blurRadius: 12,
                                spreadRadius: -2,
                              ),
                            ],
                    ),
                    child: posterUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: posterUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => Container(color: AppTheme.bgCard),
                            errorWidget: (_, _, _) =>
                                Container(color: AppTheme.bgCard),
                          )
                        : const Icon(Icons.movie_outlined,
                            color: Colors.white38, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Because you watched',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.seedTitle.isEmpty ? 'recently' : widget.seedTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 2.5,
                          width: 36,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            gradient: LinearGradient(
                              colors: [
                                AppTheme.primaryColor,
                                AppTheme.primaryColor.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _frostedAction(Icons.shuffle_rounded, widget.onShuffle,
                      tooltip: 'Pick a different show'),
                  if (widget.onShuffle != null) const SizedBox(width: 6),
                  _frostedAction(
                      Icons.arrow_back_ios_new_rounded, () => _scroll(-600)),
                  const SizedBox(width: 6),
                  _frostedAction(
                      Icons.arrow_forward_ios_rounded, () => _scroll(600)),
                ],
              ),
            ),
            SizedBox(
              height: 290,
              child: ListView.separated(
                clipBehavior: Clip.none,
                controller: _ctrl,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: movies.length.clamp(0, 25),
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, i) => _MovieCard(
                  movie: movies[i],
                  onTap: () => widget.onMovieTap(movies[i]),
                  isPortrait: true,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
