import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

class DrivingRoute {
  DrivingRoute({
    required this.points,
    required this.durationSeconds,
    required this.distanceMeters,
  });

  final List<LatLng> points;
  final double durationSeconds;
  final double distanceMeters;
}

/// Itinéraire voiture via le serveur public OSRM, en passant par une série
/// de points (position de départ puis tronçons de la boucle de recherche).
class RoutingService {
  RoutingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<DrivingRoute?> route(List<LatLng> waypoints) async {
    if (waypoints.length < 2) return null;
    final coords = waypoints
        .map((p) => '${p.longitude.toStringAsFixed(6)},'
            '${p.latitude.toStringAsFixed(6)}')
        .join(';');
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/$coords'
      '?overview=full&geometries=geojson&continue_straight=false',
    );
    final resp =
        await _client.get(uri, headers: const {'User-Agent': kUserAgent});
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final routes = (data['routes'] as List?) ?? const [];
    if (routes.isEmpty) return null;
    final r = routes.first as Map<String, dynamic>;
    final geometry =
        ((r['geometry'] as Map)['coordinates'] as List).cast<List>();
    return DrivingRoute(
      points: [
        for (final c in geometry)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ],
      durationSeconds: (r['duration'] as num).toDouble(),
      distanceMeters: (r['distance'] as num).toDouble(),
    );
  }
}
