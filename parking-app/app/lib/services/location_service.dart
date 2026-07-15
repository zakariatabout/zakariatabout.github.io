import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationFailure {
  servicesDisabled,
  permissionDenied,
  permissionDeniedForever,
  timeout,
  unavailable,
}

class LocationResult {
  const LocationResult.success(this.sample) : failure = null;
  const LocationResult.failure(this.failure) : sample = null;

  final LocationSample? sample;
  final LocationFailure? failure;

  LatLng? get position => sample?.position;
  bool get isSuccess => sample != null;

  String get userMessage => switch (failure) {
    LocationFailure.servicesDisabled =>
      'Activez la localisation pour démarrer le guidage.',
    LocationFailure.permissionDenied =>
      'La position est nécessaire uniquement pendant le guidage.',
    LocationFailure.permissionDeniedForever =>
      'Autorisez la localisation de ParkRadar dans les réglages.',
    LocationFailure.timeout =>
      'La position GPS tarde à arriver. Réessayez à ciel ouvert.',
    LocationFailure.unavailable => 'Position indisponible pour le moment.',
    null => '',
  };
}

/// Mesure GPS conservant les métadonnées indispensables pour distinguer une
/// vraie position de guidage d'un point ancien ou trop imprécis.
class LocationSample {
  const LocationSample({
    required this.position,
    required this.timestamp,
    required this.accuracyMeters,
    this.speedMetersPerSecond = 0,
    this.headingDegrees = 0,
  });

  final LatLng position;
  final DateTime timestamp;
  final double accuracyMeters;
  final double speedMetersPerSecond;
  final double headingDegrees;

  bool isUsable(
    DateTime now, {
    Duration maxAge = const Duration(seconds: 20),
    double maxAccuracyMeters = 45,
  }) {
    final age = now.toUtc().difference(timestamp.toUtc());
    return position.latitude.isFinite &&
        position.longitude.isFinite &&
        position.latitude >= -90 &&
        position.latitude <= 90 &&
        position.longitude >= -180 &&
        position.longitude <= 180 &&
        accuracyMeters.isFinite &&
        accuracyMeters > 0 &&
        accuracyMeters <= maxAccuracyMeters &&
        age >= const Duration(seconds: -5) &&
        age <= maxAge;
  }
}

abstract interface class LocationService {
  Future<LocationResult> current();
  Stream<LocationSample> watch();
  Future<bool> openSettings();
}

class DeviceLocationService implements LocationService {
  const DeviceLocationService();

  @override
  Future<LocationResult> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 5),
      )) {
        return const LocationResult.failure(LocationFailure.servicesDisabled);
      }

      var permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 5),
      );
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission().timeout(
          const Duration(seconds: 30),
        );
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationResult.failure(
          LocationFailure.permissionDeniedForever,
        );
      }
      if (permission == LocationPermission.denied) {
        return const LocationResult.failure(LocationFailure.permissionDenied);
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return LocationResult.success(
        LocationSample(
          position: LatLng(position.latitude, position.longitude),
          timestamp: position.timestamp,
          accuracyMeters: position.accuracy,
          speedMetersPerSecond: position.speed,
          headingDegrees: position.heading,
        ),
      );
    } on TimeoutException {
      return const LocationResult.failure(LocationFailure.timeout);
    } catch (_) {
      return const LocationResult.failure(LocationFailure.unavailable);
    }
  }

  @override
  Stream<LocationSample> watch() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 8,
      ),
    ).map(
      (position) => LocationSample(
        position: LatLng(position.latitude, position.longitude),
        timestamp: position.timestamp,
        accuracyMeters: position.accuracy,
        speedMetersPerSecond: position.speed,
        headingDegrees: position.heading,
      ),
    );
  }

  @override
  Future<bool> openSettings() => Geolocator.openAppSettings();
}
