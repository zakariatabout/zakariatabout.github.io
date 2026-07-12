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
          points[i].latitude + (points[i + 1].latitude - points[i].latitude) * f,
          points[i].longitude +
              (points[i + 1].longitude - points[i].longitude) * f,
        );
      }
      acc += d;
    }
    return points[points.length ~/ 2];
  }

  /// Distance minimale du tronçon à un point, en mètres.
  double distanceTo(LatLng p) {
    var best = double.infinity;
    for (final pt in points) {
      final d = _distance(pt, p);
      if (d < best) best = d;
    }
    return best;
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
