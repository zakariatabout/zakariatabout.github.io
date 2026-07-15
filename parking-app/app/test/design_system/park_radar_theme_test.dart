import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/design_system/design_system.dart';

void main() {
  test('les thèmes clair et sombre exposent les mêmes rôles sémantiques', () {
    expect(ParkRadarTheme.light.brightness, Brightness.light);
    expect(ParkRadarTheme.dark.brightness, Brightness.dark);
    expect(
      ParkRadarTheme.light.extension<ParkRadarColors>(),
      same(ParkRadarColors.light),
    );
    expect(
      ParkRadarTheme.dark.extension<ParkRadarColors>(),
      same(ParkRadarColors.dark),
    );
    expect(
      ParkRadarTheme.light.materialTapTargetSize,
      MaterialTapTargetSize.padded,
    );
    expect(
      ParkRadarTheme.dark.materialTapTargetSize,
      MaterialTapTargetSize.padded,
    );
  });

  test('tous les tons sémantiques atteignent un contraste texte AA', () {
    final palettes = [ParkRadarColors.light, ParkRadarColors.dark];
    for (final palette in palettes) {
      final tones = [
        palette.confidenceLow,
        palette.confidenceMedium,
        palette.confidenceHigh,
        palette.confidenceUnknown,
        palette.info,
        palette.success,
        palette.warning,
        palette.danger,
        palette.neutral,
      ];
      for (final tone in tones) {
        expect(
          _contrastRatio(tone.foreground, tone.background),
          greaterThanOrEqualTo(4.5),
          reason: '${tone.foreground} sur ${tone.background}',
        );
      }
    }
  });

  test('la marque reste lisible dans les deux thèmes', () {
    for (final palette in [ParkRadarColors.light, ParkRadarColors.dark]) {
      expect(
        _contrastRatio(palette.onBrand, palette.brand),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('les règles responsive choisissent le bon type de panneau', () {
    expect(ParkRadarBreakpoints.usesSidePanel(const Size(390, 844)), isFalse);
    expect(ParkRadarBreakpoints.usesSidePanel(const Size(844, 390)), isTrue);
    expect(ParkRadarBreakpoints.usesSidePanel(const Size(1440, 900)), isTrue);
  });
}

double _contrastRatio(Color a, Color b) {
  final aLuminance = a.computeLuminance();
  final bLuminance = b.computeLuminance();
  final lighter = aLuminance > bLuminance ? aLuminance : bLuminance;
  final darker = aLuminance > bLuminance ? bLuminance : aLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
