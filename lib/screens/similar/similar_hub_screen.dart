// "Similar" hub — soothing landing screen.
//
// Layout:
//   • Liquid blob backdrop (animated CustomPainter)
//   • Big rounded glass search bar
//   • Filter chips: All / Movies / TV
//   • TMDB search results grid (debounced 280ms)
//   • Trending fallback when search is empty
//
// Tapping a result fetches BestSimilar → SimilarResultsScreen.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/bestsimilar_scraper.dart';
import '../../api/tmdb_api.dart';
import '../../models/movie.dart';
import 'similar_results_screen.dart';

enum _MediaFilter { all, movies, tv }

class SimilarHubScreen extends StatefulWidget {
  const SimilarHubScreen({super.key});

  @override
  State<SimilarHubScreen> createState() => _SimilarHubScreenState();
}

class _SimilarHubScreenState extends State<SimilarHubScreen>
    with SingleTickerProviderStateMixin {
  final _api = TmdbApi();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  late final AnimationController _blobCtrl;

  Timer? _debounce;
  String _query = '';
  _MediaFilter _filter = _MediaFilter.all;

  bool _loading = false;
  List<Movie> _results = const [];
  List<Movie> _trending = const [];

  // For inline progress when user taps a card.
  int? _resolvingId;

  @override
  void initState() {
    super.initState();
    _blobCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
    _loadTrending();
  }

  @override
  void dispose() {
    _blobCtrl.dispose();
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadTrending() async {
    try {
      final m = await _api.getTrending();
      if (mounted) setState(() => _trending = m);
    } catch (_) {}
  }

  void _onQueryChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () {
      _runSearch(v.trim());
    });
  }

  Future<void> _runSearch(String q) async {
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _query = '';
          _results = const [];
          _loading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _query = q;
        _loading = true;
      });
    }
    try {
      List<Movie> hits;
      switch (_filter) {
        case _MediaFilter.all:
          hits = await _api.searchMulti(q);
          break;
        case _MediaFilter.movies:
          hits = await _api.searchMovies(q);
          break;
        case _MediaFilter.tv:
          hits = await _api.searchTvShows(q);
          break;
      }
      if (!mounted) return;
      setState(() {
        _results = hits;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setFilter(_MediaFilter f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    if (_query.isNotEmpty) _runSearch(_query);
  }

  Future<void> _openMovie(Movie m) async {
    if (_resolvingId != null) return;
    setState(() => _resolvingId = m.id);
    HapticFeedbackPulse.run();
    try {
      final isTv = m.mediaType == 'tv';
      final yearStr = m.releaseDate.length >= 4
          ? m.releaseDate.substring(0, 4)
          : null;
      final year = yearStr != null ? int.tryParse(yearStr) : null;
      final hit = await BestSimilarScraper.findBest(
        title: m.title,
        year: year,
        isTv: isTv,
      );
      if (!mounted) return;
      if (hit == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No bestsimilar.com match for "${m.title}"'),
          behavior: SnackBarBehavior.floating,
        ));
        setState(() => _resolvingId = null);
        return;
      }
      await Navigator.of(context).push(_buildRoute(SimilarResultsScreen(
        bsId: hit.id,
        bsSlug: hit.slug,
        seedTitle: hit.title,
        seedYear: hit.year,
        seedPoster: m.posterPath,
        seedBackdrop: m.backdropPath,
        seedTmdbMovie: m,
      )));
      if (mounted) setState(() => _resolvingId = null);
    } catch (_) {
      if (mounted) setState(() => _resolvingId = null);
    }
  }

  Route _buildRoute(Widget child) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 460),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, _, _) => child,
      transitionsBuilder: (_, anim, _, ch) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(curved),
            child: ch,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final showResults = _query.isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFF06080F),
      body: Stack(
        children: [
          // Liquid background blobs.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _blobCtrl,
              builder: (_, _) => CustomPaint(
                painter: _LiquidBlobsPainter(_blobCtrl.value),
              ),
            ),
          ),
          // Subtle vignette.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [
                      Colors.transparent,
                      const Color(0xFF06080F).withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  slivers: [
                    SliverToBoxAdapter(child: _buildHeader()),
                    SliverToBoxAdapter(child: _buildSearchBar()),
                    SliverToBoxAdapter(
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: _query.isEmpty
                            ? const SizedBox(width: double.infinity)
                            : _buildFilterChips(),
                      ),
                    ),
                    if (_loading)
                      const SliverToBoxAdapter(
                          child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 36),
                        child: Center(
                            child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white70))),
                      ))
                    else if (showResults)
                      _buildResultsGrid(_results)
                    else ...[
                      const SliverToBoxAdapter(
                          child: Padding(
                        padding: EdgeInsets.fromLTRB(20, 24, 20, 8),
                        child: Text('Trending right now',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3)),
                      )),
                      _buildResultsGrid(_trending),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
                    ),
                  ),
                  child: const Icon(Icons.auto_awesome,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                const Text('Similar',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    )),
              ],
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.only(left: 50),
              child: Text('Find your next favourite',
                  style: TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      letterSpacing: 0.2)),
            ),
          ],
        ),
      );

  Widget _buildSearchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10), width: 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded, color: Colors.white70),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      cursorColor: const Color(0xFF8AB4FF),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          letterSpacing: 0.1),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Search a movie or show…',
                        hintStyle: TextStyle(
                            color: Colors.white38, fontSize: 14),
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 16),
                      ),
                      onChanged: _onQueryChanged,
                      onSubmitted: _runSearch,
                      textInputAction: TextInputAction.search,
                    ),
                  ),
                  if (_query.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white60, size: 20),
                      onPressed: () {
                        _searchCtrl.clear();
                        _onQueryChanged('');
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildFilterChips() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _chip('All', _MediaFilter.all),
            const SizedBox(width: 8),
            _chip('Movies', _MediaFilter.movies),
            const SizedBox(width: 8),
            _chip('TV Shows', _MediaFilter.tv),
          ],
        ),
      );

  Widget _chip(String label, _MediaFilter f) {
    final active = _filter == f;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: active
            ? const LinearGradient(
                colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
              )
            : null,
        color: active ? null : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
            color: Colors.white.withValues(alpha: active ? 0.18 : 0.08)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => _setFilter(f),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : Colors.white70,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResultsGrid(List<Movie> items) {
    if (items.isEmpty) {
      return const SliverToBoxAdapter(
          child: Padding(
        padding: EdgeInsets.all(40),
        child: Center(
            child: Text('No results',
                style: TextStyle(color: Colors.white38, fontSize: 14))),
      ));
    }
    final width = MediaQuery.of(context).size.width;
    final cols = width > 1100
        ? 6
        : width > 800
            ? 5
            : width > 500
                ? 4
                : 3;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) => _PosterCard(
            movie: items[i],
            onTap: () => _openMovie(items[i]),
            loading: _resolvingId == items[i].id,
          ),
          childCount: items.length,
        ),
      ),
    );
  }
}

