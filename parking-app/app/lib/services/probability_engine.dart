import 'dart:math' as math;

import '../models/availability_estimate.dart';
import '../models/street_segment.dart';
import 'probability_calibrator.dart';

/// Moteur heuristique d'estimation de la probabilité de place libre.
///
/// Ce moteur déterministe constitue un prior explicite, et non une vérité
/// terrain. Il conserve l'API historique [score], mais [estimateAvailability]
/// expose aussi l'incertitude, la fraîcheur et les versions nécessaires pour
/// auditer la prédiction.
class ProbabilityEngine {
  const ProbabilityEngine({
    this.calibrator = const IdentityProbabilityCalibrator(),
  });

  /// Étape de calibration injectable. Par défaut, l'identité signale
  /// explicitement qu'aucune calibration supervisée n'est disponible.
  final ProbabilityCalibrator calibrator;

  static const String modelVersion = 'heuristic-paris-hourly-v3';
  static const String defaultDataVersion = 'paris-inventory-hourly-prior-v3';
  static const Duration defaultValidity = Duration(minutes: 15);

  /// Longueur moyenne d'une place en créneau (m).
  static const double meterPerSpot = 5.5;

  /// Part de la longueur d'un tronçon réellement utilisable pour se garer
  /// (entrées charretières, intersections, passages piétons...).
  static const double usableFraction = 0.65;

  /// Échelle de rendement décroissant de la capacité.
  ///
  /// Une longue géométrie sans capacité déclarée ne représente pas autant d'occasions
  /// indépendantes qu'elle contient de places théoriques : interdictions
  /// locales, rotation et arrivée future sont corrélées. Cette échelle évite
  /// donc que les longs tronçons saturent artificiellement près de 100 %.
  ///
  /// Relevée de 2.5 à 4.0 après l'audit de crédibilité : en conditions
  /// réelles, seules 5 à 10 places d'une longue rue sont des occasions
  /// réellement décorrélées, et l'écart affiché entre une rue courte et une
  /// rue longue devenait invraisemblable en soirée.
  static const double findabilityFactor = 4.0;

  /// Profil d'occupation par heure (0-23) pour une rue résidentielle
  /// parisienne. Calé sur les enquêtes de rotation : saturée la nuit,
  /// creux modéré en journée (le stationnement payant limite les pendulaires),
  /// remontée dès 17-18h avec le retour des résidents — le stationnement
  /// devient gratuit à 20h, donc la rue est déjà presque pleine à 20h.
  static const List<double> _residentialProfile = [
    0.97, 0.97, 0.97, 0.97, 0.97, 0.96, 0.95, 0.92, // 0h-7h
    0.87, 0.82, 0.78, 0.77, 0.78, 0.78, 0.77, 0.77, // 8h-15h
    0.79, 0.84, 0.89, 0.93, 0.96, 0.97, 0.97, 0.97, // 16h-23h
  ];

  /// Profil pour une rue mixte / animée (commerces, restaurants) : deux pics
  /// (déjeuner et surtout dîner 19-21h, quand résidents et visiteurs se
  /// disputent les mêmes places), creux relatif en milieu de matinée et
  /// d'après-midi grâce à la rotation des places payantes.
  static const List<double> _mixedProfile = [
    0.93, 0.90, 0.88, 0.87, 0.87, 0.87, 0.86, 0.84, // 0h-7h
    0.82, 0.80, 0.82, 0.86, 0.90, 0.90, 0.85, 0.82, // 8h-15h
    0.82, 0.86, 0.91, 0.95, 0.96, 0.95, 0.93, 0.93, // 16h-23h
  ];

