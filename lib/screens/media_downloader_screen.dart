// Media Downloader — search any movie / TV episode and grab a direct
// download link from the 111477 file index. UI mirrors the Similar Hub
// (liquid blob backdrop, glass search bar, gradient accents).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/site111477_service.dart';
import '../api/tmdb_api.dart';
import '../models/movie.dart';

class MediaDownloaderScreen extends StatefulWidget {
  const MediaDownloaderScreen({super.key});

  @override
  State<MediaDownloaderScreen> createState() => _MediaDownloaderScreenState();
}

class _MediaDownloaderScreenState extends State<MediaDownloaderScreen>
    with TickerProviderStateMixin {
  // ── Animated backdrop ────────────────────────────────────────────────
  late final AnimationController _blobCtrl;

  // Horizontal scroll controllers for season / episode strips.
  final ScrollController _seasonScroll = ScrollController();
  final ScrollController _episodeScroll = ScrollController();

  // ── Search ───────────────────────────────────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;
  String _query = '';
  bool _searching = false;
  List<Movie> _results = const [];

  // ── Selected media (drives the link picker) ──────────────────────────
  Movie? _selected;
  bool _loadingDetails = false;
  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  int _seasonCount = 0;
  List<Map<String, dynamic>> _episodes = const [];

  // ── Link search ──────────────────────────────────────────────────────
  bool _searchingLinks = false;
  String? _linksError;
  List<Site111477Match> _links = const [];

  @override
  void initState() {
    super.initState();
    _blobCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
    _searchCtrl.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), () {
        _runSearch(_searchCtrl.text.trim());
      });
    });
  }

  @override
  void dispose() {
    _blobCtrl.dispose();
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _seasonScroll.dispose();
    _episodeScroll.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────
  //  SEARCH
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _runSearch(String q) async {
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _query = '';
          _results = const [];
          _searching = false;
        });
      }
      return;
    }
    setState(() {
      _query = q;
      _searching = true;
    });
    try {
      final hits = await TmdbApi().searchMulti(q);
      if (!mounted || _query != q) return;
      setState(() {
        _results = hits.where((m) => m.posterPath.isNotEmpty).toList();
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = const [];
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  //  SELECTION
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _selectMedia(Movie m) async {
    setState(() {
      _selected = m;
      _loadingDetails = true;
      _seasonCount = 0;
      _episodes = const [];
      _selectedSeason = 1;
      _selectedEpisode = 1;
      _linksError = null;
      _links = const [];
    });
    if (m.mediaType == 'tv') {
      try {
        final full = await TmdbApi().getTvDetails(m.id);
        if (!mounted || _selected?.id != m.id) return;
        setState(() {
          _seasonCount = full.numberOfSeasons.clamp(1, 99);
          _selected = full;
        });
        await _loadSeason(1);
      } catch (_) {
        if (mounted) setState(() => _loadingDetails = false);
      }
    } else {
      // Movie — go straight to scraping.
      setState(() => _loadingDetails = false);
      _scrapeLinks();
    }
  }

  Future<void> _loadSeason(int n) async {
    if (_selected == null) return;
    setState(() {
      _loadingDetails = true;
      _selectedSeason = n;
      _selectedEpisode = 1;
      _episodes = const [];
      _linksError = null;
      _links = const [];
    });
    try {
      final data = await TmdbApi().getTvSeasonDetails(_selected!.id, n);
      final eps = (data['episodes'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _episodes = eps;
        _loadingDetails = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingDetails = false);
    }
  }

  void _selectEpisode(int n) {
    setState(() {
      _selectedEpisode = n;
      _linksError = null;
      _links = const [];
    });
    _scrapeLinks();
  }

  // ─────────────────────────────────────────────────────────────────────
  //  111477 SCRAPE
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _scrapeLinks() async {
    final m = _selected;
    if (m == null) return;
    setState(() {
      _searchingLinks = true;
      _linksError = null;
      _links = const [];
    });
    try {
      final svc = Site111477Service();
      List<Site111477Match> hits;
      if (m.mediaType == 'tv') {
        hits = await svc.findEpisodeSources(
          showTitle: m.title,
          season: _selectedSeason,
          episode: _selectedEpisode,
        );
      } else {
        final year = m.releaseDate.length >= 4
            ? m.releaseDate.substring(0, 4)
            : null;
        hits = await svc.findMovieSources(title: m.title, year: year);
      }
      if (!mounted) return;
      setState(() {
        _links = hits;
        _searchingLinks = false;
        if (hits.isEmpty) _linksError = 'No download links found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchingLinks = false;
        _linksError = 'Lookup failed: $e';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  //  ACTIONS
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _open(Site111477Match m) async {
    final uri = Uri.tryParse(m.fileUrl);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${m.fileName}')),
      );
    }
  }

  Future<void> _copy(Site111477Match m) async {
    await Clipboard.setData(ClipboardData(text: m.fileUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Link copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _clearSelection() {
    setState(() {
      _selected = null;
      _episodes = const [];
      _links = const [];
      _linksError = null;
      _seasonCount = 0;
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showLinks = _selected != null;
    return Scaffold(
      backgroundColor: const Color(0xFF06080F),
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _blobCtrl,
              builder: (_, _) => CustomPaint(
                painter: _LiquidBlobsPainter(_blobCtrl.value),
              ),
            ),
          ),
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
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: showLinks
                        ? _buildLinksView(key: const ValueKey('links'))
                        : _buildSearchView(key: const ValueKey('search')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: [
          if (_selected != null)
            _CircleIconButton(
              icon: Icons.arrow_back_rounded,
              onTap: _clearSelection,
              tooltip: 'Back to search',
            )
          else
            const _GradientBadge(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selected?.title ?? 'Media Downloader',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                if (_selected == null)
                  Text(
                    'Search any movie or show — get a direct download link.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else
                  Text(
                    _selected!.mediaType == 'tv'
                        ? 'TV Show · pick an episode below'
                        : 'Movie · download links below',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Search view ──────────────────────────────────────────────────────

  Widget _buildSearchView({Key? key}) {
    return Column(
      key: key,
      children: [
        _buildSearchBar(),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
                    ).createShader(r),
                    child: const Icon(Icons.search_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      cursorColor: const Color(0xFF7B61FF),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: _runSearch,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Search movies and shows…',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  if (_searchCtrl.text.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        _runSearch('');
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.close_rounded,
                            color: Colors.white60, size: 20),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_searching) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: Colors.white),
        ),
      );
    }
    if (_query.isEmpty) {
      return _buildEmptyState();
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          'No results for "$_query"',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        final cols = w >= 1500
            ? 7
            : w >= 1200
                ? 6
                : w >= 900
                    ? 5
                    : w >= 700
                        ? 4
                        : w >= 480
                            ? 3
                            : 2;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            childAspectRatio: 0.62,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
          ),
          itemCount: _results.length,
          itemBuilder: (_, i) =>
              _PosterCard(item: _results[i], onTap: () => _selectMedia(_results[i])),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
              ).createShader(r),
              child: const Icon(Icons.cloud_download_outlined,
                  size: 80, color: Colors.white),
            ),
            const SizedBox(height: 18),
            const Text(
              'Find anything to download',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Search a movie or show, pick a quality, open in your\n'
              'browser or any download manager.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Links view ───────────────────────────────────────────────────────

  Widget _buildLinksView({Key? key}) {
    final m = _selected!;
    final isTv = m.mediaType == 'tv';
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSelectedHero(m),
          if (isTv) ...[
            const SizedBox(height: 22),
            _buildSeasonStrip(),
            const SizedBox(height: 14),
            _buildEpisodeStrip(),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              const Text(
                'Download links',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_links.isNotEmpty)
                Text(
                  '${_links.length} found',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(width: 10),
              _CircleIconButton(
                icon: Icons.refresh_rounded,
                onTap: _searchingLinks ? null : _scrapeLinks,
                size: 32,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildLinksBody(),
        ],
      ),
    );
  }

  Widget _buildSelectedHero(Movie m) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 90,
              height: 135,
              child: m.posterPath.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: TmdbApi.getImageUrl(m.posterPath),
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(
                          color: Colors.white.withValues(alpha: 0.05)),
                      errorWidget: (_, _, _) => Container(
                          color: Colors.white.withValues(alpha: 0.05)),
                    )
                  : Container(color: Colors.white.withValues(alpha: 0.05)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _Chip(
                      label: m.mediaType == 'tv' ? 'TV Show' : 'Movie',
                      color: const Color(0xFF7B61FF),
                    ),
                    if (m.releaseDate.length >= 4)
                      _Chip(
                        label: m.releaseDate.substring(0, 4),
                        color: const Color(0xFF38C7FF),
                      ),
                    if (m.voteAverage > 0)
                      _Chip(
                        label: '★ ${m.voteAverage.toStringAsFixed(1)}',
                        color: const Color(0xFFFFD86B),
                      ),
                  ],
                ),
                if (m.overview.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    m.overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonStrip() {
    if (_seasonCount <= 0) return const SizedBox.shrink();
    return _ArrowScroller(
      controller: _seasonScroll,
      height: 38,
      step: 200,
      child: ListView.separated(
        controller: _seasonScroll,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: _seasonCount,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final n = i + 1;
          final sel = _selectedSeason == n;
          return _Pill(
            label: 'Season $n',
            selected: sel,
            onTap: () => _loadSeason(n),
          );
        },
      ),
    );
  }

  Widget _buildEpisodeStrip() {
    if (_loadingDetails) {
      return const SizedBox(
        height: 100,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2.2, color: Colors.white),
          ),
        ),
      );
    }
    if (_episodes.isEmpty) return const SizedBox.shrink();
    return _ArrowScroller(
      controller: _episodeScroll,
      height: 100,
      step: 340,
      child: ListView.separated(
        controller: _episodeScroll,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: _episodes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final ep = _episodes[i];
          final n = (ep['episode_number'] as int?) ?? (i + 1);
          final still = (ep['still_path'] as String?) ?? '';
          final name = (ep['name'] as String?) ?? 'Episode $n';
          final sel = _selectedEpisode == n;
          return GestureDetector(
            onTap: () => _selectEpisode(n),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 160,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: sel
                      ? const Color(0xFF7B61FF)
                      : Colors.white.withValues(alpha: 0.10),
                  width: sel ? 2 : 1,
                ),
                boxShadow: sel
                    ? [
                        BoxShadow(
                          color: const Color(0xFF7B61FF)
                              .withValues(alpha: 0.35),
                          blurRadius: 18,
                          spreadRadius: -2,
                        )
                      ]
                    : const [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (still.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: TmdbApi.getStillUrl(still),
                        fit: BoxFit.cover,
                        placeholder: (_, _) => Container(
                            color: Colors.white.withValues(alpha: 0.05)),
                        errorWidget: (_, _, _) => Container(
                            color: Colors.white.withValues(alpha: 0.05)),
                      )
                    else
                      Container(color: Colors.white.withValues(alpha: 0.05)),
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.85),
                            ],
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
                            'EP $n',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
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
        },
      ),
    );
  }

  Widget _buildLinksBody() {
    if (_searchingLinks) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Column(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: Colors.white),
              ),
              const SizedBox(height: 14),
              Text(
                'Scanning index…',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_links.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.cloud_off_rounded,
                  color: Colors.white.withValues(alpha: 0.4), size: 44),
              const SizedBox(height: 10),
              Text(
                _linksError ?? 'Pick an episode to start',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final m in _links)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _LinkCard(
              match: m,
              onOpen: () => _open(m),
              onCopy: () => _copy(m),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  WIDGETS
// ─────────────────────────────────────────────────────────────────────────

class _PosterCard extends StatefulWidget {
  final Movie item;
  final VoidCallback onTap;
  const _PosterCard({required this.item, required this.onTap});

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, _hover ? -4.5 : 0.0, 0.0, 1.0)
            ..scaleByDouble(_hover ? 1.04 : 1.0, _hover ? 1.04 : 1.0, 1.0, 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: const Color(0xFF7B61FF)
                          .withValues(alpha: 0.35),
                      blurRadius: 22,
                      spreadRadius: -4,
                    )
                  ]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (m.posterPath.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: TmdbApi.getImageUrl(m.posterPath),
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 320),
                    placeholder: (_, _) => Container(
                        color: Colors.white.withValues(alpha: 0.04)),
                    errorWidget: (_, _, _) =>
                        const _PosterFallback(),
                  )
                else
                  const _PosterFallback(),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.85),
                        ],
                        stops: const [0.55, 1.0],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      m.mediaType == 'tv' ? 'TV' : 'MOVIE',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      if (m.releaseDate.length >= 4) ...[
                        const SizedBox(height: 2),
                        Text(
                          m.releaseDate.substring(0, 4),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();
  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFF1A1F2C),
        child: const Icon(Icons.movie_outlined,
            color: Colors.white24, size: 36),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
                )
              : null,
          color: selected ? null : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _LinkCard extends StatefulWidget {
  final Site111477Match match;
  final VoidCallback onOpen;
  final VoidCallback onCopy;
  const _LinkCard({
    required this.match,
    required this.onOpen,
    required this.onCopy,
  });

  @override
  State<_LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<_LinkCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.match;
    final q = Site111477Service.qualityTagFor(m.fileName);
    final size =
        m.sizeBytes > 0 ? Site111477Service.humanSize(m.sizeBytes) : null;
    final qColor = _qualityColor(q);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hover
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hover
                  ? const Color(0xFF7B61FF).withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      qColor.withValues(alpha: 0.85),
                      qColor.withValues(alpha: 0.45),
                    ],
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  q.isEmpty ? 'FILE' : q.replaceAll('P', ''),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      m.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.storage_rounded,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.5)),
                        const SizedBox(width: 4),
                        Text(
                          size ?? 'Unknown size',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(Icons.cloud_rounded,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.5)),
                        const SizedBox(width: 4),
                        Text(
                          '111477',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _CircleIconButton(
                icon: Icons.copy_rounded,
                onTap: widget.onCopy,
                size: 36,
                tooltip: 'Copy link',
              ),
              const SizedBox(width: 6),
              _CircleIconButton(
                icon: Icons.open_in_new_rounded,
                onTap: widget.onOpen,
                size: 36,
                tooltip: 'Open',
                gradient: const LinearGradient(
                  colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _qualityColor(String q) {
    switch (q) {
      case '2160P':
        return const Color(0xFFFF7AB6);
      case '1080P':
        return const Color(0xFF7B61FF);
      case '720P':
        return const Color(0xFF38C7FF);
      case '480P':
        return const Color(0xFFFFD86B);
      default:
        return const Color(0xFF6B6F80);
    }
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final String? tooltip;
  final Gradient? gradient;
  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.size = 38,
    this.tooltip,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: gradient == null
              ? Colors.white.withValues(alpha: 0.08)
              : null,
          gradient: gradient,
          border: gradient == null
              ? Border.all(color: Colors.white.withValues(alpha: 0.12))
              : null,
        ),
        child: Icon(icon,
            color: Colors.white, size: size * 0.48),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}

class _GradientBadge extends StatelessWidget {
  const _GradientBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF7B61FF), Color(0xFF38C7FF)],
        ),
      ),
      child: const Icon(Icons.cloud_download_rounded,
          color: Colors.white, size: 22),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  Horizontal scroller with edge-fade arrow buttons.
