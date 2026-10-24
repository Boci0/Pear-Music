import 'package:flutter/material.dart';

import '../theme/glass.dart';

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

/// The default [PearAppBar] title: the tab's name in spaced capitals, a
/// short stripe block and a faint tag, like a label on equipment.
class PearTabTitle extends StatelessWidget {
  final String label;

  /// A short status read-out ("14 TRACKS") beside the title, like a menu's
  /// code tag.
  final String? tag;
  const PearTabTitle(this.label, {super.key, this.tag});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // On narrow bars the tag gives way first, then the title shortens; the
    // stripe mark stays.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          flex: 3,
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 2.4,
            ),
          ),
        ),
        // The tag shows whole or not at all: a clipped "14 TR" reads as a
        // bug, on a phone or beside the expanded pane alike.
        if (tag != null) ...[
          const SizedBox(width: 10),
          Flexible(child: _WholeOrNothing(tag!)),
        ],
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
        color: PearGlassTokens.angularPanel,
        surfaceTintColor: Colors.transparent,
        shape: PearGlassTokens.angularShape(),
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
  // AppBar's own size, so the Scaffold takes the theme's toolbar height (the
  // lower bar on a short screen) instead of a fixed 56.
  Size get preferredSize => AppBar().preferredSize;

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

/// A one-line label drawn only when it fits its width in full.
class _WholeOrNothing extends StatelessWidget {
  const _WholeOrNothing(this.text);

  final String text;

  static final TextStyle _style = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4,
    color: Colors.white.withValues(alpha: 0.38),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: _style),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final fits = painter.width <= box.maxWidth;
          painter.dispose();
          return fits
              ? Text(text, maxLines: 1, softWrap: false, style: _style)
              : const SizedBox.shrink();
        },
      );
}
