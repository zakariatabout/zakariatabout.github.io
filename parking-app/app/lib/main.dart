import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'design_system/design_system.dart';
import 'screens/map_screen.dart';
import 'services/calibration_store.dart';
import 'services/flutter_test_environment.dart';
import 'services/map_style_repository.dart';
import 'services/probability_calibrator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Styles vectoriels : préchargement lancé immédiatement, JAMAIS attendu.
  // Le premier build part sur le repli raster si le parse (quelques ms) n'est
  // pas fini ; MapScreen bascule ensuite via son propre ensureLoaded().
  if (AppConfig.useVectorRenderer && !isFlutterTestEnvironment) {
    unawaited(MapStyleRepository.instance.ensureLoaded());
  }
  // Calibration supervisée : chargée si des paramètres ont été appris,
  // sinon calibrateur identité (comportement honnêtement non calibré).
  final calibrator = await CalibrationStore().load();
  runApp(ParkingApp(calibrator: calibrator));
}

class ParkingApp extends StatelessWidget {
  const ParkingApp({
    super.key,
    this.calibrator = const IdentityProbabilityCalibrator(),
  });

  final ProbabilityCalibrator calibrator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ParkRadar',
      debugShowCheckedModeBanner: false,
      theme: ParkRadarTheme.light,
      darkTheme: ParkRadarTheme.dark,
      themeMode: ThemeMode.system,
      themeAnimationDuration: ParkRadarMotion.standard,
      themeAnimationCurve: ParkRadarMotion.enter,
      home: MapScreen(calibrator: calibrator),
    );
  }
}
