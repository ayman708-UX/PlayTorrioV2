import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/movie.dart';
import '../api/tmdb_api.dart';
import '../api/stream_extractor.dart';
import '../api/stremio_service.dart';
import '../api/stream_providers.dart';
import '../api/nuvio_service.dart';
import '../models/stream_source.dart';
import '../api/webstreamr_service.dart';
import '../api/site111477_service.dart';
import '../api/site111477_proxy.dart' as site111477_proxy;
import '../api/videasy_extractor.dart';
import '../api/vidsrc_extractor.dart';
import '../api/settings_service.dart';
import '../widgets/loading_overlay.dart';
import '../services/episode_watched_service.dart';
import '../widgets/movie_atmosphere.dart';
import 'player_screen.dart';

class StreamingDetailsScreen extends StatefulWidget {
  final Movie movie;
  final int? initialSeason;
  final int? initialEpisode;
  final Duration? startPosition;

  const StreamingDetailsScreen({
    super.key,
    required this.movie,
    this.initialSeason,
    this.initialEpisode,
    this.startPosition,
  });

  @override
  State<StreamingDetailsScreen> createState() => _StreamingDetailsScreenState();
}

class _StreamingDetailsScreenState extends State<StreamingDetailsScreen> with AtmosphereMixin {
  bool _isExtracting = false;
  bool _extractionCancelled = false;
  String? _statusMessage;
  final StreamExtractor _extractor = StreamExtractor();
  final StremioService _stremio = StremioService();
  final TmdbApi _api = TmdbApi();
  late Movie _movie;
  bool _isLoading = true;
  bool _showFullSynopsis = false;
  List<Movie> _similarContent = [];

  // Source Selection
  final String _selectedSourceId = 'playtorrio';
  List<Map<String, dynamic>> _streamAddons = [];

  // TV State
  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  Map<String, dynamic>? _seasonData;
  bool _isLoadingSeason = false;

  // Episode watched tracking
  final EpisodeWatchedService _episodeWatchedService = EpisodeWatchedService();
  Set<String> _watchedEpisodes = {};
  
  final ScrollController _similarScrollController = ScrollController();
  final ScrollController _screenshotsScrollController = ScrollController();
  final ScrollController _episodeScrollController = ScrollController();
  final ScrollController _seasonScrollController = ScrollController();

  final Map<String, dynamic> _providers = <String, dynamic>{
    ...StreamProviders.providers,
  };
  final SettingsService _settings = SettingsService();

  @override
  void initState() {
    super.initState();
    _movie = widget.movie;
    if (widget.initialSeason != null) _selectedSeason = widget.initialSeason!;
    if (widget.initialEpisode != null) _selectedEpisode = widget.initialEpisode!;
    // Start atmosphere color extraction
    final url = (_movie.posterPath.isNotEmpty ? _movie.posterPath : _movie.backdropPath);
    loadAtmosphere(url.startsWith('http') ? url : TmdbApi.getImageUrl(url));
    _loadWatchedEpisodes();
    _loadNuvioProviders();
    _fetchDetails();
  }

  Future<void> _loadNuvioProviders() async {
    try {
      final entries = await NuvioService.instance.getProviderEntries();
      if (!mounted || entries.isEmpty) return;
      setState(() => _providers.addAll(entries));
    } catch (e) {
      debugPrint('[StreamingDetails] nuvio provider load failed: $e');
    }
  }

