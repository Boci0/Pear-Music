import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/theme/glass.dart';
import 'package:peerm_app/theme/pear_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => PearStyles.current.value = PearStyle.glass);

  test('Glass keeps the values the app shipped with', () {
    PearStyles.current.value = PearStyle.glass;
    expect(PearGlassTokens.blur, 20);
    expect(PearGlassTokens.baseAlpha, 0.38);
    expect(PearGlassTokens.accentTint, 0.20);
    expect(PearGlassTokens.popupAlpha, 0.74);
    expect(PearGlassTokens.sheenTop, 0.16);
    expect(PearGlassTokens.edgeTop, 0.34);
    expect(PearGlassTokens.edge, 0.09);
    expect(PearGlassTokens.cardFill, 0.045);
    // The old constants: 0x14FFFFFF and 0x0AFFFFFF, rim 0x10FFFFFF.
    final sheen = PearGlassTokens.cardSheen.colors;
    expect((sheen[0].a * 255).round(), 0x14);
    expect((sheen[1].a * 255).round(), 0x0A);
    expect((PearGlassTokens.cardRim.a * 255).round(), 0x10);
    expect(PearStyles.spec.glowScale, 1);
    expect(PearStyles.spec.flat, isFalse);
  });

  test('Frosted is brighter and Solid is flat', () {
    PearStyles.current.value = PearStyle.frosted;
    expect(PearGlassTokens.edgeTop, greaterThan(0.34));
    expect(PearGlassTokens.baseAlpha, lessThan(0.38));
    expect(PearStyles.spec.glowScale, greaterThan(1));

    PearStyles.current.value = PearStyle.solid;
    expect(PearStyles.spec.flat, isTrue);
    expect(PearStyles.spec.glowScale, 0);
    expect(PearGlassTokens.sheenTop, 0);
  });

  test('an unknown saved style falls back to Glass', () {
    expect(PearStyle.parse(null), PearStyle.glass);
    expect(PearStyle.parse('neon'), PearStyle.glass);
    expect(PearStyle.parse('solid'), PearStyle.solid);
  });

  test('the style is saved, restored and changes the theme', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var identity = IdentityService(prefs);
    expect(identity.style, PearStyle.glass);

    final glassTheme = PlayerTheme.buildFromScheme(
      ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
    );
    await identity.setStyle(PearStyle.solid);
    expect(PearStyles.current.value, PearStyle.solid);
    final solidTheme = PlayerTheme.buildFromScheme(
      ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
    );
    expect(solidTheme.cardTheme.color, isNot(glassTheme.cardTheme.color));

    // A fresh start reads it back.
    PearStyles.current.value = PearStyle.glass;
    prefs = await SharedPreferences.getInstance();
    identity = IdentityService(prefs);
    expect(identity.style, PearStyle.solid);
  });
}
