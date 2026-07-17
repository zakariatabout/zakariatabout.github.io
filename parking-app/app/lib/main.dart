import 'package:flutter/material.dart';

import 'design_system/design_system.dart';
import 'screens/map_screen.dart';
import 'services/calibration_store.dart';
import 'services/probability_calibrator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
