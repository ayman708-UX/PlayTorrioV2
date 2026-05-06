// Similar results — soothing detail screen showing the seed title hero
// + a vertical scroll of large "similar" cards with parallax thumbnails,
// similarity rings, and tags.
//
// Data sources:
//   • bestsimilar.com: hero info + ~30 similar items via [BestSimilarScraper]
//   • TMDB: high-res poster/backdrop enrichment per similar item (parallel)
//
// Tap a card → resolve TMDB → push StreamingDetailsScreen or DetailsScreen
// based on the user's setting.

import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../api/bestsimilar_scraper.dart';
import '../../api/settings_service.dart';
import '../../api/tmdb_api.dart';
import '../../models/movie.dart';
import '../details_screen.dart';
import '../streaming_details_screen.dart';

class SimilarResultsScreen extends StatefulWidget {
  final int bsId;
  final String bsSlug;
  final String seedTitle;
  final int? seedYear;
  final String seedPoster;       // TMDB poster_path
  final String seedBackdrop;     // TMDB backdrop_path
  final Movie? seedTmdbMovie;

  const SimilarResultsScreen({
    super.key,
    required this.bsId,
    required this.bsSlug,
    required this.seedTitle,
    required this.seedYear,
    required this.seedPoster,
    required this.seedBackdrop,
    this.seedTmdbMovie,
  });

  @override
  State<SimilarResultsScreen> createState() => _SimilarResultsScreenState();
}