  /// Estime la capacité de stationnement d'un tronçon.
  int estimateCapacity(StreetSegment s) {
    if (s.parkingForbidden) return 0;
    if (s.knownCapacity != null) return math.max(0, s.knownCapacity!);

    // Pour les seuls segments sans capacité déclarée : nombre de côtés
    // stationnables explicite via les tags OSM, sinon
    // heuristique (double sens résidentiel = souvent 2 côtés, sens unique
    // ou axe important = 1 côté).
    final sides =
        s.parkingSides ??
        ((s.isOneWay ||
                s.highwayType == 'secondary' ||
                s.highwayType == 'primary')
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

    // Le week-end : le dimanche le stationnement est gratuit, les voitures
    // résidentes ne bougent presque pas ; les zones mixtes respirent, sauf au
    // déjeuner. Le samedi, tout est plus chargé (courses, visites).
    if (when.weekday == DateTime.saturday) {
      occ = residential ? occ + 0.04 : occ + 0.03;
    } else if (when.weekday == DateTime.sunday) {
      if (residential) {
        occ = math.max(occ, 0.95);
      } else {
        occ -= 0.06;
        if (when.hour >= 12 && when.hour <= 14) occ += 0.06;
      }
    }

    // Vendredi et samedi en début de soirée (18-20h) : retour des résidents
    // et sorties simultanés, la pression monte encore d'un cran.
    if (residential &&
        (when.weekday == DateTime.friday ||
            when.weekday == DateTime.saturday) &&
        when.hour >= 18 &&
        when.hour <= 20) {
      occ += 0.02;
    }

    // Les axes importants tournent plus (arrêts courts) : occupation
    // légèrement moindre à capacité égale.
    if (s.highwayType == 'secondary' || s.highwayType == 'tertiary') {
      occ -= 0.03;
    }

    return occ.clamp(0.05, 0.995);
  }

  /// Nombre d'occasions indépendantes retenu par le prior.
  ///
  /// Il croît avec la capacité, mais de manière logarithmique. C'est une
  /// hypothèse conservatrice et monotone, destinée à être remplacée ou
  /// réajustée dès que des labels locaux représentatifs sont disponibles.
  double effectiveOpportunityCount(int capacity) {
    if (capacity <= 0) return 0;
    return 1.0 + math.log(1.0 + (capacity - 1) / findabilityFactor);
  }

  /// Probabilité brute avant calibration.
  ///
  /// Cette méthode publique rend la fonction déterministe directement
  /// testable. La valeur finale destinée au produit reste celle de
  /// [estimateAvailability], qui applique la calibration et les garde-fous.
  double estimateRawAvailability({
    required int capacity,
    required num occupancy,
  }) {
    if (capacity <= 0) return 0;
    final boundedOccupancy = ProbabilityBounds.clamp(occupancy);
    final effectiveOpportunities = effectiveOpportunityCount(capacity);
    final probability =
        1.0 - math.pow(boundedOccupancy, effectiveOpportunities).toDouble();
    return ProbabilityBounds.clamp(probability);
  }

  /// Produit une estimation bornée, versionnée et accompagnée d'incertitude.
  ///
  /// [dataAsOf] doit être renseigné par l'appelant quand les tronçons viennent
  /// d'un cache. À défaut, le moteur suppose qu'ils viennent d'être acquis.
  AvailabilityEstimate estimateAvailability(
    StreetSegment segment,
    DateTime when, {
    DateTime? generatedAt,
    DateTime? dataAsOf,
    Duration validFor = defaultValidity,
    String dataVersion = defaultDataVersion,
  }) {
    final producedAt = (generatedAt ?? DateTime.now()).toUtc();
    final sourceAsOf = (dataAsOf ?? producedAt).toUtc();
    final capacity = estimateCapacity(segment);
    final occupancy = estimateOccupancy(segment, when);
    final rawProbability = estimateRawAvailability(
      capacity: capacity,
      occupancy: occupancy,
    );
    final calibrated = calibrator.calibrate(rawProbability);
    // Une calibration globale ne peut pas rendre disponible un tronçon où
    // aucun emplacement compatible n'est estimé.
    final probability = capacity == 0 ? 0.0 : calibrated.probability;
    final confidence = _confidenceFor(
      segment,
      calibrated.supervisedObservationCount,
    );
    final halfWidth = _intervalHalfWidth(confidence);

    return AvailabilityEstimate(
      probability: probability,
      interval: ProbabilityInterval(
        lower: probability - halfWidth,
        upper: probability + halfWidth,
      ),
      confidence: confidence,
      predictionFor: when,
      generatedAt: producedAt,
      dataAsOf: sourceAsOf,
      validFor: validFor,
      versions: PredictionVersions(
        model: modelVersion,
        data: dataVersion,
        calibration: calibrated.version,
      ),
      supervisedObservationCount: calibrated.supervisedObservationCount,
    );
  }

  /// Évalue un tronçon : capacité, occupation et probabilité de place libre.
  ScoredSegment score(StreetSegment s, DateTime when) {
    final capacity = estimateCapacity(s);
    final occupancy = estimateOccupancy(s, when);
    final rawProbability = estimateRawAvailability(
      capacity: capacity,
      occupancy: occupancy,
    );
    final calibrated = calibrator.calibrate(rawProbability);
    final probability = capacity == 0 ? 0.0 : calibrated.probability;
    return ScoredSegment(
      segment: s,
      capacity: capacity,
      occupancy: occupancy,
      probabilityFree: ProbabilityBounds.clamp(
        probability,
        maximum: calibrated.supervisedObservationCount > 0
            ? 1.0
            : AvailabilityEstimate.maxUnsupervisedProbability,
      ),
    );
  }

  List<ScoredSegment> scoreAll(
    Iterable<StreetSegment> segments,
    DateTime when,
  ) {
    return [for (final s in segments) score(s, when)];
  }

  AvailabilityConfidence _confidenceFor(
    StreetSegment segment,
    int supervisedObservationCount,
  ) {
    if (supervisedObservationCount == 0) {
      return segment.parkingSides == null
          ? AvailabilityConfidence.veryLow
          : AvailabilityConfidence.low;
    }
    if (supervisedObservationCount < 500) {
      return AvailabilityConfidence.low;
    }
    // Une calibration globale, même bien alimentée, ne suffit pas à déclarer
    // une confiance haute sans observations récentes au niveau du tronçon.
    return AvailabilityConfidence.medium;
  }

  double _intervalHalfWidth(AvailabilityConfidence confidence) {
    return switch (confidence) {
      AvailabilityConfidence.veryLow => 0.30,
      AvailabilityConfidence.low => 0.22,
      AvailabilityConfidence.medium => 0.14,
      AvailabilityConfidence.high => 0.08,
    };
  }
}
