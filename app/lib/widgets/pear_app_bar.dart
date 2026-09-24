import 'package:flutter/material.dart';

import 'pear_popup.dart';

/// The pear mark shown at the start of every tab header.
class PearMark extends StatelessWidget {
  final double size;
  const PearMark({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/pear_logo.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// Pear mark + tab label, the default [PearAppBar] title.
class PearTabTitle extends StatelessWidget {
  final String label;
  const PearTabTitle(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    // At rail widths the side rail already carries the mark, so repeating it
    // in every tab title reads as clutter. Phones and narrow windows keep it
    // (they have no rail).
    final size = MediaQuery.sizeOf(context);
    final showMark =
        size.width < 900 || !(isDesktopPopupPlatform || size.shortestSide >= 600);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showMark) ...[
          const PearMark(),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
              ),
        ),
      ],
    );
  }
}

/// Gap kept after the last action so the action icons line up with the 16px
/// start inset the pear mark uses on the left.
const double kAppBarActionInset = 8;

/// Touch box every app bar action uses. [TactileIconButton] lands on this on
/// its own (8px padding around a 24px icon); Material widgets that default to
/// the 48px IconButton box must be constrained to it, see [PearMenuButton].
const double kAppBarActionBox = 40;

/// App bar action that opens a popup menu, sized like [TactileIconButton] so a
/// menu button does not widen the action row (a bare [PopupMenuButton] renders
/// at the Material 48px box).
class PearMenuButton<T> extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final PopupMenuItemSelected<T> onSelected;
  final PopupMenuItemBuilder<T> itemBuilder;

  const PearMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onSelected,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kAppBarActionBox,
      height: kAppBarActionBox,
      child: PopupMenuButton<T>(
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: Icon(icon),
        onSelected: onSelected,
        itemBuilder: itemBuilder,
      ),
    );
  }
}

/// One app bar implementation for every screen, so the headers of the tabs and
/// the detail pages share the exact same geometry: 16px start inset for the
/// pear mark (or custom title), actions flush right with an 8px end inset, and
/// action buttons sized by [TactileIconButton] (40x40) rather than the wider
/// Material [IconButton].
///
/// Without a single source of truth these drift apart: an [IconButton] is 48px
/// wide and a [TactileIconButton] is 40px, so mixing them changes both the
/// spacing between icons and the distance to the screen edge.
class PearAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Tab label rendered next to the pear mark. Ignored when [title] is given.
  final String? label;

  /// Fully custom title: search mode, a playlist name, and so on.
  final Widget? title;

  /// Right-aligned actions. A trailing inset is appended automatically.
  final List<Widget> actions;

  /// Show the automatic back button (detail pages pushed on a navigator).
  final bool showBackButton;

  const PearAppBar({
    super.key,
    this.label,
    this.title,
    this.actions = const [],
    this.showBackButton = false,
  }) : assert(label != null || title != null,
            'PearAppBar needs a label or a title');

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: showBackButton,
      titleSpacing: 16,
      title: title ?? (label == null ? null : PearTabTitle(label!)),
      actions: actions.isEmpty
          ? null
          : [...actions, const SizedBox(width: kAppBarActionInset)],
    );
  }
}