class _PosterCard extends StatefulWidget {
  final Movie movie;
  final VoidCallback onTap;
  final bool loading;
  const _PosterCard(
      {required this.movie, required this.onTap, required this.loading});

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final movie = widget.movie;
    final loading = widget.loading;
    final poster = movie.posterPath.isNotEmpty
        ? TmdbApi.getImageUrl(movie.posterPath)
        : null;

    final scale = _pressed ? 0.965 : (_hover ? 1.045 : 1.0);
    final lift = _hover ? -4.0 : 0.0;
    final glow = _hover ? 0.55 : 0.0;

    return RepaintBoundary(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: loading ? null : widget.onTap,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            offset: Offset(0, lift / 100),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              scale: scale,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF7B61FF)
                          .withValues(alpha: glow * 0.55),
                      blurRadius: 26,
                      spreadRadius: -2,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: const Color(0xFF38C7FF)
                          .withValues(alpha: glow * 0.35),
                      blurRadius: 22,
                      spreadRadius: -4,
                      offset: const Offset(0, 4),
                    ),
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: _hover ? 0.45 : 0.0),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: poster != null
                            ? CachedNetworkImage(
                                imageUrl: poster,
                                fit: BoxFit.cover,
                                fadeInDuration:
                                    const Duration(milliseconds: 320),
                                placeholder: (_, _) => Container(
                                    color: Colors.white
                                        .withValues(alpha: 0.04)),
                                errorWidget: (_, _, _) =>
                                    _posterFallback(),
                              )
                            : _posterFallback(),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              stops: const [0, 0.55, 1],
                              colors: [
                                Colors.black.withValues(
                                    alpha: _hover ? 0.92 : 0.85),
                                Colors.transparent,
                                Colors.transparent,
                              ],
                            ),
                            border: Border.all(
                              color: Colors.white.withValues(
                                  alpha: _hover ? 0.18 : 0.0),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Soft sheen overlay on hover.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration:
                              const Duration(milliseconds: 260),
                          opacity: _hover ? 1.0 : 0.0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withValues(alpha: 0.10),
                                  Colors.white.withValues(alpha: 0.0),
                                  Colors.white.withValues(alpha: 0.04),
                                ],
                                stops: const [0, 0.55, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            movie.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.15,
                            ),
                          ),
                          if (movie.releaseDate.length >= 4)
                            Text(
                              movie.releaseDate.substring(0, 4),
                              style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                    if (loading)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(
                                sigmaX: 8, sigmaY: 8),
                            child: Container(
                              color: Colors.black
                                  .withValues(alpha: 0.35),
                              child: const Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.4,
                                      color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _posterFallback() => Container(
        color: const Color(0xFF1A1F2C),
        child: const Center(
            child: Icon(Icons.movie_outlined,
                color: Colors.white24, size: 32)),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Liquid blob backdrop — three slow-orbiting radial gradients.
// ─────────────────────────────────────────────────────────────────────────
class _LiquidBlobsPainter extends CustomPainter {
  final double t;
  _LiquidBlobsPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    void blob(double phase, Color color, double rx, double ry, double r) {
      final a = (t * 2 * math.pi) + phase;
      final cx = w / 2 + math.cos(a) * (w * rx);
      final cy = h / 3 + math.sin(a * 0.8) * (h * ry);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(
            Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }

    blob(0, const Color(0xFF7B61FF), 0.32, 0.18, 280);
    blob(2, const Color(0xFF38C7FF), 0.30, 0.22, 240);
    blob(4, const Color(0xFFFF7AB6), 0.26, 0.16, 220);
  }

  @override
  bool shouldRepaint(covariant _LiquidBlobsPainter oldDelegate) =>
      oldDelegate.t != t;
}

// Lightweight haptic helper without importing services in widgets.
class HapticFeedbackPulse {
  static void run() {
    // Intentionally cheap: leave to system click; avoid extra imports.
  }
}
