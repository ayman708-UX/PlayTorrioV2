import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/settings_service.dart';
import '../api/stream_providers.dart';
import '../api/stremio_service.dart';
import '../api/nuvio_service.dart';
import '../api/torrent_stream_service.dart';
import '../api/track_auto_select.dart';
import '../services/external_player_service.dart';
import '../api/debrid_api.dart';
import '../api/trakt_service.dart';
import '../api/simkl_service.dart';
import '../api/mdblist_service.dart';
import '../services/jackett_service.dart';
import '../services/prowlarr_service.dart';
import '../services/app_updater_service.dart';
import '../widgets/update_dialog.dart';
import '../utils/app_theme.dart';
import 'lists_screen.dart';
import 'webstreamr_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settings = SettingsService();
  final StremioService _stremio = StremioService();
  final DebridApi _debrid = DebridApi();
  final JackettService _jackett = JackettService();
  final ProwlarrService _prowlarr = ProwlarrService();
  
  bool _isStreamingMode = false;
  String _externalPlayer = 'Built-in Player';
  String _sortPreference = 'Seeders (High to Low)';
  // Track auto-select
  String _preferredAudioLang = 'None';
  bool _avoidUnsupportedAudio = true;
  List<Map<String, dynamic>> _installedAddons = [];
  bool _isInstalling = false;
  
  bool _useDebrid = false;
  String _debridService = 'None';
  final TextEditingController _addonController = TextEditingController();
  final TextEditingController _nuvioController = TextEditingController();
  bool _nuvioInstalling = false;
  List<NuvioAddon> _nuvioAddons = [];
  final TextEditingController _torboxController = TextEditingController();
  final TextEditingController _alldebridController = TextEditingController();
  final TextEditingController _premiumizeController = TextEditingController();
  final TextEditingController _debridlinkController = TextEditingController();
  
  // Jackett
  final TextEditingController _jackettUrlController = TextEditingController();
  final TextEditingController _jackettApiKeyController = TextEditingController();
  bool _isTestingJackett = false;
  String? _jackettTestResult;
  
  // Prowlarr
  final TextEditingController _prowlarrUrlController = TextEditingController();
  final TextEditingController _prowlarrApiKeyController = TextEditingController();
  bool _isTestingProwlarr = false;
  String? _prowlarrTestResult;
  List<ProwlarrTag> _prowlarrAvailableTags = [];
  Set<int> _prowlarrSelectedTagIds = {};
  bool _prowlarrTagsLoaded = false;
  
  bool _isRDLoggedIn = false;
  final TextEditingController _rdController = TextEditingController();
  bool _isVerifyingRD = false;
  
  // Trakt
  final TraktService _trakt = TraktService();
  bool _isTraktLoggedIn = false;
  String? _traktUserCode;
  String? _traktVerifyUrl;
  Timer? _traktPollTimer;
  bool _isTraktSyncing = false;
  String? _traktUsername;
  Map<String, dynamic>? _traktStats;

  // Simkl
  final SimklService _simkl = SimklService();
  bool _isSimklLoggedIn = false;
  String? _simklUserCode;
  String? _simklVerifyUrl;
  Timer? _simklPollTimer;
  bool _isSimklSyncing = false;
  String? _simklUsername;

  // MDBlist
  final MdblistService _mdblist = MdblistService();
  bool _isMdblistConfigured = false;
  final TextEditingController _mdblistApiKeyController = TextEditingController();
  String? _mdblistUsername;

  bool _isCheckingUpdate = false;
  final AppUpdaterService _updater = AppUpdaterService();

  // Torrent cache
  String _torrentCacheType = 'ram';
  int _torrentRamCacheMb = 200;
  int _torrentConnectionsLimit = 25;

  // Light mode
  bool _isLightMode = false;

  // Theme preset
  String _selectedThemeId = 'cinematic';

  // Navbar config
  List<String> _navbarVisible = [];
  List<String> _navbarOrder = [];

  // Stream provider order (Direct Streaming Mode)
  List<String> _streamProviderOrder = [];
  Map<String, Map<String, dynamic>> _nuvioProviderEntries = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadNuvioAddons();
    NuvioService.changeNotifier.addListener(_loadNuvioAddons);
  }

  Future<void> _loadNuvioAddons() async {
    final list = await NuvioService.instance.listUserAddons();
    if (!mounted) return;
    setState(() => _nuvioAddons = list);
  }

  Future<void> _loadSettings() async {
    final streaming = await _settings.isStreamingModeEnabled();
    final externalPlayer = await _settings.getExternalPlayer();
    final sort = await _settings.getSortPreference();
    final useDebrid = await _settings.useDebridForStreams();
    final service = await _settings.getDebridService();
    final addons = await _settings.getStremioAddons();
    final torboxKey = await _debrid.getTorBoxKey();
    final alldebridKey = await _debrid.getAllDebridKey();
    final premiumizeKey = await _debrid.getPremiumizeKey();
    final debridlinkKey = await _debrid.getDebridLinkKey();
    final rdToken = await _debrid.getRDAccessToken();
    
    // Load Trakt status
    final traktLoggedIn = await _trakt.isLoggedIn();
    String? traktUser;
    Map<String, dynamic>? traktStats;
    if (traktLoggedIn) {
      final profile = await _trakt.getUserProfile();
      traktUser = profile?['user']?['username']?.toString() ?? profile?['username']?.toString();
      traktStats = await _trakt.getUserStats();
    }

    // Load Simkl status
    final simklLoggedIn = await _simkl.isLoggedIn();
    String? simklUser;
    if (simklLoggedIn) {
      final profile = await _simkl.getUserProfile();
      simklUser = profile?['name']?.toString();
    }

    // Load MDBlist status
    final mdblistConfigured = await _mdblist.isConfigured();
    String? mdblistUser;
    final mdblistKey = await _mdblist.getApiKey();
    if (mdblistConfigured) {
      final info = await _mdblist.getUserInfo();
      mdblistUser = info?['name']?.toString();
    }

    // Load Jackett settings
    final jackettUrl = await _settings.getJackettBaseUrl();
    final jackettKey = await _settings.getJackettApiKey();
    
    // Load Prowlarr settings
    final prowlarrUrl = await _settings.getProwlarrBaseUrl();
    final prowlarrKey = await _settings.getProwlarrApiKey();
    final prowlarrTagIds = await _settings.getProwlarrTagIds();

    // Load torrent cache settings
    final cacheType = await _settings.getTorrentCacheType();
    final ramCacheMb = await _settings.getTorrentRamCacheMb();
    final connLimit = await _settings.getTorrentConnectionsLimit();

    // Load light mode
    final lightMode = await _settings.isLightModeEnabled();

    // Load theme preset
    final themePreset = await _settings.getThemePreset();

    // Load navbar config
    final navVisible = await _settings.getNavbarConfig();
    // Full order: visible items first, then hidden items
    final allIds = SettingsService.allNavIds;
    final hidden = allIds.where((id) => !navVisible.contains(id)).toList();
    final navOrder = [...navVisible, ...hidden];

    // Load stream provider order
    final streamOrder = await _settings.getStreamProviderOrder();

    // Load track auto-select preferences
    final preferredAudio = await _settings.getPreferredAudioLanguage();
    final avoidUnsupported = await _settings.getAvoidUnsupportedAudio();

    if (mounted) {
      setState(() {
        _isStreamingMode = streaming;
        // Ensure saved value is in the current platform's player list
        final validNames = ExternalPlayerService.playerNames;
        _externalPlayer = validNames.contains(externalPlayer)
            ? externalPlayer
            : 'Built-in Player';
        _sortPreference = sort;
        _installedAddons = addons;
        _useDebrid = useDebrid;
        _debridService = service;
        _torboxController.text = torboxKey ?? '';
        _alldebridController.text = alldebridKey ?? '';
        _premiumizeController.text = premiumizeKey ?? '';
        _debridlinkController.text = debridlinkKey ?? '';
        _isRDLoggedIn = rdToken != null;
        _isTraktLoggedIn = traktLoggedIn;
        _traktUsername = traktUser;
        _traktStats = traktStats;
        _isSimklLoggedIn = simklLoggedIn;
        _simklUsername = simklUser;
        _isMdblistConfigured = mdblistConfigured;
        _mdblistUsername = mdblistUser;
        _mdblistApiKeyController.text = mdblistKey ?? '';
        
        _jackettUrlController.text = jackettUrl ?? '';
        _jackettApiKeyController.text = jackettKey ?? '';
        
        _prowlarrUrlController.text = prowlarrUrl ?? '';
        _prowlarrApiKeyController.text = prowlarrKey ?? '';
        _prowlarrSelectedTagIds = prowlarrTagIds.toSet();
        _torrentCacheType = cacheType;
        _torrentRamCacheMb = ramCacheMb;
        _torrentConnectionsLimit = connLimit;
        _isLightMode = lightMode;
        _selectedThemeId = themePreset;
        _navbarVisible = navVisible;
        _navbarOrder = navOrder;
        _streamProviderOrder = streamOrder;
        _preferredAudioLang = kTrackLanguageDisplayNames.contains(preferredAudio)
            ? preferredAudio
            : 'None';
        _avoidUnsupportedAudio = avoidUnsupported;
      });
    }
    // Pull dynamic Nuvio scrapers (one entry per enabled scraper) so they
    // show up alongside the built-in providers in the priority list.
    try {
      final entries = await NuvioService.instance.getProviderEntries();
      if (mounted) setState(() => _nuvioProviderEntries = entries);
    } catch (_) {}
    if ((prowlarrUrl?.isNotEmpty ?? false) && (prowlarrKey?.isNotEmpty ?? false)) {
      _tryLoadProwlarrTags();
    }
  }

  Future<void> _installAddon() async {
    final url = _addonController.text.trim();
    if (url.isEmpty) return;

    setState(() => _isInstalling = true);

    try {
      final addonData = await _stremio.fetchManifest(url);
      if (addonData != null) {
        await _settings.saveStremioAddon(addonData);
        _addonController.clear();
        await _loadSettings();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Addon installed successfully!')));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to install addon. Check URL.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isInstalling = false);
    }
  }

  void _removeAddon(String baseUrl) async {
    await _settings.removeStremioAddon(baseUrl);
    await _loadSettings();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Addon removed')));
  }

  @override
  void dispose() {
    NuvioService.changeNotifier.removeListener(_loadNuvioAddons);
    _addonController.dispose();
    _nuvioController.dispose();
    _torboxController.dispose();
    _alldebridController.dispose();
    _premiumizeController.dispose();
    _debridlinkController.dispose();
    _jackettUrlController.dispose();
    _jackettApiKeyController.dispose();
    _prowlarrUrlController.dispose();
    _prowlarrApiKeyController.dispose();
    _mdblistApiKeyController.dispose();
    _rdController.dispose();
    _traktPollTimer?.cancel();
    _simklPollTimer?.cancel();
    _jackett.dispose();
    _prowlarr.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _saveRDApiKey() async {
    final key = _rdController.text.trim();
    if (key.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter an API key')),
        );
      }
      return;
    }

    // Just save the key — no verify round-trip. The verify call hangs forever
    // on macOS for some users, leaving the spinner stuck. If the key is wrong
    // they'll find out the first time they try to stream.
    await _debrid.saveRDApiKey(key);
    if (!mounted) return;
    setState(() {
      _isRDLoggedIn = true;
      _isVerifyingRD = false;
      _rdController.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Real-Debrid API key saved')),
    );
  }

  void _logoutRD() async {
    await _debrid.logoutRD();
    setState(() {
      _isRDLoggedIn = false;
      _rdController.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logged out of Real-Debrid')));
    }
  }

  // Track which sections are expanded
  final Set<String> _expandedSections = {'backup'};

  // Owned scroll controller for the settings list. Without this the
  // Scrollbar attaches to the PrimaryScrollController, which on desktop
  // makes thumb-drag distance jump every time a section expands and the
  // scroll extent grows under your cursor.
  final ScrollController _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: AppTheme.backgroundDecoration,
        child: SafeArea(
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            interactive: true,
            // Plain SingleChildScrollView + Column instead of CustomScrollView
            // / SliverList: every child's height is laid out up-front so the
            // total scroll extent (and therefore the scrollbar thumb size)
            // stays stable instead of jumping when heavy items like the
            // ReorderableListView-based provider order get measured lazily.
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 16, bottom: 12),
                    child: Text('Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32, fontFamily: 'Poppins')),
                  ),

                    // ── Backup & Restore ──
                    _buildExpandableSection(
                      id: 'backup',
                      icon: Icons.backup_rounded,
                      title: 'Backup & Restore',
                      children: [_buildBackupRestore()],
                    ),

                    // ── Appearance ──
                    _buildExpandableSection(
                      id: 'appearance',
                      icon: Icons.palette_rounded,
                      title: 'Appearance',
                      children: [
                        _buildFocusableToggle(
                          'Light Mode',
                          'Disables blur, glows, shadows, and animations for better FPS.',
                          _isLightMode,
                          (val) async {
                            await _settings.setLightMode(val);
                            setState(() => _isLightMode = val);
                          },
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('THEME', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildThemePicker(),
                      ],
                    ),

                    // ── Playback ──
                    _buildExpandableSection(
                      id: 'playback',
                      icon: Icons.play_circle_outline_rounded,
                      title: 'Playback',
                      children: [
                        _buildFocusableToggle(
                          'Direct Streaming Mode',
                          'Use direct stream links instead of torrents by default.',
                          _isStreamingMode,
                          (val) async {
                            await _settings.setStreamingMode(val);
                            setState(() => _isStreamingMode = val);
                          },
                        ),
                        _buildStreamProviderOrder(),
                        _buildFocusableDropdown(
                          'Video Player',
                          'Choose which player opens videos.',
                          _externalPlayer,
                          ExternalPlayerService.playerNames,
                          (val) async {
                            if (val != null) {
                              await _settings.setExternalPlayer(val);
                              setState(() => _externalPlayer = val);
                            }
                          },
                        ),
                        _buildFocusableDropdown(
                          'Preferred Audio Language',
                          'When a video starts, automatically switch to a matching audio track. Pick "None" to leave the default.',
                          _preferredAudioLang,
                          kTrackLanguageDisplayNames,
                          (val) async {
                            if (val != null) {
                              await _settings.setPreferredAudioLanguage(val);
                              setState(() => _preferredAudioLang = val);
                            }
                          },
                        ),
                        _buildFocusableToggle(
                          'Avoid unsupported audio (Atmos / TrueHD / 7.1)',
                          'Switch to AC-3 / E-AC-3 / AAC when the original track\'s codec or channel layout isn\'t supported.',
                          _avoidUnsupportedAudio,
                          (val) async {
                            await _settings.setAvoidUnsupportedAudio(val);
                            setState(() => _avoidUnsupportedAudio = val);
                          },
                        ),
                      ],
                    ),

                    // ── Search & Torrents ──
                    _buildExpandableSection(
                      id: 'search',
                      icon: Icons.search_rounded,
                      title: 'Search & Torrents',
                      children: [
                        _buildFocusableDropdown(
                          'Default Sort Order',
                          'How torrent results are sorted automatically.',
                          _sortPreference,
                          [
                            'Seeders (High to Low)', 'Seeders (Low to High)',
                            'Quality (High to Low)', 'Quality (Low to High)',
                            'Size (High to Low)', 'Size (Low to High)',
                          ],
                          (val) {
                            if (val != null) {
                              _settings.setSortPreference(val);
                              setState(() => _sortPreference = val);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('TORRENT ENGINE', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 4),
                        _buildFocusableDropdown(
                          'Cache Type',
                          'Where torrent data is cached during streaming.',
                          _torrentCacheType == 'ram' ? 'RAM' : 'Disk',
                          ['RAM', 'Disk'],
                          (val) async {
                            if (val != null) {
                              final type = val == 'RAM' ? 'ram' : 'disk';
                              await _settings.setTorrentCacheType(type);
                              setState(() => _torrentCacheType = type);
                            }
                          },
                        ),
                        if (_torrentCacheType == 'ram')
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 4, top: 8, bottom: 4),
                                child: Text('RAM Cache Size: $_torrentRamCacheMb MB', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                              ),
                              Slider(
                                value: _torrentRamCacheMb.toDouble(),
                                min: 50, max: 2048, divisions: 39,
                                activeColor: Colors.deepPurpleAccent,
                                inactiveColor: Colors.white12,
                                label: '$_torrentRamCacheMb MB',
                                onChanged: (val) => setState(() => _torrentRamCacheMb = val.round()),
                                onChangeEnd: (val) async => await _settings.setTorrentRamCacheMb(val.round()),
                              ),
                            ],
                          ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 4, top: 8, bottom: 0),
                              child: Text(
                                'Connections per torrent: $_torrentConnectionsLimit',
                                style: const TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(left: 4, bottom: 4),
                              child: Text(
                                'Lower (5–25) often streams better on high-seed swarms.',
                                style: TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ),
                            Slider(
                              value: _torrentConnectionsLimit.toDouble().clamp(5, 200),
                              min: 5, max: 200, divisions: 39,
                              activeColor: Colors.deepPurpleAccent,
                              inactiveColor: Colors.white12,
                              label: '$_torrentConnectionsLimit',
                              onChanged: (val) => setState(
                                  () => _torrentConnectionsLimit = val.round()),
                              onChangeEnd: (val) async {
                                await TorrentStreamService()
                                    .applyConnectionsLimit(val.round());
                              },
                            ),
                          ],
                        ),
                      ],
                    ),

                    // ── Providers & Addons ──
                    _buildExpandableSection(
                      id: 'providers',
                      icon: Icons.extension_rounded,
                      title: 'Providers & Addons',
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('STREMIO ADDONS', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildAddonInput(),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('NUVIO ADDONS', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildNuvioAddonSection(),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('JACKETT', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildJackettConfig(),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('PROWLARR', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildProwlarrConfig(),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('WEBSTREAMR (LOCAL)', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.language),
                            title: const Text('WebStreamr Settings'),
                            subtitle: const Text('Country toggles, MFP, FlareSolverr, TMDB token'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const WebStreamrSettingsScreen(),
                            )),
                          ),
                        ),
                      ],
                    ),

                    // ── Debrid ──
                    _buildExpandableSection(
                      id: 'debrid',
                      icon: Icons.cloud_download_rounded,
                      title: 'Debrid',
                      children: [
                        _buildFocusableToggle(
                          'Use Debrid for Streams',
                          'Resolve torrents using your debrid account.',
                          _useDebrid,
                          (val) async {
                            await _settings.setUseDebridForStreams(val);
                            setState(() => _useDebrid = val);
                          },
                        ),
                        _buildFocusableDropdown(
                          'Debrid Service',
                          'Select your preferred provider.',
                          _debridService,
                          ['None', 'Real-Debrid', 'TorBox', 'AllDebrid', 'Premiumize', 'Debrid-Link'],
                          (val) async {
                            if (val != null) {
                              await _settings.setDebridService(val);
                              setState(() => _debridService = val);
                            }
                          },
                        ),
                        if (_debridService == 'Real-Debrid') _buildRDLogin(),
                        if (_debridService == 'TorBox') _buildTorBoxConfig(),
                        if (_debridService == 'AllDebrid') _buildAllDebridConfig(),
                        if (_debridService == 'Premiumize') _buildPremiumizeConfig(),
                        if (_debridService == 'Debrid-Link') _buildDebridLinkConfig(),
                      ],
                    ),

                    // ── Accounts & Sync ──
                    _buildExpandableSection(
                      id: 'accounts',
                      icon: Icons.sync_rounded,
                      title: 'Accounts & Sync',
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('TRAKT', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildTraktSection(),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('SIMKL', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildSimklSection(),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('MDBLIST', style: TextStyle(color: AppTheme.current.primaryColor, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        ),
                        const SizedBox(height: 8),
                        _buildMdblistSection(),
                      ],
                    ),

                    // ── Lists ──
                    _buildExpandableSection(
                      id: 'lists',
                      icon: Icons.list_alt_rounded,
                      title: 'Lists',
                      children: [_buildListsSection()],
                    ),

                    // ── Navigation Bar ──
                    _buildExpandableSection(
                      id: 'navbar',
                      icon: Icons.tab_rounded,
                      title: 'Navigation Bar',
                      children: [_buildNavbarConfig()],
                    ),

                    // ── App Updates ──
                    _buildExpandableSection(
                      id: 'updates',
                      icon: Icons.system_update_rounded,
                      title: 'App Updates',
                      children: [_buildUpdateChecker()],
                    ),

                    const SizedBox(height: 40),
                    const Center(
                      child: Text(
                        'PlayTorrio Native v1.3.7',
                        style: TextStyle(color: Colors.white24, fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 100),
                  ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Expandable Section Tile
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildExpandableSection({
    required String id,
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    final isExpanded = _expandedSections.contains(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: isExpanded ? 0.04 : 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isExpanded
                ? AppTheme.current.primaryColor.withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Column(
          children: [
            // Header (always visible, tappable)
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                setState(() {
                  if (isExpanded) {
                    _expandedSections.remove(id);
                  } else {
                    _expandedSections.add(id);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: isExpanded ? AppTheme.current.primaryColor : Colors.white54),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: isExpanded ? Colors.white : Colors.white70,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: isExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: isExpanded ? AppTheme.current.primaryColor : Colors.white30,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Content (animated)
            AnimatedCrossFade(
              firstChild: Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
              secondChild: const SizedBox.shrink(),
              crossFadeState: isExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              duration: const Duration(milliseconds: 200),
              sizeCurve: Curves.easeInOut,
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Backup & Restore
  // ═══════════════════════════════════════════════════════════════════════════

  bool _isExporting = false;
  bool _isImporting = false;

  Future<void> _exportSettings() async {
    setState(() => _isExporting = true);
    try {
      final data = await _settings.exportAllSettings();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final fileName = 'playtorrio_settings_$timestamp.json';

      // Write to a temp file first, then let the user pick where to save
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsString(jsonStr);

      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Settings',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
      );

      if (result != null) {
        // On desktop, saveFile() returns a path but doesn't write — we must do it ourselves
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          await File(result).writeAsString(jsonStr);
        }
      }

      await tempFile.delete();

      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings exported successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _importSettings() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import Settings',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final String jsonStr;
    if (file.bytes != null) {
      jsonStr = utf8.decode(file.bytes!);
    } else if (file.path != null) {
      jsonStr = await File(file.path!).readAsString();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read file.')),
        );
      }
      return;
    }

    if (!mounted) return;

    // Confirm before overwriting
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2C),
        title: const Text('Import Settings', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will overwrite all your current settings, including addons, API keys, and preferences. Continue?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isImporting = true);
    try {
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      await _settings.importAllSettings(data);
      await AppTheme.initTheme(); // Hydrate theme notifier from imported preset
      await _loadSettings(); // Refresh all UI state
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings imported successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Widget _buildBackupRestore() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Export or import all your settings, addons, API keys, and preferences as a JSON file.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isExporting ? null : _exportSettings,
                  icon: _isExporting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.upload_rounded, size: 20),
                  label: const Text('Export'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurpleAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isImporting ? null : _importSettings,
                  icon: _isImporting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_rounded, size: 20),
                  label: const Text('Import'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Navbar Configuration
  // ═══════════════════════════════════════════════════════════════════════════

  static const Map<String, Map<String, dynamic>> _navMeta = {
    'home':         {'icon': Icons.home,                       'label': 'Home'},
    'discover':     {'icon': Icons.explore,                    'label': 'Discover'},
    'similar':      {'icon': Icons.auto_awesome,               'label': 'Similar'},
    'downloader':   {'icon': Icons.cloud_download,             'label': 'Media Downloader'},
    'search':       {'icon': Icons.search,                     'label': 'Search'},
    'mylist':       {'icon': Icons.bookmark,                   'label': 'My List'},
    'magnet':       {'icon': Icons.link_rounded,               'label': 'Magnet'},
    'live_matches': {'icon': Icons.sports_soccer_rounded,      'label': 'Live Matches'},
    'iptv':         {'icon': Icons.live_tv,                    'label': 'IPTV'},
    'audiobooks':   {'icon': Icons.menu_book,                  'label': 'Audiobooks'},
    'books':        {'icon': Icons.import_contacts_rounded,    'label': 'Books'},
    'music':        {'icon': Icons.music_note,                 'label': 'Music'},
    'comics':       {'icon': Icons.auto_stories,               'label': 'Comics'},
    'manga':        {'icon': Icons.book,                       'label': 'Manga'},
    'jellyfin':     {'icon': Icons.dns_rounded,                'label': 'Jellyfin'},
    'anime':        {'icon': Icons.play_circle_filled,         'label': 'Anime'},
    'anime_arabic': {'icon': Icons.subtitles,                  'label': 'Anime Arabic'},
    'asian_drama':  {'icon': Icons.theater_comedy,             'label': 'Asian Drama'},
    'arabic':       {'icon': Icons.movie_filter,               'label': 'Arabic'},
  };

  void _saveNavbarConfig() {
    final visible = _navbarOrder.where((id) => _navbarVisible.contains(id)).toList();
    _settings.setNavbarConfig(visible);
  }

  Widget _buildNavbarConfig() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'Show, hide, and reorder navigation tabs. Drag to reorder. Settings is always visible.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
          ),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _navbarOrder.length,
          proxyDecorator: (child, index, animation) {
            return Material(
              color: Colors.transparent,
              child: child,
            );
          },
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _navbarOrder.removeAt(oldIndex);
              _navbarOrder.insert(newIndex, item);
            });
            _saveNavbarConfig();
          },
          itemBuilder: (context, index) {
            final id = _navbarOrder[index];
            final meta = _navMeta[id]!;
            final isVisible = _navbarVisible.contains(id);

            return Container(
              key: ValueKey(id),
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                color: isVisible
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.white.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: Icon(
                  meta['icon'] as IconData,
                  color: isVisible ? Colors.white : Colors.white24,
                  size: 22,
                ),
                title: Text(
                  meta['label'] as String,
                  style: TextStyle(
                    color: isVisible ? Colors.white : Colors.white38,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: isVisible,
                      activeTrackColor: AppTheme.primaryColor,
                      onChanged: (val) {
                        setState(() {
                          if (val) {
                            _navbarVisible.add(id);
                          } else {
                            _navbarVisible.remove(id);
                          }
                        });
                        _saveNavbarConfig();
                      },
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(Icons.drag_handle, color: Colors.white24, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        // Settings row — always visible, not reorderable
        Container(
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
          ),
          child: ListTile(
            leading: const Icon(Icons.settings, color: AppTheme.primaryColor, size: 22),
            title: const Text(
              'Settings',
              style: TextStyle(color: AppTheme.primaryColor, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, color: Colors.white.withValues(alpha: 0.2), size: 16),
                const SizedBox(width: 8),
                Text('Always visible', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAddonInput() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Install Stremio Addon', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addonController,
                  decoration: InputDecoration(
                    hintText: 'stremio://... or https://...',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _isInstalling ? null : _installAddon,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isInstalling 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Install', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          if (_installedAddons.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('INSTALLED ADDONS', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            const SizedBox(height: 12),
            ..._installedAddons.map((addon) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: ListTile(
                leading: addon['icon'].toString().isNotEmpty 
                  ? ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(addon['icon'], width: 32, height: 32, errorBuilder: (c,e,s) => const Icon(Icons.extension)))
                  : const Icon(Icons.extension, color: AppTheme.primaryColor),
                title: Text(addon['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: Text(addon['baseUrl'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white38)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () => _removeAddon(addon['baseUrl']),
                ),
              ),
            )),
          ],
        ],
      ),
    );
  }

  Widget _buildNuvioAddonSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Install Nuvio Addon',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Paste a Nuvio manifest URL (raw .../manifest.json)',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nuvioController,
                  decoration: InputDecoration(
                    hintText: 'https://.../manifest.json',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _nuvioInstalling ? null : _installNuvioAddon,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _nuvioInstalling
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Install', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          if (_nuvioAddons.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text(
              'INSTALLED NUVIO ADDONS',
              style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
            ),
            const SizedBox(height: 12),
            ..._nuvioAddons.map((addon) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      leading: const Icon(Icons.code_rounded, color: AppTheme.primaryColor),
                      title: Text(addon.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: Text(
                        '${addon.scrapers.length} scraper${addon.scrapers.length == 1 ? '' : 's'} \u00b7 v${addon.version}',
                        style: const TextStyle(fontSize: 11, color: Colors.white38),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        onPressed: () => _removeNuvioAddon(addon.manifestUrl),
                        tooltip: 'Remove addon',
                      ),
                      children: addon.scrapers.map((s) {
                        return SwitchListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                          dense: true,
                          activeThumbColor: AppTheme.primaryColor,
                          value: s.enabled,
                          onChanged: (val) async {
                            await NuvioService.instance.setScraperEnabled(
                              manifestUrl: addon.manifestUrl,
                              scraperId: s.id,
                              enabled: val,
                            );
                          },
                          title: Text(s.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            [
                              if (s.description != null && s.description!.isNotEmpty) s.description!,
                              if (s.supportedTypes.isNotEmpty) s.supportedTypes.join(', '),
                            ].join(' \u00b7 '),
                            style: const TextStyle(fontSize: 11, color: Colors.white54),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Future<void> _installNuvioAddon() async {
    final url = _nuvioController.text.trim();
    if (url.isEmpty) return;
    setState(() => _nuvioInstalling = true);
    try {
      final addon = await NuvioService.instance.install(url);
      if (!mounted) return;
      _nuvioController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Installed ${addon.name} (${addon.scrapers.length} scrapers)')),
      );
      await _loadNuvioAddons();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Install failed: $e'), backgroundColor: Colors.redAccent),
      );
    } finally {
      if (mounted) setState(() => _nuvioInstalling = false);
    }
  }

  Future<void> _removeNuvioAddon(String manifestUrl) async {
    await NuvioService.instance.remove(manifestUrl);
    await _loadNuvioAddons();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nuvio addon removed')),
    );
  }

  Widget _buildRDLogin() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isRDLoggedIn)
            ElevatedButton.icon(
              onPressed: _logoutRD,
              icon: const Icon(Icons.logout),
              label: const Text('Logout from Real-Debrid'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                foregroundColor: Colors.redAccent,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            )
          else ...[
            const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rdController,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: 'Enter Real-Debrid API Key',
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isVerifyingRD ? null : _saveRDApiKey,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isVerifyingRD
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final url = Uri.parse('https://real-debrid.com/apitoken');
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text(
                'Get your API key at real-debrid.com/apitoken',
                style: TextStyle(color: AppTheme.primaryColor, fontSize: 12, decoration: TextDecoration.underline),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTorBoxConfig() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _torboxController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Enter TorBox API Key',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () async {
                  await _debrid.saveTorBoxKey(_torboxController.text);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TorBox API Key Saved!')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAllDebridConfig() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _alldebridController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Enter AllDebrid API Key',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () async {
                  await _debrid.saveAllDebridKey(_alldebridController.text);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AllDebrid API Key Saved!')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final url = Uri.parse('https://alldebrid.com/apikeys');
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text(
              'Get your API key at alldebrid.com/apikeys',
              style: TextStyle(color: AppTheme.primaryColor, fontSize: 12, decoration: TextDecoration.underline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumizeConfig() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _premiumizeController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Enter Premiumize API Key',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () async {
                  await _debrid.savePremiumizeKey(_premiumizeController.text);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Premiumize API Key Saved!')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final url = Uri.parse('https://www.premiumize.me/account');
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text(
              'Get your API key at premiumize.me/account',
              style: TextStyle(color: AppTheme.primaryColor, fontSize: 12, decoration: TextDecoration.underline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebridLinkConfig() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _debridlinkController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Enter Debrid-Link API Key',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () async {
                  await _debrid.saveDebridLinkKey(_debridlinkController.text);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Debrid-Link API Key Saved!')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final url = Uri.parse('https://debrid-link.com/webapp/apikey');
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text(
              'Get your API key at debrid-link.com/webapp/apikey',
              style: TextStyle(color: AppTheme.primaryColor, fontSize: 12, decoration: TextDecoration.underline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJackettConfig() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Base URL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _jackettUrlController,
            decoration: InputDecoration(
              hintText: 'http://localhost:9117',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onChanged: (_) => setState(() => _jackettTestResult = null),
          ),
          const SizedBox(height: 16),
          const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _jackettApiKeyController,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Enter Jackett API Key',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onChanged: (_) => setState(() => _jackettTestResult = null),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _isTestingJackett ? null : _testJackettConnection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isTestingJackett
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Test Connection', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saveJackettSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          if (_jackettTestResult != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _jackettTestResult!.startsWith('✅')
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _jackettTestResult!.startsWith('✅')
                      ? Colors.green.withValues(alpha: 0.3)
                      : Colors.red.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                _jackettTestResult!,
                style: TextStyle(
                  color: _jackettTestResult!.startsWith('✅') ? Colors.green : Colors.red,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProwlarrConfig() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Base URL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _prowlarrUrlController,
            decoration: InputDecoration(
              hintText: 'http://localhost:9696',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onChanged: (_) => setState(() {
              _prowlarrTestResult = null;
              _prowlarrTagsLoaded = false;
              _prowlarrAvailableTags = [];
            }),
          ),
          const SizedBox(height: 16),
          const Text('API Key', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _prowlarrApiKeyController,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Enter Prowlarr API Key',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onChanged: (_) => setState(() {
              _prowlarrTestResult = null;
              _prowlarrTagsLoaded = false;
              _prowlarrAvailableTags = [];
            }),
          ),
          const SizedBox(height: 20),
          const Text('Filter by Tag', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          if (!_prowlarrTagsLoaded) ...[
            Text(
              'Use the Test Connection button to load available tags.',
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.4)),
            ),
          ] else if (_prowlarrAvailableTags.isEmpty) ...[
            Text(
              'No tags found in Prowlarr. Add tags to your indexers to use this filter.',
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.4)),
            ),
          ] else ...[
            Text(
              'Limit searches to indexers with the selected tags. Leave all unselected to search all indexers.',
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _prowlarrAvailableTags.map((tag) {
                final isSelected = _prowlarrSelectedTagIds.contains(tag.id);
                return FilterChip(
                  label: Text(tag.label),
                  selected: isSelected,
                  onSelected: (value) {
                    setState(() {
                      if (value) {
                        _prowlarrSelectedTagIds.add(tag.id);
                      } else {
                        _prowlarrSelectedTagIds.remove(tag.id);
                      }
                    });
                  },
                  selectedColor: AppTheme.primaryColor.withValues(alpha: 0.25),
                  checkmarkColor: AppTheme.primaryColor,
                  backgroundColor: Colors.white.withValues(alpha: 0.05),
                  labelStyle: TextStyle(
                    color: isSelected ? AppTheme.primaryColor : Colors.white70,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                  side: BorderSide(
                    color: isSelected
                        ? AppTheme.primaryColor
                        : Colors.white.withValues(alpha: 0.2),
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                );
              }).toList(),
            ),
            if (_prowlarrSelectedTagIds.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'All indexers will be searched.',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.4)),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _isTestingProwlarr ? null : _testProwlarrConnection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isTestingProwlarr
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Test Connection', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saveProwlarrSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          if (_prowlarrTestResult != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _prowlarrTestResult!.startsWith('✅')
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _prowlarrTestResult!.startsWith('✅')
                      ? Colors.green.withValues(alpha: 0.3)
                      : Colors.red.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                _prowlarrTestResult!,
                style: TextStyle(
                  color: _prowlarrTestResult!.startsWith('✅') ? Colors.green : Colors.red,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _testJackettConnection() async {
    final url = _jackettUrlController.text.trim();
    final apiKey = _jackettApiKeyController.text.trim();

    if (url.isEmpty || apiKey.isEmpty) {
      setState(() => _jackettTestResult = '❌ Please enter both Base URL and API Key');
      return;
    }

    setState(() {
      _isTestingJackett = true;
      _jackettTestResult = null;
    });

    try {
      final result = await _jackett.testConnection(url, apiKey);
      if (mounted) {
        setState(() {
          _jackettTestResult = result.message;
          _isTestingJackett = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _jackettTestResult = '❌ Error: $e';
          _isTestingJackett = false;
        });
      }
    }
  }

  Future<void> _saveJackettSettings() async {
    final url = _jackettUrlController.text.trim();
    final apiKey = _jackettApiKeyController.text.trim();

    await _settings.setJackettBaseUrl(url);
    await _settings.setJackettApiKey(apiKey);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Jackett settings saved!')),
      );
    }
  }

  Future<void> _testProwlarrConnection() async {
    final url = _prowlarrUrlController.text.trim();
    final apiKey = _prowlarrApiKeyController.text.trim();

    if (url.isEmpty || apiKey.isEmpty) {
      setState(() => _prowlarrTestResult = '❌ Please enter both Base URL and API Key');
      return;
    }

    setState(() {
      _isTestingProwlarr = true;
      _prowlarrTestResult = null;
    });

    try {
      final result = await _prowlarr.testConnection(url, apiKey);
      if (result.success) {
        _tryLoadProwlarrTags();
      }
      if (mounted) {
        setState(() {
          _prowlarrTestResult = result.message;
          _isTestingProwlarr = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _prowlarrTestResult = '❌ Error: $e';
          _isTestingProwlarr = false;
        });
      }
    }
  }

  Future<void> _saveProwlarrSettings() async {
    final url = _prowlarrUrlController.text.trim();
    final apiKey = _prowlarrApiKeyController.text.trim();

    await _settings.setProwlarrBaseUrl(url);
    await _settings.setProwlarrApiKey(apiKey);
    await _settings.setProwlarrTagIds(_prowlarrSelectedTagIds.toList());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prowlarr settings saved!')),
      );
    }
  }

  /// Silently fetch Prowlarr tags; used on init and after a successful test.
  Future<void> _tryLoadProwlarrTags() async {
    final url = _prowlarrUrlController.text.trim();
    final apiKey = _prowlarrApiKeyController.text.trim();
    if (url.isEmpty || apiKey.isEmpty) return;
    try {
      final tags = await _prowlarr.fetchTags(url, apiKey);
      if (mounted) {
        setState(() {
          _prowlarrAvailableTags = tags;
          _prowlarrTagsLoaded = true;
        });
      }
    } catch (_) {
      // Non-fatal — tags section simply not shown until explicit test
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Trakt
  // ═══════════════════════════════════════════════════════════════════════

  void _startTraktLogin() async {
    final data = await _trakt.startDeviceAuth();
    if (data == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start Trakt login')),
        );
      }
      return;
    }

    final userCode = data['user_code'] as String;
    final verifyUrl = data['verification_url'] as String;
    final interval = (data['interval'] as int?) ?? 5;
    final expiresIn = (data['expires_in'] as int?) ?? 600;
    final deviceCode = data['device_code'] as String;

    setState(() {
      _traktUserCode = userCode;
      _traktVerifyUrl = verifyUrl;
    });

    await Clipboard.setData(ClipboardData(text: userCode));

    // Auto-open the verification URL in the default browser
    final uri = Uri.parse(verifyUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Code $userCode copied! Opening $verifyUrl...')),
      );
    }

    _traktPollTimer?.cancel();
    _traktPollTimer = Timer.periodic(Duration(seconds: interval), (timer) async {
      final result = await _trakt.pollForToken(deviceCode);
      if (result == 'success') {
        timer.cancel();
        // Fetch username
        final profile = await _trakt.getUserProfile();
        final username = profile?['user']?['username']?.toString() ?? profile?['username']?.toString();
        if (mounted) {
          setState(() {
            _traktUserCode = null;
            _traktVerifyUrl = null;
            _isTraktLoggedIn = true;
            _traktUsername = username;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Logged in to Trakt${username != null ? " as $username" : ""}!')),
          );
        }
        // Auto-sync after login
        _syncTrakt();
      } else if (result == 'expired' || result == 'denied') {
        timer.cancel();
        if (mounted) {
          setState(() {
            _traktUserCode = null;
            _traktVerifyUrl = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result == 'denied' ? 'Trakt login denied' : 'Code expired, try again')),
          );
        }
      }
      // 'pending' → keep polling
    });

    // Expire timer
    Future.delayed(Duration(seconds: expiresIn), () {
      if (_traktPollTimer?.isActive ?? false) {
        _traktPollTimer?.cancel();
        if (mounted) {
          setState(() {
            _traktUserCode = null;
            _traktVerifyUrl = null;
          });
        }
      }
    });
  }

  void _logoutTrakt() async {
    await _trakt.logout();
    if (mounted) {
      setState(() {
        _isTraktLoggedIn = false;
        _traktUsername = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logged out of Trakt')),
      );
    }
  }

  Future<void> _syncTrakt() async {
    if (_isTraktSyncing) return;
    setState(() => _isTraktSyncing = true);

    try {
      final watchlistCount = await _trakt.importWatchlistToMyList();
      final playbackCount = await _trakt.importPlaybackToWatchHistory();
      final episodesImported = await _trakt.importWatchedEpisodes();
      final exportedCount = await _trakt.exportMyListToWatchlist();
      final episodesExported = await _trakt.exportWatchedEpisodes();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Trakt sync done! Imported $watchlistCount watchlist, '
              '$playbackCount playback, $episodesImported episodes. '
              'Exported $exportedCount watchlist, $episodesExported episodes.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Trakt sync error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isTraktSyncing = false);
    }
  }

  Widget _buildTraktStatsWidget() {
    final stats = _traktStats!;
    final movies = stats['movies'] as Map<String, dynamic>? ?? {};
    final episodes = stats['episodes'] as Map<String, dynamic>? ?? {};
    final moviesWatched = movies['watched'] as int? ?? 0;
    final moviesMinutes = movies['minutes'] as int? ?? 0;
    final epsWatched = episodes['watched'] as int? ?? 0;
    final epsMinutes = episodes['minutes'] as int? ?? 0;
    final totalHours = ((moviesMinutes + epsMinutes) / 60).round();

    Widget stat(IconData icon, String label, String value) {
      return Column(
        children: [
          Icon(icon, color: AppTheme.primaryColor, size: 20),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          stat(Icons.movie_rounded, 'Movies', '$moviesWatched'),
          stat(Icons.tv_rounded, 'Episodes', '$epsWatched'),
          stat(Icons.schedule_rounded, 'Hours', '$totalHours'),
        ],
      ),
    );
  }

  Widget _buildTraktSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sync your watchlist and watch history with Trakt.tv',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 16),

          if (_isTraktLoggedIn) ...[
            // ── Logged in ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected${_traktUsername != null ? " as $_traktUsername" : ""}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const Text('Trakt.tv', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  const Icon(Icons.sync, color: AppTheme.primaryColor, size: 18),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Stats
            if (_traktStats != null) ...[
              _buildTraktStatsWidget(),
              const SizedBox(height: 12),
            ],

            // Sync button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isTraktSyncing ? null : _syncTrakt,
                icon: _isTraktSyncing
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync),
                label: Text(_isTraktSyncing ? 'Syncing...' : 'Sync Now'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Logout button
            ElevatedButton.icon(
              onPressed: _logoutTrakt,
              icon: const Icon(Icons.logout),
              label: const Text('Logout from Trakt'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                foregroundColor: Colors.redAccent,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ] else if (_traktUserCode != null) ...[
            // ── Polling — show code ──
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    'Go to the URL below and enter this code:',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _traktUserCode!,
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryColor,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _traktVerifyUrl ?? 'https://trakt.tv/activate',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(
                    color: AppTheme.primaryColor,
                    backgroundColor: Colors.white10,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Waiting for authorization...',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ] else ...[
            // ── Not logged in ──
            ElevatedButton.icon(
              onPressed: _startTraktLogin,
              icon: const Icon(Icons.login),
              label: const Text('Login with Trakt'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white10,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Simkl
  // ═══════════════════════════════════════════════════════════════════════

  void _startSimklLogin() async {
    final data = await _simkl.requestPin();
    if (data == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start Simkl login')),
        );
      }
      return;
    }

    final userCode = data['user_code'] as String;
    final verifyUrl = data['verification_url']?.toString() ?? 'https://simkl.com/pin/$userCode';
    final interval = (data['interval'] as int?) ?? 5;
    final expiresIn = (data['expires_in'] as int?) ?? 900;

    setState(() {
      _simklUserCode = userCode;
      _simklVerifyUrl = verifyUrl;
    });

    await Clipboard.setData(ClipboardData(text: userCode));

    final uri = Uri.parse(verifyUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Code $userCode copied! Opening $verifyUrl...')),
      );
    }

    _simklPollTimer?.cancel();
    _simklPollTimer = Timer.periodic(Duration(seconds: interval), (timer) async {
      final token = await _simkl.pollForToken(userCode);
      if (token != null) {
        timer.cancel();
        final profile = await _simkl.getUserProfile();
        final username = profile?['name']?.toString();
        if (mounted) {
          setState(() {
            _simklUserCode = null;
            _simklVerifyUrl = null;
            _isSimklLoggedIn = true;
            _simklUsername = username;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Logged in to Simkl${username != null ? " as $username" : ""}!')),
          );
        }
        _syncSimkl();
      }
    });

    Future.delayed(Duration(seconds: expiresIn), () {
      if (_simklPollTimer?.isActive ?? false) {
        _simklPollTimer?.cancel();
        if (mounted) {
          setState(() {
            _simklUserCode = null;
            _simklVerifyUrl = null;
          });
        }
      }
    });
  }

  void _logoutSimkl() async {
    await _simkl.logout();
    if (mounted) {
      setState(() {
        _isSimklLoggedIn = false;
        _simklUsername = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logged out of Simkl')),
      );
    }
  }

  Future<void> _syncSimkl() async {
    if (_isSimklSyncing) return;
    setState(() => _isSimklSyncing = true);

    try {
      final watchlistCount = await _simkl.importWatchlistToMyList();
      final episodesImported = await _simkl.importWatchedEpisodes();
      final exportedCount = await _simkl.exportMyListToWatchlist();
      final episodesExported = await _simkl.exportWatchedEpisodes();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Simkl sync done! Imported $watchlistCount watchlist, '
              '$episodesImported episodes. '
              'Exported $exportedCount watchlist, $episodesExported episodes.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Simkl sync error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSimklSyncing = false);
    }
  }

  Widget _buildSimklSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sync your watchlist and watch history with Simkl',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 16),

          if (_isSimklLoggedIn) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected${_simklUsername != null ? " as $_simklUsername" : ""}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const Text('Simkl', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  const Icon(Icons.sync, color: AppTheme.primaryColor, size: 18),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSimklSyncing ? null : _syncSimkl,
                icon: _isSimklSyncing
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync),
                label: Text(_isSimklSyncing ? 'Syncing...' : 'Sync Now'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _logoutSimkl,
              icon: const Icon(Icons.logout),
              label: const Text('Logout from Simkl'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                foregroundColor: Colors.redAccent,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ] else if (_simklUserCode != null) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    'Go to the URL below and enter this code:',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _simklUserCode!,
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryColor,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _simklVerifyUrl ?? 'https://simkl.com/pin',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(
                    color: AppTheme.primaryColor,
                    backgroundColor: Colors.white10,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Waiting for authorization...',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ] else ...[
            ElevatedButton.icon(
              onPressed: _startSimklLogin,
              icon: const Icon(Icons.login),
              label: const Text('Login with Simkl'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white10,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MDBlist
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _saveMdblistApiKey() async {
    final key = _mdblistApiKeyController.text.trim();
    if (key.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter an API key')),
        );
      }
      return;
    }

    await _mdblist.setApiKey(key);

    // Validate by fetching user info
    final info = await _mdblist.getUserInfo();
    if (info != null) {
      if (mounted) {
        setState(() {
          _isMdblistConfigured = true;
          _mdblistUsername = info['name']?.toString();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('MDBlist connected${_mdblistUsername != null ? " as $_mdblistUsername" : ""}!')),
        );
      }
    } else {
      await _mdblist.logout();
      if (mounted) {
        setState(() {
          _isMdblistConfigured = false;
          _mdblistUsername = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid MDBlist API key')),
        );
      }
    }
  }

  void _logoutMdblist() async {
    await _mdblist.logout();
    if (mounted) {
      setState(() {
        _isMdblistConfigured = false;
        _mdblistUsername = null;
        _mdblistApiKeyController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MDBlist API key removed')),
      );
    }
  }

  Widget _buildMdblistSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Aggregated ratings from IMDb, TMDB, Trakt, Letterboxd, RT, and more',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 16),

          if (_isMdblistConfigured) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected${_mdblistUsername != null ? " as $_mdblistUsername" : ""}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const Text('MDBlist', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _logoutMdblist,
              icon: const Icon(Icons.logout),
              label: const Text('Remove API Key'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                foregroundColor: Colors.redAccent,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ] else ...[
            TextField(
              controller: _mdblistApiKeyController,
              decoration: InputDecoration(
                labelText: 'MDBlist API Key',
                hintText: 'Paste your API key from mdblist.com',
                labelStyle: const TextStyle(color: Colors.white54),
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _saveMdblistApiKey,
              icon: const Icon(Icons.save),
              label: const Text('Save API Key'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildListsSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Browse and manage your Trakt and MDBlist custom lists',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const ListsScreen(),
              )),
              icon: const Icon(Icons.list_alt_rounded),
              label: const Text('Manage Lists'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateChecker() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Check for new versions of PlayTorrio',
            style: TextStyle(fontSize: 14, color: Colors.white70),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isCheckingUpdate ? null : _checkForUpdates,
              icon: _isCheckingUpdate
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.system_update_rounded),
              label: Text(
                _isCheckingUpdate ? 'Checking...' : 'Check for Updates',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingUpdate = true);
    
    try {
      final updateInfo = await _updater.checkForUpdates();
      
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
        
        if (updateInfo != null) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => UpdateDialog(updateInfo: updateInfo),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 12),
                  Text('You\'re running the latest version!'),
                ],
              ),
              backgroundColor: Colors.green.withValues(alpha: 0.2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to check for updates: $e'),
            backgroundColor: Colors.red.withValues(alpha: 0.2),
          ),
        );
      }
    }
  }

  Widget _buildThemePicker() {
    final width = MediaQuery.of(context).size.width;
    // Responsive: 2 cols on narrow, 3 on medium, 4 on wide
    final cols = width > 900 ? 4 : (width > 550 ? 3 : 2);
    final aspect = width > 550 ? 2.8 : 2.6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Choose a vibe for your app.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            childAspectRatio: aspect,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: AppTheme.presets.length,
          itemBuilder: (context, index) {
            final preset = AppTheme.presets[index];
            final isSelected = preset.id == _selectedThemeId;
            return GestureDetector(
              onTap: () async {
                await AppTheme.setPreset(preset.id);
                setState(() => _selectedThemeId = preset.id);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: preset.bgCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? preset.primaryColor : Colors.white12,
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: isSelected
                      ? [BoxShadow(color: preset.primaryColor.withValues(alpha: 0.25), blurRadius: 8, spreadRadius: 0)]
                      : [],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [preset.primaryColor, preset.accentColor],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Icon(preset.icon, size: 13, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        preset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (isSelected)
                      Icon(Icons.check_circle, size: 14, color: preset.primaryColor),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildStreamProviderOrder() {
    final providers = <String, dynamic>{
      ...StreamProviders.providers,
      ..._nuvioProviderEntries,
    };
    final order = <String>[
      ..._streamProviderOrder.where(providers.containsKey),
    ];
    for (final k in providers.keys) {
      if (!order.contains(k)) order.add(k);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Provider Order',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'Order in which Direct Streaming Mode tries each provider. The '
            'first one that works wins; the rest become in-player fallbacks.',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: order.length,
              onReorder: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = order.removeAt(oldIndex);
                order.insert(newIndex, item);
                setState(() => _streamProviderOrder = List<String>.from(order));
                await _settings.setStreamProviderOrder(order);
              },
              itemBuilder: (context, i) {
                final key = order[i];
                final name = (providers[key]?['name'] as String?) ?? key;
                return ListTile(
                  key: ValueKey(key),
                  leading: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.current.primaryColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: AppTheme.current.primaryColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(name,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  subtitle: Text(key,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle_rounded, color: Colors.white54),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                final defaults = List<String>.from(
                    SettingsService.defaultStreamProviderOrder);
                await _settings.setStreamProviderOrder(defaults);
                setState(() => _streamProviderOrder = defaults);
              },
              icon: const Icon(Icons.restore_rounded, size: 16),
              label: const Text('Reset to default'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.current.primaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFocusableToggle(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return FocusableControl(
      onTap: () => onChanged(!value),
      scaleOnFocus: 1.0, // Disable scaling
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(fontSize: 13, color: Colors.white54)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: AppTheme.current.primaryColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFocusableDropdown(String title, String subtitle, String value, List<String> options, ValueChanged<String?> onChanged) {
    return FocusableControl(
      onTap: () {},
      scaleOnFocus: 1.0, // Disable scaling
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(fontSize: 13, color: Colors.white54)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButton<String>(
                value: value,
                dropdownColor: Color.lerp(AppTheme.current.bgDark, AppTheme.current.primaryColor, 0.08),
                underline: const SizedBox.shrink(),
                icon: Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.current.primaryColor),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                selectedItemBuilder: (BuildContext context) {
                  return options.map<Widget>((String item) {
                    return Container(
                      alignment: Alignment.centerLeft,
                      child: Text(item, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    );
                  }).toList();
                },
                items: options.map((o) => DropdownMenuItem(value: o, child: Text(o, style: const TextStyle(color: Colors.white)))).toList(),
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
