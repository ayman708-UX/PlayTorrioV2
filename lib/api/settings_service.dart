import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  /// Fires whenever Stremio addons are added or removed.
  /// Listeners can compare the value to detect changes.
  static final ValueNotifier<int> addonChangeNotifier = ValueNotifier<int>(0);

  static const String _streamingModeKey = 'streaming_mode';
  static const String _sortPreferenceKey = 'sort_preference';
  static const String _useDebridKey = 'use_debrid_for_streams';
  static const String _debridServiceKey = 'debrid_service';
  static const String _stremioAddonsKey = 'stremio_addons';
  
  // External player setting
  static const String _externalPlayerKey = 'external_player';

  // Jackett settings
  static const String _jackettBaseUrlKey = 'jackett_base_url';
  static const String _jackettApiKeyKey = 'jackett_api_key';
  
  // Prowlarr settings
  static const String _prowlarrBaseUrlKey = 'prowlarr_base_url';
  static const String _prowlarrApiKeyKey = 'prowlarr_api_key';
  static const String _prowlarrTagIdsKey = 'prowlarr_tag_ids';

  // Light mode (performance)
  static const String _lightModeKey = 'light_mode';

  // Theme preset
  static const String _themePresetKey = 'theme_preset';

  /// Notifier that fires when light mode changes so all widgets can react.
  static final ValueNotifier<bool> lightModeNotifier = ValueNotifier<bool>(false);

  // Torrent cache settings
  static const String _torrentCacheTypeKey = 'torrent_cache_type';
  static const String _torrentRamCacheMbKey = 'torrent_ram_cache_mb';
  static const String _torrentConnectionsLimitKey = 'torrent_connections_limit';

  // Subtitle preferences
  static const String _subSizeKey = 'sub_size';
  static const String _subColorKey = 'sub_color';
  static const String _subBgOpacityKey = 'sub_bg_opacity';
  static const String _subBoldKey = 'sub_bold';
  static const String _subBottomPaddingKey = 'sub_bottom_padding';
  static const String _subFontKey = 'sub_font';

  // Track auto-select preferences
  static const String _preferredAudioLangKey = 'preferred_audio_lang';
  static const String _avoidUnsupportedAudioKey = 'avoid_unsupported_audio';

  // ── Track auto-select getters/setters ─────────────────────────────────────

  /// Display name (e.g. "English") of the audio language to auto-switch to
  /// once a video's audio tracks are known. Returns 'None' to mean
  /// "don't touch the default audio track".
  Future<String> getPreferredAudioLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_preferredAudioLangKey) ?? 'None';
  }
  Future<void> setPreferredAudioLanguage(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferredAudioLangKey, v);
  }

  Future<bool> getAvoidUnsupportedAudio() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_avoidUnsupportedAudioKey) ?? true;
  }
  Future<void> setAvoidUnsupportedAudio(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_avoidUnsupportedAudioKey, v);
  }

  // ── Subtitle getters/setters ──────────────────────────────────────────────

  Future<double> getSubSize({bool isDesktop = false}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_subSizeKey) ?? (isDesktop ? 44.0 : 24.0);
  }
  Future<void> setSubSize(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_subSizeKey, v);
  }

  Future<int> getSubColor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_subColorKey) ?? 0xFFFFFFFF; // white
  }
  Future<void> setSubColor(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_subColorKey, v);
  }

  Future<double> getSubBgOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_subBgOpacityKey) ?? 0.67;
  }
  Future<void> setSubBgOpacity(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_subBgOpacityKey, v);
  }

  Future<bool> getSubBold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_subBoldKey) ?? false;
  }
  Future<void> setSubBold(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_subBoldKey, v);
  }

  Future<double> getSubBottomPadding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_subBottomPaddingKey) ?? 24.0;
  }
  Future<void> setSubBottomPadding(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_subBottomPaddingKey, v);
  }

  Future<String> getSubFont() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subFontKey) ?? 'Default';
  }
  Future<void> setSubFont(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subFontKey, v);
  }

  Future<List<Map<String, dynamic>>> getStremioAddons() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> list = prefs.getStringList(_stremioAddonsKey) ?? [];
    return list.map((s) => json.decode(s) as Map<String, dynamic>).toList();
  }

  Future<void> saveStremioAddon(Map<String, dynamic> addon) async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> current = await getStremioAddons();
    // Prevent duplicates by manifest URL
    current.removeWhere((a) => a['baseUrl'] == addon['baseUrl']);
    current.add(addon);
    await prefs.setStringList(_stremioAddonsKey, current.map((e) => json.encode(e)).toList().cast<String>());
    addonChangeNotifier.value++;
  }

  Future<void> removeStremioAddon(String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> current = await getStremioAddons();
    current.removeWhere((a) => a['baseUrl'] == baseUrl);
    await prefs.setStringList(_stremioAddonsKey, current.map((e) => json.encode(e)).toList().cast<String>());
    addonChangeNotifier.value++;
  }

  Future<bool> isStreamingModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_streamingModeKey) ?? false;
  }

  Future<void> setStreamingMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_streamingModeKey, enabled);
  }

  // ── Streaming-mode provider order ─────────────────────────────────────────
  // Order in which Direct Streaming Mode tries each provider. The first
  // provider that yields a working stream wins; the rest become fallbacks
  // inside the player (in the same order). User-editable in Settings.
  static const String _streamProviderOrderKey = 'stream_provider_order';
  static const List<String> defaultStreamProviderOrder = <String>[
    'videasy',
    'vidlink',
    'vidsrc',
    'vixsrc',
    'vidnest',
    'service111477',
    'webstreamr',
  ];

  Future<List<String>> getStreamProviderOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_streamProviderOrderKey);
    if (saved == null || saved.isEmpty) {
      return List<String>.from(defaultStreamProviderOrder);
    }
    // Preserve every saved key (including Nuvio scrapers like
    // `nuvio:moviesmod` that aren't in the built-in default list), then
    // append any newly-shipped built-in providers we didn't know about
    // when the order was first saved.
    final out = <String>[...saved];
    for (final k in defaultStreamProviderOrder) {
      if (!out.contains(k)) out.add(k);
    }
    return out;
  }

  /// Merges a saved provider order with the currently-available provider
  /// keys: keeps user ordering for keys that still exist, then appends any
  /// new keys at the end. Drops keys whose provider has gone away.
  static List<String> mergeProviderOrder(
      List<String> saved, Iterable<String> available) {
    final availSet = available.toSet();
    final out = <String>[];
    for (final k in saved) {
      if (availSet.contains(k) && !out.contains(k)) out.add(k);
    }
    for (final k in available) {
      if (!out.contains(k)) out.add(k);
    }
    return out;
  }

  Future<void> setStreamProviderOrder(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_streamProviderOrderKey, order);
  }

  Future<String> getSortPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_sortPreferenceKey) ?? 'Seeders (High to Low)';
  }

  Future<void> setSortPreference(String preference) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortPreferenceKey, preference);
  }

  Future<bool> useDebridForStreams() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_useDebridKey) ?? false;
  }

  Future<void> setUseDebridForStreams(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useDebridKey, enabled);
  }

  Future<String> getDebridService() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_debridServiceKey) ?? 'None';
  }

  Future<void> setDebridService(String service) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_debridServiceKey, service);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // External Player
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> getExternalPlayer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_externalPlayerKey) ?? 'Built-in Player';
  }

  Future<void> setExternalPlayer(String player) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_externalPlayerKey, player);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Jackett Settings
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String?> getJackettBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_jackettBaseUrlKey);
  }

  Future<void> setJackettBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = url.trimRight().replaceAll(RegExp(r'/+$'), '');
    await prefs.setString(_jackettBaseUrlKey, normalized);
  }

  Future<String?> getJackettApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_jackettApiKeyKey);
  }

  Future<void> setJackettApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_jackettApiKeyKey, apiKey);
  }

  Future<bool> isJackettConfigured() async {
    final baseUrl = await getJackettBaseUrl();
    final apiKey = await getJackettApiKey();
    return baseUrl != null && baseUrl.isNotEmpty && 
           apiKey != null && apiKey.isNotEmpty;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Prowlarr Settings
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String?> getProwlarrBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prowlarrBaseUrlKey);
  }

  Future<void> setProwlarrBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = url.trimRight().replaceAll(RegExp(r'/+$'), '');
    await prefs.setString(_prowlarrBaseUrlKey, normalized);
  }

  Future<String?> getProwlarrApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prowlarrApiKeyKey);
  }

  Future<void> setProwlarrApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prowlarrApiKeyKey, apiKey);
  }

  Future<bool> isProwlarrConfigured() async {
    final baseUrl = await getProwlarrBaseUrl();
    final apiKey = await getProwlarrApiKey();
    return baseUrl != null && baseUrl.isNotEmpty && 
           apiKey != null && apiKey.isNotEmpty;
  }

  Future<List<int>> getProwlarrTagIds() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prowlarrTagIdsKey) ?? [];
    return stored
        .map((s) => int.tryParse(s) ?? -1)
        .where((id) => id >= 0)
        .toList();
  }

  Future<void> setProwlarrTagIds(List<int> tagIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prowlarrTagIdsKey, tagIds.map((id) => id.toString()).toList());
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Torrent Cache Settings
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns 'ram' or 'disk'. Defaults to 'ram'.
  Future<String> getTorrentCacheType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_torrentCacheTypeKey) ?? 'ram';
  }

  Future<void> setTorrentCacheType(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_torrentCacheTypeKey, type);
  }

  /// RAM cache size in MB. Defaults to 200.
  Future<int> getTorrentRamCacheMb() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_torrentRamCacheMbKey) ?? 200;
  }

  Future<void> setTorrentRamCacheMb(int mb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_torrentRamCacheMbKey, mb);
  }

  /// Per-torrent peer connection limit. Lower (5–25) often streams better
  /// on high-seed swarms because a few slow peers can't head-of-line-block
  /// the streaming reader. Default: 25 (matches libtorrent_flutter example).
  Future<int> getTorrentConnectionsLimit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_torrentConnectionsLimitKey) ?? 25;
  }

  Future<void> setTorrentConnectionsLimit(int limit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_torrentConnectionsLimitKey, limit);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Light Mode (Performance)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<bool> isLightModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_lightModeKey) ?? false;
  }

  Future<void> setLightMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lightModeKey, enabled);
    lightModeNotifier.value = enabled;
  }

  /// Call once at app startup to hydrate the notifier from disk.
  Future<void> initLightMode() async {
    lightModeNotifier.value = await isLightModeEnabled();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Theme Preset
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> getThemePreset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_themePresetKey) ?? 'cinematic';
  }

  Future<void> setThemePreset(String preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePresetKey, preset);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Navbar Configuration
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _navbarConfigKey = 'navbar_config';
  /// Tracks every nav ID the user has already been shown in the configurator,
  /// so we can distinguish "user explicitly hid it" from "new ID we just
  /// shipped". Without this, hidden items reappear on every load because the
  /// merge logic treats any missing ID as new.
  static const String _navbarKnownIdsKey = 'navbar_known_ids';

  /// Notifier that fires when navbar config changes so MainScreen rebuilds.
  static final ValueNotifier<int> navbarChangeNotifier = ValueNotifier<int>(0);

  /// All available nav items in default order. 'settings' is always last and locked.
  static const List<String> allNavIds = [
    'home', 'discover', 'similar', 'search', 'mylist', 'downloader', 'magnet', 'live_matches',
    'iptv', 'audiobooks', 'books', 'music', 'comics', 'manga',
    'jellyfin', 'anime', 'anime_arabic', 'asian_drama', 'arabic',
  ];

  /// Returns the ordered list of visible nav item IDs.
  /// Settings is NOT stored — it's always appended by the consumer.
  Future<List<String>> getNavbarConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_navbarConfigKey);
    if (raw == null) {
      // First launch — everything visible, mark all current IDs as known.
      await prefs.setStringList(_navbarKnownIdsKey, List.from(allNavIds));
      return List.from(allNavIds);
    }
    // Drop any stale IDs (removed from `allNavIds` since last save).
    final filtered = raw.where((id) => allNavIds.contains(id)).toList();

    // Only auto-insert IDs the user has never been shown. Anything in the
    // known-IDs set that's missing from `filtered` was deliberately hidden
    // and must stay hidden.
    final known = (prefs.getStringList(_navbarKnownIdsKey) ?? const <String>[])
        .toSet();
    final newlyAdded = <String>[];
    for (var i = 0; i < allNavIds.length; i++) {
      final id = allNavIds[i];
      if (filtered.contains(id)) continue;
      if (known.contains(id)) continue; // user hid it on purpose
      newlyAdded.add(id);
      // Insert near its default neighbour for stable ordering.
      var insertAt = filtered.length;
      for (var j = i - 1; j >= 0; j--) {
        final idx = filtered.indexOf(allNavIds[j]);
        if (idx >= 0) {
          insertAt = idx + 1;
          break;
        }
      }
      filtered.insert(insertAt, id);
    }

    // Persist updated known-IDs set so we don't keep re-adding these.
    if (newlyAdded.isNotEmpty || known.length != allNavIds.length) {
      await prefs.setStringList(_navbarKnownIdsKey, List.from(allNavIds));
    }
    return filtered;
  }

  /// Save the ordered list of visible nav item IDs (excluding 'settings').
  Future<void> setNavbarConfig(List<String> visibleIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_navbarConfigKey, visibleIds);
    // Mark every current ID as "known" so anything the user hid in this save
    // stays hidden on the next load.
    await prefs.setStringList(_navbarKnownIdsKey, List.from(allNavIds));
    navbarChangeNotifier.value++;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Export / Import All Settings
  // ═══════════════════════════════════════════════════════════════════════════

  static const List<String> _secureKeys = [
    'rd_access_token',
    'rd_refresh_token',
    'rd_token_expiry',
    'rd_client_id',
    'rd_client_secret',
    'torbox_api_key',
    'trakt_access_token',
    'trakt_refresh_token',
    'trakt_expires_at',
  ];

  /// Collects every setting (SharedPreferences + FlutterSecureStorage) into a
  /// single JSON-encodable map.
  Future<Map<String, dynamic>> exportAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final secure = const FlutterSecureStorage();

    final Map<String, dynamic> data = {};

    // --- SharedPreferences ---
    final prefsMap = <String, dynamic>{};
    // Bool keys
    for (final key in [_streamingModeKey, _useDebridKey, _lightModeKey]) {
      final v = prefs.getBool(key);
      if (v != null) prefsMap[key] = v;
    }
    // String keys
    for (final key in [
      _sortPreferenceKey,
      _debridServiceKey,
      _externalPlayerKey,
      _jackettBaseUrlKey,
      _jackettApiKeyKey,
      _prowlarrBaseUrlKey,
      _prowlarrApiKeyKey,
      _torrentCacheTypeKey,
      _themePresetKey,
    ]) {
      final v = prefs.getString(key);
      if (v != null) prefsMap[key] = v;
    }
    // Int keys
    for (final key in [_torrentRamCacheMbKey]) {
      final v = prefs.getInt(key);
      if (v != null) prefsMap[key] = v;
    }
    // StringList keys
    for (final key in [_stremioAddonsKey, _navbarConfigKey, _prowlarrTagIdsKey]) {
      final v = prefs.getStringList(key);
      if (v != null) prefsMap[key] = v;
    }
    data['shared_preferences'] = prefsMap;

    // --- FlutterSecureStorage ---
    final secureMap = <String, String>{};
    for (final key in _secureKeys) {
      final v = await secure.read(key: key);
      if (v != null) secureMap[key] = v;
    }
    data['secure_storage'] = secureMap;

    data['export_version'] = 1;
    data['exported_at'] = DateTime.now().toIso8601String();

    return data;
  }

  /// Restores every setting from a previously-exported JSON map.
  Future<void> importAllSettings(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final secure = const FlutterSecureStorage();

    // --- SharedPreferences ---
    final prefsMap = data['shared_preferences'] as Map<String, dynamic>? ?? {};

    // Bool keys
    for (final key in [_streamingModeKey, _useDebridKey, _lightModeKey]) {
      if (prefsMap.containsKey(key)) {
        await prefs.setBool(key, prefsMap[key] as bool);
      }
    }
    // String keys
    for (final key in [
      _sortPreferenceKey,
      _debridServiceKey,
      _externalPlayerKey,
      _jackettBaseUrlKey,
      _jackettApiKeyKey,
      _prowlarrBaseUrlKey,
      _prowlarrApiKeyKey,
      _torrentCacheTypeKey,
      _themePresetKey,
    ]) {
      if (prefsMap.containsKey(key)) {
        await prefs.setString(key, prefsMap[key] as String);
      }
    }
    // Int keys
    for (final key in [_torrentRamCacheMbKey]) {
      if (prefsMap.containsKey(key)) {
        await prefs.setInt(key, prefsMap[key] as int);
      }
    }
    // StringList keys
    for (final key in [_stremioAddonsKey, _navbarConfigKey, _prowlarrTagIdsKey]) {
      if (prefsMap.containsKey(key)) {
        await prefs.setStringList(
            key, (prefsMap[key] as List).cast<String>());
      }
    }

    // --- FlutterSecureStorage ---
    final secureMap = data['secure_storage'] as Map<String, dynamic>? ?? {};
    for (final key in _secureKeys) {
      if (secureMap.containsKey(key)) {
        await secure.write(key: key, value: secureMap[key] as String);
      }
    }

    // Notify listeners so UI refreshes
    addonChangeNotifier.value++;
    navbarChangeNotifier.value++;
  }
}
