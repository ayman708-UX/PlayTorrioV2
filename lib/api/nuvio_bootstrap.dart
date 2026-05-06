import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nuvio_service.dart';

/// Auto-installs / auto-refreshes the curated bundled Nuvio addon so its
/// scrapers are available out-of-the-box in Direct Streaming Mode.
///
/// Call [ensureInstalled] from `main()` (unawaited). Behaviour:
///   * If the manifest isn't installed yet, install it (lightweight refresh —
///     scripts are pulled lazily on first use, not pre-downloaded).
///   * If it IS installed but the last refresh was >24h ago, re-fetch the
///     manifest so any upstream fixes/new providers flow through.
///   * Failures are non-fatal and logged.
class NuvioBootstrap {
  NuvioBootstrap._();

  static const String defaultManifestUrl =
      'https://raw.githubusercontent.com/D3adlyRocket/All-in-One-Nuvio/'
      'refs/heads/main/manifest.json';

  static const String _lastRefreshKey = 'nuvio_bootstrap_last_refresh_v1';
  static const Duration _refreshInterval = Duration(hours: 24);

  static Future<void> ensureInstalled({String? manifestUrl}) async {
    final url = manifestUrl ?? defaultManifestUrl;
    try {
      final prefs = await SharedPreferences.getInstance();
      final svc = NuvioService.instance;
      final addons = await svc.listAddons();
      final installed = addons.any((a) => a.manifestUrl == url);
      final lastTs = prefs.getInt(_lastRefreshKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final stale = (now - lastTs) > _refreshInterval.inMilliseconds;
      if (installed && !stale) {
        debugPrint('[NuvioBootstrap] up-to-date — skipping');
        return;
      }
      debugPrint('[NuvioBootstrap] refreshing manifest…');
      await svc.refreshFromUrl(url);
      await prefs.setInt(_lastRefreshKey, now);
      debugPrint('[NuvioBootstrap] refreshed OK');
    } catch (e) {
      debugPrint('[NuvioBootstrap] refresh failed (non-fatal): $e');
    }
  }
}
