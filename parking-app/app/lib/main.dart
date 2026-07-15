import 'package:flutter/material.dart';

import 'design_system/design_system.dart';
import 'screens/map_screen.dart';

void main() {
  runApp(const ParkingApp());
}

class ParkingApp extends StatelessWidget {
  const ParkingApp({super.key});

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
      home: const MapScreen(),
    );
  }
}
