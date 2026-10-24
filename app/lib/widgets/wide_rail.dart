import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../screens/playlists_screen.dart';
import '../theme/glass.dart';
import 'tactile_button.dart';

/// The wide shell's left rail: the Pear mark,
/// a search field (Ctrl+K), the sections, your playlists, and Settings at the
/// foot. [compact] shrinks it to a column of icons (Theater mode).
///
/// Indexes are the shell's screen indexes: 5 Home, 2 Explore, 0 Library,
/// 3 History, 1 Playlists, 4 Settings.
class WideRail extends StatefulWidget {
  const WideRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onOpenPlaylist,
    required this.onOpenLiked,
    required this.onSearch,
    required this.searchFocus,
    this.compact = false,
    this.openPlaylist,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<Playlist> onOpenPlaylist;
  final VoidCallback onOpenLiked;

  /// Called with the query when the search field is submitted.
  final ValueChanged<String> onSearch;

  /// Owned by the shell, which focuses it on Ctrl+K.
  final FocusNode searchFocus;
  final bool compact;

  /// The playlist open in the Playlists tab ([liked] for Liked songs), lit
  /// in the list while that tab shows it.
  final String? openPlaylist;

  static const String liked = 'liked';

  static const double width = 248;
  static const double compactWidth = 72;

  static const List<({int index, String label, IconData icon})> sections = [
    (index: 5, label: 'Home', icon: Icons.home_outlined),
    (index: 2, label: 'Explore', icon: Icons.explore_outlined),
    (index: 0, label: 'Library', icon: Icons.library_music_outlined),
    (index: 3, label: 'History', icon: Icons.history_outlined),
  ];

  @override
  State<WideRail> createState() => _WideRailState();
}

class _WideRailState extends State<WideRail> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    widget.onSearch(q);
    _search.clear();
    widget.searchFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    // A Material, not a coloured box: the rows' hover and press ink paints
    // on it, where a box would cover it.
    return Material(
      key: const ValueKey('wide_rail'),
      color: const Color(0xFF111114),
      shape: const Border(right: BorderSide(color: PearGlassTokens.cardRim)),
      child: SizedBox(
        width: compact ? WideRail.compactWidth : WideRail.width,
        child: compact ? _buildCompact() : _buildFull(context),
      ),
    );
  }

  Widget _buildCompact() {
    return Column(
      children: [
        const SizedBox(height: 16),
        for (final s in WideRail.sections)
          _icon(s.icon, s.label, s.index),
        _icon(Icons.queue_music_outlined, 'Playlists', 1),
        const Spacer(),
        _icon(Icons.settings_outlined, 'Settings', 4),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _icon(IconData icon, String label, int index) {
    final selected = widget.selectedIndex == index;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        decoration: PearGlassTokens.navPill(
          selected ? PearGlassTokens.navTint(scheme) : Colors.transparent,
        ),
        child: TactileIconButton(
          tooltip: label,
          icon: Icon(
            icon,
            color: selected
                ? scheme.primary
                : Colors.white.withValues(alpha: 0.6),
          ),
          onPressed: () => widget.onDestinationSelected(index),
        ),
      ),
    );
  }

  Widget _buildFull(BuildContext context) {
    final controller = context.watch<AppController>();
    final accent = Theme.of(context).colorScheme.primary;
    final muted = Colors.white.withValues(alpha: 0.47);
    final openList = widget.selectedIndex == 1 ? widget.openPlaylist : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 18),
            child: Row(
              children: [
                const Text(
                  'PEAR',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 38,
            child: TextField(
              key: const ValueKey('rail_search'),
              controller: _search,
              focusNode: widget.searchFocus,
              onSubmitted: _submit,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search',
                hintStyle: TextStyle(fontSize: 13, color: muted),
                prefixIcon: Icon(Icons.search_rounded, size: 17, color: muted),
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      'Ctrl K',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                ),
                filled: true,
                fillColor: const Color(0xFF18191C),
                contentPadding: EdgeInsets.zero,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(19)),
                  borderSide: BorderSide(color: Color(0x14FFFFFF)),
                ),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(19)),
                  borderSide: BorderSide(color: Color(0x14FFFFFF)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: const BorderRadius.all(Radius.circular(19)),
                  borderSide: BorderSide(color: accent.withValues(alpha: 0.6)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          for (final s in WideRail.sections)
            _RailRow(
              label: s.label,
              icon: s.icon,
              selected: widget.selectedIndex == s.index,
              onTap: () => widget.onDestinationSelected(s.index),
            ),
          const SizedBox(height: 14),
          _RailRow(
            label: 'Playlists',
            icon: Icons.queue_music_outlined,
            selected: widget.selectedIndex == 1 && openList == null,
            onTap: () => widget.onDestinationSelected(1),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _PlaylistRow(
                  key: const ValueKey('rail_liked'),
                  name: 'Liked songs',
                  thumb: Container(
                    key: const ValueKey('rail_liked_thumb'),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.favorite_rounded,
                      size: 13,
                      // Dark on a light accent, white on a dark one.
                      color: accent.computeLuminance() > 0.35
                          ? const Color(0xFF15161A)
                          : Colors.white,
                    ),
                  ),
                  selected: openList == WideRail.liked,
                  onTap: widget.onOpenLiked,
                ),
                for (final p in controller.playlists)
                  _PlaylistRow(
                    key: ValueKey('rail_playlist_${p.id}'),
                    name: p.name,
                    thumb: PlaylistArtwork(
                      firstSong: PlaylistArtwork.firstSongOf(controller, p),
                      size: 22,
                      radius: 6,
                    ),
                    selected: openList == p.id,
                    onTap: () => widget.onOpenPlaylist(p),
                  ),
              ],
            ),
          ),
          _RailRow(
            label: 'Settings',
            icon: Icons.settings_outlined,
            selected: widget.selectedIndex == 4,
            onTap: () => widget.onDestinationSelected(4),
          ),
        ],
      ),
    );
  }
}

/// A section link: icon and name. The selected one sits in an
/// accent-tinted pill with accent text; the pill fades, it never moves.
class _RailRow extends StatelessWidget {
  const _RailRow({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () {
            TactileFeedback.click();
            onTap();
          },
          customBorder: const StadiumBorder(),
          hoverColor: _railHover,
          highlightColor: _railPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: PearGlassTokens.navPill(
              selected ? PearGlassTokens.navTint(scheme) : Colors.transparent,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected
                      ? scheme.primary
                      : Colors.white.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? scheme.primary
                          : Colors.white.withValues(alpha: 0.85),
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
}

/// Hover and press fills shared by every rail row.
final Color _railHover = Colors.white.withValues(alpha: 0.07);
final Color _railPress = Colors.white.withValues(alpha: 0.12);

/// A playlist link: thumbnail and name. The open one gets the sections'
/// accent pill.
class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    super.key,
    required this.name,
    required this.thumb,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Widget thumb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () {
            TactileFeedback.click();
            onTap();
          },
          customBorder: const StadiumBorder(),
          hoverColor: _railHover,
          highlightColor: _railPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            height: 36,
            decoration: PearGlassTokens.navPill(
              selected ? PearGlassTokens.navTint(scheme) : Colors.transparent,
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                thumb,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? scheme.primary
                          : Colors.white.withValues(alpha: 0.8),
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
}