  Future<void> _fetchDetails() async {
    try {
      final Movie fullDetails;
      if (_movie.mediaType == 'tv') {
        fullDetails = await _api.getTvDetails(widget.movie.id);
        await _fetchSeason(widget.initialSeason ?? 1);
      } else {
        fullDetails = await _api.getMovieDetails(widget.movie.id);
      }

      final streamAddons = await _stremio.getAddonsForResource('stream');
      
      // Fetch similar content
      final similar = _movie.mediaType == 'tv' 
          ? await _api.getSimilarTvShows(_movie.id)
          : await _api.getSimilarMovies(_movie.id);
      
      if (mounted) {
        setState(() {
          _movie = fullDetails;
          _streamAddons = streamAddons;
          _similarContent = similar;
          _isLoading = false;
        });

        // Auto-start extraction when opened with a start position (e.g. from Continue Watching / Trakt)
        if (widget.startPosition != null) {
          _startExtraction();
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchSeason(int seasonNumber) async {
    setState(() => _isLoadingSeason = true);
    try {
      final data = await _api.getTvSeasonDetails(_movie.id, seasonNumber);
      if (mounted) {
        setState(() {
          _seasonData = data;
          _isLoadingSeason = false;
          _selectedSeason = seasonNumber;
        });
        _loadWatchedEpisodes();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingSeason = false);
    }
  }

  @override
  void dispose() {
    _extractor.dispose();
    _similarScrollController.dispose();
    _screenshotsScrollController.dispose();
    _episodeScrollController.dispose();
    _seasonScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadWatchedEpisodes() async {
    final set = await _episodeWatchedService.getWatchedSet(_movie.id);
    if (mounted) setState(() => _watchedEpisodes = set);
  }

  Future<void> _toggleEpisodeWatched(int season, int episode) async {
    await _episodeWatchedService.toggle(_movie.id, season, episode);
    await _loadWatchedEpisodes();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // EXTRACTION LOGIC - PRESERVED FROM ORIGINAL
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startExtraction() async {
    if (_selectedSourceId == 'playtorrio') {
      _startPlayTorrioExtraction();
    } else {
      _startStremioExtraction();
    }
  }

  Future<void> _startStremioExtraction() async {
    final addon = _streamAddons.firstWhere((a) => a['baseUrl'] == _selectedSourceId);
    final baseUrl = addon['baseUrl'];
    
    setState(() {
      _statusMessage = 'Fetching from ${addon['name']}...';
    });

    try {
      String stremioId = _movie.imdbId ?? '';
      if (_movie.mediaType == 'tv') {
        stremioId = '$stremioId:$_selectedSeason:$_selectedEpisode';
      }

      final type = _movie.mediaType == 'tv' ? 'series' : 'movie';
      final streams = await _stremio.getStreams(baseUrl: baseUrl, type: type, id: stremioId);

      if (mounted) {
        setState(() {
          if (streams.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No streams found for this content.')));
          }
        });
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _statusMessage = null);
    }
  }

  Future<void> _startPlayTorrioExtraction() async {
    _extractionCancelled = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black,
      builder: (context) => LoadingOverlay(
        movie: _movie,
        onCancel: () {
          _extractionCancelled = true;
          Navigator.of(context).pop();
        },
      ),
    );

    setState(() {
      _isExtracting = true;
      _statusMessage = 'Initializing Stream Extractor...';
    });

    // Load user-defined provider order. The first provider that yields a
    // working stream wins; the player uses the rest as fallbacks (in this
    // same order) when the active source dies.
    final order = await _settings.getStreamProviderOrder();

    // Build a reordered providers map so the player's fallback loop
    // (which iterates `widget.providers!.keys`) follows the user's order.
    final orderedProviders = <String, dynamic>{
      for (final k in order)
        if (_providers.containsKey(k)) k: _providers[k],
      // Append anything in StreamProviders not in the saved order, just in
      // case a new built-in provider ships before settings are migrated.
      for (final k in _providers.keys)
        if (!order.contains(k)) k: _providers[k],
    };

    bool found = false;
    for (final key in orderedProviders.keys) {
      if (!mounted || _extractionCancelled) break;
      final provider = orderedProviders[key];
      final displayName = (provider?['name'] as String?) ?? key;
      if (mounted) {
        setState(() => _statusMessage = 'Searching $displayName…');
      }
      try {
        found = await _tryProvider(key, orderedProviders);
      } catch (e) {
        debugPrint('Error extracting from $key: $e');
      }
      if (found) break;
    }

    if (mounted) {
      if (_extractionCancelled) {
        setState(() { _isExtracting = false; _statusMessage = null; });
        return;
      }
      if (!found && Navigator.canPop(context)) Navigator.pop(context);
      setState(() {
        _isExtracting = false;
        _statusMessage = found ? null : 'No streams found. Try again later.';
      });
      if (!found) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to find a working stream.')));
      }
    }
  }

  /// Tries a single provider by key. Returns true if a stream was found and
  /// the PlayerScreen was pushed; false otherwise. Always passes
  /// [orderedProviders] (not the static map) so the player's auto-fallback
  /// honours the user's preferred order.
  Future<bool> _tryProvider(
      String key, Map<String, dynamic> orderedProviders) async {
    final isTv = _movie.mediaType == 'tv';
    final title = isTv
        ? '${_movie.title} - S$_selectedSeason E$_selectedEpisode'
        : _movie.title;

    void pushPlayer({
      required String streamUrl,
      String? audioUrl,
      Map<String, String>? headers,
      List<dynamic>? sources,
      List<Map<String, dynamic>>? subtitles,
    }) {
      if (Navigator.canPop(context)) Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PlayerScreen(
            streamUrl: streamUrl,
            audioUrl: audioUrl,
            title: title,
            headers: headers,
            movie: _movie,
            providers: orderedProviders,
            activeProvider: key,
            selectedSeason: isTv ? _selectedSeason : null,
            selectedEpisode: isTv ? _selectedEpisode : null,
            startPosition: widget.startPosition,
            sources: sources?.cast(),
            externalSubtitles: subtitles,
          ),
        ),
      );
    }

    if (key == 'service111477') {
      final svc = Site111477Service();
      List<Site111477Match> hits;
      if (isTv) {
        hits = await svc.findEpisodeSources(
          showTitle: _movie.title,
          season: _selectedSeason,
          episode: _selectedEpisode,
        );
      } else {
        final year = _movie.releaseDate.length >= 4
            ? _movie.releaseDate.substring(0, 4)
            : null;
        hits = await svc.findMovieSources(title: _movie.title, year: year);
      }
      if (_extractionCancelled || hits.isEmpty) return false;
      if (mounted) setState(() => _statusMessage = 'Starting 111477 proxy…');
      final proxiedUrl =
          await site111477_proxy.start111477Proxy(hits.first.fileUrl);
      if (_extractionCancelled || !mounted) return false;
      pushPlayer(
        streamUrl: proxiedUrl,
        sources: Site111477Service.toStreamSources(hits),
      );
      return true;
    }

    if (key == 'webstreamr') {
      if (_movie.imdbId == null || _movie.imdbId!.isEmpty) return false;
      final ws = WebStreamrService();
      final wsSources = await ws.getStreams(
        imdbId: _movie.imdbId!,
        isMovie: !isTv,
        season: isTv ? _selectedSeason : null,
        episode: isTv ? _selectedEpisode : null,
        tmdbId: _movie.id,
      );
      if (_extractionCancelled || wsSources.isEmpty) return false;
      if (!mounted) return false;
      final first = wsSources.first;
      pushPlayer(
        streamUrl: first.url,
        headers: first.headers,
        sources: wsSources,
      );
      return true;
    }

    if (key == 'videasy') {
      final ve = VideasyExtractor(onLog: (m) => debugPrint(m));
      final result = await ve.extract(
        tmdbId: _movie.id.toString(),
        isMovie: !isTv,
        season: isTv ? _selectedSeason : null,
        episode: isTv ? _selectedEpisode : null,
      );
      if (_extractionCancelled || result == null || result.url.isEmpty) {
        return false;
      }
      if (!mounted) return false;
      pushPlayer(
        streamUrl: result.url,
        audioUrl: result.audioUrl,
        headers: result.headers,
        sources: result.sources,
        subtitles: result.externalSubtitles,
      );
      return true;
    }

    if (key == 'vidsrc') {
      final ve = VidsrcExtractor();
      final result = await ve.extract(
        tmdbId: _movie.id.toString(),
        isMovie: !isTv,
        season: isTv ? _selectedSeason : null,
        episode: isTv ? _selectedEpisode : null,
      );
      if (_extractionCancelled || result == null || result.url.isEmpty) {
        return false;
      }
      if (!mounted) return false;
      pushPlayer(
        streamUrl: result.url,
        audioUrl: result.audioUrl,
        headers: result.headers,
        sources: result.sources,
        subtitles: result.externalSubtitles,
      );
      return true;
    }

    // Nuvio scrapers — `nuvio:<scraperId>`. Each entry is one provider in
    // the user's priority list, so we run a SINGLE scraper here (not all of
    // them like the regular details screen does). The first stream becomes
    // the primary; the rest become entries in the player's multi-link menu.
    if (key.startsWith('nuvio:')) {
      final scraperId = key.substring(6);
      final results = await NuvioService.instance.runOneScraper(
        scraperId: scraperId,
        tmdbId: _movie.id.toString(),
        type: isTv ? 'tv' : 'movie',
        season: isTv ? _selectedSeason : null,
        episode: isTv ? _selectedEpisode : null,
      );
      if (_extractionCancelled || results.isEmpty || !mounted) return false;
      final first = results.first;
      final sources = results.map((r) => StreamSource(
            url: r.url,
            title: r.title.isNotEmpty ? r.title : r.name,
            type: _typeFromUrl(r.url),
            headers: r.headers.isEmpty ? null : r.headers,
          )).toList();
      final subtitles = first.subtitles
          .where((s) => (s['url'] ?? '').isNotEmpty)
          .map((s) => <String, dynamic>{
                'url': s['url']!,
                'lang': s['lang'] ?? 'Unknown',
              })
          .toList();
      pushPlayer(
        streamUrl: first.url,
        headers: first.headers.isEmpty ? null : first.headers,
        sources: sources,
        subtitles: subtitles,
      );
      return true;
    }

    // Generic web-embed providers (vidlink/vixsrc/vidnest/…).
    final provider = orderedProviders[key];
    if (provider == null ||
        provider['movie'] == null ||
        provider['tv'] == null) {
      return false;
    }
    final String url = isTv
        ? provider['tv'](
            _movie.id.toString(),
            _selectedSeason.toString(),
            _selectedEpisode.toString(),
          )
        : provider['movie'](_movie.id.toString());
    debugPrint('[StreamExtractor] Trying ${provider['name']} source: $url');
    final result =
        await _extractor.extract(url, timeout: const Duration(seconds: 5));
    if (_extractionCancelled || result == null) return false;
    if (!mounted) return false;
    pushPlayer(
      streamUrl: result.url,
      audioUrl: result.audioUrl,
      headers: result.headers,
      sources: result.sources,
      subtitles: result.externalSubtitles,
    );
    return true;
  }

  String _typeFromUrl(String url) {
    final u = url.toLowerCase();
    if (u.contains('.m3u8')) return 'hls';
    if (u.contains('.mpd')) return 'dash';
    if (u.contains('.mkv')) return 'mkv';
    return 'mp4';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD METHOD - NEW DESIGN
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: const Center(child: CircularProgressIndicator(color: Color(0xFF1565C0))),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 600;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Stack(
        children: [
          // Fixed background
          Positioned.fill(
            child: _buildFixedBackground(),
          ),
          // Scrollable content
          CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 40),
                  _buildHeroSection(isTablet),
                  const SizedBox(height: 32),
                  _buildAboutSection(),
                  const SizedBox(height: 32),
                  if (_movie.mediaType == 'tv') ...[
                    _buildSeasonsAndEpisodes(),
                    const SizedBox(height: 32),
                  ],
                  if (_movie.screenshots.isNotEmpty) ...[
                    _buildScreenshotsSection(),
                    const SizedBox(height: 32),
                  ],
                  _buildSimilarContent(),
                  const SizedBox(height: 32),
                  _buildDetailsSection(),
                  const SizedBox(height: 48),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // UI COMPONENTS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFixedBackground() {
    final url = _movie.backdropPath.isNotEmpty
        ? TmdbApi.getBackdropUrl(_movie.backdropPath)
        : (_movie.posterPath.isNotEmpty ? TmdbApi.getImageUrl(_movie.posterPath) : '');
    if (url.isEmpty) return Container(color: const Color(0xFF0A0A0A));
    // Strip the Positioned.fill from buildAtmosphereBackdrop — we're already inside one
    return Stack(
      fit: StackFit.expand,
      children: [
        KenBurnsBackdrop(
          imageUrl: url,
          colors: atmosphereColors,
          blurSigma: 4,
        ),
        IgnorePointer(
          child: GenreParticles(
            genres: _movie.genres,
            colors: atmosphereColors,
          ),
        ),
      ],
    );
  }

  Widget _buildHeroSection(bool isTablet) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: isTablet
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPoster(),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMovieInfo(),
                      const SizedBox(height: 24),
                      _buildActionButtons(),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              children: [
                _buildPoster(),
                const SizedBox(height: 24),
                _buildMovieInfo(),
                const SizedBox(height: 24),
                _buildActionButtons(),
              ],
            ),
    );
  }

