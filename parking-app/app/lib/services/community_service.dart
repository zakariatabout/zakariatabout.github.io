import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'local_community_store.dart';

/// Un signalement communautaire : un conducteur s'est garé ou a libéré
/// une place à cet endroit.
class ParkingEvent {
  ParkingEvent({
    required this.type,
    required this.position,
    required this.createdAt,
  });

  /// 'parked' (place prise) ou 'freed' (place libérée).
  final String type;
  final LatLng position;
  final DateTime createdAt;

  bool get isFreed => type == 'freed';
}

/// Couche temps réel communautaire, via l'API REST (PostgREST) de Supabase —
/// même stack que Tennis AI Coach. Anonyme : aucun compte requis, seules la
/// position et l'heure de l'événement sont stockées.
class CommunityService {
  CommunityService({http.Client? client, LocalCommunityStore? localStore})
      : _client = client ?? http.Client(),
        _local = localStore ?? LocalCommunityStore();

  final http.Client _client;
  final LocalCommunityStore _local;

  /// La couche communautaire est toujours disponible : backend Supabase
  /// partagé si configuré, sinon stockage local (mode démo mono-appareil).
  bool get isEnabled => true;

  /// Vrai si un backend Supabase partagé est branché (sinon : mode local).
  bool get isRemote => AppConfig.communityEnabled;

  Map<String, String> get _headers => {
        'apikey': AppConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${AppConfig.supabaseAnonKey}',
        'Content-Type': 'application/json',
      };

  Uri _table([Map<String, dynamic>? params]) =>
      Uri.parse('${AppConfig.supabaseUrl}/rest/v1/parking_events')
          .replace(queryParameters: params);

  /// Signale une place prise ('parked') ou libérée ('freed').
  Future<bool> report(String type, LatLng position) async {
    if (!isRemote) return _local.report(type, position);
    final resp = await _client.post(
      _table(),
      headers: {..._headers, 'Prefer': 'return=minimal'},
      body: jsonEncode({
        'event_type': type,
        'lat': position.latitude,
        'lon': position.longitude,
      }),
    );
    return resp.statusCode >= 200 && resp.statusCode < 300;
  }

  /// Événements récents dans un rayon autour d'un point (boîte englobante,
  /// suffisante à cette échelle).
  Future<List<ParkingEvent>> recentEventsNear(
    LatLng center, {
    double radiusMeters = 600,
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    if (!isRemote) {
      return _local.recentEventsNear(center,
          radiusMeters: radiusMeters, maxAge: maxAge);
    }
    final dLat = radiusMeters / 111320.0;
    final dLon = radiusMeters /
        (111320.0 * math.cos(center.latitude * math.pi / 180).abs());
    final since = DateTime.now().toUtc().subtract(maxAge).toIso8601String();

    final resp = await _client.get(
      _table({
        'select': 'event_type,lat,lon,created_at',
        'created_at': 'gte.$since',
        // PostgREST accepte des filtres répétés sur la même colonne.
        'lat': [
          'gte.${center.latitude - dLat}',
          'lte.${center.latitude + dLat}',
        ],
        'lon': [
          'gte.${center.longitude - dLon}',
          'lte.${center.longitude + dLon}',
        ],
        'order': 'created_at.desc',
        'limit': '200',
      }),
      headers: _headers,
    );
    if (resp.statusCode != 200) return const [];
    final data = jsonDecode(resp.body) as List;
    return [
      for (final e in data.cast<Map<String, dynamic>>())
        ParkingEvent(
          type: e['event_type'] as String,
          position: LatLng(
            (e['lat'] as num).toDouble(),
            (e['lon'] as num).toDouble(),
          ),
          createdAt: DateTime.parse(e['created_at'] as String),
        ),
    ];
  }
}
