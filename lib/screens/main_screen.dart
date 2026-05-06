import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home_screen.dart';
import 'discover_screen.dart';
import 'search_screen.dart';
import 'my_list_screen.dart';
import 'settings_screen.dart';
import 'music_screen.dart';
import 'audiobook_screen.dart';
import 'books_screen.dart';
import 'comics_screen.dart';
import 'manga_screen.dart';
import 'jellyfin_screen.dart';
import 'anime_screen.dart';
import 'anime_arabic_screen.dart';
import 'asian_drama_screen.dart';
import 'similar/similar_hub_screen.dart';
import 'media_downloader_screen.dart';
import 'arabic_screen.dart';
import 'live_matches_screen.dart';
import 'magnet_player_screen.dart';
import '../features/iptv/playtorrio_tv/screens/iptv_pt_screen.dart';
import '../utils/app_theme.dart';
import '../api/settings_service.dart';
import '../services/app_updater_service.dart';
import '../widgets/update_dialog.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  /// Notifier that SearchScreen listens to for incoming Stremio search requests.
  /// Value is {'query': '...', 'addonBaseUrl': '...'} or null.
  static final ValueNotifier<Map<String, String>?> stremioSearchNotifier = ValueNotifier<Map<String, String>?>(null);

  /// Anywhere in the app: `MainScreen.requestTab.value = 'home';` to switch tab.
  static final ValueNotifier<String?> requestTab = ValueNotifier<String?>(null);

  static State<MainScreen>? of(BuildContext context) {
    return context.findAncestorStateOfType<_MainScreenState>();
  }

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  Timer? _metricsDebounce;
  Timer? _metricsSafety;

  /// All screens keyed by nav ID — created once, never recreated.
  late final Map<String, Widget> _allScreens;

  /// Nav item metadata keyed by nav ID.
  static const Map<String, Map<String, dynamic>> _navMeta = {
    'home':         {'icon': Icons.home_outlined,              'active': Icons.home,                    'label': 'Home'},
    'discover':     {'icon': Icons.explore_outlined,            'active': Icons.explore,                 'label': 'Discover'},
    'similar':      {'icon': Icons.auto_awesome_outlined, 'active': Icons.auto_awesome, 'label': 'Similar'},
    'downloader':   {'icon': Icons.cloud_download_outlined, 'active': Icons.cloud_download, 'label': 'Media Downloader'},
    'search':       {'icon': Icons.search,                      'active': Icons.search,                  'label': 'Search'},
    'mylist':       {'icon': Icons.bookmark_outline,            'active': Icons.bookmark,                'label': 'My List'},
    'magnet':       {'icon': Icons.link_rounded,                'active': Icons.link_rounded,            'label': 'Magnet'},
    'live_matches': {'icon': Icons.sports_soccer_outlined,      'active': Icons.sports_soccer_rounded,   'label': 'Live Matches'},
    'iptv':         {'icon': Icons.live_tv_outlined,            'active': Icons.live_tv,                 'label': 'IPTV'},
    'audiobooks':   {'icon': Icons.menu_book_outlined,          'active': Icons.menu_book,               'label': 'Audiobooks'},
    'books':        {'icon': Icons.import_contacts_rounded,     'active': Icons.import_contacts_rounded, 'label': 'Books'},
    'music':        {'icon': Icons.music_note_outlined,         'active': Icons.music_note,              'label': 'Music'},
    'comics':       {'icon': Icons.auto_stories_outlined,       'active': Icons.auto_stories,            'label': 'Comics'},
    'manga':        {'icon': Icons.book_outlined,               'active': Icons.book,                    'label': 'Manga'},
    'jellyfin':     {'icon': Icons.dns_outlined,                'active': Icons.dns_rounded,             'label': 'Jellyfin'},
    'anime':        {'icon': Icons.play_circle_outline,         'active': Icons.play_circle_filled,      'label': 'Anime'},
    'anime_arabic': {'icon': Icons.subtitles_outlined,           'active': Icons.subtitles,                'label': 'Anime Arabic'},
    'asian_drama':  {'icon': Icons.theater_comedy_outlined,     'active': Icons.theater_comedy,          'label': 'Asian Drama'},
    'arabic':       {'icon': Icons.movie_filter_outlined,       'active': Icons.movie_filter,            'label': 'Arabic'},
    'settings':     {'icon': Icons.settings_outlined,           'active': Icons.settings,                'label': 'Settings'},
  };

  /// Currently visible nav IDs (always ends with 'settings').
  List<String> _visibleIds = [...SettingsService.allNavIds, 'settings'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MainScreen.stremioSearchNotifier.addListener(_onStremioSearch);
    MainScreen.requestTab.addListener(_onRequestTab);
    SettingsService.navbarChangeNotifier.addListener(_onNavbarConfigChanged);

    _allScreens = {
      'home':         const HomeScreen(),
      'discover':     const DiscoverScreen(),
      'similar':      const SimilarHubScreen(),
      'downloader':   const MediaDownloaderScreen(),
      'search':       const SearchScreen(),
      'mylist':       const MyListScreen(),
      'magnet':       const MagnetPlayerScreen(),
      'live_matches': const LiveMatchesScreen(),
      'iptv':         const IptvPtScreen(),
      'audiobooks':   const AudiobookScreen(),
      'books':        const BooksScreen(),
      'music':        const MusicScreen(),
      'comics':       ComicsScreen(initialSearch: null),
      'manga':        MangaScreen(initialSearch: null),
      'jellyfin':     const JellyfinScreen(),
      'anime':        const AnimeScreen(),
      'anime_arabic': const AnimeArabicScreen(),
      'asian_drama':  const AsianDramaScreen(),
      'arabic':       const ArabicScreen(),
      'settings':     const SettingsScreen(),
    };

    _loadNavbarConfig();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    try {
      final updater = AppUpdaterService();
      final updateInfo = await updater.checkForUpdates();
      if (updateInfo != null && mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => UpdateDialog(updateInfo: updateInfo),
        );
      }
    } catch (e) {
      debugPrint('[MainScreen] Update check failed: $e');
    }
  }

  Future<void> _loadNavbarConfig() async {
    final visible = await SettingsService().getNavbarConfig();
    if (!mounted) return;
    setState(() {
      // Remember which screen we're currently on
      final currentId = _selectedIndex < _visibleIds.length
          ? _visibleIds[_selectedIndex]
          : null;
      _visibleIds = [...visible, 'settings'];
      // Try to stay on the same screen after reorder/hide
      if (currentId != null) {
        final newIndex = _visibleIds.indexOf(currentId);
        if (newIndex >= 0) {
          _selectedIndex = newIndex;
        } else if (_selectedIndex >= _visibleIds.length) {
          _selectedIndex = _visibleIds.length - 1;
        }
      } else if (_selectedIndex >= _visibleIds.length) {
        _selectedIndex = 0;
      }
    });
  }

  void _onNavbarConfigChanged() {
    _loadNavbarConfig();
  }

  /// Rotation on MediaTek/Transsion can cause a multi-second frame storm.
  /// Two-timer strategy:
  ///   1. Debounced timer (1.5s): resets on every metrics change, fires
  ///      after the storm quiets down.
  ///   2. Safety timer (4s): fires once after the FIRST metrics change—
  ///      never cancelled—so even if the storm outlasts the debounce,
  ///      a clean rebuild is guaranteed.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Debounced: fires 1.5s after the LAST metrics change.
    _metricsDebounce?.cancel();
    _metricsDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() {});
    });
    // Safety: fires 4s after the FIRST metrics change. Never cancelled.
    _metricsSafety ??= Timer(const Duration(seconds: 4), () {
      _metricsSafety = null;
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      // Only re-apply immersive mode; do NOT reset preferred orientations
      // here — it interferes with the player's orientation lock when the
      // player is pushed on top of this screen.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _onStremioSearch() {
    final data = MainScreen.stremioSearchNotifier.value;
    if (data == null || (data['query'] ?? '').isEmpty) return;
    final idx = _visibleIds.indexOf('search');
    if (idx != -1) setState(() => _selectedIndex = idx);
  }

  void _onRequestTab() {
    final id = MainScreen.requestTab.value;
    if (id == null) return;
    final idx = _visibleIds.indexOf(id);
    if (idx != -1 && mounted) setState(() => _selectedIndex = idx);
    MainScreen.requestTab.value = null;
  }

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  void searchComics(String query) {
    final idx = _visibleIds.indexOf('comics');
    if (idx != -1) setState(() => _selectedIndex = idx);
  }

  void searchManga(String query) {
    final idx = _visibleIds.indexOf('manga');
    if (idx != -1) setState(() => _selectedIndex = idx);
  }

  @override
  void dispose() {
    _metricsDebounce?.cancel();
    _metricsSafety?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    MainScreen.stremioSearchNotifier.removeListener(_onStremioSearch);
    MainScreen.requestTab.removeListener(_onRequestTab);
    SettingsService.navbarChangeNotifier.removeListener(_onNavbarConfigChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    
    final bool useNavRail = isDesktop || isLandscape;

    return Scaffold(
      body: Stack(
        children: [
          // Base gradient
          Container(decoration: AppTheme.effectiveBackground),
          // Ambient glows (skipped in light mode)
          if (!AppTheme.isLightMode) ...[
          // Ambient purple glow – top-right
          Positioned(
            top: -80,
            right: -60,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.current.primaryColor.withValues(alpha: 0.18),
                    AppTheme.current.primaryColor.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // Ambient cyan glow – bottom-left
          Positioned(
            bottom: 40,
            left: -80,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.current.accentColor.withValues(alpha: 0.08),
                    AppTheme.current.accentColor.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // Soft violet glow – center-left
          Positioned(
            top: MediaQuery.of(context).size.height * 0.35,
            left: -40,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.current.primaryColor.withValues(alpha: 0.10),
                    AppTheme.current.primaryColor.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          ], // end light mode glow skip
          // Content layer
          Row(
            children: [
              if (useNavRail)
              SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height),
                  child: IntrinsicHeight(
                    child: NavigationRail(
                          backgroundColor: Colors.transparent,
                          selectedIndex: _selectedIndex,
                          onDestinationSelected: _onItemTapped,
                          labelType: NavigationRailLabelType.all,
                          indicatorColor: AppTheme.current.primaryColor,
                          selectedLabelTextStyle: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          unselectedLabelTextStyle: const TextStyle(
                            color: Colors.white54,
                          ),
                          leading: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24.0),
                            child: Icon(
                              Icons.play_circle_fill,
                              color: AppTheme.current.primaryColor,
                              size: 48,
                            ),
                          ),
                          destinations: _visibleIds.map((id) {
                            final meta = _navMeta[id]!;
                            return NavigationRailDestination(
                              icon: Icon(meta['icon'] as IconData, color: Colors.white54),
                              selectedIcon: Icon(meta['active'] as IconData, color: Colors.white),
                              label: Text(meta['label'] as String),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: _visibleIds.map((id) => _allScreens[id]!).toList(),
              ),
            ),
          ],
        ),
        ],
      ),
      bottomNavigationBar: useNavRail
          ? null
          : _buildScrollableBottomNav(),
    );
  }

  Widget _buildScrollableBottomNav() {
    final lightMode = AppTheme.isLightMode;

    Widget navContent = Container(
          height: 80,
          decoration: BoxDecoration(
            color: AppTheme.current.bgDark.withValues(alpha: lightMode ? 1.0 : 0.75),
            border: const Border(top: BorderSide(color: Colors.white10, width: 0.5)),
          ),
          child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: _visibleIds.asMap().entries.map((entry) {
                final int idx = entry.key;
                final String id = entry.value;
                final meta = _navMeta[id]!;
                final bool isSelected = _selectedIndex == idx;

                return InkWell(
                  onTap: () => _onItemTapped(idx),
                  child: Container(
                    width: 100,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? AppTheme.current.primaryColor.withValues(alpha: 0.2) : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            isSelected ? meta['active'] as IconData : meta['icon'] as IconData,
                            color: isSelected ? Colors.white : Colors.white54,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          meta['label'] as String,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white54,
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          if (!lightMode)
          Positioned(
            right: 0, top: 0, bottom: 0,
            child: IgnorePointer(
              child: Container(
                width: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Colors.transparent, AppTheme.current.bgDark.withValues(alpha: 0.7)],
                  ),
                ),
                child: const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.white24),
              ),
            ),
          ),
        ],
      ),
    );

    if (lightMode) {
      return ClipRect(child: navContent);
    }

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: navContent,
      ),
    );
  }
}
