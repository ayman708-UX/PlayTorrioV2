import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/movie.dart';
import '../api/tmdb_api.dart';
import '../models/torrent_result.dart';
import '../api/torrent_api.dart';
import '../api/torr_server_service.dart';
import '../api/stremio_service.dart';
import '../api/torrent_filter.dart';
import '../api/settings_service.dart';
import '../api/debrid_api.dart';
import '../services/jackett_service.dart';
import '../services/prowlarr_service.dart';
import '../services/link_resolver.dart';
import '../services/watch_history_service.dart';
import '../utils/extensions.dart';
import '../utils/app_theme.dart';
import '../widgets/loading_overlay.dart';
import 'player_screen.dart';
import 'stremio_catalog_screen.dart';
import 'main_screen.dart';

class DetailsScreen extends StatefulWidget {
  final Movie movie;
  /// Optional: when opened from a Stremio addon search result with a custom ID,
  /// pass the original item so we can auto-select the right addon and use its ID.
  final Map<String, dynamic>? stremioItem;
  const DetailsScreen({super.key, required this.movie, this.stremioItem});

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  late Movie _movie;
  bool _isLoading = true;
  final TmdbApi _api = TmdbApi();
  final TorrentApi _torrentApi = TorrentApi();
  final SettingsService _settings = SettingsService();
  final StremioService _stremio = StremioService();
  final JackettService _jackett = JackettService();
  final ProwlarrService _prowlarr = ProwlarrService();
  final LinkResolver _linkResolver = LinkResolver();

  String _sortPreference = 'Seeders (High to Low)';
  Set<String> _activeAudioFilters = {};
  List<TorrentResult> _allTorrentResults = [];
  bool _isSearching = false;
  String? _errorMessage;
  Map<String, dynamic>? _lastProgress;

  String _selectedSourceId = 'playtorrio';
  List<Map<String, dynamic>> _streamAddons = [];
  List<dynamic> _stremioStreams = [];
  List<Map<String, dynamic>> _allCombinedStremioStreams = [];
  bool _isStremioFetching = false;

  /// Tracks which addon baseUrls have returned results (for dynamic chip display).
  final Set<String> _loadedAddonBaseUrls = {};

  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  Map<String, dynamic>? _seasonData;
  bool _isLoadingSeason = false;

  bool _isJackettConfigured = false;
  bool _isProwlarrConfigured = false;

  // Stremio recommendations from meta links
  List<Map<String, dynamic>> _stremioRecommendations = [];
  bool _isLoadingRecommendations = false;
  final ScrollController _recommendationsScrollController = ScrollController();

  // Desktop cast avatars
  List<Map<String, String>> _castMembers = [];
  final ScrollController _castScrollController = ScrollController();

  final ScrollController _episodeScrollController = ScrollController();
  final ScrollController _seasonScrollController = ScrollController();
  final FocusNode _keyboardFocusNode = FocusNode();

