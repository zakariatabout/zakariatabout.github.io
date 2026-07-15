import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ParkedSession {
  const ParkedSession({
    required this.position,
    required this.parkedAt,
    this.sharedWithCommunity = false,
  });

  final LatLng position;
  final DateTime parkedAt;
  final bool sharedWithCommunity;
}

abstract interface class ParkingSessionStore {
  Future<ParkedSession?> load();
  Future<void> save(
    LatLng position,
    DateTime parkedAt, {
    bool sharedWithCommunity = false,
  });
  Future<void> clear();
}

/// Mémorise uniquement la session de stationnement de l'installation locale.
/// Aucune coordonnée supplémentaire n'est envoyée au backend par ce stockage.
class SharedPreferencesParkingSessionStore implements ParkingSessionStore {
  SharedPreferencesParkingSessionStore({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const _key = 'active_parking_session_v1';
  static const _maximumAge = Duration(hours: 24);
  static const _coordinatePrecision = 1000.0; // cellule ~70–110 m à Paris.
  final DateTime Function() _clock;

  @override
  Future<ParkedSession?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null) return null;
    try {
      final data = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final latitude = (data['latitude'] as num).toDouble();
      final longitude = (data['longitude'] as num).toDouble();
      final parkedAt = DateTime.parse(data['parkedAt'] as String);
      final age = _clock().difference(parkedAt);
      if (!latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180 ||
          age < const Duration(minutes: -5) ||
          age > _maximumAge) {
        await preferences.remove(_key);
        return null;
      }
      return ParkedSession(
        position: LatLng(latitude, longitude),
        parkedAt: parkedAt,
        sharedWithCommunity: data['sharedWithCommunity'] == true,
      );
    } catch (_) {
      await preferences.remove(_key);
      return null;
    }
  }

  @override
  Future<void> save(
    LatLng position,
    DateTime parkedAt, {
    bool sharedWithCommunity = false,
  }) async {
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        position.longitude < -180 ||
        position.longitude > 180) {
      throw ArgumentError('Position de stationnement invalide');
    }
    final preferences = await SharedPreferences.getInstance();
    final latitude = _quantize(position.latitude);
    final longitude = _quantize(position.longitude);
    final saved = await preferences.setString(
      _key,
      jsonEncode({
        'latitude': latitude,
        'longitude': longitude,
        'parkedAt': parkedAt.toIso8601String(),
        'sharedWithCommunity': sharedWithCommunity,
      }),
    );
    if (!saved) throw StateError('Échec de la sauvegarde locale');
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
  }

  double _quantize(double value) =>
      (value * _coordinatePrecision).roundToDouble() / _coordinatePrecision;
}
