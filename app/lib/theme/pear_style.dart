import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The app's look. Every style keeps the same layout and shapes; they differ
/// only in the numbers [PearStyleSpec] holds (how much the panels blur and
/// tint, how bright the rim is, how loud the backdrop glows are).
enum PearStyle {
  /// The default: dark frosted panels tinted by the song.
  glass('Glass'),

  /// Lighter, more colourful glass with a stronger rim.
  frosted('Frosted'),

  /// Flat dark surfaces and hairline borders: no blur, no glows.
  solid('Solid');

  const PearStyle(this.label);
  final String label;

  static PearStyle parse(String? name) => PearStyle.values.firstWhere(
    (s) => s.name == name,
    orElse: () => PearStyle.glass,
  );
}

/// The numbers one [PearStyle] is made of.
class PearStyleSpec {
  const PearStyleSpec({
    required this.blur,
    required this.baseAlpha,
    required this.accentTint,
    required this.popupAlpha,
    required this.sheenTop,
    required this.sheenBottom,
    required this.edgeTop,
    required this.edge,
    required this.cardFill,
    required this.cardSheenTop,
    required this.cardSheenBottom,
    required this.cardRim,
    required this.shadowAlpha,
    required this.glowScale,
    required this.watermarkAlpha,
    this.flat = false,
  });

  /// Backdrop blur strength of the panels that content scrolls under.
  final double blur;

  /// Strength of the tint under a panel's sheen.
  final double baseAlpha;

  /// How much of the song's accent goes into a panel's base.
  final double accentTint;

  /// Denser base for popups, menus and sheets.
  final double popupAlpha;

  /// White light at the top of a panel and at its foot.
  final double sheenTop;
  final double sheenBottom;

  /// Hairline rim: brightest along the top, and the plain edge.
  final double edgeTop;
  final double edge;

  /// Resting fill, top and bottom sheen, and rim of cards and rows.
  final double cardFill;
  final double cardSheenTop;
  final double cardSheenBottom;
  final double cardRim;

  /// Strength of the drop shadow under floating chrome.
  final double shadowAlpha;

  /// Multiplier on the backdrop's colour glows (0 = none).
  final double glowScale;

  /// How loud the pear watermark is.
  final double watermarkAlpha;

  /// Opaque surfaces and no blur, as Reduced Effects draws panels.
  final bool flat;

  LinearGradient get cardSheen => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.fromRGBO(255, 255, 255, cardSheenTop),
      Color.fromRGBO(255, 255, 255, cardSheenBottom),
    ],
  );
}

/// The style in use. Set once from the saved setting and again when the user
/// picks another one; the theme listens and rebuilds.
class PearStyles {
  PearStyles._();

  static final ValueNotifier<PearStyle> current = ValueNotifier(
    PearStyle.glass,
  );

  static const Map<PearStyle, PearStyleSpec> _specs = {
    PearStyle.glass: PearStyleSpec(
      blur: 20,
      baseAlpha: 0.38,
      accentTint: 0.20,
      popupAlpha: 0.74,
      sheenTop: 0.16,
      sheenBottom: 0.02,
      edgeTop: 0.34,
      edge: 0.09,
      cardFill: 0.045,
      cardSheenTop: 0.078,
      cardSheenBottom: 0.039,
      cardRim: 0.063,
      shadowAlpha: 0.35,
      glowScale: 1,
      watermarkAlpha: 0.035,
    ),
    PearStyle.frosted: PearStyleSpec(
      blur: 24,
      baseAlpha: 0.30,
      accentTint: 0.28,
      popupAlpha: 0.72,
      sheenTop: 0.26,
      sheenBottom: 0.05,
      edgeTop: 0.55,
      edge: 0.20,
      cardFill: 0.09,
      cardSheenTop: 0.15,
      cardSheenBottom: 0.08,
      cardRim: 0.22,
      shadowAlpha: 0.30,
      glowScale: 1.6,
      watermarkAlpha: 0.06,
    ),
    PearStyle.solid: PearStyleSpec(
      blur: 0,
      baseAlpha: 0.38,
      accentTint: 0.10,
      popupAlpha: 0.94,
      sheenTop: 0,
      sheenBottom: 0,
      edgeTop: 0.10,
      edge: 0.10,
      cardFill: 0.06,
      cardSheenTop: 0.06,
      cardSheenBottom: 0.06,
      cardRim: 0.10,
      shadowAlpha: 0.18,
      glowScale: 0,
      watermarkAlpha: 0.03,
      flat: true,
    ),
  };

  static PearStyleSpec get spec => _specs[current.value]!;
}
