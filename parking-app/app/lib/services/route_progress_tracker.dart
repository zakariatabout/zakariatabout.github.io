import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'routing_service.dart';

class RouteProgressSnapshot {
  const RouteProgressSnapshot({
    required this.alongRouteMeters,
    required this.distanceToRouteMeters,
    required this.stepIndex,
  });

  final double alongRouteMeters;
  final double distanceToRouteMeters;
  final int stepIndex;
}

/// Suit une position par projection sur la géométrie OSRM.
///
/// La progression reste monotone : un saut GPS après une manœuvre fait avancer
/// le HUD, tandis qu'un échantillon légèrement en arrière ne restaure pas une
/// instruction déjà dépassée. Cette logique est plus robuste qu'un simple
/// rayon autour du point de manœuvre, notamment lorsque l'origine OSRM est
/// décalée ou qu'un échantillon manque au niveau d'un virage.
class RouteProgressTracker {
  RouteProgressTracker({
    this.maneuverAdvanceMeters = 35,
    this.allowedBacktrackMeters = 30,
  });

  final double maneuverAdvanceMeters;
  final double allowedBacktrackMeters;

  static const Distance _distance = Distance();

  DrivingRoute? _route;
  List<double> _stepOffsets = const [];
  double _alongRouteMeters = 0;
  int _stepIndex = 0;

  void reset() {
    _route = null;
    _stepOffsets = const [];
    _alongRouteMeters = 0;
    _stepIndex = 0;
  }

  RouteProgressSnapshot update(DrivingRoute route, LatLng position) {
    if (!identical(_route, route)) _resetForRoute(route);
    final projection = _project(
      route.points,
      position,
      minimumAlongMeters: math.max(
        0,
        _alongRouteMeters - allowedBacktrackMeters,
      ),
      referenceAlongMeters: _alongRouteMeters,
    );
    _alongRouteMeters = math.max(
      _alongRouteMeters,
      projection.alongRouteMeters,
    );

    while (_stepIndex < _stepOffsets.length - 1 &&
        _alongRouteMeters + maneuverAdvanceMeters >= _stepOffsets[_stepIndex]) {
      _stepIndex++;
    }
    return RouteProgressSnapshot(
      alongRouteMeters: _alongRouteMeters,
      distanceToRouteMeters: projection.distanceToRouteMeters,
      stepIndex: _stepIndex,
    );
  }

  void _resetForRoute(DrivingRoute route) {
    _route = route;
    _alongRouteMeters = 0;
    _stepIndex = 0;
    final offsets = <double>[];
    var minimum = 0.0;
    for (final step in route.steps) {
      final projected = _project(
        route.points,
        step.location,
        minimumAlongMeters: math.max(0, minimum - allowedBacktrackMeters),
        referenceAlongMeters: minimum,
      );
      final offset = math.max(minimum, projected.alongRouteMeters);
      offsets.add(offset);
      minimum = offset;
    }
    _stepOffsets = offsets;
  }

  _RouteProjection _project(
    List<LatLng> points,
    LatLng position, {
    required double minimumAlongMeters,
    required double referenceAlongMeters,
  }) {
    if (points.length < 2) {
      return const _RouteProjection(
        alongRouteMeters: 0,
        distanceToRouteMeters: double.infinity,
      );
    }

    const earthRadiusMeters = 6371000.0;
    final radians = math.pi / 180;
    final cosLatitude = math
        .cos(position.latitude * radians)
        .abs()
        .clamp(1e-6, 1.0);
    double x(LatLng point) =>
        (point.longitude - position.longitude) *
        radians *
        earthRadiusMeters *
        cosLatitude;
    double y(LatLng point) =>
        (point.latitude - position.latitude) * radians * earthRadiusMeters;

    var bestDistanceSquared = double.infinity;
    var bestAlong = minimumAlongMeters;
    var bestReferenceDelta = double.infinity;
    var cumulative = 0.0;
    for (var index = 0; index < points.length - 1; index++) {
      final a = points[index];
      final b = points[index + 1];
      final length = _distance(a, b);
      final segmentEnd = cumulative + length;
      if (segmentEnd + allowedBacktrackMeters < minimumAlongMeters) {
        cumulative = segmentEnd;
        continue;
      }

      final ax = x(a);
      final ay = y(a);
      final bx = x(b);
      final by = y(b);
      final dx = bx - ax;
      final dy = by - ay;
      final squaredLength = dx * dx + dy * dy;
      final fraction = squaredLength == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / squaredLength).clamp(0.0, 1.0);
      final projectedAlong = cumulative + length * fraction;
      if (projectedAlong + allowedBacktrackMeters < minimumAlongMeters) {
        cumulative = segmentEnd;
        continue;
      }
      final qx = ax + fraction * dx;
      final qy = ay + fraction * dy;
      final distanceSquared = qx * qx + qy * qy;
      final distanceMeters = math.sqrt(distanceSquared);
      final bestDistanceMeters = math.sqrt(bestDistanceSquared);
      final referenceDelta = (projectedAlong - referenceAlongMeters).abs();
      // Aux croisements et au point commun d'une boucle, plusieurs segments
      // peuvent être presque équidistants. On choisit alors l'abscisse la plus
      // proche de la progression connue au lieu de sauter arbitrairement vers
      // la fin de l'itinéraire.
      final clearlyCloser = distanceMeters + 8 < bestDistanceMeters;
      final sameCorridor =
          (distanceMeters - bestDistanceMeters).abs() <= 8 &&
          referenceDelta < bestReferenceDelta;
      if (clearlyCloser || sameCorridor) {
        bestDistanceSquared = distanceSquared;
        bestAlong = projectedAlong;
        bestReferenceDelta = referenceDelta;
      }
      cumulative = segmentEnd;
    }

    return _RouteProjection(
      alongRouteMeters: bestAlong,
      distanceToRouteMeters: math.sqrt(bestDistanceSquared),
    );
  }
}

class _RouteProjection {
  const _RouteProjection({
    required this.alongRouteMeters,
    required this.distanceToRouteMeters,
  });

  final double alongRouteMeters;
  final double distanceToRouteMeters;
}