  // ─── lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _movie = widget.movie;
    _checkHistory();
    _loadSortPreference();
    _checkIndexerConfiguration();
    _fetchDetails();
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    _episodeScrollController.dispose();
    _seasonScrollController.dispose();
    _recommendationsScrollController.dispose();
    _castScrollController.dispose();
    _jackett.dispose();
    _prowlarr.dispose();
    _linkResolver.dispose();
    super.dispose();
  }

  // ─── data methods ─────────────────────────────────────────────────────────

  Future<void> _checkHistory() async {
    final progress = await WatchHistoryService().getProgress(
      _movie.id,
      season: _movie.mediaType == 'tv' ? _selectedSeason : null,
      episode: _movie.mediaType == 'tv' ? _selectedEpisode : null,
    );
    if (mounted) setState(() => _lastProgress = progress);
  }

  Future<void> _loadSortPreference() async {
    final pref = await _settings.getSortPreference();
    if (mounted) setState(() => _sortPreference = pref);
  }

  // ─── audio filter helpers ────────────────────────────────────────────────

  static const List<String> _kAudioTags = [
    'Atmos', 'TrueHD', 'DTS:X', 'DTS-HD', 'DTS', 'DD+', 'DD', 'AAC', '7.1', '5.1', '2.0',
  ];

  /// Returns every audio tag found in [name] (upper-cased for matching).
  static List<String> _detectAudioTags(String name) {
    final n = name.toUpperCase();
    final found = <String>[];
    // Order matters – more specific tags must be checked before their substrings
    if (n.contains('ATMOS')) found.add('Atmos');
    if (n.contains('TRUEHD')) found.add('TrueHD');
    if (n.contains('DTS:X') || n.contains('DTSX')) found.add('DTS:X');
    if (!found.contains('DTS:X') && (n.contains('DTS-HD') || n.contains('DTSHD'))) found.add('DTS-HD');
    if (!found.contains('DTS:X') && !found.contains('DTS-HD') && n.contains('DTS')) found.add('DTS');
    if (n.contains('DD+') || n.contains('EAC3') || n.contains('E-AC-3') || n.contains('DDPLUS')) found.add('DD+');
    if (!found.contains('DD+') && (n.contains(' DD ') || n.contains('AC3') || n.contains('DOLBY DIGITAL'))) found.add('DD');
    if (n.contains('AAC')) found.add('AAC');
    if (n.contains('7.1')) found.add('7.1');
    if (!found.contains('7.1') && n.contains('5.1')) found.add('5.1');
    if (n.contains(' 2.0') || n.contains('.2.0')) found.add('2.0');
    return found;
  }

  /// Torrent results after applying the active audio filters.
  List<TorrentResult> get _filteredTorrentResults {
    if (_activeAudioFilters.isEmpty) return _allTorrentResults;
    return _allTorrentResults.where((r) {
      final tags = _detectAudioTags(r.name);
      // Show the result if it matches ANY of the selected tags
      return tags.any((t) => _activeAudioFilters.contains(t));
    }).toList();
  }

  Future<void> _checkIndexerConfiguration() async {
    final jackettConfigured = await _settings.isJackettConfigured();
    final prowlarrConfigured = await _settings.isProwlarrConfigured();
    if (mounted) {
      setState(() {
        _isJackettConfigured = jackettConfigured;
        _isProwlarrConfigured = prowlarrConfigured;
      });
    }
  }

  String _getHash(String magnet) {
    if (magnet.startsWith('magnet:?xt=urn:btih:')) {
      final parts = magnet.split('magnet:?xt=urn:btih:')[1].split('&');
      if (parts.isNotEmpty) return parts[0].toLowerCase();
    }
    return magnet.toLowerCase();
  }

  Future<void> _sortResults() async {
    if (_allTorrentResults.isEmpty) return;
    final sorted = await TorrentFilter.sortTorrentsAsync(_allTorrentResults, _sortPreference);
    if (_lastProgress != null && _lastProgress!['method'] == 'torrent') {
      final historyHash = _getHash(_lastProgress!['sourceId']);
      final index = sorted.indexWhere((r) => _getHash(r.magnet) == historyHash);
      if (index != -1) {
        final match = sorted.removeAt(index);
        sorted.insert(0, match);
      }
    }
    if (mounted) setState(() => _allTorrentResults = sorted);
  }

  Future<void> _fetchDetails() async {
    final stremioItem = widget.stremioItem;
    final bool isCustomId = stremioItem != null &&
        !(stremioItem['id']?.toString().startsWith('tt') ?? true);

    try {
      final streamAddons = await _stremio.getAddonsForResource('stream');

      // If this is a custom-ID Stremio item, skip TMDB fetch — we already
      // have all the info we need from the search result.
      if (isCustomId) {
        debugPrint('[DetailsScreen] Custom ID detected: ${stremioItem['id']}');
        debugPrint('[DetailsScreen] stremioItem keys: ${stremioItem.keys.toList()}');
        debugPrint('[DetailsScreen] _addonBaseUrl: ${stremioItem['_addonBaseUrl']}');
        debugPrint('[DetailsScreen] _addonName: ${stremioItem['_addonName']}');
        debugPrint('[DetailsScreen] type: ${stremioItem['type']}');
        if (mounted) {
          setState(() {
            _streamAddons = streamAddons;
            _isLoading = false;
            // Auto-select the addon that owns this item
            final addonBaseUrl = stremioItem['_addonBaseUrl']?.toString() ?? '';
            if (addonBaseUrl.isNotEmpty) {
              _selectedSourceId = addonBaseUrl;
            } else if (streamAddons.isNotEmpty) {
              _selectedSourceId = streamAddons.first['baseUrl'];
            }
          });
          _fetchStremioStreamsForCustomId(stremioItem);
        }
        return;
      }

      final Movie fullDetails;
      if (_movie.mediaType == 'tv') {
        fullDetails = await _api.getTvDetails(widget.movie.id);
        await _fetchSeason(1);
      } else {
        fullDetails = await _api.getMovieDetails(widget.movie.id);
      }
      if (mounted) {
        setState(() {
          _movie = fullDetails;
          _streamAddons = streamAddons;
          _isLoading = false;
        });
        _autoSearch();
        _fetchAllStremioStreams();
        _fetchStremioRecommendations();
        _fetchCastMembers();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchCastMembers() async {
    try {
      final members = await _api.getCredits(_movie.id, _movie.mediaType);
      if (mounted) setState(() => _castMembers = members);
    } catch (_) {}
  }

  /// Fetches recommendations by getting meta from Stremio addons and
  /// collecting meta.links (stremio:///detail/...) items.
  Future<void> _fetchStremioRecommendations() async {
    final stremioId = _movie.imdbId ?? '';
    if (stremioId.isEmpty) return;

    setState(() => _isLoadingRecommendations = true);
    try {
      final type = _movie.mediaType == 'tv' ? 'series' : 'movie';
      final meta = await _stremio.getMetaFromAny(type: type, id: stremioId);
      if (meta == null || !mounted) {
        if (mounted) setState(() => _isLoadingRecommendations = false);
        return;
      }

      final links = meta['links'] as List? ?? [];
      final List<Map<String, dynamic>> recommendations = [];

      for (final link in links) {
        if (link is! Map) continue;
        final url = link['url']?.toString() ?? '';
        final name = link['name']?.toString() ?? '';
        final category = link['category']?.toString() ?? '';

        final parsed = StremioService.parseMetaLink(url);
        if (parsed == null) continue;

        if (parsed['action'] == 'detail') {
          recommendations.add({
            'name': name,
            'category': category,
            'type': parsed['type'],
            'id': parsed['id'],
            'url': url,
            'poster': null, // Will try to resolve
          });
        }
      }

      // Try to load posters for recommendations by batch-resolving metas
      if (recommendations.isNotEmpty) {
        await Future.wait(recommendations.map((rec) async {
          try {
            final recMeta = await _stremio.getMetaFromAny(
              type: rec['type'] ?? type,
              id: rec['id'],
            );
            if (recMeta != null) {
              rec['poster'] = recMeta['poster'];
              rec['name'] = rec['name'].isEmpty ? (recMeta['name'] ?? '') : rec['name'];
            }
          } catch (_) {}
        }));
      }

      if (mounted) {
        setState(() {
          _stremioRecommendations = recommendations;
          _isLoadingRecommendations = false;
        });
      }
    } catch (e) {
      debugPrint('[DetailsScreen] Recommendations error: $e');
      if (mounted) setState(() => _isLoadingRecommendations = false);
    }
  }

  Future<void> _openRecommendation(Map<String, dynamic> rec) async {
    final id = rec['id']?.toString() ?? '';
    final type = rec['type']?.toString() ?? 'movie';

    // Try TMDB lookup first for IMDB IDs
    if (id.startsWith('tt')) {
      try {
        final movie = await _api.findByImdbId(id, mediaType: type == 'series' ? 'tv' : 'movie');
        if (movie != null && mounted) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: movie)));
          return;
        }
      } catch (_) {}
    }

    // Fallback: search TMDB by name
    final name = rec['name']?.toString() ?? '';
    if (name.isNotEmpty) {
      try {
        final results = await _api.searchMulti(name);
        if (results.isNotEmpty && mounted) {
          final match = results.firstWhere(
            (m) => m.title.toLowerCase() == name.toLowerCase(),
            orElse: () => results.first,
          );
          Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: match)));
          return;
        }
      } catch (_) {}
    }

    // Last fallback: minimal Movie
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(
        movie: Movie(
          id: id.hashCode,
          imdbId: id.startsWith('tt') ? id : null,
          title: name.isNotEmpty ? name : id,
          posterPath: '', backdropPath: '', voteAverage: 0,
          releaseDate: '', overview: '',
          mediaType: type == 'series' ? 'tv' : 'movie',
        ),
      )));
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
          _selectedEpisode = 1;
        });
        if (_selectedSourceId == 'playtorrio') {
          _autoSearch();
        } else if (_selectedSourceId == 'jackett') {
          _searchJackett();
        } else if (_selectedSourceId == 'prowlarr') {
          _searchProwlarr();
        } else if (_selectedSourceId == 'all_stremio') {
          _fetchAllStremioStreams();
        } else {
          _fetchStremioStreams();
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingSeason = false);
    }
  }

  void _autoSearch() {
    _checkHistory();
    final year = _movie.releaseDate.take(4);
    if (_movie.mediaType == 'tv') {
      final s = _selectedSeason.toString().padLeft(2, '0');
      final e = _selectedEpisode.toString().padLeft(2, '0');
      _searchTvTorrents('${_movie.title} S$s', '${_movie.title} S${s}E$e');
    } else {
      _searchTorrents('${_movie.title} $year');
    }
  }

  /// Fetches streams from ALL installed stream addons in parallel,
  /// updating the UI incrementally as each addon responds.
  Future<void> _fetchAllStremioStreams() async {
    if (_streamAddons.isEmpty) return;
    setState(() {
      _isStremioFetching = true;
      _errorMessage = null;
      _allCombinedStremioStreams = [];
      _loadedAddonBaseUrls.clear();
      if (!_isTorrentSource) _stremioStreams = [];
    });
    try {
      String stremioId = _movie.imdbId ?? '';
      if (stremioId.isEmpty) {
        if (mounted) setState(() => _isStremioFetching = false);
        return;
      }
      if (_movie.mediaType == 'tv') stremioId = '$stremioId:$_selectedSeason:$_selectedEpisode';
      final type = _movie.mediaType == 'tv' ? 'series' : 'movie';

      int pendingCount = _streamAddons.length;

      for (final addon in _streamAddons) {
        // Fire each addon fetch independently — don't await here
        _stremio.getStreams(baseUrl: addon['baseUrl'], type: type, id: stremioId).then((streams) {
          if (!mounted) return;
          final tagged = streams.map((s) {
            if (s is Map<String, dynamic>) {
              return <String, dynamic>{
                ...s,
                '_addonName': addon['name'] ?? 'Unknown',
                '_addonBaseUrl': addon['baseUrl'],
              };
            }
            return <String, dynamic>{'_addonName': addon['name'], '_addonBaseUrl': addon['baseUrl']};
          }).toList();

          setState(() {
            // Only show chip if addon returned results
            if (tagged.isNotEmpty) {
              _loadedAddonBaseUrls.add(addon['baseUrl'] as String);
            }
            // Append below existing results
            _allCombinedStremioStreams.addAll(tagged);
            if (!_isTorrentSource) _applyStremioFilter();
          });
        }).catchError((_) {
          // No-op: don't show chip for errored addons
        }).whenComplete(() {
          if (!mounted) return;
          pendingCount--;
          if (pendingCount <= 0) {
            setState(() {
              _isStremioFetching = false;
              if (_allCombinedStremioStreams.isEmpty && !_isTorrentSource) {
                _errorMessage = 'No streams found from any addon';
              }
            });
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = 'Error: $e'; _isStremioFetching = false; });
    }
  }

  /// Fetches streams using the custom Stremio ID from the originating addon.
  Future<void> _fetchStremioStreamsForCustomId(Map<String, dynamic> item) async {
    final customId = item['id']?.toString() ?? '';
    final addonBaseUrl = item['_addonBaseUrl']?.toString() ?? '';
    final addonName = item['_addonName']?.toString() ?? 'Unknown';
    final type = item['type']?.toString() ?? (_movie.mediaType == 'tv' ? 'series' : 'movie');
    debugPrint('[CustomIdStreams] customId=$customId, addonBaseUrl=$addonBaseUrl, type=$type');
    if (customId.isEmpty || addonBaseUrl.isEmpty) {
      debugPrint('[CustomIdStreams] SKIPPED: customId empty=${customId.isEmpty}, addonBaseUrl empty=${addonBaseUrl.isEmpty}');
      return;
    }

    setState(() { _isStremioFetching = true; _errorMessage = null; _stremioStreams = []; _allCombinedStremioStreams = []; _loadedAddonBaseUrls.clear(); });
    
    try {
      // For series, first fetch meta to get videos array with season/episode info
      if (type == 'series') {
        final meta = await _stremio.getMeta(baseUrl: addonBaseUrl, type: type, id: customId);
        if (meta != null && meta['videos'] != null) {
          final videos = meta['videos'] as List;
          debugPrint('[CustomIdStreams] Got ${videos.length} videos from meta');
          
          // Parse videos to build season/episode structure
          _parseCustomIdVideos(videos);
          
          // Now fetch streams for the selected episode
          final selectedVideo = _getSelectedVideoFromCustomId(videos);
          if (selectedVideo != null) {
            final videoId = selectedVideo['id']?.toString() ?? '';
            debugPrint('[CustomIdStreams] Fetching streams for video: $videoId');
            final streams = await _stremio.getStreams(baseUrl: addonBaseUrl, type: type, id: videoId);
            debugPrint('[CustomIdStreams] Got ${streams.length} streams');
            
            if (mounted) {
              final tagged = streams.map((s) {
                if (s is Map<String, dynamic>) {
                  return <String, dynamic>{...s, '_addonName': addonName, '_addonBaseUrl': addonBaseUrl};
                }
                return <String, dynamic>{'_addonName': addonName, '_addonBaseUrl': addonBaseUrl};
              }).toList();
              setState(() {
                _stremioStreams = tagged;
                _allCombinedStremioStreams = tagged;
                _loadedAddonBaseUrls.add(addonBaseUrl);
                _isStremioFetching = false;
                if (streams.isEmpty) _errorMessage = 'No streams found';
              });
            }
            return;
          }
        }
      }
      
      // For movies or if meta fetch failed, use the original ID directly
      final streams = await _stremio.getStreams(baseUrl: addonBaseUrl, type: type, id: customId);
      debugPrint('[CustomIdStreams] Got ${streams.length} streams');
      if (streams.isNotEmpty) debugPrint('[CustomIdStreams] First stream: ${streams.first}');
      if (mounted) {
        final tagged = streams.map((s) {
          if (s is Map<String, dynamic>) {
            return <String, dynamic>{...s, '_addonName': addonName, '_addonBaseUrl': addonBaseUrl};
          }
          return <String, dynamic>{'_addonName': addonName, '_addonBaseUrl': addonBaseUrl};
        }).toList();
        setState(() {
          _stremioStreams = tagged;
          _allCombinedStremioStreams = tagged;
          _loadedAddonBaseUrls.add(addonBaseUrl);
          _isStremioFetching = false;
          if (streams.isEmpty) _errorMessage = 'No streams found';
        });
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = 'Error: $e'; _isStremioFetching = false; _loadedAddonBaseUrls.add(addonBaseUrl); });
    }
  }

  /// Parses the videos array from custom ID meta to build season/episode structure
  void _parseCustomIdVideos(List videos) {
    if (videos.isEmpty) return;
    
    // Build a map of seasons to episodes
    final Map<int, List<Map<String, dynamic>>> seasonMap = {};
    for (final video in videos) {
      if (video is! Map) continue;
      final season = video['season'] as int? ?? 1;
      final episode = video['episode'] as int? ?? 1;
      
      seasonMap.putIfAbsent(season, () => []);
      seasonMap[season]!.add({
        'id': video['id'],
        'title': video['title'] ?? 'Episode $episode',
        'episode': episode,
        'season': season,
        'thumbnail': video['thumbnail'],
        'released': video['released'],
      });
    }
    
    // Sort episodes within each season
    for (final episodes in seasonMap.values) {
      episodes.sort((a, b) => (a['episode'] as int).compareTo(b['episode'] as int));
    }
    
    // Store in _seasonData format compatible with existing UI
    if (mounted) {
      setState(() {
        _seasonData = {
          'seasons': seasonMap.keys.toList()..sort(),
          'episodesBySeason': seasonMap,
        };
        // Ensure selected season/episode are valid
        if (!seasonMap.containsKey(_selectedSeason)) {
          _selectedSeason = seasonMap.keys.first;
        }
        final episodes = seasonMap[_selectedSeason] ?? [];
        if (episodes.isEmpty || _selectedEpisode > episodes.length) {
          _selectedEpisode = episodes.isNotEmpty ? episodes.first['episode'] : 1;
        }
      });
    }
  }

  /// Gets the selected video from the custom ID videos array
  Map<String, dynamic>? _getSelectedVideoFromCustomId(List videos) {
    for (final video in videos) {
      if (video is! Map) continue;
      final season = video['season'] as int? ?? 1;
      final episode = video['episode'] as int? ?? 1;
      if (season == _selectedSeason && episode == _selectedEpisode) {
        return video as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// Fetches streams from a single selected addon only.
  Future<void> _fetchStremioStreams() async {
    if (_selectedSourceId == 'all_stremio') {
      // "All" chip → just re-filter from cached results, or re-fetch if empty
      if (_allCombinedStremioStreams.isEmpty) {
        return _fetchAllStremioStreams();
      }
      setState(() { _stremioStreams = _allCombinedStremioStreams; _errorMessage = null; });
      return;
    }
    final addon = _streamAddons.firstWhere(
      (a) => a['baseUrl'] == _selectedSourceId,
      orElse: () => _streamAddons.isNotEmpty ? _streamAddons.first : <String, dynamic>{},);
    if (addon.isEmpty) return;
    setState(() { _isStremioFetching = true; _errorMessage = null; _stremioStreams = []; });
    try {
      String stremioId = _movie.imdbId ?? '';
      if (_movie.mediaType == 'tv') stremioId = '$stremioId:$_selectedSeason:$_selectedEpisode';
      final type = _movie.mediaType == 'tv' ? 'series' : 'movie';
      final streams = await _stremio.getStreams(baseUrl: addon['baseUrl'], type: type, id: stremioId);
      if (mounted) {
        setState(() {
          _stremioStreams = streams;
          if (streams.isEmpty) _errorMessage = 'No streams found in ${addon['name']}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _isStremioFetching = false);
    }
  }

  /// Applies the current addon filter chip to _allCombinedStremioStreams.
  void _applyStremioFilter() {
    if (_selectedSourceId == 'all_stremio' || _isTorrentSource) {
      _stremioStreams = _allCombinedStremioStreams;
    } else {
      _stremioStreams = _allCombinedStremioStreams
          .where((s) => s['_addonBaseUrl'] == _selectedSourceId)
          .toList();
    }
  }

  Future<void> _searchTvTorrents(String seasonQuery, String episodeQuery) async {
    setState(() { _isSearching = true; _allTorrentResults = []; _errorMessage = null; });
    try {
      final results = await Future.wait([
        _torrentApi.searchTorrents(seasonQuery),
        _torrentApi.searchTorrents(episodeQuery),
      ]);
      if (mounted) {
        final filteredSeason = await TorrentFilter.filterTorrentsAsync(results[0], _movie.title, requiredSeason: _selectedSeason);
        final filteredEpisode = await TorrentFilter.filterTorrentsAsync(results[1], _movie.title, requiredSeason: _selectedSeason, requiredEpisode: _selectedEpisode);
        final combined = <String, TorrentResult>{};
        for (var r in filteredEpisode) { combined[r.magnet] = r; }
        for (var r in filteredSeason) { combined[r.magnet] = r; }
        if (mounted) {
          setState(() { _allTorrentResults = combined.values.toList(); _isSearching = false; });
          _sortResults();
        }
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = e.toString(); _isSearching = false; });
    }
  }

  Future<void> _searchTorrents(String query) async {
    setState(() { _isSearching = true; _allTorrentResults = []; _errorMessage = null; });
    try {
      final results = await _torrentApi.searchTorrents(query);
      if (mounted) {
        final filtered = await TorrentFilter.filterTorrentsAsync(results, _movie.title);
        if (mounted) {
          setState(() { _allTorrentResults = filtered; _isSearching = false; });
          _sortResults();
        }
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = e.toString(); _isSearching = false; });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Jackett Search
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _searchJackett() async {
    if (!_isJackettConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Jackett is not configured. Go to Settings to add your Base URL and API Key.'))
        );
      }
      return;
    }

    setState(() { _isSearching = true; _allTorrentResults = []; _errorMessage = null; });

    try {
      final baseUrl = await _settings.getJackettBaseUrl();
      final apiKey = await _settings.getJackettApiKey();

      if (baseUrl == null || apiKey == null) throw Exception('Jackett configuration missing');

      if (_movie.mediaType == 'tv') {
        final s = _selectedSeason.toString().padLeft(2, '0');
        final e = _selectedEpisode.toString().padLeft(2, '0');
        final results = await Future.wait([
          _jackett.search(baseUrl, apiKey, '${_movie.title} S$s'),
          _jackett.search(baseUrl, apiKey, '${_movie.title} S${s}E$e'),
        ]);
        if (mounted) {
          final filteredSeason = await TorrentFilter.filterTorrentsAsync(results[0], _movie.title, requiredSeason: _selectedSeason);
          final filteredEpisode = await TorrentFilter.filterTorrentsAsync(results[1], _movie.title, requiredSeason: _selectedSeason, requiredEpisode: _selectedEpisode);
          final combined = <String, TorrentResult>{};
          for (var r in filteredEpisode) { combined[r.magnet] = r; }
          for (var r in filteredSeason) { combined[r.magnet] = r; }
          if (mounted) {
            if (combined.isEmpty) {
              setState(() { _errorMessage = 'No results found for "S${s}E$e". Try checking your configured indexers in Jackett.'; _isSearching = false; });
            } else {
              setState(() { _allTorrentResults = combined.values.toList(); _isSearching = false; });
              _sortResults();
            }
          }
        }
      } else {
        final year = _movie.releaseDate.length >= 4 ? _movie.releaseDate.substring(0, 4) : '';
        final query = year.isNotEmpty ? '${_movie.title} $year' : _movie.title;
        final results = await _jackett.search(baseUrl, apiKey, query);
        if (mounted) {
          final filtered = await TorrentFilter.filterTorrentsAsync(results, _movie.title);
          if (mounted) {
            if (filtered.isEmpty) {
              setState(() { _errorMessage = 'No results found for "$query". Try checking your configured indexers in Jackett.'; _isSearching = false; });
            } else {
              setState(() { _allTorrentResults = filtered; _isSearching = false; });
              _sortResults();
            }
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = e.toString(); _isSearching = false; });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Prowlarr Search
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _searchProwlarr() async {
    if (!_isProwlarrConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Prowlarr is not configured. Go to Settings to add your Base URL and API Key.'))
        );
      }
      return;
    }

    setState(() { _isSearching = true; _allTorrentResults = []; _errorMessage = null; });

    try {
      final baseUrl = await _settings.getProwlarrBaseUrl();
      final apiKey = await _settings.getProwlarrApiKey();

      if (baseUrl == null || apiKey == null) throw Exception('Prowlarr configuration missing');

      if (_movie.mediaType == 'tv') {
        final s = _selectedSeason.toString().padLeft(2, '0');
        final e = _selectedEpisode.toString().padLeft(2, '0');
        final results = await Future.wait([
          _prowlarr.search(baseUrl, apiKey, '${_movie.title} S$s'),
          _prowlarr.search(baseUrl, apiKey, '${_movie.title} S${s}E$e'),
        ]);
        if (mounted) {
          final filteredSeason = await TorrentFilter.filterTorrentsAsync(results[0], _movie.title, requiredSeason: _selectedSeason);
          final filteredEpisode = await TorrentFilter.filterTorrentsAsync(results[1], _movie.title, requiredSeason: _selectedSeason, requiredEpisode: _selectedEpisode);
          final combined = <String, TorrentResult>{};
          for (var r in filteredEpisode) { combined[r.magnet] = r; }
          for (var r in filteredSeason) { combined[r.magnet] = r; }
          if (mounted) {
            if (combined.isEmpty) {
              setState(() { _errorMessage = 'No results found for "S${s}E$e". Try checking your configured indexers in Prowlarr.'; _isSearching = false; });
            } else {
              setState(() { _allTorrentResults = combined.values.toList(); _isSearching = false; });
              _sortResults();
            }
          }
        }
      } else {
        final year = _movie.releaseDate.length >= 4 ? _movie.releaseDate.substring(0, 4) : '';
        final query = year.isNotEmpty ? '${_movie.title} $year' : _movie.title;
        final results = await _prowlarr.search(baseUrl, apiKey, query);
        if (mounted) {
          final filtered = await TorrentFilter.filterTorrentsAsync(results, _movie.title);
          if (mounted) {
            if (filtered.isEmpty) {
              setState(() { _errorMessage = 'No results found for "$query". Try checking your configured indexers in Prowlarr.'; _isSearching = false; });
            } else {
              setState(() { _allTorrentResults = filtered; _isSearching = false; });
              _sortResults();
            }
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = e.toString(); _isSearching = false; });
    }
  }

  // ─── safe field helpers ───────────────────────────────────────────────────

  List<String> _getCastNames() {
    try {
      final dynamic m = _movie;
      final dynamic raw = m.castNames ?? m.cast ?? m.credits;
      if (raw is List) return raw.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  String _getTrackerName(TorrentResult result) {
    try {
      final dynamic r = result;
      final dynamic raw = r.source ?? r.tracker ?? r.provider ?? r.site;
      if (raw is String) return raw;
    } catch (_) {}
    return '';
  }

  // ─── play methods ─────────────────────────────────────────────────────────

  void _playStremioStream(Map<String, dynamic> stream, {Duration? startPosition}) async {
    // Handle externalUrl streams (e.g. "More Like This" addon)
    final externalUrl = stream['externalUrl']?.toString();
    if (externalUrl != null && externalUrl.isNotEmpty) {
      final streamAddonBaseUrl = stream['_addonBaseUrl']?.toString() ?? _selectedSourceId;
      await _handleExternalUrl(externalUrl, addonBaseUrl: streamAddonBaseUrl);
      return;
    }

    final useDebrid = await _settings.useDebridForStreams();
    final debridService = await _settings.getDebridService();

    if (stream['url'] != null) {
      if (!mounted) return;
      // Determine stremio item ID for resume (custom ID or IMDB ID)
      final stremioId = widget.stremioItem?['id']?.toString() ?? _movie.imdbId;
      final stremioAddonBaseUrl = stream['_addonBaseUrl']?.toString() ?? _selectedSourceId;
      Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(
        streamUrl: stream['url'], title: _movie.title,
        headers: Map<String, String>.from(stream['behaviorHints']?['proxyHeaders']?['request'] ?? {}),
        movie: _movie,
        selectedSeason: _movie.mediaType == 'tv' ? _selectedSeason : null,
        selectedEpisode: _movie.mediaType == 'tv' ? _selectedEpisode : null,
        startPosition: startPosition,
        activeProvider: 'stremio_direct',
        stremioId: stremioId,
        stremioAddonBaseUrl: stremioAddonBaseUrl,
      )));
    } else if (stream['infoHash'] != null) {
      // Build a proper magnet link:
      // - include display name from stream title
      // - include tracker URLs from the 'sources' list
      //   (Stremio addons provide these as "tracker:udp://...", "tracker:http://...")
      final infoHash = stream['infoHash'] as String;
      final streamTitle = (stream['title'] ?? stream['name'] ?? '').toString();
      final dn = streamTitle.isNotEmpty ? '&dn=${Uri.encodeComponent(streamTitle)}' : '';

      // Extract trackers from sources
      final sources = stream['sources'];
      final trackerParams = StringBuffer();
      if (sources is List) {
        for (final src in sources) {
          if (src is String && src.startsWith('tracker:')) {
            final tracker = src.substring('tracker:'.length);
            trackerParams.write('&tr=${Uri.encodeComponent(tracker)}');
          }
        }
      }

      final magnet = 'magnet:?xt=urn:btih:$infoHash$dn$trackerParams';

      // fileIdx tells us exactly which file to play — no metadata poll needed
      final fileIdx = stream['fileIdx'] as int?;

      if (!mounted) return;
      showDialog(context: context, barrierDismissible: false, barrierColor: Colors.black,
        builder: (_) => LoadingOverlay(movie: _movie,
          message: useDebrid && debridService != 'None' ? 'Resolving with $debridService...' : 'Starting Torrent Engine...'));
      final navigator = Navigator.of(context);
      String? url;
      try {
        if (useDebrid && debridService != 'None') {
          final debrid = DebridApi();
          final files = debridService == 'Real-Debrid'
              ? await debrid.resolveRealDebrid(magnet) : await debrid.resolveTorBox(magnet);
          if (files.isNotEmpty) {
            if (_movie.mediaType == 'tv') {
              final s = 'S${_selectedSeason.toString().padLeft(2, '0')}';
              final e = 'E${_selectedEpisode.toString().padLeft(2, '0')}';
              final match = files.where((f) => f.filename.toUpperCase().contains(s) && f.filename.toUpperCase().contains(e)).toList();
              files.sort((a, b) => b.filesize.compareTo(a.filesize));
              url = match.isNotEmpty ? match.first.downloadUrl : files.first.downloadUrl;
            } else {
              files.sort((a, b) => b.filesize.compareTo(a.filesize));
              url = files.first.downloadUrl;
            }
          }
        } else {
          url = await TorrServerService().streamTorrent(magnet,
            season: _movie.mediaType == 'tv' ? _selectedSeason : null,
            episode: _movie.mediaType == 'tv' ? _selectedEpisode : null,
            fileIdx: fileIdx);
        }
      } catch (e) { debugPrint('Stremio hash error: $e'); }
      if (navigator.canPop()) navigator.pop();
      if (url != null && mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(
          streamUrl: url!, title: _movie.title, magnetLink: magnet, movie: _movie,
          selectedSeason: _movie.mediaType == 'tv' ? _selectedSeason : null,
          selectedEpisode: _movie.mediaType == 'tv' ? _selectedEpisode : null,
          startPosition: startPosition)));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to resolve stream.')));
      }
    }
  }

  /// Handles a Stremio externalUrl: stremio:///detail, stremio:///search, or web URLs.
  Future<void> _handleExternalUrl(String url, {String? addonBaseUrl}) async {
    // Try parsing as a stremio:// link
    final parsed = StremioService.parseMetaLink(url);
    if (parsed != null) {
      switch (parsed['action']) {
        case 'detail':
          var id = parsed['id']?.toString() ?? '';
          final type = parsed['type']?.toString() ?? 'movie';
          // Extract IMDB ID from prefixed IDs like "mlt-rec-tt14905854"
          if (!id.startsWith('tt')) {
            final imdbMatch = RegExp(r'(tt\d+)').firstMatch(id);
            if (imdbMatch != null) {
              id = imdbMatch.group(1)!;
            }
          }
          await _openRecommendation({'id': id, 'type': type, 'name': ''});
          return;

        case 'search':
          final query = parsed['query']?.toString() ?? '';
          if (query.isNotEmpty && mounted) {
            // Pop back to MainScreen, then fire the search notifier
            Navigator.popUntil(context, (route) => route.isFirst);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              MainScreen.stremioSearchNotifier.value = null;
              MainScreen.stremioSearchNotifier.value = {
                'query': query,
                'addonBaseUrl': addonBaseUrl ?? '',
              };
            });
          }
          return;

        case 'discover':
          // Open the catalog screen for this discover link
          if (mounted) {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => StremioCatalogScreen()));
          }
          return;
      }
    }

    // Regular https:// URL → open in external browser
    if (url.startsWith('http://') || url.startsWith('https://')) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to handle this link')));
    }
  }

  void _playTorrent(TorrentResult result, {Duration? startPosition}) async {
    final useDebrid = await _settings.useDebridForStreams();
    final debridService = await _settings.getDebridService();
    if (!mounted) return;

    showDialog(context: context, barrierDismissible: false, barrierColor: Colors.black,
      builder: (_) => LoadingOverlay(movie: _movie,
        message: useDebrid && debridService != 'None' ? 'Resolving with $debridService...' : 'Starting Torrent Engine...'));

    String? url;
    String? magnetLink = result.magnet;

    try {
      if (!magnetLink.startsWith('magnet:')) {
        if (!mounted) return;
        Navigator.pop(context);
        showDialog(context: context, barrierDismissible: false, barrierColor: Colors.black,
          builder: (_) => LoadingOverlay(movie: _movie, message: 'Resolving download link...'));
        try {
          final resolved = await _linkResolver.resolve(magnetLink);
          if (resolved.isMagnet) {
            magnetLink = resolved.link;
          } else if (resolved.torrentBytes != null) {
            if (!mounted) return;
            if (Navigator.canPop(context)) Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Torrent file downloads not yet supported. Please use magnet links.'))
            );
            return;
          }
        } catch (e) {
          if (!mounted) return;
          if (Navigator.canPop(context)) Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
          return;
        }
        if (!mounted) return;
        if (Navigator.canPop(context)) Navigator.pop(context);
        showDialog(context: context, barrierDismissible: false, barrierColor: Colors.black,
          builder: (_) => LoadingOverlay(movie: _movie,
            message: useDebrid && debridService != 'None' ? 'Resolving with $debridService...' : 'Starting Torrent Engine...'));
      }

      if (useDebrid && debridService != 'None') {
        final debrid = DebridApi();
        final files = debridService == 'Real-Debrid'
            ? await debrid.resolveRealDebrid(magnetLink)
            : await debrid.resolveTorBox(magnetLink);
        if (files.isNotEmpty) {
          if (_movie.mediaType == 'tv') {
            final s = 'S${_selectedSeason.toString().padLeft(2, '0')}';
            final e = 'E${_selectedEpisode.toString().padLeft(2, '0')}';
            final match = files.where((f) => f.filename.toUpperCase().contains(s) && f.filename.toUpperCase().contains(e)).toList();
            files.sort((a, b) => b.filesize.compareTo(a.filesize));
            url = match.isNotEmpty ? match.first.downloadUrl : files.first.downloadUrl;
          } else {
            files.sort((a, b) => b.filesize.compareTo(a.filesize));
            url = files.first.downloadUrl;
          }
        }
      } else {
        url = await TorrServerService().streamTorrent(magnetLink,
          season: _movie.mediaType == 'tv' ? _selectedSeason : null,
          episode: _movie.mediaType == 'tv' ? _selectedEpisode : null);
      }
    } catch (e) {
      debugPrint('Stream error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }

    if (!mounted) return;
    if (Navigator.canPop(context)) Navigator.pop(context);

    if (url != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(
        streamUrl: url!, title: result.name, magnetLink: magnetLink, movie: _movie,
        selectedSeason: _movie.mediaType == 'tv' ? _selectedSeason : null,
        selectedEpisode: _movie.mediaType == 'tv' ? _selectedEpisode : null,
        startPosition: startPosition)));
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Stack(fit: StackFit.expand, children: [
          _buildBackdropWidget(),
          const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
        ]),
      );
    }

    final w = MediaQuery.of(context).size.width;
    final isMobile = w < 800;

    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent && _movie.mediaType == 'tv' && _seasonData != null) {
          final episodes = _seasonData!['episodes'] as List?;
          if (episodes == null || episodes.isEmpty) return;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft && _selectedEpisode > 1) {
            setState(() => _selectedEpisode--); _autoSearch();
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight && _selectedEpisode < episodes.length) {
            setState(() => _selectedEpisode++); _autoSearch();
          } else if (event.logicalKey == LogicalKeyboardKey.arrowUp && _selectedSeason > 1) {
            _fetchSeason(_selectedSeason - 1); setState(() => _selectedEpisode = 1);
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown && _selectedSeason < _movie.numberOfSeasons) {
            _fetchSeason(_selectedSeason + 1); setState(() => _selectedEpisode = 1);
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: Padding(
            padding: const EdgeInsets.all(8),
            child: FocusableControl(
              onTap: () => Navigator.of(context).pop(),
              borderRadius: 50,
              child: const CircleAvatar(
                backgroundColor: Colors.black54,
                child: Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
        ),
        body: Stack(children: [
          _buildBackdropWidget(),
          SafeArea(child: isMobile ? _buildMobileLayout() : _buildDesktopLayout()),
        ]),
      ),
    );
  }

  // ─── shared backdrop ──────────────────────────────────────────────────────

  /// Returns a full image URL. If the path is already a full URL (e.g. from
  /// Stremio), returns it as-is; otherwise wraps with TMDB base URL.
  String _imageUrl(String path) =>
      path.startsWith('http') ? path : TmdbApi.getImageUrl(path);

  Widget _buildBackdropWidget() {
    final url = _imageUrl(_movie.backdropPath.isNotEmpty ? _movie.backdropPath : _movie.posterPath);
    return Positioned.fill(
      child: Stack(fit: StackFit.expand, children: [
        CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorWidget: (c, u, e) => Container(color: const Color(0xFF0A0A1A)),
        ),
        BackdropFilter(filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(color: Colors.transparent)),
        Container(decoration: const BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xD5050510), Color(0xE8000000)]))),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MOBILE LAYOUT
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildMobileLayout() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildMobileHero(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 6, runSpacing: 6,
                  children: _movie.genres.take(3).map(_genreChip).toList()),
                const SizedBox(height: 16),
                _ExpandableSynopsis(text: _movie.overview),
                const SizedBox(height: 16),
                Builder(builder: (ctx) {
                  final cast = _getCastNames();
                  if (cast.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionLabel('Cast'),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: cast.take(8).map((n) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _castChip(n),
                          )).toList(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  );
                }),
                _buildRecommendationsSection(),
                if (_movie.mediaType == 'tv') ...[
                  _buildSeasonSelector(),
                  const SizedBox(height: 16),
                  _buildEpisodeSelector(),
                  const SizedBox(height: 6),
                  const Text('← → Episodes  |  ↑ ↓ Season',
                    style: TextStyle(color: Colors.white24, fontSize: 10)),
                  const SizedBox(height: 20),
                ],
                _buildSourceToggle(),
                const SizedBox(height: 12),
                _buildSourceChips(),
                const SizedBox(height: 16),
                _buildResultsHeader(),
                const SizedBox(height: 10),
                _buildStreamList(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileHero() {
    return SizedBox(
      height: 260,
      child: Stack(
        children: [
          Positioned.fill(
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.5, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: CachedNetworkImage(
                imageUrl: _imageUrl(_movie.backdropPath.isNotEmpty ? _movie.backdropPath : _movie.posterPath),
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorWidget: (c, u, e) => Container(color: const Color(0xFF0A0A1A)),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x33000000), Color(0xCC000000), Color(0xFF000000)],
                stops: [0.0, 0.65, 1.0],
              )),
            ),
          ),
          Positioned(
            left: 16, right: 16, bottom: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Hero(
                  tag: 'movie-poster-${_movie.id}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetworkImage(
                      imageUrl: _imageUrl(_movie.posterPath),
                      width: 90, height: 132, fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_movie.title,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                          color: Colors.white, height: 1.2),
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 6),
                      Row(children: [
                        Text(_movie.releaseDate.take(4),
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        const SizedBox(width: 8),
                        const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 13),
                        const SizedBox(width: 3),
                        Text(_movie.voteAverage.toStringAsFixed(1),
                          style: const TextStyle(color: Color(0xFFFFD700), fontSize: 12, fontWeight: FontWeight.w600)),
                      ]),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DESKTOP LAYOUT
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDesktopLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 520,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 16, 20, 32),
            child: _buildDesktopLeftPanel(),
          ),
        ),
        Container(width: 1, color: Colors.white.withValues(alpha: 0.07)),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: _buildRightPanel(),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopLeftPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'movie-poster-${_movie.id}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: _imageUrl(_movie.posterPath),
                  width: 260, height: 380, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(_movie.title,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                      color: Colors.white, height: 1.2)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Text(_movie.releaseDate.take(4),
                      style: const TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(width: 8),
                    const Text('·', style: TextStyle(color: Colors.white38)),
                    const SizedBox(width: 8),
                    const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 15),
                    const SizedBox(width: 3),
                    Text(_movie.voteAverage.toStringAsFixed(1),
                      style: const TextStyle(color: Color(0xFFFFD700), fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6,
                    children: _movie.genres.take(3).map(_genreChip).toList()),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(_movie.overview,
          style: const TextStyle(color: Color(0xFFB0B0C0), fontSize: 13.5, height: 1.6)),
        const SizedBox(height: 20),
        if (_castMembers.isNotEmpty) _buildDesktopCastRow(),
        _buildRecommendationsSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  RIGHT PANEL
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_movie.mediaType == 'tv') ...[
          _buildSeasonSelector(),
          const SizedBox(height: 20),
          _buildEpisodeSelector(),
          const SizedBox(height: 8),
          const Text('← → Navigate Episodes  |  ↑ ↓ Change Season',
            style: TextStyle(color: Colors.white24, fontSize: 11)),
          const SizedBox(height: 24),
        ],
        _buildSourceToggle(),
        const SizedBox(height: 14),
        _buildSourceChips(),
        const SizedBox(height: 20),
        _buildResultsHeader(),
        const SizedBox(height: 12),
        _buildStreamList(),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SEASON SELECTOR
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildSeasonSelector() {
    // Get season count from either TMDB or custom ID data
    int seasonCount = _movie.numberOfSeasons;
    if (_seasonData != null && _seasonData!['seasons'] != null) {
      // Custom ID format
      final seasons = _seasonData!['seasons'] as List<int>;
      seasonCount = seasons.length;
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              const Icon(Icons.layers_outlined, color: Colors.white54, size: 16),
              const SizedBox(width: 6),
              const Text('Seasons', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            Row(children: [
              _scrollArrow(Icons.arrow_back_ios_rounded, () => _seasonScrollController.animateTo(
                _seasonScrollController.offset - 160, duration: const Duration(milliseconds: 280), curve: Curves.easeInOut)),
              _scrollArrow(Icons.arrow_forward_ios_rounded, () => _seasonScrollController.animateTo(
                _seasonScrollController.offset + 160, duration: const Duration(milliseconds: 280), curve: Curves.easeInOut)),
            ]),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 38,
          child: ListView.separated(
            controller: _seasonScrollController,
            scrollDirection: Axis.horizontal,
            itemCount: seasonCount,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final n = i + 1;
              final sel = _selectedSeason == n;
              return FocusableControl(
                onTap: () {
                  // For custom IDs, just update state and re-fetch
                  if (widget.stremioItem != null && _seasonData != null && _seasonData!['episodesBySeason'] != null) {
                    setState(() {
                      _selectedSeason = n;
                      _selectedEpisode = 1;
                    });
                    _fetchStremioStreamsForCustomId(widget.stremioItem!);
                  } else {
                    // For TMDB, fetch season data
                    _fetchSeason(n);
                  }
                },
                borderRadius: 20,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: sel ? Colors.white : Colors.white30, width: 1.2),
                  ),
                  child: Text('Season $n',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: sel ? Colors.black : Colors.white70)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  EPISODE SELECTOR
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildEpisodeSelector() {
    if (_isLoadingSeason) {
      return const SizedBox(height: 140,
        child: Center(child: CircularProgressIndicator(color: AppTheme.primaryColor, strokeWidth: 2)));
    }
    
    // Handle both TMDB format (_seasonData['episodes']) and custom ID format (_seasonData['episodesBySeason'])
    List episodes = [];
    if (_seasonData != null) {
      if (_seasonData!['episodes'] != null) {
        // TMDB format
        episodes = _seasonData!['episodes'] as List;
      } else if (_seasonData!['episodesBySeason'] != null) {
        // Custom ID format
        final episodesBySeason = _seasonData!['episodesBySeason'] as Map<int, List<Map<String, dynamic>>>;
        episodes = episodesBySeason[_selectedSeason] ?? [];
      }
    }
    
    if (episodes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              const Icon(Icons.video_library_outlined, color: Colors.white54, size: 16),
              const SizedBox(width: 6),
              Text('Episodes (${episodes.length})',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            Row(children: [
              _scrollArrow(Icons.arrow_back_ios_rounded, () => _episodeScrollController.animateTo(
                _episodeScrollController.offset - 240, duration: const Duration(milliseconds: 280), curve: Curves.easeInOut)),
              _scrollArrow(Icons.arrow_forward_ios_rounded, () => _episodeScrollController.animateTo(
                _episodeScrollController.offset + 240, duration: const Duration(milliseconds: 280), curve: Curves.easeInOut)),
            ]),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 155,
          child: ListView.separated(
            controller: _episodeScrollController,
            scrollDirection: Axis.horizontal,
            itemCount: episodes.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) {
              final ep = episodes[i];
              // Handle both TMDB and custom ID formats
              final epNum = (ep['episode_number'] ?? ep['episode']) as int;
              final sel = _selectedEpisode == epNum;
              final epName = ep['name'] ?? ep['title'] ?? 'Episode $epNum';
              final thumbnail = ep['still_path'] ?? ep['thumbnail'];
              
              return FocusableControl(
                onTap: () {
                  setState(() => _selectedEpisode = epNum);
                  if (_selectedSourceId == 'playtorrio') {
                    _autoSearch();
                  } else if (_selectedSourceId == 'jackett') {
                    _searchJackett();
                  } else if (_selectedSourceId == 'prowlarr') {
                    _searchProwlarr();
                  } else if (_selectedSourceId == 'all_stremio') {
                    _fetchAllStremioStreams();
                  } else {
                    // For custom IDs, re-fetch streams with the new episode
                    if (widget.stremioItem != null) {
                      _fetchStremioStreamsForCustomId(widget.stremioItem!);
                    } else {
                      _fetchStremioStreams();
                    }
                  }
                },
                borderRadius: 10,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 200,
                  decoration: BoxDecoration(
                    color: sel ? AppTheme.primaryColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: sel ? AppTheme.primaryColor : Colors.white12, width: sel ? 1.5 : 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(fit: StackFit.expand, children: [
                          ClipRRect(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                            child: thumbnail != null
                                ? CachedNetworkImage(
                                    imageUrl: thumbnail.startsWith('http') 
                                        ? thumbnail 
                                        : TmdbApi.getImageUrl(thumbnail),
                                    fit: BoxFit.cover,
                                    errorWidget: (c, u, e) => Container(
                                      color: Colors.white.withValues(alpha: 0.06),
                                      child: const Center(child: Icon(Icons.movie_outlined, color: Colors.white24, size: 28))))
                                : Container(color: Colors.white.withValues(alpha: 0.06),
                                    child: const Center(child: Icon(Icons.movie_outlined, color: Colors.white24, size: 28))),
                          ),
                          Positioned(
                            top: 6, left: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(4)),
                              child: Text('$epNum', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ]),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Text(epName, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                            color: sel ? Colors.white : Colors.white70)),
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  SOURCE TOGGLE + CHIPS
  // ═══════════════════════════════════════════════════════════════════════════

  bool get _isTorrentSource =>
      _selectedSourceId == 'playtorrio' ||
      _selectedSourceId == 'jackett' ||
      _selectedSourceId == 'prowlarr';

  Widget _buildSourceToggle() {
    final isTorrent = _isTorrentSource;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sourceTab('Stremio Addons', Icons.extension_outlined, !isTorrent, () {
            if (_streamAddons.isNotEmpty) {
              setState(() {
                _selectedSourceId = 'all_stremio';
                _applyStremioFilter();
                _errorMessage = null;
              });
              // Re-fetch if we don't have cached results
              if (_allCombinedStremioStreams.isEmpty) _fetchAllStremioStreams();
            }
          }),
          _sourceTab('Torrent Sources', Icons.downloading_rounded, isTorrent, () {
            setState(() => _selectedSourceId = 'playtorrio');
            _autoSearch();
          }),
        ],
      ),
    );
  }

  Widget _sourceTab(String label, IconData icon, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primaryColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(children: [
          Icon(icon, size: 14, color: selected ? Colors.white : Colors.white54),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.white54)),
        ]),
      ),
    );
  }

  Widget _buildSourceChips() {
    final isTorrent = _isTorrentSource;
    final chips = <Map<String, dynamic>>[];
    if (isTorrent) {
      chips.add({'id': 'playtorrio', 'label': 'PlayTorrio'});
      if (_isJackettConfigured) chips.add({'id': 'jackett', 'label': '🔍 Jackett'});
      if (_isProwlarrConfigured) chips.add({'id': 'prowlarr', 'label': '🔍 Prowlarr'});
      for (final a in _streamAddons) {
        if (a['type'] == 'torrent') chips.add({'id': a['baseUrl'], 'label': a['name']});
      }
    } else {
      // "All" chip shows combined streams from every addon
      if (_streamAddons.length > 1) {
        chips.add({'id': 'all_stremio', 'label': '⚡ All'});
      }
      // Only show addon chips that have finished loading
      for (final a in _streamAddons) {
        if (_loadedAddonBaseUrls.contains(a['baseUrl'])) {
          chips.add({'id': a['baseUrl'], 'label': a['name']});
        }
      }
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: chips.map((chip) {
          final sel = _selectedSourceId == chip['id'];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                final id = chip['id'] as String;
                setState(() => _selectedSourceId = id);
                if (id == 'playtorrio') {
                  _autoSearch();
                } else if (id == 'jackett') {
                  _searchJackett();
                } else if (id == 'prowlarr') {
                  _searchProwlarr();
                } else if (id == 'all_stremio') {
                  setState(() {
                    _applyStremioFilter();
                    _errorMessage = _stremioStreams.isEmpty && !_isStremioFetching
                        ? 'No streams found from any addon' : null;
                  });
                } else {
                  // Single addon filter from cached combined results
                  setState(() {
                    _applyStremioFilter();
                    _errorMessage = _stremioStreams.isEmpty && !_isStremioFetching
                        ? 'No streams found in ${chip['label']}' : null;
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: sel ? AppTheme.primaryColor : Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: sel ? AppTheme.primaryColor : Colors.white.withValues(alpha: 0.2)),
                ),
                child: Text(chip['label'] as String,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : Colors.white.withValues(alpha: 0.6))),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  RESULTS HEADER
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildResultsHeader() {
    // Show sort dropdown for ALL torrent sources, not just PlayTorrio
    final showSort = _isTorrentSource;
    String? epLabel;
    if (_movie.mediaType == 'tv') {
      final s = _selectedSeason.toString().padLeft(2, '0');
      final e = _selectedEpisode.toString().padLeft(2, '0');
      epLabel = 'S${s}E$e';
    }
    return Row(
      children: [
        const Icon(Icons.download_rounded, color: Colors.white54, size: 16),
        const SizedBox(width: 6),
        const Text('Available Sources',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
        if (epLabel != null) ...[
          const SizedBox(width: 6),
          Text('— $epLabel', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
        if (_isSearching || _isStremioFetching) ...[
          const SizedBox(width: 8),
          const SizedBox(width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor)),
        ],
        const Spacer(),
        if (showSort)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: DropdownButton<String>(
              value: _sortPreference,
              isDense: true,
              underline: const SizedBox.shrink(),
              dropdownColor: const Color(0xFF0F0F2D),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white54, size: 16),
              style: const TextStyle(color: Colors.white70, fontSize: 11),
              items: [
                'Seeders (High to Low)', 'Seeders (Low to High)',
                'Quality (High to Low)', 'Quality (Low to High)',
                'Size (High to Low)', 'Size (Low to High)',
              ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() => _sortPreference = val);
                  _settings.setSortPreference(val);
                  _sortResults();
                }
              },
            ),
          ),
        if (showSort) ...[const SizedBox(width: 8), _buildAudioFilterButton()],
      ],
    );
  }

  Widget _buildAudioFilterButton() {
    final active = _activeAudioFilters.isNotEmpty;
    return GestureDetector(
      onTapDown: (details) async {
        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
        final position = RelativeRect.fromRect(
          Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 1, 1),
          Offset.zero & overlay.size,
        );
        // Build a temporary stateful popup via showMenu
        await showMenu(
          context: context,
          position: position,
          color: const Color(0xFF0F0F2D),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          items: [
            PopupMenuItem(
              enabled: false,
              padding: EdgeInsets.zero,
              child: _AudioFilterMenu(
                allTags: _kAudioTags,
                activeTags: Set<String>.from(_activeAudioFilters),
                onChanged: (updated) => setState(() => _activeAudioFilters = updated),
              ),
            ),
          ],
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.primaryColor.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? AppTheme.primaryColor.withValues(alpha: 0.6) : Colors.white12,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.graphic_eq,
              size: 14,
              color: active ? AppTheme.primaryColor : Colors.white54),
          if (active) ...[const SizedBox(width: 4),
            Text('${_activeAudioFilters.length}',
                style: TextStyle(color: AppTheme.primaryColor, fontSize: 11,
                    fontWeight: FontWeight.bold))],
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STREAM LIST
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildStreamList() {
    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent))),
      );
    }
    final isTorrent = _isTorrentSource;
    final count = isTorrent ? _filteredTorrentResults.length : _stremioStreams.length;
    if (!_isSearching && !_isStremioFetching && count == 0) {
      final msg = (isTorrent && _activeAudioFilters.isNotEmpty && _allTorrentResults.isNotEmpty)
          ? 'No results match the audio filter'
          : 'No streams found';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text(msg, style: const TextStyle(color: Colors.white38))),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        if (isTorrent) {
          final r = _filteredTorrentResults[i];
          double prog = 0; bool resumable = false;
          if (_lastProgress != null && _lastProgress!['method'] == 'torrent') {
            if (_getHash(r.magnet) == _getHash(_lastProgress!['sourceId'])) {
              final pos = _lastProgress!['position'] as int;
              final dur = _lastProgress!['duration'] as int;
              if (dur > 0) { prog = (pos / dur).clamp(0.0, 1.0); resumable = true; }
            }
          }
          return _buildTorrentTile(r, progress: prog, isResumable: resumable);
        } else {
          final s = _stremioStreams[i];
          double prog = 0; bool resumable = false;
          if (_lastProgress != null) {
            final String? sid = s['infoHash'] != null
                ? 'magnet:?xt=urn:btih:${s['infoHash']}' : s['url'];
            if (sid != null) {
              final hs = _lastProgress!['sourceId'] as String;
              final match = s['infoHash'] != null
                  ? _getHash(hs) == _getHash(sid) : hs == sid;
              if (match) {
                final pos = _lastProgress!['position'] as int;
                final dur = _lastProgress!['duration'] as int;
                if (dur > 0) { prog = (pos / dur).clamp(0.0, 1.0); resumable = true; }
              }
            }
          }
          return _buildStremioTile(
            stream: s,
            title: s['title'] ?? s['name'] ?? 'Unknown Stream',
            description: s['description'] ?? '',
            progress: prog, isResumable: resumable);
        }
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  TORRENT TILE
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildTorrentTile(TorrentResult result, {double progress = 0, bool isResumable = false}) {
    final n = result.name.toUpperCase();
    String quality = '?'; Color qColor = Colors.grey;
    if (n.contains('2160') || n.contains('4K') || n.contains('UHD')) {
      quality = '4K'; qColor = const Color(0xFF7C3AED);
    } else if (n.contains('1080')) {
      quality = '1080p'; qColor = const Color(0xFF1D4ED8);
    } else if (n.contains('720')) {
      quality = '720p'; qColor = const Color(0xFF0369A1);
    } else if (n.contains('480')) {
      quality = '480p'; qColor = Colors.grey.shade700;
    }

    String? codec;
    if (n.contains('HEVC') || n.contains('X265') || n.contains('H.265')) {
      codec = 'HEVC';
    } else if (n.contains('X264') || n.contains('H.264') || n.contains('H264') || n.contains('AVC')) {
      codec = 'h264';
    } else if (n.contains('AV1')) {
      codec = 'AV1';
    }

    final tracker = _getTrackerName(result);

    return FocusableControl(
      onTap: () => _playTorrent(result,
        startPosition: isResumable ? Duration(milliseconds: _lastProgress!['position'] as int) : null),
      borderRadius: 10,
      child: Container(
        decoration: BoxDecoration(
          color: isResumable ? AppTheme.primaryColor.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isResumable
              ? AppTheme.primaryColor.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.07)),
        ),
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 52,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _qualityBadge(quality, qColor),
                      if (codec != null) ...[const SizedBox(height: 4), _codecBadge(codec)],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isResumable)
                        const Text('RESUME', style: TextStyle(color: AppTheme.primaryColor,
                          fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                      Text(result.name, maxLines: 3, overflow: TextOverflow.visible,
                        style: const TextStyle(color: Colors.white, fontSize: 12,
                          height: 1.35, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8, runSpacing: 2,
                        children: [
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.arrow_upward_rounded, size: 11, color: Color(0xFF22C55E)),
                            const SizedBox(width: 2),
                            Text(result.seeders, style: const TextStyle(color: Color(0xFF22C55E), fontSize: 11)),
                          ]),
                          Text(result.size, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                          if (tracker.isNotEmpty)
                            Text(tracker, style: const TextStyle(color: Color(0xFF60A5FA), fontSize: 11),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(children: [
                  _iconBtn(Icons.content_copy_rounded, false, () {
                    Clipboard.setData(ClipboardData(text: result.magnet));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Magnet copied'), duration: Duration(seconds: 1)));
                  }),
                  const SizedBox(height: 6),
                  _iconBtn(Icons.play_arrow_rounded, true, () => _playTorrent(result,
                    startPosition: isResumable ? Duration(milliseconds: _lastProgress!['position'] as int) : null)),
                ]),
              ],
            ),
          ),
          if (isResumable && progress > 0)
            Positioned(bottom: 0, left: 0, right: 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                child: LinearProgressIndicator(value: progress,
                  backgroundColor: Colors.transparent, color: AppTheme.primaryColor, minHeight: 2.5))),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STREMIO TILE
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildStremioTile({
    required Map<String, dynamic> stream,
    required String title,
    required String description,
    double progress = 0,
    bool isResumable = false,
  }) {
    // Determine if this is an external-link stream (e.g. "More Like This" addon)
    final externalUrl = stream['externalUrl']?.toString();
    final isExternal = externalUrl != null && externalUrl.isNotEmpty;
    final bool isStremioLink = isExternal && externalUrl.startsWith('stremio://');
    final bool isWebLink = isExternal && (externalUrl.startsWith('http://') || externalUrl.startsWith('https://'));
    final String? addonName = stream['_addonName']?.toString();

    // Choose icon based on link type
    IconData leadingIcon;
    Color leadingColor;
    IconData actionIcon;
    if (isStremioLink) {
      final parsed = StremioService.parseMetaLink(externalUrl);
      final action = parsed?['action'];
      if (action == 'detail') {
        leadingIcon = Icons.movie_outlined;
        leadingColor = Colors.amberAccent;
        actionIcon = Icons.open_in_new_rounded;
      } else if (action == 'search') {
        leadingIcon = Icons.search_rounded;
        leadingColor = Colors.cyanAccent;
        actionIcon = Icons.search_rounded;
      } else {
        leadingIcon = Icons.explore_outlined;
        leadingColor = Colors.tealAccent;
        actionIcon = Icons.open_in_new_rounded;
      }
    } else if (isWebLink) {
      leadingIcon = Icons.language_rounded;
      leadingColor = Colors.lightBlueAccent;
      actionIcon = Icons.open_in_browser_rounded;
    } else if (isResumable) {
      leadingIcon = Icons.play_circle_filled_rounded;
      leadingColor = AppTheme.primaryColor;
      actionIcon = Icons.play_arrow_rounded;
    } else {
      leadingIcon = Icons.extension_rounded;
      leadingColor = Colors.blueAccent;
      actionIcon = Icons.play_arrow_rounded;
    }

    return FocusableControl(
      onTap: () => _playStremioStream(stream,
        startPosition: isResumable ? Duration(milliseconds: _lastProgress!['position'] as int) : null),
      borderRadius: 10,
      child: Container(
        decoration: BoxDecoration(
          color: isExternal
              ? leadingColor.withValues(alpha: 0.06)
              : (isResumable ? AppTheme.primaryColor.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isExternal
              ? leadingColor.withValues(alpha: 0.25)
              : (isResumable ? AppTheme.primaryColor.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.07))),
        ),
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Icon(leadingIcon, color: leadingColor, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (isResumable && !isExternal)
                    const Text('RESUME', style: TextStyle(color: AppTheme.primaryColor,
                      fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                  if (addonName != null && _selectedSourceId == 'all_stremio')
                    Text(addonName, style: TextStyle(color: leadingColor.withValues(alpha: 0.7),
                      fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  Text(title, maxLines: 4, overflow: TextOverflow.visible,
                    style: const TextStyle(color: Colors.white, fontSize: 12,
                      height: 1.35, fontWeight: FontWeight.w500)),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(description, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              _iconBtn(actionIcon, true, () => _playStremioStream(stream,
                startPosition: isResumable ? Duration(milliseconds: _lastProgress!['position'] as int) : null)),
            ]),
          ),
          if (isResumable && progress > 0 && !isExternal)
            Positioned(bottom: 0, left: 0, right: 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                child: LinearProgressIndicator(value: progress,
                  backgroundColor: Colors.transparent, color: AppTheme.primaryColor, minHeight: 2.5))),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SMALL REUSABLE WIDGETS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _sectionLabel(String text) => Text(text,
    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14));

  Widget _genreChip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white24)),
    child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)));

  Widget _castChip(String name) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white24)),
    child: Text(name, style: const TextStyle(color: Colors.white70, fontSize: 12)));

  Widget _qualityBadge(String q, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(5)),
    child: Text(q, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)));

  Widget _codecBadge(String codec) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(5),
      border: Border.all(color: Colors.white.withValues(alpha: 0.2))),
    child: Text(codec,
      style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 10, fontWeight: FontWeight.w600)));

  Widget _iconBtn(IconData icon, bool highlight, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 32, height: 32,
      decoration: BoxDecoration(
        color: highlight ? AppTheme.primaryColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: highlight ? AppTheme.primaryColor.withValues(alpha: 0.4) : Colors.white12)),
      child: Icon(icon, size: 17, color: highlight ? AppTheme.primaryColor : Colors.white54)));

  Widget _scrollArrow(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Icon(icon, color: Colors.white38, size: 16)));

  // ═════════════════════════════════════════════════════════════════════════════
  //  DESKTOP CAST ROW
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildDesktopCastRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel('Cast'),
            Row(
              children: [
                _castNavButton(Icons.arrow_back_ios_rounded, -300),
                const SizedBox(width: 4),
                _castNavButton(Icons.arrow_forward_ios_rounded, 300),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 155,
          child: ListView.separated(
            controller: _castScrollController,
            scrollDirection: Axis.horizontal,
            itemCount: _castMembers.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final m = _castMembers[i];
              final profilePath = m['profilePath'] ?? '';
              final name = m['name'] ?? '';
              final character = m['character'] ?? '';
              return SizedBox(
                width: 92,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundColor: Colors.white10,
                      backgroundImage: profilePath.isNotEmpty
                          ? CachedNetworkImageProvider(
                              TmdbApi.getImageUrl(profilePath))
                          : null,
                      child: profilePath.isEmpty
                          ? Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w600),
                            )
                          : null,
                    ),
                    const SizedBox(height: 7),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                    Text(
                      character,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _castNavButton(IconData icon, double delta) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 16, color: Colors.white60),
        onPressed: () {
          if (!_castScrollController.hasClients) return;
          final target = (_castScrollController.offset + delta)
              .clamp(0.0, _castScrollController.position.maxScrollExtent);
          _castScrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  RECOMMENDATIONS SECTION
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildRecommendationsSection() {
    if (_isLoadingRecommendations) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('Similar'),
            const SizedBox(height: 12),
            const SizedBox(
              height: 40,
              child: Center(child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor),
              )),
            ),
          ],
        ),
      );
    }
    if (_stremioRecommendations.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _sectionLabel('Similar'),
              const Spacer(),
              Row(children: [
                _scrollArrow(Icons.arrow_back_ios_rounded, () => _recommendationsScrollController.animateTo(
                  _recommendationsScrollController.offset - 260,
                  duration: const Duration(milliseconds: 280), curve: Curves.easeInOut)),
                _scrollArrow(Icons.arrow_forward_ios_rounded, () => _recommendationsScrollController.animateTo(
                  _recommendationsScrollController.offset + 260,
                  duration: const Duration(milliseconds: 280), curve: Curves.easeInOut)),
              ]),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: ListView.separated(
              controller: _recommendationsScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: _stremioRecommendations.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final rec = _stremioRecommendations[index];
                final poster = rec['poster']?.toString() ?? '';
                final name = rec['name']?.toString() ?? 'Unknown';

                return FocusableControl(
                  onTap: () => _openRecommendation(rec),
                  borderRadius: 10,
                  child: SizedBox(
                    width: 115,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            width: 115, height: 150,
                            color: AppTheme.bgCard,
                            child: poster.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl: poster,
                                    fit: BoxFit.cover,
                                    width: 115, height: 150,
                                    placeholder: (_, _) => Container(color: AppTheme.bgCard),
                                    errorWidget: (_, _, _) => Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(6),
                                        child: Text(name, textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 10, color: Colors.white38)),
                                      ),
                                    ),
                                  )
                                : Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Text(name, textAlign: TextAlign.center,
                                        style: const TextStyle(fontSize: 10, color: Colors.white38)),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Colors.white70)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  EXPANDABLE SYNOPSIS
