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
}) {
  if (isDesktopPopupPlatform) {
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
