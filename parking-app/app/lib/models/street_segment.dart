import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Un tronçon de rue candidat au stationnement.
class StreetSegment {
  StreetSegment({
    required this.id,
    required this.name,
    required this.highwayType,
    required this.points,
    this.isOneWay = false,
    this.parkingForbidden = false,
    this.parkingSides,
    this.knownCapacity,
    this.parkingSourceKey,
  });

  final int id;
  final String name;

  /// Valeur du tag OSM `highway` (residential, tertiary, ...).
  final String highwayType;
  final List<LatLng> points;
  final bool isOneWay;

  /// Vrai si les tags OSM indiquent explicitement l'interdiction de stationner.
  final bool parkingForbidden;

  /// Nombre de côtés où le stationnement est explicitement autorisé
  /// d'après les tags `parking:lane:*` (null si inconnu).
  final int? parkingSides;

  /// Capacité issue d'un référentiel officiel lorsqu'elle est connue.
  /// Le moteur ne la réestime alors pas à partir de la longueur OSM.
  final int? knownCapacity;

  /// Identifiant interne de l'enregistrement Paris Data ayant créé l'unité.
  ///
  /// Lorsqu'il est présent, le garde-fou réglementaire doit réutiliser ce
  /// même enregistrement plutôt qu'un emplacement voisin. Deux régimes
  /// différents peuvent en effet être inventoriés à quelques mètres l'un de
  /// l'autre sur une même bordure parisienne.
  final String? parkingSourceKey;

  static const Distance _distance = Distance();

  double? _lengthCache;

  /// Longueur du tronçon en mètres.
  double get lengthMeters {
    if (_lengthCache != null) return _lengthCache!;
    var total = 0.0;
    for (var i = 0; i < points.length - 1; i++) {
      total += _distance(points[i], points[i + 1]);
    }
    return _lengthCache = total;
  }

  /// Point médian approximatif du tronçon (pour le routage).
  LatLng get midpoint {
    final target = lengthMeters / 2;
    var acc = 0.0;
    for (var i = 0; i < points.length - 1; i++) {
      final d = _distance(points[i], points[i + 1]);
      if (acc + d >= target && d > 0) {
        final f = (target - acc) / d;
        return LatLng(
          points[i].latitude +
              (points[i + 1].latitude - points[i].latitude) * f,
          points[i].longitude +
              (points[i + 1].longitude - points[i].longitude) * f,
        );
      }
      acc += d;
    }
    return points[points.length ~/ 2];
  }

  /// Point de la polyligne le plus proche de [p].
  ///
  /// La projection équirectangulaire locale est suffisamment précise à
  /// l'échelle d'un quartier et, contrairement à une distance aux seuls
  /// sommets, associe correctement un signal situé au milieu d'une longue rue.
  LatLng nearestPointTo(LatLng p) {
    if (points.isEmpty) return p;
    if (points.length == 1) return points.first;

    const earthRadiusMeters = 6371000.0;
    final radians = math.pi / 180;
    final cosLatitude = math.cos(p.latitude * radians).abs().clamp(1e-6, 1.0);

    double x(LatLng point) =>
        (point.longitude - p.longitude) *
        radians *
        earthRadiusMeters *
        cosLatitude;
    double y(LatLng point) =>
        (point.latitude - p.latitude) * radians * earthRadiusMeters;

    var bestSquaredDistance = double.infinity;
    var bestX = 0.0;
    var bestY = 0.0;

    for (var i = 0; i < points.length - 1; i++) {
      final ax = x(points[i]);
      final ay = y(points[i]);
      final bx = x(points[i + 1]);
      final by = y(points[i + 1]);
      final dx = bx - ax;
      final dy = by - ay;
      final squaredLength = dx * dx + dy * dy;
      final projection = squaredLength == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / squaredLength).clamp(0.0, 1.0);
      final qx = ax + projection * dx;
      final qy = ay + projection * dy;
      final squaredDistance = qx * qx + qy * qy;
      if (squaredDistance < bestSquaredDistance) {
        bestSquaredDistance = squaredDistance;
        bestX = qx;
        bestY = qy;
      }
    }

    return LatLng(
      p.latitude + bestY / earthRadiusMeters / radians,
      p.longitude + bestX / (earthRadiusMeters * cosLatitude) / radians,
    );
  }

  /// Distance minimale réelle entre la polyligne et [p], en mètres.
  double distanceTo(LatLng p) => _distance(nearestPointTo(p), p);

  StreetSegment copyWith({
    int? id,
    String? name,
    String? highwayType,
    List<LatLng>? points,
    bool? isOneWay,
    bool? parkingForbidden,
    int? parkingSides,
    int? knownCapacity,
    String? parkingSourceKey,
  }) {
    return StreetSegment(
      id: id ?? this.id,
      name: name ?? this.name,
      highwayType: highwayType ?? this.highwayType,
      points: points ?? this.points,
      isOneWay: isOneWay ?? this.isOneWay,
      parkingForbidden: parkingForbidden ?? this.parkingForbidden,
      parkingSides: parkingSides ?? this.parkingSides,
      knownCapacity: knownCapacity ?? this.knownCapacity,
      parkingSourceKey: parkingSourceKey ?? this.parkingSourceKey,
    );
  }
}

/// Un tronçon évalué par le moteur de probabilité.
class ScoredSegment {
  ScoredSegment({
    required this.segment,
    required this.capacity,
    required this.occupancy,
    required this.probabilityFree,
  });

  final StreetSegment segment;

  /// Nombre estimé de places sur le tronçon.
  final int capacity;

  /// Taux d'occupation estimé (0..1).
  final double occupancy;

  /// Probabilité qu'au moins une place soit libre (0..1).
  final double probabilityFree;
}
