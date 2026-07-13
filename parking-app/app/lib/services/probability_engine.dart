import 'dart:math' as math;

import '../models/street_segment.dart';

/// Moteur heuristique d'estimation de la probabilité de place libre.
///
/// Modèle : pour un tronçon de capacité `c` et un taux d'occupation `rho`,
/// P(au moins une place libre) = 1 - rho^c.
///
/// Le taux d'occupation est estimé à partir de profils horaires par type de
/// rue (résidentiel / mixte / commerçant), calibrés sur les courbes types de
/// la littérature (SFpark, Melbourne). Ce moteur est volontairement
/// déterministe et sans réseau : il constitue le "prior" qui sera plus tard
/// affiné par l'historique réel et les signalements temps réel.
class ProbabilityEngine {
  const ProbabilityEngine();

  /// Longueur moyenne d'une place en créneau (m).
  static const double meterPerSpot = 5.5;

  /// Part de la longueur d'un tronçon réellement utilisable pour se garer
  /// (entrées charretières, intersections, passages piétons...).
  static const double usableFraction = 0.65;

  /// Facteur de « trouvabilité » : en pratique, une seule place théoriquement
  /// libre ne suffit pas (on la rate, elle est mal placée, occupée à l'arrivée…).
  /// On divise la capacité effective par ce facteur : le modèle devient plus
  /// conservateur et surtout plus sensible à l'heure (évite la saturation à
  /// ~100 % qui rendait le curseur d'heure sans effet).
  static const double findabilityFactor = 2.5;

  /// Profil d'occupation par heure (0-23) pour une rue résidentielle :
  /// saturée la nuit, se libère en journée.
  static const List<double> _residentialProfile = [
    0.97, 0.97, 0.97, 0.97, 0.96, 0.95, 0.92, 0.86, // 0h-7h
    0.78, 0.72, 0.70, 0.72, 0.74, 0.72, 0.70, 0.72, // 8h-15h
    0.75, 0.80, 0.88, 0.93, 0.95, 0.96, 0.97, 0.97, // 16h-23h
  ];

  /// Profil pour une rue mixte / animée : pic en journée et en soirée.
  static const List<double> _mixedProfile = [
    0.80, 0.78, 0.76, 0.75, 0.75, 0.78, 0.82, 0.87, // 0h-7h
    0.92, 0.95, 0.96, 0.96, 0.95, 0.94, 0.94, 0.95, // 8h-15h
    0.95, 0.94, 0.93, 0.94, 0.93, 0.90, 0.86, 0.82, // 16h-23h
  ];

  /// Estime la capacité de stationnement d'un tronçon.
  int estimateCapacity(StreetSegment s) {
    if (s.parkingForbidden) return 0;

    // Nombre de côtés stationnables : explicite via les tags OSM sinon
    // heuristique (double sens résidentiel = souvent 2 côtés, sens unique
    // ou axe important = 1 côté).
    final sides = s.parkingSides ??
        ((s.isOneWay || s.highwayType == 'secondary' || s.highwayType == 'primary')
            ? 1
            : 2);
    if (sides == 0) return 0;

    final spots =
        (s.lengthMeters * usableFraction / meterPerSpot).floor() * sides;
    return math.max(0, spots);
  }

  /// Taux d'occupation estimé d'un tronçon à une heure donnée.
  double estimateOccupancy(StreetSegment s, DateTime when) {
    final residential =
        s.highwayType == 'residential' || s.highwayType == 'living_street';
    final profile = residential ? _residentialProfile : _mixedProfile;
    var occ = profile[when.hour];

    // Le week-end : les rues résidentielles restent pleines en journée,
    // les zones mixtes sont plus chargées le samedi et plus calmes le dimanche.
    if (when.weekday == DateTime.saturday) {
      occ = residential ? occ + 0.05 : occ + 0.02;
    } else if (when.weekday == DateTime.sunday) {
      occ = residential ? occ + 0.06 : occ - 0.08;
    }

    // Les axes importants tournent plus (arrêts courts) : occupation
    // légèrement moindre à capacité égale.
    if (s.highwayType == 'secondary' || s.highwayType == 'tertiary') {
      occ -= 0.03;
    }

    return occ.clamp(0.05, 0.995);
  }

  /// Évalue un tronçon : capacité, occupation et probabilité de place libre.
  ScoredSegment score(StreetSegment s, DateTime when) {
    final capacity = estimateCapacity(s);
    final occupancy = estimateOccupancy(s, when);
    // P(place trouvable) = 1 - occupation^(capacité effective).
    final effectiveCapacity = capacity / findabilityFactor;
    final pFree = capacity == 0
        ? 0.0
        : 1.0 - math.pow(occupancy, effectiveCapacity).toDouble();
    return ScoredSegment(
      segment: s,
      capacity: capacity,
      occupancy: occupancy,
      probabilityFree: pFree.clamp(0.0, 1.0),
    );
  }

  List<ScoredSegment> scoreAll(Iterable<StreetSegment> segments, DateTime when) {
    return [for (final s in segments) score(s, when)];
  }
}
