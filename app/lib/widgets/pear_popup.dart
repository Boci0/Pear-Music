import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// True when popups should use the desktop treatment (a centered card) instead
/// of the phone push-up sheet: Windows, Linux and macOS.
bool get isDesktopPopupPlatform =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Shows [builder]'s content as a modal popup.
///
/// Phones keep the familiar pull-up sheet. Desktop gets a centered card capped
/// by [maxWidth] and [maxHeightFactor], because a sheet sliding up from the
/// taskbar edge reads as an Android import on Windows. Both flavors close on
/// an outside tap, and the desktop card also closes on Escape.
///
/// The content sits directly on the popup surface, exactly like the old
/// sheets. Tall content should bring its own scrolling, since the desktop
/// card caps the height at [maxHeightFactor] of the window.
Future<T?> showPearPopup<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool showDragHandle = false,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool useRootNavigator = false,
  double maxWidth = 380,
  double maxHeightFactor = 0.8,
  // Optional cap for the phone sheet; null keeps the sheet free to grow
  // (scroll-controlled content can take the full screen).
  double? mobileMaxHeightFactor,
  Color? barrierColor,
  bool useDialogSurface = true,
  // When set, desktop menus open next to this global position (for example
  // the three-dot button that triggered them) instead of in the middle of the
  // window. Phones always use the sheet and ignore it.
  Offset? anchor,
  bool anchorAlignRight = false,
}) {
  if (isDesktopPopupPlatform) {
    final menuAnchor = anchor;
    if (menuAnchor != null) {
      return _showAnchoredPopup<T>(
        context: context,
        anchor: menuAnchor,
        alignRight: anchorAlignRight,
        maxWidth: maxWidth,
        builder: builder,
      );
    }
    return showDialog<T>(
      context: context,
      useRootNavigator: true,
      barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.55),
      builder: (ctx) {
        final height = MediaQuery.sizeOf(ctx).height;
        return Dialog(
          // Some content (the diagnostics panes) paints its own card; drop the
          // dialog surface and border so only that card shows.
          backgroundColor: useDialogSurface ? null : Colors.transparent,
          elevation: useDialogSurface ? null : 0,
          shape: useDialogSurface
              ? null
              : const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: height * maxHeightFactor,
            ),
            child: builder(ctx),
          ),
        );
      },
    );
  }
  WidgetBuilder effectiveBuilder = builder;
  final mobileCap = mobileMaxHeightFactor;
  if (mobileCap != null) {
    effectiveBuilder = (ctx) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * mobileCap,
          ),
          child: builder(ctx),
        );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    barrierColor: barrierColor,
    builder: effectiveBuilder,
  );
}

/// Opens a desktop popup card next to [anchor]: below it when there is room,
/// flipped above when the anchor sits near the bottom edge, and always kept
/// inside the window. This is the desktop "menu" flavor of [showPearPopup].
Future<T?> _showAnchoredPopup<T>({
  required BuildContext context,
  required Offset anchor,
  required bool alignRight,
  required double maxWidth,
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'Dismiss menu',
    barrierColor: Colors.black.withValues(alpha: 0.10),
    transitionDuration: const Duration(milliseconds: 120),
    transitionBuilder: (ctx, animation, secondaryAnimation, child) =>
        FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      final screen = MediaQuery.sizeOf(ctx);
      const margin = 8.0;
      final cardWidth = maxWidth <= screen.width - margin * 2
          ? maxWidth
          : screen.width - margin * 2;
      var left = alignRight ? anchor.dx - cardWidth : anchor.dx;
      left = left.clamp(margin, screen.width - cardWidth - margin);
      final belowTop = anchor.dy + 6;
      final spaceBelow = screen.height - belowTop - margin;
      final spaceAbove = anchor.dy - 6 - margin;
      final openAbove = spaceBelow < 240 && spaceAbove > spaceBelow;
      final maxHeight =
          (openAbove ? spaceAbove : spaceBelow).clamp(120.0, screen.height * 0.9);

      final card = Material(
        color: const Color(0xFF1F1F23),
        elevation: 8,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: builder(ctx),
        ),
      );

      return Stack(
        children: [
          if (openAbove)
            Positioned(
              left: left,
              bottom: screen.height - (anchor.dy - 6),
              width: cardWidth,
              child: card,
            )
          else
            Positioned(
              left: left,
              top: belowTop,
              width: cardWidth,
              child: card,
            ),
        ],
      );
    },
  );
}

/// Global bottom-right corner of [context]'s render box, used to anchor a
/// popup menu under the control that opened it. Returns null when the box
/// cannot be measured, in which case the popup falls back to centered.
Offset? popupAnchorBelowRight(
  BuildContext context, {
  double insetX = 0,
  double insetY = 0,
}) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final corner = box.localToGlobal(box.size.bottomRight(Offset.zero));
  return Offset(corner.dx - insetX, corner.dy - insetY);
}

/// Global bottom-left corner of [context]'s render box (toolbar controls that
/// should open their menu down and to the right).
Offset? popupAnchorBelowLeft(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(box.size.bottomLeft(Offset.zero));
}
