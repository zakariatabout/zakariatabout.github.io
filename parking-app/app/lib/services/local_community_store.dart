import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'community_service.dart';

/// Stockage local des signalements (mode démo sans backend).
///
/// Persiste les événements dans le navigateur / l'appareil via
/// shared_preferences. Mono-appareil : parfait pour tester le flux
/// « Je me gare / Je libère » sans installer de backend. Dès qu'une URL
/// Supabase est fournie, [CommunityService] bascule automatiquement sur le
/// backend partagé et ce store n'est plus utilisé.
class LocalCommunityStore {
  LocalCommunityStore({DateTime Function()? now, Duration? retention})
    : _now = now ?? DateTime.now,
      _retention = retention ?? AppConfig.communityRetention;

  static const _key = 'local_parking_events';
  static const _maxStored = 300;
  final DateTime Function() _now;
  final Duration _retention;

  Future<List<Map<String, dynamic>>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Map<String, dynamic>> events) async {
    final prefs = await SharedPreferences.getInstance();
    // On borne la taille et applique le TTL local configurable (24 h par
    // défaut, comme le backend).
    final cutoff = _now().toUtc().subtract(_retention);
    final kept = events
        .where(
          (e) =>
              DateTime.tryParse(
                e['created_at'] as String? ?? '',
              )?.isAfter(cutoff) ??
              false,
        )
        .toList();
    final trimmed = kept.length > _maxStored
        ? kept.sublist(kept.length - _maxStored)
        : kept;
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  Future<bool> report(String type, LatLng position) async {
    if (type != 'parked' && type != 'freed') return false;
    if (!position.latitude.isFinite || !position.longitude.isFinite) {
      return false;
    }
    final events = await _load();
    events.add({
      'event_type': type,
      'lat': position.latitude,
      'lon': position.longitude,
      'created_at': _now().toUtc().toIso8601String(),
    });
    await _save(events);
    return true;
  }

  Future<List<ParkingEvent>> recentEventsNear(
    LatLng center, {
    double radiusMeters = 600,
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    final events = await _load();
    final now = _now().toUtc();
    final dLat = radiusMeters / 111320.0;
    final dLon =
        radiusMeters /
        (111320.0 * math.cos(center.latitude * math.pi / 180).abs());

    final result = <ParkingEvent>[];
    for (final e in events) {
      final createdAt = DateTime.tryParse(e['created_at'] as String? ?? '');
      if (createdAt == null) continue;
      final age = now.difference(createdAt.toUtc());
      if (age > maxAge || age < const Duration(minutes: -2)) continue;
      final lat = (e['lat'] as num).toDouble();
      final lon = (e['lon'] as num).toDouble();
      if ((lat - center.latitude).abs() > dLat) continue;
      if ((lon - center.longitude).abs() > dLon) continue;
      result.add(
        ParkingEvent(
          type: e['event_type'] as String,
          position: LatLng(lat, lon),
          createdAt: createdAt,
        ),
      );
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> purgeExpired() async => _save(await _load());
}