// ─────────────────────────────────────────────────────────────────────────

class _ArrowScroller extends StatefulWidget {
  final Widget child;
  final ScrollController controller;
  final double height;
  final double step;
  const _ArrowScroller({
    required this.child,
    required this.controller,
    required this.height,
    required this.step,
  });

  @override
  State<_ArrowScroller> createState() => _ArrowScrollerState();
}

class _ArrowScrollerState extends State<_ArrowScroller> {
  bool _showLeft = false;
  bool _showRight = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_recompute);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_recompute);
    super.dispose();
  }

  void _recompute() {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final left = pos.pixels > 4;
    final right = pos.pixels < pos.maxScrollExtent - 4;
    if (left != _showLeft || right != _showRight) {
      if (mounted) {
        setState(() {
          _showLeft = left;
          _showRight = right;
        });
      }
    }
  }

  void _scrollBy(double delta) {
    if (!widget.controller.hasClients) return;
    final target = (widget.controller.offset + delta)
        .clamp(0.0, widget.controller.position.maxScrollExtent);
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
          return false;
        },
        child: Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (_showLeft)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _ArrowBtn(
                  icon: Icons.chevron_left_rounded,
                  onTap: () => _scrollBy(-widget.step),
                  alignLeft: true,
                ),
              ),
            if (_showRight)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _ArrowBtn(
                  icon: Icons.chevron_right_rounded,
                  onTap: () => _scrollBy(widget.step),
                  alignLeft: false,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool alignLeft;
  const _ArrowBtn({
    required this.icon,
    required this.onTap,
    required this.alignLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
          end: alignLeft ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            const Color(0xFF06080F).withValues(alpha: 0.85),
            const Color(0xFF06080F).withValues(alpha: 0.0),
          ],
        ),
      ),
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  Liquid blob backdrop (matches Similar Hub).
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
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }

    blob(0, const Color(0xFF7B61FF), 0.32, 0.18, 280);
    blob(2, const Color(0xFF38C7FF), 0.30, 0.22, 240);
    blob(4, const Color(0xFFFF7AB6), 0.26, 0.16, 220);
  }

  @override
  bool shouldRepaint(covariant _LiquidBlobsPainter old) => old.t != t;
}
