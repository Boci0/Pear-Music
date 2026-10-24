import 'package:flutter/material.dart';

import '../theme/glass.dart';

/// The Graphite dialog every confirmation, prompt and notice shares: an
/// angular panel with a spaced-capitals title. Takes the same arguments as an
/// [AlertDialog].
class PearAlertDialog extends StatelessWidget {
  const PearAlertDialog({
    super.key,
    required this.title,
    this.content,
    this.actions,
    this.scrollable = false,
  });

  final Widget title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: PearGlassTokens.angularPanel,
      surfaceTintColor: Colors.transparent,
      shape: PearGlassTokens.angularShape(),
      scrollable: scrollable,
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
      actionsPadding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DefaultTextStyle.merge(
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
            child: title,
          ),
        ],
      ),
      content: content,
      actions: actions,
    );
  }
}

/// A sheet's heading: an optional picture ([leading], a song's cover), a
/// title and an optional line under it, and [trailing] on the right.
class PearSheetTitle extends StatelessWidget {
  const PearSheetTitle(
    this.title, {
    super.key,
    this.subtitle,
    this.leading,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(20, 6, 20, 10),
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 48, height: 48, child: leading),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A section label in spaced capitals.
class PearSheetLabel extends StatelessWidget {
  const PearSheetLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

/// A flat menu row with a hairline under it: an optional icon, a label, and
/// on the right an optional hint and a chevron for a row that opens more.
class PearSheetRow extends StatelessWidget {
  const PearSheetRow({
    super.key,
    required this.label,
    required this.onTap,
    this.hint,
    this.detail,
    this.icon,
    this.danger = false,
    this.selected = false,
    this.chevron = false,
  });

  final String label;
  final String? hint;

  /// A chevron at the right edge: the row opens another list.
  final bool chevron;

  /// A smaller line under the label saying what the row does.
  final String? detail;
  final IconData? icon;
  final bool danger;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger
        ? scheme.error
        : selected
            ? scheme.primary
            : scheme.onSurface;
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
          ),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            // Not flexible: sharing the width with the label left the hint
            // floating mid-row.
            if (hint != null) ...[
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  hint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (chevron) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    ));
  }
}

/// A soft rounded button for sheets: a quiet tonal fill with the icon in the
/// accent, [filled] takes the accent, [danger] turns it red.
class PearSheetButton extends StatelessWidget {
  const PearSheetButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.filled = false,
    this.danger = false,
    this.height = 48,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool filled;
  final bool danger;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tone = danger ? scheme.error : scheme.primary;
    final fg = filled
        ? (tone.computeLuminance() > 0.35
            ? const Color(0xFF15161A)
            : Colors.white)
        : danger
        ? tone
        : scheme.onSurface;
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: filled ? tone : Colors.white.withValues(alpha: 0.07),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: onTap,
          child: SizedBox(
            height: height,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: filled ? fg : tone),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A choice chip for timers and speeds: the selected one is filled.
class PearSheetChip extends StatelessWidget {
  const PearSheetChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : Colors.white.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected
              ? scheme.primary
              : Colors.white.withValues(alpha: PearGlassTokens.edge),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? (scheme.primary.computeLuminance() > 0.35
                      ? const Color(0xFF15161A)
                      : Colors.white)
                  : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of a right-click menu. [separatorBefore] draws a hairline above it.
class PearMenuEntry {
  const PearMenuEntry(
    this.value,
    this.label, {
    this.color,
    this.separatorBefore = false,
  });

  final String value;
  final String label;
  final Color? color;
  final bool separatorBefore;
}

/// The desktop right-click menu at [position]: a Graphite panel with text rows
/// and hairlines between the groups.
Future<String?> showPearContextMenu(
  BuildContext context,
  Offset position,
  List<PearMenuEntry> entries,
) {
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return Future.value();
  final items = <PopupMenuEntry<String>>[];
  for (final e in entries) {
    if (e.separatorBefore) items.add(const PopupMenuDivider(height: 9));
    items.add(
      PopupMenuItem<String>(
        value: e.value,
        height: 38,
        child: Text(
          e.label,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: e.color, fontSize: 14),
        ),
      ),
    );
  }
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: items,
    color: PearGlassTokens.angularPanel,
    surfaceTintColor: Colors.transparent,
    shape: PearGlassTokens.angularShape(),
    constraints: const BoxConstraints(minWidth: 220),
  );
}