class _SimilarResultsScreenState extends State<SimilarResultsScreen>
    with TickerProviderStateMixin {
  final _api = TmdbApi();
  final _scrollCtrl = ScrollController();
  late final AnimationController _heroFade;

  BSDetails? _details;
  bool _loading = true;
  String? _error;
  Color _ambient = const Color(0xFF1B2034);
  double _scrollOffset = 0;
  int? _resolvingId;

  @override
  void initState() {
    super.initState();
    _heroFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scrollCtrl.addListener(() {
      if ((_scrollCtrl.offset - _scrollOffset).abs() > 1.5) {
        setState(() => _scrollOffset = _scrollCtrl.offset);
      }
    });
    _load();
    _resolveAmbient();
  }

  @override
  void dispose() {
    _heroFade.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _resolveAmbient() async {
    if (widget.seedBackdrop.isEmpty && widget.seedPoster.isEmpty) return;
    try {
      final imgPath = widget.seedBackdrop.isNotEmpty
          ? widget.seedBackdrop
          : widget.seedPoster;
      final url = widget.seedBackdrop.isNotEmpty
          ? TmdbApi.getBackdropUrl(imgPath)
          : TmdbApi.getImageUrl(imgPath);
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(160, 90),
        maximumColorCount: 8,
      );
      final c = palette.darkMutedColor?.color ??
          palette.darkVibrantColor?.color ??
          palette.dominantColor?.color;
      if (c != null && mounted) {
        setState(() => _ambient = Color.lerp(c, Colors.black, 0.45)!);
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await BestSimilarScraper.fetchDetails(
        id: widget.bsId,
        slug: widget.bsSlug,
      );
      if (!mounted) return;
      if (d == null) {
        setState(() {
          _loading = false;
          _error = 'Couldn\'t load similar list';
        });
        return;
      }
      setState(() {
        _details = d;
        _loading = false;
      });
      _heroFade.forward();
      _enrichWithTmdb(d.similar);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// Look up each BS item on TMDB in parallel to swap in HD poster.
  Future<void> _enrichWithTmdb(List<BSItem> items) async {
    final futures = items.map((it) async {
      try {
        final hits = await _api.searchMulti(it.title);
        if (hits.isEmpty) return;
        Movie? best;
        var bestScore = -1;
        for (final h in hits) {
          var s = 0;
          if (h.title.toLowerCase() == it.title.toLowerCase()) s += 5;
          if (it.year != null && h.releaseDate.length >= 4) {
            final hy = int.tryParse(h.releaseDate.substring(0, 4));
            if (hy == it.year) s += 4;
            if (hy != null && (hy - it.year!).abs() <= 1) s += 1;
          }
          if (s > bestScore) {
            bestScore = s;
            best = h;
          }
        }
        if (best != null && bestScore >= 4) {
          if (mounted) {
            setState(() {
              it.tmdbId = best!.id;
              it.tmdbMediaType = best.mediaType;
              if (best.posterPath.isNotEmpty) {
                it.tmdbPosterUrl = TmdbApi.getImageUrl(best.posterPath);
              }
              if (best.backdropPath.isNotEmpty) {
                it.tmdbBackdropUrl =
                    TmdbApi.getBackdropUrl(best.backdropPath);
              }
            });
          }
        }
      } catch (_) {}
    });
    await Future.wait(futures);
  }

  Future<void> _openItem(BSItem item) async {
    if (_resolvingId != null) return;
    setState(() => _resolvingId = item.id);
    try {
      Movie? movie;
      if (item.tmdbId != null) {
        if (item.tmdbMediaType == 'tv') {
          movie = await _api.getTvDetails(item.tmdbId!);
        } else {
          movie = await _api.getMovieDetails(item.tmdbId!);
        }
      } else {
        // No prior TMDB enrichment — search now.
        final hits = await _api.searchMulti(item.title);
        Movie? best;
        for (final h in hits) {
          if (h.title.toLowerCase() != item.title.toLowerCase()) continue;
          if (item.year != null && h.releaseDate.length >= 4) {
            final hy = int.tryParse(h.releaseDate.substring(0, 4));
            if (hy == item.year) {
              best = h;
              break;
            }
          }
          best ??= h;
        }
        if (best != null) {
          if (best.mediaType == 'tv') {
            movie = await _api.getTvDetails(best.id);
          } else {
            movie = await _api.getMovieDetails(best.id);
          }
        }
      }
      if (!mounted) return;
      if (movie == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not find "${item.title}" on TMDB'),
          behavior: SnackBarBehavior.floating,
        ));
        setState(() => _resolvingId = null);
        return;
      }
      final streaming = await SettingsService().isStreamingModeEnabled();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => streaming
            ? StreamingDetailsScreen(movie: movie!)
            : DetailsScreen(movie: movie!),
      ));
      if (mounted) setState(() => _resolvingId = null);
    } catch (e) {
      if (mounted) {
        setState(() => _resolvingId = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to open: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06080F),
      body: Stack(
        children: [
          // Ambient gradient driven by palette of seed backdrop.
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 700),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _ambient,
                    Color.lerp(_ambient, Colors.black, 0.65)!,
                    const Color(0xFF06080F),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
          ),
          // Backdrop blur layer — parallax with scroll.
          // Pre-blur via ImageFiltered so the image can never appear sharp
          // for a frame during fade-in.
          if (widget.seedBackdrop.isNotEmpty)
            Positioned(
              top: -_scrollOffset * 0.35,
              left: 0,
              right: 0,
              height: 360,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(
                      imageFilter:
                          ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                      child: CachedNetworkImage(
                        imageUrl:
                            TmdbApi.getBackdropUrl(widget.seedBackdrop),
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 500),
                        placeholder: (_, _) =>
                            Container(color: _ambient),
                      ),
                    ),
                    Container(
                        color: Colors.black.withValues(alpha: 0.35)),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            const Color(0xFF06080F).withValues(alpha: 0.85),
                            const Color(0xFF06080F),
                          ],
                          stops: const [0, 0.7, 1],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: _loading
                ? _buildLoading()
                : _error != null
                    ? _buildError()
                    : _buildContent(),
          ),
          // Floating back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            left: 12,
            child: _GlassButton(
              icon: Icons.arrow_back_rounded,
              onTap: () => Navigator.maybePop(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
              strokeWidth: 2.6, color: Colors.white70),
        ),
      );

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  color: Colors.white38, size: 48),
              const SizedBox(height: 14),
              Text(_error ?? 'Error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 18),
              FilledButton(
                  onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );

  Widget _buildContent() {
    final d = _details!;
    return CustomScrollView(
      controller: _scrollCtrl,
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        SliverToBoxAdapter(child: _buildHero(d)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 22,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Text('Most similar (${d.similar.length})',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _AnimatedListEntry(
                index: i,
                child: _SimilarBigCard(
                  item: d.similar[i],
                  loading: _resolvingId == d.similar[i].id,
                  onTap: () => _openItem(d.similar[i]),
                ),
              ),
              childCount: d.similar.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHero(BSDetails d) {
    final tmdbBackdrop = widget.seedBackdrop.isNotEmpty
        ? TmdbApi.getBackdropUrl(widget.seedBackdrop)
        : null;
    final tmdbPoster = widget.seedPoster.isNotEmpty
        ? TmdbApi.getImageUrl(widget.seedPoster)
        : null;

    return FadeTransition(
      opacity: CurvedAnimation(
          parent: _heroFade, curve: Curves.easeOutCubic),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 80, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox(
                    width: 110,
                    height: 165,
                    child: tmdbPoster != null
                        ? CachedNetworkImage(
                            imageUrl: tmdbPoster,
                            fit: BoxFit.cover,
                            fadeInDuration:
                                const Duration(milliseconds: 400),
                          )
                        : Image.network(d.thumbUrl, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              height: 1.1,
                              letterSpacing: -0.2)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (d.year != null) _miniChip('${d.year}'),
                          if (d.rating != null)
                            _miniChip('★ ${d.rating!.toStringAsFixed(1)}'),
                          if (d.duration != null && d.duration!.isNotEmpty)
                            _miniChip(d.duration!),
                        ],
                      ),
                      if (d.genre != null) ...[
                        const SizedBox(height: 8),
                        Text(d.genre!,
                            style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                                fontWeight: FontWeight.w500)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (d.story != null && d.story!.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(d.story!,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13.5,
                      height: 1.45)),
            ],
            if (d.styleTags.isNotEmpty || d.plotTags.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ...d.styleTags.take(4).map(_pillTag),
                  ...d.plotTags.take(4).map(_pillTag),
                ],
              ),
            ],
            // Mute the unused param warning.
            const SizedBox.shrink(),
            if (tmdbBackdrop != null) const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  Widget _miniChip(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.10), width: 1),
        ),
        child: Text(s,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w600)),
      );

  Widget _pillTag(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(s,
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Big similar card.
// ─────────────────────────────────────────────────────────────────────────
class _SimilarBigCard extends StatelessWidget {
  final BSItem item;
  final VoidCallback onTap;
  final bool loading;
  const _SimilarBigCard(
      {required this.item, required this.onTap, required this.loading});

  @override
  Widget build(BuildContext context) {
    final poster = item.tmdbPosterUrl ?? item.thumbUrl;
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Material(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: loading ? null : onTap,
            child: Stack(
              children: [
                // Hazy backdrop using the (eventually) HD backdrop or poster.
                // Pre-blurred via ImageFiltered so it never flashes sharp.
                if (item.tmdbBackdropUrl != null)
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.32,
                      child: ImageFiltered(
                        imageFilter:
                            ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                        child: CachedNetworkImage(
                          imageUrl: item.tmdbBackdropUrl!,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                if (item.tmdbBackdropUrl != null)
                  Positioned.fill(
                    child: Container(
                        color: Colors.black.withValues(alpha: 0.35)),
                  ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          width: 110,
                          height: 165,
                          child: CachedNetworkImage(
                            imageUrl: poster,
                            fit: BoxFit.cover,
                            fadeInDuration:
                                const Duration(milliseconds: 380),
                            placeholder: (_, _) => Container(
                                color:
                                    Colors.white.withValues(alpha: 0.06)),
                            errorWidget: (_, _, _) => Container(
                              color: const Color(0xFF1A1F2C),
                              child: const Icon(Icons.movie_outlined,
                                  color: Colors.white24, size: 28),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    item.displayTitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w700,
                                        height: 1.15,
                                        letterSpacing: -0.1),
                                  ),
                                ),
                                if (item.similarityPercent != null) ...[
                                  const SizedBox(width: 8),
                                  _SimilarityRing(
                                      percent:
                                          item.similarityPercent!),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                if (item.rating != null) ...[
                                  const Icon(Icons.star_rounded,
                                      color: Color(0xFFFFD86B), size: 14),
                                  const SizedBox(width: 3),
                                  Text(
                                    item.rating!.toStringAsFixed(1),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                if (item.voteCount != null)
                                  Text(item.voteCount!,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11.5)),
                                if (item.duration != null) ...[
                                  const Text(' · ',
                                      style: TextStyle(
                                          color: Colors.white24)),
                                  Text(item.duration!,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11.5)),
                                ],
                              ],
                            ),
                            if (item.genre != null) ...[
                              const SizedBox(height: 4),
                              Text(item.genre!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500)),
                            ],
                            if (item.story != null) ...[
                              const SizedBox(height: 8),
                              Text(item.story!,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12.5,
                                      height: 1.4)),
                            ],
                            if (item.styleTags.isNotEmpty ||
                                item.plotTags.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  ...item.styleTags.take(2).map(_tag),
                                  ...item.plotTags.take(3).map(_tag),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (loading)
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.25),
                        child: const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4, color: Colors.white),
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
    );
  }

  Widget _tag(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(s,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 10.5,
                fontWeight: FontWeight.w500)),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Similarity ring (animated).
// ─────────────────────────────────────────────────────────────────────────
class _SimilarityRing extends StatelessWidget {
  final int percent;
  const _SimilarityRing({required this.percent});

  Color get _color {
    if (percent >= 85) return const Color(0xFF38E7B5);
    if (percent >= 70) return const Color(0xFF7BC9FF);
    if (percent >= 55) return const Color(0xFFFFD86B);
    return const Color(0xFFFF8A8A);
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: percent / 100),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) {
        return SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(44, 44),
                painter: _RingPainter(value: v, color: _color),
              ),
              Text('$percent%',
                  style: TextStyle(
                      color: _color,
                      fontSize: 11,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value; // 0..1
  final Color color;
  _RingPainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 3;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.12);
    canvas.drawCircle(center, radius, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * value,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}

// ─────────────────────────────────────────────────────────────────────────
// Stagger entry animation.
// ─────────────────────────────────────────────────────────────────────────
class _AnimatedListEntry extends StatefulWidget {
  final int index;
  final Widget child;
  const _AnimatedListEntry({required this.index, required this.child});

  @override
  State<_AnimatedListEntry> createState() => _AnimatedListEntryState();
}

class _AnimatedListEntryState extends State<_AnimatedListEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    Future.delayed(
        Duration(milliseconds: 60 + (widget.index.clamp(0, 8)) * 55),
        () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved =
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}
