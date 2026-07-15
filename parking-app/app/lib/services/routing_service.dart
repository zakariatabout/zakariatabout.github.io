import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'network_client.dart';

class RouteStep {
  RouteStep({
    required this.instruction,
    required this.maneuver,
    required this.location,
    required this.durationSeconds,
    required this.distanceMeters,
    this.streetName,
  });

  /// Formulation courte, exploitable plus tard par l'UI vocale/guidage.
  final String instruction;

  /// Type OSRM normalisé, par exemple `turn:right` ou `arrive`.
  final String maneuver;
  final LatLng location;
  final double durationSeconds;
  final double distanceMeters;
  final String? streetName;
}

class DrivingRoute {
  DrivingRoute({
    required this.points,
    required this.durationSeconds,
    required this.distanceMeters,
    this.steps = const [],
  });

  final List<LatLng> points;
  final double durationSeconds;
  final double distanceMeters;
  final List<RouteStep> steps;
}

/// Itinéraire voiture via le serveur public OSRM, en passant par une série
/// de points (position de départ puis tronçons de la boucle de recherche).
class RoutingService {
  RoutingService({http.Client? client, String? endpoint, Duration? timeout})
    : _endpoint = parseHttpEndpoint(
        endpoint ?? AppConfig.osrmDrivingBaseUrl,
        configName: 'OSRM_DRIVING_BASE_URL',
      ),
      _network = NetworkClient(
        client: client,
        timeout: timeout ?? AppConfig.networkTimeout,
      );

  final Uri _endpoint;
  final NetworkClient _network;

  /// API historique tolérante : `null` si le fournisseur est indisponible.
  Future<DrivingRoute?> route(List<LatLng> waypoints) async {
    try {
      return await routeOrThrow(waypoints);
    } on NetworkException {
      return null;
    }
  }

  /// Variante diagnostique : les erreurs réseau/décodage restent typées.
  Future<DrivingRoute?> routeOrThrow(List<LatLng> waypoints) async {
    if (waypoints.length < 2) return null;
    final coords = waypoints
        .map(
          (p) =>
              '${p.longitude.toStringAsFixed(6)},'
              '${p.latitude.toStringAsFixed(6)}',
        )
        .join(';');
    final base = _endpoint.toString().replaceFirst(RegExp(r'/$'), '');
    final uri = Uri.parse('$base/$coords').replace(
      queryParameters: const {
        'overview': 'full',
        'geometries': 'geojson',
        'continue_straight': 'false',
        'steps': 'true',
      },
    );
    final resp = await _network.get(
      uri,
      headers: const {'User-Agent': kUserAgent},
    );
    _network.requireSuccess(resp, uri, acceptedStatusCodes: const {200});
    final data = _network.decodeObject(resp, uri);
    final routes = (data['routes'] as List?) ?? const [];
    if (routes.isEmpty) return null;
    try {
      final route = (routes.first as Map).cast<String, dynamic>();
      final geometry = ((route['geometry'] as Map)['coordinates'] as List)
          .cast<List>();
      if (geometry.length < 2) {
        throw const FormatException(
          'La géométrie OSRM doit contenir au moins deux points',
        );
      }
      final steps = <RouteStep>[];
      for (final rawLeg in (route['legs'] as List?) ?? const []) {
        if (rawLeg is! Map) continue;
        for (final rawStep in (rawLeg['steps'] as List?) ?? const []) {
          if (rawStep is! Map) continue;
          steps.add(_parseStep(rawStep.cast<String, dynamic>()));
        }
      }
      final points = [
        for (final c in geometry)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];
      if (points.any(
        (point) =>
            !point.latitude.isFinite ||
            !point.longitude.isFinite ||
            point.latitude < -90 ||
            point.latitude > 90 ||
            point.longitude < -180 ||
            point.longitude > 180,
      )) {
        throw const FormatException('Coordonnées OSRM invalides');
      }
      final duration = (route['duration'] as num).toDouble();
      final distance = (route['distance'] as num).toDouble();
      if (!duration.isFinite ||
          duration < 0 ||
          !distance.isFinite ||
          distance <= 0) {
        throw const FormatException('Métriques OSRM invalides');
      }
      return DrivingRoute(
        points: points,
        durationSeconds: duration,
        distanceMeters: distance,
        steps: steps,
      );
    } catch (error) {
      throw NetworkPayloadException(
        'Itinéraire OSRM invalide',
        uri: uri,
        cause: error,
      );
    }
  }

  RouteStep _parseStep(Map<String, dynamic> raw) {
    final maneuver = (raw['maneuver'] as Map).cast<String, dynamic>();
    final type = (maneuver['type'] as String?) ?? 'turn';
    final modifier = maneuver['modifier'] as String?;
    final normalized = modifier == null ? type : '$type:$modifier';
    final location = maneuver['location'] as List;
    final streetName = (raw['name'] as String?)?.trim();
    return RouteStep(
      instruction: _instruction(type, modifier, streetName),
      maneuver: normalized,
      location: LatLng(
        (location[1] as num).toDouble(),
        (location[0] as num).toDouble(),
      ),
      durationSeconds: (raw['duration'] as num).toDouble(),
      distanceMeters: (raw['distance'] as num).toDouble(),
      streetName: streetName == null || streetName.isEmpty ? null : streetName,
    );
  }

  String _instruction(String type, String? modifier, String? streetName) {
    final road = streetName == null || streetName.isEmpty
        ? ''
        : ' sur $streetName';
    return switch (type) {
      'depart' => 'Démarrez$road',
      'arrive' => 'Vous êtes arrivé',
      'roundabout' || 'rotary' => 'Prenez le rond-point$road',
      'merge' => 'Insérez-vous$road',
      'fork' =>
        modifier == 'left' ? 'Restez à gauche$road' : 'Restez à droite$road',
      'continue' || 'new name' => 'Continuez$road',
      _ => switch (modifier) {
        'left' || 'sharp left' || 'slight left' => 'Tournez à gauche$road',
        'right' || 'sharp right' || 'slight right' => 'Tournez à droite$road',
        'uturn' => 'Faites demi-tour$road',
        'straight' => 'Continuez tout droit$road',
        _ => 'Continuez$road',
      },
    };
  }

  void close() => _network.close();

  void dispose() => close();
}
