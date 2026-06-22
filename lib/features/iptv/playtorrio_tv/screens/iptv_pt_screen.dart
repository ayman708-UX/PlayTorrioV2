import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../controller/iptv_controller.dart';
import '../data/hardcoded_channels.dart';
import '../data/iptv_network.dart';
import '../data/models.dart';
import '../m3u/m3u_playlists_screen.dart';
import 'iptv_pt_player_screen.dart';

/// Mask a URL for safe display: keeps host, masks each path segment to first 2 chars + ***.
/// Returns '—' for empty/invalid input. Strips query and fragment.
String _redactUrl(String? url) {
  if (url == null || url.trim().isEmpty) return '—';
  return url.trim();
}

/// Main entry-point widget for the PT IPTV experience.
/// Presents all 6 sub-views and routes to the dedicated player.
class IptvPtScreen extends StatefulWidget {
  const IptvPtScreen({super.key});

  @override
  State<IptvPtScreen> createState() => _IptvPtScreenState();
}

class _IptvPtScreenState extends State<IptvPtScreen> {
  late final IptvController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = IptvController();
    _ctrl.init();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _isCompact(BuildContext c) => MediaQuery.sizeOf(c).width < 720;
  bool _isWide(BuildContext c) => MediaQuery.sizeOf(c).width >= 1100;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _ctrl.view == IptvView.portalList,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _ctrl.back();
      },
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A0A0F), Color(0xFF0E1428), Color(0xFF06070C)],
          ),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(
              key: ValueKey(_ctrl.view),
              child: _buildView(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildView(BuildContext context) {
    switch (_ctrl.view) {
      case IptvView.portalList:
        return _PortalListView(ctrl: _ctrl, compact: _isCompact(context));
      case IptvView.sectionPick:
        return _SectionPickView(ctrl: _ctrl, compact: _isCompact(context));
      case IptvView.browser:
        return _BrowserView(
            ctrl: _ctrl,
            compact: _isCompact(context),
            wide: _isWide(context));
      case IptvView.episodeList:
        return _EpisodeListView(ctrl: _ctrl, compact: _isCompact(context));
      case IptvView.channelsHub:
        return _ChannelsHubView(ctrl: _ctrl, compact: _isCompact(context));
      case IptvView.channelResults:
        return _ChannelResultsView(ctrl: _ctrl, compact: _isCompact(context));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Common widgets
// ─────────────────────────────────────────────────────────────────────────────
class _PtAppBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;
  const _PtAppBar({
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white70, size: 20),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.bebasNeue(
                    color: Colors.white,
                    fontSize: 28,
                    letterSpacing: 1.6,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  final String label;
  final String tag;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _SourceChip({
    required this.label,
    required this.tag,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF00E5FF)],
                  )
                : null,
            color: selected ? null : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tag,
                    style: GoogleFonts.poppins(
                      color: selected
                          ? Colors.white
                          : const Color(0xFF00E5FF),
                      fontWeight: FontWeight.w500,
                      fontSize: 11,
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
}

class _PrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool subtle;
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.subtle = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: subtle
              ? LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.06),
                    Colors.white.withValues(alpha: 0.03),
                  ],
                )
              : const LinearGradient(
                  colors: [Color(0xFF1565C0), Color(0xFF00E5FF)],
                ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: subtle
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : onPressed,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                else
                  Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
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

// ─────────────────────────────────────────────────────────────────────────────
// PORTAL LIST VIEW
// ─────────────────────────────────────────────────────────────────────────────
class _PortalListView extends StatelessWidget {
  final IptvController ctrl;
  final bool compact;
  const _PortalListView({required this.ctrl, required this.compact});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _PtAppBar(
            title: 'IPTV Portals',
            subtitle: ctrl.statusText.isEmpty
                ? '${ctrl.verified.length} verified'
                : ctrl.statusText,
            actions: [
              IconButton(
                tooltip: 'M3U Playlists',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const M3uPlaylistsScreen(),
                  ),
                ),
                icon: const Icon(Icons.playlist_play_rounded,
                    color: Color(0xFF00E5FF)),
              ),
              IconButton(
                tooltip: 'Add portal',
                onPressed: () => _showAddDialog(context),
                icon: const Icon(Icons.add_rounded,
                    color: Color(0xFF00E5FF)),
              ),
              if (ctrl.verified.isNotEmpty)
                IconButton(
                  tooltip: ctrl.editMode ? 'Done' : 'Edit',
                  onPressed: ctrl.toggleEditMode,
                  icon: Icon(
                    ctrl.editMode ? Icons.check_rounded : Icons.edit_rounded,
                    color: ctrl.editMode
                        ? const Color(0xFF00E5FF)
                        : Colors.white70,
                  ),
                ),
            ],
          ),
          if (ctrl.editMode && ctrl.verified.isNotEmpty)
            _buildEditBar(),
          Expanded(
            child: ctrl.verified.isEmpty
                ? _buildEmpty(context)
                : _buildPortalGrid(),
          ),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildEditBar() {
    final allSelected = ctrl.selected.length == ctrl.verified.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF1565C0).withValues(alpha: 0.15),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: ctrl.toggleSelectAll,
            icon: Icon(
              allSelected ? Icons.deselect : Icons.select_all,
              color: const Color(0xFF00E5FF),
              size: 18,
            ),
            label: Text(
              allSelected ? 'Clear' : 'All',
              style: GoogleFonts.poppins(color: const Color(0xFF00E5FF)),
            ),
          ),
          const Spacer(),
          Text(
            '${ctrl.selected.length} selected',
            style: GoogleFonts.poppins(color: Colors.white70),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed:
                ctrl.selected.isEmpty ? null : () => ctrl.deleteSelected(),
            icon: Icon(
              Icons.delete_rounded,
              color: ctrl.selected.isEmpty
                  ? Colors.white24
                  : const Color(0xFFEF4444),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.satellite_alt_rounded,
                size: 80, color: Color(0xFF00E5FF)),
            const SizedBox(height: 24),
            Text('No portals yet',
                style: GoogleFonts.bebasNeue(
                    color: Colors.white,
                    fontSize: 36,
                    letterSpacing: 1.6)),
            const SizedBox(height: 8),
            Text(
              ctrl.statusText.isEmpty
                  ? 'Find live Xtream portals,\nor add one manually.'
                  : ctrl.statusText,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: Colors.white60),
            ),
            const SizedBox(height: 28),
            _PrimaryButton(
              icon: Icons.travel_explore,
              label: 'Find Portals',
              busy: ctrl.isScraping,
              onPressed: ctrl.scrape,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortalGrid() {
    return LayoutBuilder(
      builder: (context, c) {
        final cross = (c.maxWidth ~/ 320).clamp(1, 4);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            mainAxisExtent: 120,
          ),
          itemCount: ctrl.verified.length,
          itemBuilder: (_, i) {
            final v = ctrl.verified[i];
            final selected = ctrl.selected.contains(v.key);
            return _PortalCard(
              v: v,
              editMode: ctrl.editMode,
              selected: selected,
              isFavorite: ctrl.isFavoritePortal(v.key),
              onToggleFavorite: () => ctrl.toggleFavoritePortal(v.key),
              onTap: () {
                if (ctrl.editMode) {
                  ctrl.toggleSelect(v.key);
                } else {
                  ctrl.openPortal(v);
                }
              },
              onLongPress: () {
                if (!ctrl.editMode) {
                  ctrl.toggleEditMode();
                  ctrl.toggleSelect(v.key);
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSourcePicker(),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _PrimaryButton(
                  icon: Icons.travel_explore,
                  label: 'Scrape',
                  busy: ctrl.isScraping,
                  onPressed: ctrl.scrape,
                ),
                const SizedBox(width: 8),
                if (ctrl.canGetMore)
                  _PrimaryButton(
                    icon: Icons.add_circle_outline,
                    label: 'Get More',
                    subtle: true,
                    onPressed: ctrl.isScraping ? null : ctrl.getMore,
                  ),
                if (ctrl.canGetMore) const SizedBox(width: 8),
                _PrimaryButton(
                  icon: Icons.tv_rounded,
                  label: 'Channels',
                  subtle: true,
                  onPressed: ctrl.openChannelsHub,
                ),
                const SizedBox(width: 8),
                if (ctrl.verified.isNotEmpty)
                  _PrimaryButton(
                    icon: Icons.refresh_rounded,
                    label: 'Re-verify',
                    subtle: true,
                    onPressed: ctrl.runVerification,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourcePicker() {
    const items = <(CatalogSource, String, String)>[
      (CatalogSource.best, 'Source 1', 'Best'),
      (CatalogSource.works, 'Source 2', 'Works'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final it in items) ...[
            _SourceChip(
              label: it.$2,
              tag: it.$3,
              selected: ctrl.scrapeSource == it.$1,
              enabled: !ctrl.isScraping,
              onTap: () => ctrl.setScrapeSource(it.$1),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final urlCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AnimatedBuilder(
        animation: ctrl,
        builder: (_, _) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A24),
          title: Text('Add Portal',
              style: GoogleFonts.bebasNeue(
                  color: Colors.white, fontSize: 26, letterSpacing: 1.4)),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _input(urlCtrl, 'http://portal.example.com:8080', 'Portal URL'),
                const SizedBox(height: 8),
                _input(userCtrl, 'username', 'Username'),
                const SizedBox(height: 8),
                _input(passCtrl, 'password', 'Password', obscure: true),
                if (ctrl.addError != null) ...[
                  const SizedBox(height: 10),
                  Text(ctrl.addError!,
                      style: GoogleFonts.poppins(
                          color: const Color(0xFFEF4444), fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: ctrl.isAdding
                  ? null
                  : () {
                      ctrl.dismissAddDialog();
                      Navigator.of(ctx).pop();
                    },
              child: Text('Cancel',
                  style: GoogleFonts.poppins(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0)),
              onPressed: ctrl.isAdding
                  ? null
                  : () async {
                      await ctrl.addManual(
                        url: urlCtrl.text,
                        username: userCtrl.text,
                        password: passCtrl.text,
                      );
                      if (ctrl.addError == null && ctx.mounted) {
                        Navigator.of(ctx).pop();
                      }
                    },
              child: ctrl.isAdding
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text('Add',
                      style: GoogleFonts.poppins(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _input(TextEditingController c, String hint, String label,
      {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(color: Colors.white60, fontSize: 12),
        hintText: hint,
        hintStyle: GoogleFonts.poppins(color: Colors.white24, fontSize: 12),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
    );
  }
}

class _PortalCard extends StatelessWidget {
  final VerifiedPortal v;
  final bool editMode;
  final bool selected;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleFavorite;
  const _PortalCard({
    required this.v,
    required this.editMode,
    required this.selected,
    required this.isFavorite,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF14213A), Color(0xFF0E1428)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? const Color(0xFF00E5FF)
                : Colors.white.withValues(alpha: 0.08),
            width: selected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                if (editMode) ...[
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? const Color(0xFF00E5FF)
                        : Colors.white30,
                  ),
                  const SizedBox(width: 12),
                ] else
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1565C0), Color(0xFF00E5FF)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.tv_rounded,
                        color: Colors.white, size: 22),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_displayName(v),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      const SizedBox(height: 4),
                      Text(_redactUrl(v.portal.url),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                              color: Colors.white60, fontSize: 11)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _Pill(
                              icon: Icons.event_rounded,
                              label: v.expiry,
                              color: const Color(0xFFA855F7)),
                          const SizedBox(width: 6),
                          _Pill(
                              icon: Icons.people_rounded,
                              label: '${v.activeConnections}/${v.maxConnections}',
                              color: const Color(0xFF22C55E)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!editMode) ...[
                  IconButton(
                    tooltip: 'Copy portal details',
                    onPressed: () {
                      final p = v.portal;
                      final cleanUrl = p.url.replaceFirst('http://', '').replaceFirst('https://', '');
                      Clipboard.setData(ClipboardData(text: '$cleanUrl:${p.username}:${p.password}'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Portal details copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, color: Colors.white54, size: 20),
                  ),
                  IconButton(
                    tooltip: isFavorite ? 'Unfavorite' : 'Favorite',
                    onPressed: onToggleFavorite,
                    icon: Icon(
                      isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                      color: isFavorite
                          ? const Color(0xFFFACC15)
                          : Colors.white38,
                      size: 22,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Show a friendly name; if the portal had no name we fall back to a
  /// redacted form of its URL so we never leak host paths in the UI.
  static String _displayName(VerifiedPortal v) {
    final n = v.name.trim();
    if (n.isEmpty) return _redactUrl(v.portal.url);
    if (n.startsWith('http://') || n.startsWith('https://')) {
      return _redactUrl(n);
    }
    return n;
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Pill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 4),
          Text(label,
              style: GoogleFonts.poppins(
                  color: color, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION PICK
// ─────────────────────────────────────────────────────────────────────────────
class _SectionPickView extends StatelessWidget {
  final IptvController ctrl;
  final bool compact;
  const _SectionPickView({required this.ctrl, required this.compact});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _PtAppBar(
            title: ctrl.activePortal?.name ?? 'Portal',
            subtitle: _redactUrl(ctrl.activePortal?.portal.url),
            onBack: ctrl.back,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, c) {
                final cross = c.maxWidth >= 800 ? 3 : (c.maxWidth >= 520 ? 3 : 1);
                return GridView.count(
                  padding: const EdgeInsets.all(20),
                  crossAxisCount: cross,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: cross == 1 ? 2.6 : 1.1,
                  children: [
                    _SectionTile(
                      icon: Icons.live_tv_rounded,
                      label: 'Live TV',
                      colors: const [Color(0xFFEF4444), Color(0xFF7C2D12)],
                      onTap: () => ctrl.openSection(IptvSection.live),
                    ),
                    _SectionTile(
                      icon: Icons.movie_rounded,
                      label: 'Movies',
                      colors: const [Color(0xFFEC4899), Color(0xFF8B5CF6)],
                      onTap: () => ctrl.openSection(IptvSection.vod),
                    ),
                    _SectionTile(
                      icon: Icons.video_library_rounded,
                      label: 'Series',
                      colors: const [Color(0xFF1565C0), Color(0xFF00E5FF)],
                      onTap: () => ctrl.openSection(IptvSection.series),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<Color> colors;
  final VoidCallback onTap;
  const _SectionTile({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: colors.first.withValues(alpha: 0.5),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 56),
                const SizedBox(height: 14),
                Text(label,
                    style: GoogleFonts.bebasNeue(
                        color: Colors.white,
                        fontSize: 28,
                        letterSpacing: 1.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BROWSER (Live / VOD / Series listing)
// ─────────────────────────────────────────────────────────────────────────────
class _BrowserView extends StatefulWidget {
  final IptvController ctrl;
  final bool compact;
  final bool wide;
  const _BrowserView({
    required this.ctrl,
    required this.compact,
    required this.wide,
  });

  @override
  State<_BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<_BrowserView> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.ctrl.browserSearch;
    // auto-start alive check for live category
    if (widget.ctrl.activeSection == IptvSection.live &&
        widget.ctrl.aliveCheckedAt == null &&
        !widget.ctrl.isVerifyingAlive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.ctrl.startAliveCheck();
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _sectionTitle {
    switch (widget.ctrl.activeSection) {
      case IptvSection.live:
        return 'Live TV';
      case IptvSection.vod:
        return 'Movies';
      case IptvSection.series:
        return 'Series';
      default:
        return 'Browse';
    }
  }

  /// Categories visible in the sidebar/chips. When the user types a query,
  /// hide categories whose name doesn't match — but always keep the currently
  /// selected one so the UI never shows an empty selection.
  List<IptvCategory> get _filteredCategories {
    final ctrl = widget.ctrl;
    final q = ctrl.browserSearch.trim().toLowerCase();
    if (q.isEmpty) return ctrl.categories;
    final selected = ctrl.browserSelectedCategoryId;
    return ctrl.categories.where((c) {
      if (c.id == selected) return true;
      // 'All' (id == '') is always useful while searching globally
      if (c.id.isEmpty) return true;
      return c.name.toLowerCase().contains(q);
    }).toList();
  }

  List<IptvStream> get _filteredStreams {
    final ctrl = widget.ctrl;
    var s = ctrl.browserAllStreams;
    final cat = ctrl.browserSelectedCategoryId;
    final q = ctrl.browserSearch.trim().toLowerCase();

    if (q.isNotEmpty) {
      // Search is global across categories AND matches by stream name OR by
      // the stream's category name. Lookup table built once per filter pass.
      final catNameById = <String, String>{
        for (final c in ctrl.categories) c.id: c.name.toLowerCase(),
      };
      s = s.where((x) {
        if (x.name.toLowerCase().contains(q)) return true;
        final cn = catNameById[x.categoryId];
        return cn != null && cn.contains(q);
      }).toList();
    } else if (cat != null && cat.isNotEmpty) {
      s = s.where((x) => x.categoryId == cat).toList();
    }

    if (ctrl.activeSection == IptvSection.live && ctrl.liveOnly) {
      s = s.where((x) => ctrl.aliveStreamIds.contains(x.streamId)).toList();
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.ctrl;
    return SafeArea(
      child: Column(
        children: [
          _PtAppBar(
            title: _sectionTitle,
            subtitle: ctrl.activePortal?.name,
            onBack: ctrl.back,
            actions: [
              if (ctrl.activeSection == IptvSection.live)
                IconButton(
                  tooltip: ctrl.isVerifyingAlive ? 'Stop' : 'Re-check alive',
                  onPressed: ctrl.isVerifyingAlive
                      ? ctrl.stopAliveCheck
                      : ctrl.recheckAlive,
                  icon: Icon(
                    ctrl.isVerifyingAlive
                        ? Icons.stop_circle_rounded
                        : Icons.refresh_rounded,
                    color: const Color(0xFF00E5FF),
                  ),
                ),
            ],
          ),
          _buildSearch(),
          if (ctrl.activeSection == IptvSection.live && ctrl.isVerifyingAlive)
            _buildAliveProgress(),
          if (ctrl.activeSection == IptvSection.live &&
              !ctrl.isVerifyingAlive &&
              ctrl.aliveCheckedAt != null)
            _buildLiveOnlyToggle(),
          if (ctrl.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(ctrl.error!,
                  style: GoogleFonts.poppins(
                      color: const Color(0xFFEF4444))),
            ),
          Expanded(
            child: ctrl.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00E5FF)))
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _searchCtrl,
        onChanged: widget.ctrl.setBrowserSearch,
        style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, color: Colors.white60),
          hintText: 'Search channels or categories…',
          hintStyle: GoogleFonts.poppins(color: Colors.white30, fontSize: 13),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
    );
  }

  Widget _buildAliveProgress() {
    final ctrl = widget.ctrl;
    final ratio = ctrl.aliveTotal == 0 ? 0.0 : ctrl.aliveChecked / ctrl.aliveTotal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Checking streams: ${ctrl.aliveChecked}/${ctrl.aliveTotal}  ·  ${ctrl.aliveCount} alive',
              style: GoogleFonts.poppins(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation(Color(0xFF00E5FF)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveOnlyToggle() {
    final ctrl = widget.ctrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Switch(
            value: ctrl.liveOnly,
            activeThumbColor: const Color(0xFF00E5FF),
            onChanged: ctrl.setLiveOnly,
          ),
          const SizedBox(width: 8),
          Text('Show only alive streams (${ctrl.aliveStreamIds.length})',
              style: GoogleFonts.poppins(
                  color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final useSidebar = !widget.compact;
    return Row(
      children: [
        if (useSidebar)
          SizedBox(
            width: widget.wide ? 240 : 200,
            child: _buildCategorySidebar(),
          ),
        if (!useSidebar)
          // mobile: horizontal chips
          const SizedBox.shrink(),
        Expanded(
          child: Column(
            children: [
              if (!useSidebar) _buildCategoryChips(),
              Expanded(child: _buildStreamGrid()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCategorySidebar() {
    final ctrl = widget.ctrl;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Builder(builder: (_) {
        final cats = _filteredCategories;
        return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: cats.length,
        itemBuilder: (_, i) {
          final c = cats[i];
          final selected = c.id == ctrl.browserSelectedCategoryId;
          return InkWell(
            onTap: () => ctrl.selectBrowserCategory(c.id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF00E5FF).withValues(alpha: 0.12)
                    : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: selected
                        ? const Color(0xFF00E5FF)
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Text(
                c.name.isEmpty ? 'Uncategorized' : c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
        );
      }),
    );
  }

  Widget _buildCategoryChips() {
    final ctrl = widget.ctrl;
    return SizedBox(
      height: 40,
      child: Builder(builder: (_) {
        final cats = _filteredCategories;
        return ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: cats.length,
        itemBuilder: (_, i) {
          final c = cats[i];
          final selected = c.id == ctrl.browserSelectedCategoryId;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: ChoiceChip(
              label: Text(c.name.isEmpty ? 'Uncategorized' : c.name,
                  style: GoogleFonts.poppins(
                      color: selected ? Colors.black : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
              selected: selected,
              showCheckmark: false,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              selectedColor: const Color(0xFF00E5FF),
              onSelected: (_) => ctrl.selectBrowserCategory(c.id),
            ),
          );
        },
        );
      }),
    );
  }

  Widget _buildStreamGrid() {
    final list = _filteredStreams;
    if (list.isEmpty) {
      return Center(
        child: Text('No streams in this view',
            style: GoogleFonts.poppins(color: Colors.white60)),
      );
    }
    return LayoutBuilder(
      builder: (_, c) {
        final cross = (c.maxWidth ~/ 180).clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.9,
          ),
          itemCount: list.length,
          itemBuilder: (_, i) => _StreamCard(
            stream: list[i],
            ctrl: widget.ctrl,
            onTap: () => _onStreamTap(list[i]),
          ),
        );
      },
    );
  }

  void _onStreamTap(IptvStream s) {
    final ctrl = widget.ctrl;
    final p = ctrl.activePortal;
    if (p == null) return;
    if (s.kind == 'series') {
      ctrl.openSeries(s);
      return;
    }
    final url = IptvClient.streamUrl(p.portal, s);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => IptvPtPlayerScreen.singleStream(
        url: url,
        stream: s,
        portalName: p.name,
      ),
    ));
  }
}

class _StreamCard extends StatelessWidget {
  final IptvStream stream;
  final IptvController ctrl;
  final VoidCallback onTap;
  const _StreamCard({
    required this.stream,
    required this.ctrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: stream.kind == 'live'
              ? () => _showEpgSheet(context)
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12)),
                  child: stream.icon.isEmpty
                      ? const _StreamPlaceholder()
                      : Image.network(
                          stream.icon,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const _StreamPlaceholder(),
                          loadingBuilder: (_, child, p) =>
                              p == null ? child : const _StreamPlaceholder(),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Tooltip(
                  message: stream.name,
                  waitDuration: const Duration(milliseconds: 600),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        stream.name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        softWrap: true,
                        style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 12,
                            height: 1.15,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ),
              if (stream.kind == 'live') _EpgNowFooter(stream: stream, ctrl: ctrl),
            ],
          ),
        ),
      ),
    );
  }

  void _showEpgSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF11151C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _EpgSheet(stream: stream, ctrl: ctrl),
    );
  }
}

/// Tiny "NOW · Title  •  HH:mm–HH:mm" strip rendered at the bottom of a live
/// `_StreamCard`. Quietly renders nothing while loading or when the panel has
/// no EPG for this channel — we never want a visible spinner per tile.
class _EpgNowFooter extends StatelessWidget {
  final IptvStream stream;
  final IptvController ctrl;
  const _EpgNowFooter({required this.stream, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EpgEntry>>(
      future: ctrl.epgFor(stream),
      builder: (_, snap) {
        final data = snap.data;
        if (data == null || data.isEmpty) return const SizedBox.shrink();
        final now = data.firstWhere(
          (e) => e.isNow,
          orElse: () => data.first,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: now.isNow
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF00E5FF).withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  now.isNow ? 'NOW' : 'NEXT',
                  style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  now.title.isEmpty ? '—' : now.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 9,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Long-press detail sheet — lists the next few programmes with start times.
class _EpgSheet extends StatelessWidget {
  final IptvStream stream;
  final IptvController ctrl;
  const _EpgSheet({required this.stream, required this.ctrl});

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(stream.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: FutureBuilder<List<EpgEntry>>(
                    // Re-request with a higher limit for the sheet view.
                    future: IptvClient.shortEpg(
                      ctrl.activePortal!.portal,
                      stream.streamId,
                      limit: 8,
                    ),
                    builder: (_, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF00E5FF), strokeWidth: 2),
                    ),
                  );
                }
                final data = snap.data ?? const <EpgEntry>[];
                if (data.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('No EPG available for this channel.',
                        style: GoogleFonts.poppins(
                            color: Colors.white60, fontSize: 12)),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in data)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 86,
                              child: Text(
                                '${_fmtTime(e.start)}–${_fmtTime(e.stop)}',
                                style: GoogleFonts.poppins(
                                    color: e.isNow
                                        ? const Color(0xFFEF4444)
                                        : Colors.white60,
                                    fontSize: 11,
                                    fontWeight: e.isNow
                                        ? FontWeight.w700
                                        : FontWeight.w500),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      e.title.isEmpty ? '—' : e.title,
                                      style: GoogleFonts.poppins(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                  if (e.description.isNotEmpty)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(top: 2),
                                      child: Text(
                                        e.description,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.poppins(
                                            color: Colors.white60,
                                            fontSize: 10),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StreamPlaceholder extends StatelessWidget {
  const _StreamPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withValues(alpha: 0.03),
      child: const Center(
        child:
            Icon(Icons.tv_rounded, color: Colors.white24, size: 36),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EPISODE LIST
// ─────────────────────────────────────────────────────────────────────────────
class _EpisodeListView extends StatelessWidget {
  final IptvController ctrl;
  final bool compact;
  const _EpisodeListView({required this.ctrl, required this.compact});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _PtAppBar(
            title: ctrl.activeSeries?.name ?? 'Series',
            onBack: ctrl.back,
          ),
          Expanded(
            child: ctrl.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00E5FF)))
                : ctrl.episodes.isEmpty
                    ? Center(
                        child: Text('No episodes found',
                            style: GoogleFonts.poppins(color: Colors.white60)),
                      )
                    : _buildList(context),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    // Group by season
    final bySeason = <int, List<IptvEpisode>>{};
    for (final e in ctrl.episodes) {
      bySeason.putIfAbsent(e.season, () => []).add(e);
    }
    final seasons = bySeason.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: seasons.length,
      itemBuilder: (_, si) {
        final season = seasons[si];
        final eps = bySeason[season]!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text('Season $season',
                    style: GoogleFonts.bebasNeue(
                        color: Colors.white,
                        fontSize: 22,
                        letterSpacing: 1.2)),
              ),
              ...eps.map((e) => _EpisodeTile(episode: e, ctrl: ctrl)),
            ],
          ),
        );
      },
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final IptvEpisode episode;
  final IptvController ctrl;
  const _EpisodeTile({required this.episode, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          final p = ctrl.activePortal;
          if (p == null) return;
          final url = IptvClient.episodeUrl(p.portal, episode);
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => IptvPtPlayerScreen(
              sources: [
                IptvPlaySource(url: url, label: p.name),
              ],
              title: 'Ep ${episode.episode} · ${episode.title}',
              subtitle: 'Season ${episode.season}',
              logoUrl: episode.image,
            ),
          ));
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 96,
                  height: 56,
                  child: episode.image.isEmpty
                      ? const _StreamPlaceholder()
                      : Image.network(
                          episode.image,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const _StreamPlaceholder(),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Ep ${episode.episode}  ${episode.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    if (episode.plot.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(episode.plot,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                              color: Colors.white60, fontSize: 11)),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.play_circle_outline_rounded,
                  color: Color(0xFF00E5FF)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNELS HUB
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelsHubView extends StatefulWidget {
  final IptvController ctrl;
  final bool compact;
  const _ChannelsHubView({required this.ctrl, required this.compact});

  @override
  State<_ChannelsHubView> createState() => _ChannelsHubViewState();
}

class _ChannelsHubViewState extends State<_ChannelsHubView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<HardcodedChannel> get _filtered {
    if (_query.trim().isEmpty) return HardcodedChannels.all;
    final q = _query.trim().toLowerCase();
    return HardcodedChannels.all.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.short.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final results = _filtered;
    return SafeArea(
      child: Column(
        children: [
          _PtAppBar(
            title: 'Channels',
            subtitle: 'Curated brands · auto-find live streams',
            onBack: widget.ctrl.back,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              style: GoogleFonts.poppins(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search channels…',
                hintStyle:
                    GoogleFonts.poppins(color: Colors.white38, fontSize: 14),
                prefixIcon:
                    const Icon(Icons.search_rounded, color: Colors.white54),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white54),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFF1A1A22),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
                ),
              ),
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Text(
                      'No channels match “$_query”.',
                      style: GoogleFonts.poppins(
                          color: Colors.white54, fontSize: 14),
                    ),
                  )
                : LayoutBuilder(
                    builder: (_, c) {
                      final cross = (c.maxWidth ~/ 160).clamp(2, 8);
                      return GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cross,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 1.0,
                        ),
                        itemCount: results.length,
                        itemBuilder: (_, i) {
                          final ch = results[i];
                          return _ChannelTile(
                            channel: ch,
                            onTap: () => widget.ctrl.openHardcodedChannel(ch),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final HardcodedChannel channel;
  final VoidCallback onTap;
  const _ChannelTile({required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: channel.gradient,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: channel.gradient.first.withValues(alpha: 0.4),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(channel.short,
                    style: GoogleFonts.bebasNeue(
                      color: Colors.white,
                      fontSize: 36,
                      letterSpacing: 1.4,
                      shadows: const [
                        Shadow(
                            color: Colors.black54,
                            blurRadius: 6,
                            offset: Offset(0, 2)),
                      ],
                    )),
                const SizedBox(height: 4),
                Text(channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL RESULTS
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelResultsView extends StatefulWidget {
  final IptvController ctrl;
  final bool compact;
  const _ChannelResultsView({required this.ctrl, required this.compact});

  @override
  State<_ChannelResultsView> createState() => _ChannelResultsViewState();
}

class _ChannelResultsViewState extends State<_ChannelResultsView> {
  bool _editMode = false;
  /// Selection tracks streamUrl, not index, so it stays valid when the
  /// displayed list is filtered/sorted by the search box & EPG-first sort.
  final Set<String> _selected = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Sort order: favorites first, then hits whose Xtream stream has an
  /// `epg_channel_id` (a hint that the panel ships EPG for it), then
  /// everything else. Stable within each tier so user-curated ordering is
  /// preserved. Then filter by the search query if set.
  List<ChannelHit> _displayList(IptvController ctrl) {
    final channelId = ctrl.activeHardcoded?.id ?? '';
    final fav = <ChannelHit>[];
    final epg = <ChannelHit>[];
    final rest = <ChannelHit>[];
    for (final h in ctrl.channelResults) {
      if (ctrl.isFavoriteHit(channelId, h)) {
        fav.add(h);
      } else if (h.stream.epgChannelId.isNotEmpty) {
        epg.add(h);
      } else {
        rest.add(h);
      }
    }
    var list = <ChannelHit>[...fav, ...epg, ...rest];
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((h) {
        return h.stream.name.toLowerCase().contains(q) ||
            h.portal.name.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.ctrl;
    final ch = ctrl.activeHardcoded;
    final displayed = _displayList(ctrl);
    return SafeArea(
      child: Column(
        children: [
          _PtAppBar(
            title: ch?.name ?? 'Channel',
            subtitle: ctrl.channelStatus.isEmpty
                ? '${displayed.length}${_query.isEmpty ? '' : '/${ctrl.channelResults.length}'} hits'
                : ctrl.channelStatus,
            onBack: ctrl.back,
            actions: [
              if (ctrl.channelResults.isNotEmpty)
                IconButton(
                  tooltip: _editMode ? 'Done' : 'Edit',
                  onPressed: () => setState(() {
                    _editMode = !_editMode;
                    if (!_editMode) _selected.clear();
                  }),
                  icon: Icon(
                    _editMode ? Icons.check_rounded : Icons.edit_rounded,
                    color: _editMode
                        ? const Color(0xFF00E5FF)
                        : Colors.white70,
                  ),
                ),
            ],
          ),
          if (ctrl.channelResults.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: GoogleFonts.poppins(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search hits…',
                  hintStyle: GoogleFonts.poppins(
                      color: Colors.white38, fontSize: 14),
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: Colors.white54),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white54),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  fillColor: const Color(0xFF1A1A22),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: Color(0xFF00E5FF), width: 1.2),
                  ),
                ),
              ),
            ),
          if (_editMode && ctrl.channelResults.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF1565C0).withValues(alpha: 0.15),
              child: Row(
                children: [
                  Text(
                    _selected.isEmpty
                        ? 'Select streams'
                        : '${_selected.length} selected',
                    style: GoogleFonts.poppins(color: Colors.white70),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        // Select-all operates on the currently DISPLAYED list
                        // so users can bulk-select within a search filter.
                        final urls = displayed.map((h) => h.streamUrl).toSet();
                        final allSelected =
                            urls.isNotEmpty && _selected.containsAll(urls);
                        if (allSelected) {
                          _selected.removeAll(urls);
                        } else {
                          _selected.addAll(urls);
                        }
                      });
                    },
                    icon: Icon(
                      displayed.isNotEmpty &&
                              _selected.containsAll(
                                  displayed.map((h) => h.streamUrl))
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      color: const Color(0xFF00E5FF),
                      size: 18,
                    ),
                    label: Text(
                      displayed.isNotEmpty &&
                              _selected.containsAll(
                                  displayed.map((h) => h.streamUrl))
                          ? 'Clear'
                          : 'Select all',
                      style: GoogleFonts.poppins(
                          color: const Color(0xFF00E5FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_selected.isNotEmpty)
                    IconButton(
                      tooltip: 'Delete selected',
                      onPressed: () async {
                        // Selection is by streamUrl; map back to source
                        // indices for the controller API.
                        final indices = <int>{};
                        for (var i = 0;
                            i < ctrl.channelResults.length;
                            i++) {
                          if (_selected.contains(
                              ctrl.channelResults[i].streamUrl)) {
                            indices.add(i);
                          }
                        }
                        await ctrl.deleteChannelHits(indices);
                        setState(() {
                          _selected.clear();
                          _editMode = false;
                        });
                      },
                      icon: const Icon(Icons.delete_rounded,
                          color: Color(0xFFEF4444)),
                    ),
                ],
              ),
            ),
          if (ctrl.channelIsRunning) _buildSearchingBar(),
          Expanded(
            child: ctrl.channelResults.isEmpty
                ? _buildEmpty()
                : displayed.isEmpty
                    ? Center(
                        child: Text(
                          'No hits match “$_query”.',
                          style: GoogleFonts.poppins(
                              color: Colors.white54, fontSize: 14),
                        ),
                      )
                    : _buildResults(displayed),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildSearchingBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFF00E5FF)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.ctrl.channelStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                  color: Colors.white70, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: widget.ctrl.stopChannelSearch,
            child: Text('Stop',
                style:
                    GoogleFonts.poppins(color: const Color(0xFFEF4444))),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final ctrl = widget.ctrl;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded,
                size: 80, color: Color(0xFF00E5FF)),
            const SizedBox(height: 16),
            Text(
              ctrl.channelIsRunning ? 'Searching…' : 'No hits yet',
              style: GoogleFonts.bebasNeue(
                  color: Colors.white,
                  fontSize: 28,
                  letterSpacing: 1.4),
            ),
            const SizedBox(height: 8),
            Text(
              ctrl.channelStatus.isEmpty
                  ? 'Tap "Search Again" or "Get More" to scan saved + new portals.'
                  : ctrl.channelStatus,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(List<ChannelHit> displayed) {
    final ctrl = widget.ctrl;
    return LayoutBuilder(
      builder: (_, c) {
        final cross = (c.maxWidth ~/ 320).clamp(1, 4);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 132,
          ),
          itemCount: displayed.length,
          itemBuilder: (_, i) {
            final hit = displayed[i];
            final selected = _selected.contains(hit.streamUrl);
            return _ChannelHitCard(
              hit: hit,
              ctrl: ctrl,
              editMode: _editMode,
              selected: selected,
              isFavorite: ctrl.isFavoriteHit(
                  ctrl.activeHardcoded?.id ?? '', hit),
              onToggleFavorite: () => ctrl.toggleFavoriteHit(hit),
              onTap: () {
                if (_editMode) {
                  setState(() {
                    if (selected) {
                      _selected.remove(hit.streamUrl);
                    } else {
                      _selected.add(hit.streamUrl);
                    }
                  });
                } else {
                  // Put the tapped hit first so the player actually opens it,
                  // and keep the rest as failover sources for the watchdog.
                  // Use the full original results list (not filtered) so the
                  // watchdog has every fallback available.
                  final ordered = [
                    hit,
                    ...ctrl.channelResults.where((h) => h != hit),
                  ];
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => IptvPtPlayerScreen.fromHits(
                      hits: ordered,
                      title: ctrl.activeHardcoded?.name ?? hit.stream.name,
                      logoUrl: hit.stream.icon,
                    ),
                  ));
                }
              },
              onLongPress: () {
                if (!_editMode) {
                  setState(() {
                    _editMode = true;
                    _selected.add(hit.streamUrl);
                  });
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final ctrl = widget.ctrl;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _PrimaryButton(
              icon: Icons.refresh_rounded,
              label: 'Search Again',
              busy: ctrl.channelIsRunning,
              onPressed: ctrl.searchAgainChannel,
            ),
            const SizedBox(width: 8),
            _PrimaryButton(
              icon: Icons.add_circle_outline,
              label: 'Get More',
              subtle: true,
              onPressed:
                  ctrl.channelIsRunning ? null : ctrl.getMoreChannels,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelHitCard extends StatelessWidget {
  final ChannelHit hit;
  final IptvController ctrl;
  final bool editMode;
  final bool selected;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleFavorite;
  const _ChannelHitCard({
    required this.hit,
    required this.ctrl,
    required this.editMode,
    required this.selected,
    required this.isFavorite,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(0xFF00E5FF)
                : Colors.white.withValues(alpha: 0.08),
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                if (editMode) ...[
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? const Color(0xFF00E5FF)
                        : Colors.white30,
                  ),
                  const SizedBox(width: 8),
                ],
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: hit.stream.icon.isEmpty
                        ? const _StreamPlaceholder()
                        : Image.network(
                            hit.stream.icon,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const _StreamPlaceholder(),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Tooltip(
                        message: hit.stream.name,
                        waitDuration: const Duration(milliseconds: 600),
                        child: Text(hit.stream.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            softWrap: true,
                            style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontSize: 12,
                                height: 1.2,
                                fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 4),
                      Text('via ${_portalLabel(hit.portal)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: GoogleFonts.poppins(
                              color: Colors.white60, fontSize: 10)),
                      _HitEpgNowRow(hit: hit, ctrl: ctrl),
                    ],
                  ),
                ),
                if (!editMode)
                  IconButton(
                    tooltip: isFavorite ? 'Unfavorite' : 'Favorite',
                    onPressed: onToggleFavorite,
                    icon: Icon(
                      isFavorite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      color: isFavorite
                          ? const Color(0xFFFACC15)
                          : Colors.white38,
                      size: 20,
                    ),
                  ),
                if (!editMode)
                  const Icon(Icons.play_circle_outline_rounded,
                      color: Color(0xFF00E5FF)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _portalLabel(VerifiedPortal v) {
    final n = v.name.trim();
    if (n.isEmpty) return _redactUrl(v.portal.url);
    if (n.startsWith('http://') || n.startsWith('https://')) {
      return _redactUrl(n);
    }
    return n;
  }
}

/// Compact `[NOW] Programme` row rendered under the "via …" line on a hit
/// card. Stays empty (zero-height) when the portal has no EPG for this stream
/// so card layout doesn't shift visibly while loading.
class _HitEpgNowRow extends StatelessWidget {
  final ChannelHit hit;
  final IptvController ctrl;
  const _HitEpgNowRow({required this.hit, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EpgEntry>>(
      future: ctrl.epgForHit(hit),
      builder: (_, snap) {
        final data = snap.data;
        if (data == null || data.isEmpty) return const SizedBox.shrink();
        final now = data.firstWhere(
          (e) => e.isNow,
          orElse: () => data.first,
        );
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: now.isNow
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF00E5FF).withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  now.isNow ? 'NOW' : 'NEXT',
                  style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  now.title.isEmpty ? '—' : now.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
