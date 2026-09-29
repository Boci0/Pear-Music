import 'package:flutter/widgets.dart';

/// Clips a horizontally scrolling row at its left and right edges only, so
/// the glow of a selected pill can spill above and below the row instead of
/// being sliced off. Pills scrolled out of the row stay hidden at the sides.
///
/// Put it around the scroll view and give that scroll view
/// `clipBehavior: Clip.none`.
class GlowRoom extends StatelessWidget {
  const GlowRoom({super.key, required this.child, this.room = 16});

  final Widget child;

  /// How far the glow may reach past the top and bottom of the row.
  final double room;

  @override
  Widget build(BuildContext context) =>
      ClipRect(clipper: _SidesOnly(room), child: child);
}

class _SidesOnly extends CustomClipper<Rect> {
  const _SidesOnly(this.room);

  final double room;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, -room, size.width, size.height + room);

  @override
  bool shouldReclip(_SidesOnly oldClipper) => oldClipper.room != room;
}