// ═════════════════════════════════════════════════════════════════════════════

class _ExpandableSynopsis extends StatefulWidget {
  final String text;
  const _ExpandableSynopsis({required this.text});

  @override
  State<_ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<_ExpandableSynopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 250),
          firstChild: Text(widget.text,
            maxLines: 3, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFB0B0C0), fontSize: 13.5, height: 1.6)),
          secondChild: Text(widget.text,
            style: const TextStyle(color: Color(0xFFB0B0C0), fontSize: 13.5, height: 1.6)),
          crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(_expanded ? 'Show less' : 'Show more',
            style: TextStyle(color: AppTheme.primaryColor.withValues(alpha: 0.9),
              fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AUDIO FILTER MENU  (stateful so checkboxes update without closing the menu)
// ─────────────────────────────────────────────────────────────────────────────

class _AudioFilterMenu extends StatefulWidget {
  final List<String> allTags;
  final Set<String> activeTags;
  final ValueChanged<Set<String>> onChanged;
  const _AudioFilterMenu({
    required this.allTags,
    required this.activeTags,
    required this.onChanged,
  });

  @override
  State<_AudioFilterMenu> createState() => _AudioFilterMenuState();
}

class _AudioFilterMenuState extends State<_AudioFilterMenu> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.activeTags);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq,
                      size: 14, color: Colors.white54),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text('Audio',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5)),
                  ),
                  if (_selected.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        setState(() => _selected.clear());
                        widget.onChanged({});
                      },
                      child: Text('Clear',
                          style: TextStyle(
                              color: AppTheme.primaryColor,
                              fontSize: 11)),
                    ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 8),
            ...widget.allTags.map((tag) {
              final on = _selected.contains(tag);
              return InkWell(
                onTap: () {
                  setState(() {
                    if (on) { _selected.remove(tag); } else { _selected.add(tag); }
                  });
                  widget.onChanged(Set<String>.from(_selected));
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        color: on ? AppTheme.primaryColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: on ? AppTheme.primaryColor : Colors.white30,
                          width: 1.5,
                        ),
                      ),
                      child: on
                          ? const Icon(Icons.check_rounded,
                              size: 13, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(tag,
                        style: TextStyle(
                            color: on ? Colors.white : Colors.white60,
                            fontSize: 13)),
                  ]),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}