  Widget _buildPoster() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
    final posterWidth = isMobile ? screenWidth * 0.5 : 180.0;
    final posterHeight = posterWidth * 1.5;
    
    return wrapPosterGlow(
      width: posterWidth,
      height: posterHeight,
      borderRadius: 12,
      genres: _movie.genres,
      child: Hero(
        tag: 'movie-poster-${_movie.id}',
        child: Container(
          width: posterWidth,
          height: posterHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(
              imageUrl: TmdbApi.getImageUrl(_movie.posterPath),
              fit: BoxFit.cover,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMovieInfo() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 600;
    final logoHeight = isTablet ? 100.0 : 80.0;
    
    return Column(
      crossAxisAlignment: isTablet ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        // Logo or Text Title
        if (_movie.logoPath.isNotEmpty)
          SizedBox(
            height: logoHeight,
            child: Row(
              mainAxisAlignment: isTablet ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Flexible(
                  child: CachedNetworkImage(
                    imageUrl: TmdbApi.getImageUrl(_movie.logoPath),
                    height: logoHeight,
                    fit: BoxFit.contain,
                    alignment: isTablet ? Alignment.centerLeft : Alignment.center,
                    fadeInDuration: const Duration(milliseconds: 0),
                    fadeOutDuration: const Duration(milliseconds: 0),
                    placeholder: (context, url) => SizedBox(
                      height: logoHeight,
                      width: double.infinity,
                    ),
                    errorWidget: (context, url, error) => Text(
                      _movie.title,
                      style: GoogleFonts.montserrat(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Text(
            _movie.title,
            style: GoogleFonts.montserrat(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              _movie.releaseDate.isNotEmpty ? _movie.releaseDate.split('-').first : 'N/A',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(width: 8),
            const Text('·', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF1565C0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    _movie.voteAverage.toStringAsFixed(1),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            if (_movie.runtime > 0) ...[
              const SizedBox(width: 8),
              const Text('·', style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 8),
              Text(
                '${_movie.runtime}m',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (_movie.genres.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _movie.genres.take(4).map((genre) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                ),
                child: Text(
                  genre,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildActionButtons() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 600;
    
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isExtracting)
            Column(
              children: [
                const CircularProgressIndicator(color: Color(0xFF1565C0)),
                const SizedBox(height: 16),
                Text(
                  _statusMessage ?? 'Processing...',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            )
          else
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _startExtraction,
                child: Container(
                  width: isDesktop ? 300 : double.infinity,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1565C0).withValues(alpha: 0.4),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.play_arrow, color: Colors.white, size: 28),
                      const SizedBox(width: 8),
                      Text(
                        'Play Now',
                        style: GoogleFonts.montserrat(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAboutSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'About',
            style: GoogleFonts.montserrat(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          AnimatedCrossFade(
            firstChild: Text(
              _movie.overview.isNotEmpty ? _movie.overview : 'No synopsis available.',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 14, height: 1.5),
            ),
            secondChild: Text(
              _movie.overview.isNotEmpty ? _movie.overview : 'No synopsis available.',
              style: const TextStyle(color: Colors.grey, fontSize: 14, height: 1.5),
            ),
            crossFadeState: _showFullSynopsis ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 300),
          ),
          if (_movie.overview.isNotEmpty && _movie.overview.length > 150)
            TextButton(
              onPressed: () => setState(() => _showFullSynopsis = !_showFullSynopsis),
              child: Text(
                _showFullSynopsis ? 'Show less' : 'Show more',
                style: const TextStyle(color: Color(0xFF1565C0)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSeasonsAndEpisodes() {
    void scrollSeasonsBy(double delta) {
      if (!_seasonScrollController.hasClients) return;
      final target = (_seasonScrollController.offset + delta)
          .clamp(0.0, _seasonScrollController.position.maxScrollExtent);
      _seasonScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Episodes',
                style: GoogleFonts.montserrat(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_rounded, size: 18, color: Colors.white70),
                    onPressed: () => scrollSeasonsBy(-200),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18, color: Colors.white70),
                    onPressed: () => scrollSeasonsBy(200),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 50,
          child: ListView.builder(
            controller: _seasonScrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: _movie.numberOfSeasons,
            itemBuilder: (context, index) {
              final seasonNum = index + 1;
              final isSelected = _selectedSeason == seasonNum;
              return _SeasonChip(
                seasonNumber: seasonNum,
                isSelected: isSelected,
                onTap: () => _fetchSeason(seasonNum),
              );
            },
          ),
        ),
        const SizedBox(height: 24),
        if (_isLoadingSeason)
          const Center(child: CircularProgressIndicator(color: Color(0xFF1565C0)))
        else if (_seasonData != null && _seasonData!['episodes'] != null)
          _buildEpisodeList(),
      ],
    );
  }

  Widget _buildEpisodeList() {
    final episodes = _seasonData!['episodes'] as List;

    void scrollBy(double delta) {
      if (!_episodeScrollController.hasClients) return;
      final target = (_episodeScrollController.offset + delta)
          .clamp(0.0, _episodeScrollController.position.maxScrollExtent);
      _episodeScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── arrow row ──────────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_rounded, size: 18, color: Colors.white70),
                onPressed: () => scrollBy(-400),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18, color: Colors.white70),
                onPressed: () => scrollBy(400),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ── horizontal list ────────────────────────────────────────────────
          SizedBox(
            height: 190,
            child: ListView.separated(
              controller: _episodeScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: episodes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final episode = episodes[index];
                final epNum = episode['episode_number'] as int;
                final title = (episode['name'] ?? 'Episode $epNum').toString();
                final still = episode['still_path'] as String?;
                final isSelected = _selectedEpisode == epNum;
                final isWatched = _watchedEpisodes.contains('${_movie.id}_S${_selectedSeason}_E$epNum');

                return _HorizontalEpisodeCard(
                  epNum: epNum,
                  title: title,
                  stillPath: still,
                  isSelected: isSelected,
                  isWatched: isWatched,
                  onToggleWatched: () => _toggleEpisodeWatched(_selectedSeason, epNum),
                  onTap: () {
                    setState(() => _selectedEpisode = epNum);
                    _startExtraction();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimilarContent() {
    if (_similarContent.isEmpty) return const SizedBox.shrink();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'More Like This',
                style: GoogleFonts.montserrat(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios, color: Colors.white70, size: 20),
                    onPressed: () {
                      _similarScrollController.animateTo(
                        _similarScrollController.offset - 300,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 20),
                    onPressed: () {
                      _similarScrollController.animateTo(
                        _similarScrollController.offset + 300,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 250,
          child: ListView.builder(
            controller: _similarScrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            itemCount: _similarContent.length,
            itemBuilder: (context, index) {
              final movie = _similarContent[index];
              return _SimilarMovieCard(movie: movie);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScreenshotsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Screenshots',
                style: GoogleFonts.montserrat(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios, color: Colors.white70, size: 20),
                    onPressed: () {
                      _screenshotsScrollController.animateTo(
                        _screenshotsScrollController.offset - 300,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 20),
                    onPressed: () {
                      _screenshotsScrollController.animateTo(
                        _screenshotsScrollController.offset + 300,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 180,
          child: ListView.builder(
            controller: _screenshotsScrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: _movie.screenshots.take(10).length,
            itemBuilder: (context, index) {
              final screenshot = _movie.screenshots[index];
              return Container(
                width: 320,
                margin: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: TmdbApi.getStillUrl(screenshot),
                    fit: BoxFit.cover,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Details',
            style: GoogleFonts.montserrat(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Column(
              children: [
                _buildDetailRow('Type', _movie.mediaType == 'tv' ? 'TV Series' : 'Movie'),
                const SizedBox(height: 12),
                _buildDetailRow('Release Date', _movie.releaseDate.isNotEmpty ? _movie.releaseDate : 'N/A'),
                const SizedBox(height: 12),
                _buildDetailRow('Rating', '${_movie.voteAverage.toStringAsFixed(1)}/10'),
                if (_movie.runtime > 0) ...[
                  const SizedBox(height: 12),
                  _buildDetailRow('Runtime', '${_movie.runtime} minutes'),
                ],
                if (_movie.mediaType == 'tv' && _movie.numberOfSeasons > 0) ...[
                  const SizedBox(height: 12),
                  _buildDetailRow('Seasons', _movie.numberOfSeasons.toString()),
                ],
                if (_movie.genres.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildDetailRow('Genres', _movie.genres.join(', ')),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

class _HorizontalEpisodeCard extends StatefulWidget {
  final int epNum;
  final String title;
  final String? stillPath;
  final bool isSelected;
  final bool isWatched;
  final VoidCallback onTap;
  final VoidCallback onToggleWatched;

  const _HorizontalEpisodeCard({
    required this.epNum,
    required this.title,
    required this.stillPath,
    required this.isSelected,
    required this.isWatched,
    required this.onTap,
    required this.onToggleWatched,
  });

  @override
  State<_HorizontalEpisodeCard> createState() => _HorizontalEpisodeCardState();
}

class _HorizontalEpisodeCardState extends State<_HorizontalEpisodeCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 220,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isSelected
                  ? const Color(0xFF1565C0)
                  : _isHovered
                      ? Colors.white38
                      : Colors.white12,
              width: 2,
            ),
            boxShadow: (widget.isSelected || _isHovered)
                ? [
                    BoxShadow(
                      color: widget.isSelected
                          ? const Color(0xFF1565C0).withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.08),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Stack(
              children: [
                // thumbnail
                SizedBox(
                  width: 220,
                  height: 190,
                  child: widget.stillPath != null
                      ? CachedNetworkImage(
                          imageUrl: TmdbApi.getStillUrl(widget.stillPath!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        )
                      : Container(
                          color: Colors.white10,
                          child: const Center(
                            child: Icon(Icons.movie_rounded,
                                color: Colors.white24, size: 40),
                          ),
                        ),
                ),
                // dark gradient at bottom
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    height: 70,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                ),
                // play icon in centre
                Center(
                  child: AnimatedOpacity(
                    opacity: _isHovered || widget.isSelected ? 1.0 : 0.55,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: widget.isSelected
                            ? const Color(0xFF1565C0).withValues(alpha: 0.85)
                            : Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 24),
                    ),
                  ),
                ),
                // watched checkmark
                Positioned(
                  top: 6, right: 6,
                  child: GestureDetector(
                    onTap: widget.onToggleWatched,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: widget.isWatched ? Colors.green : Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 14,
                        color: widget.isWatched ? Colors.white : Colors.white38,
                      ),
                    ),
                  ),
                ),
                // episode number + title
                Positioned(
                  left: 10, right: 10, bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'E${widget.epNum}',
                        style: TextStyle(
                          color: widget.isSelected
                              ? const Color(0xFF64B5F6)
                              : Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
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
      ),
    );
  }
}

class _EpisodeCard extends StatefulWidget {
  final Map<String, dynamic> episode;
  final bool isSelected;
  final VoidCallback onTap;

  const _EpisodeCard({
    required this.episode,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final epNum = widget.episode['episode_number'];
    
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.isSelected 
                ? Colors.white.withValues(alpha: 0.12) 
                : _isHovered
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isSelected 
                  ? const Color(0xFF1565C0) 
                  : _isHovered
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.transparent,
              width: widget.isSelected || _isHovered ? 2 : 1,
            ),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: widget.isSelected
                          ? const Color(0xFF1565C0).withValues(alpha: 0.3)
                          : Colors.white.withValues(alpha: 0.1),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 130,
                height: 73,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black26,
                ),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: widget.episode['still_path'] != null
                          ? CachedNetworkImage(
                              imageUrl: TmdbApi.getStillUrl(widget.episode['still_path']),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                            )
                          : const Center(
                              child: Icon(Icons.movie, color: Colors.white24, size: 32),
                            ),
                    ),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Episode $epNum',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.episode['name'] ?? 'Episode $epNum',
                      style: TextStyle(
                        color: _isHovered || widget.isSelected ? Colors.white : Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.episode['runtime'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${widget.episode['runtime']}m',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                    if (widget.episode['overview'] != null && widget.episode['overview'].isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.episode['overview'],
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withValues(alpha: _isHovered ? 0.3 : 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Color(0xFF1565C0), size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeasonChip extends StatefulWidget {
  final int seasonNumber;
  final bool isSelected;
  final VoidCallback onTap;

  const _SeasonChip({
    required this.seasonNumber,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SeasonChip> createState() => _SeasonChipState();
}

class _SeasonChipState extends State<_SeasonChip> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          transform: _isPressed 
              ? Matrix4.diagonal3Values(0.95, 0.95, 1.0)
              : _isHovered 
                  ? Matrix4.diagonal3Values(1.05, 1.05, 1.0)
                  : Matrix4.identity(),
          decoration: BoxDecoration(
            color: widget.isSelected 
                ? const Color(0xFF1565C0) 
                : _isHovered 
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(25),
            border: Border.all(
              color: widget.isSelected 
                  ? const Color(0xFF1565C0) 
                  : _isHovered
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.3),
              width: widget.isSelected || _isHovered ? 2 : 1,
            ),
            boxShadow: _isHovered && !widget.isSelected
                ? [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.2),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              'Season ${widget.seasonNumber}',
              style: TextStyle(
                color: widget.isSelected || _isHovered ? Colors.white : Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SimilarMovieCard extends StatefulWidget {
  final Movie movie;

  const _SimilarMovieCard({required this.movie});

  @override
  State<_SimilarMovieCard> createState() => _SimilarMovieCardState();
}

class _SimilarMovieCardState extends State<_SimilarMovieCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: () {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => StreamingDetailsScreen(movie: widget.movie),
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 130,
          margin: const EdgeInsets.only(right: 16),
          transform: _isHovered ? Matrix4.diagonal3Values(1.05, 1.05, 1.0) : Matrix4.identity(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 195,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _isHovered 
                          ? const Color(0xFF1565C0).withValues(alpha: 0.5)
                          : Colors.black.withValues(alpha: 0.3),
                      blurRadius: _isHovered ? 12 : 8,
                      spreadRadius: _isHovered ? 3 : 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: widget.movie.posterPath.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: TmdbApi.getImageUrl(widget.movie.posterPath),
                          fit: BoxFit.cover,
                        )
                      : Container(
                          color: Colors.white.withValues(alpha: 0.1),
                          child: const Icon(Icons.movie, color: Colors.white38),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.movie.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _isHovered ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: _isHovered ? FontWeight.bold : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 12),
                  const SizedBox(width: 4),
                  Text(
                    widget.movie.voteAverage.toStringAsFixed(1),
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
