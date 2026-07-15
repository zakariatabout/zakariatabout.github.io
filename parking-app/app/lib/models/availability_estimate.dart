/// Niveau de confiance attaché à une estimation de disponibilité.
///
/// La confiance décrit la qualité des données et de la calibration, pas la
/// valeur de la probabilité. Une probabilité élevée peut donc avoir une
/// confiance faible.
enum AvailabilityConfidence { veryLow, low, medium, high }

/// Fraîcheur des données qui ont servi à produire une estimation.
enum AvailabilityFreshness { live, recent, stale, expired }

/// Intervalle probabiliste borné et immuable.
class ProbabilityInterval {
  factory ProbabilityInterval({required num lower, required num upper}) {
    var boundedLower = ProbabilityBounds.clamp(lower);
    var boundedUpper = ProbabilityBounds.clamp(upper);
    if (boundedLower > boundedUpper) {
      final previousLower = boundedLower;
      boundedLower = boundedUpper;
      boundedUpper = previousLower;
    }
    return ProbabilityInterval._(boundedLower, boundedUpper);
  }

  const ProbabilityInterval._(this.lower, this.upper);

  final double lower;
  final double upper;

  double get width => upper - lower;

  bool contains(num value) {
    final candidate = value.toDouble();
    if (!candidate.isFinite) return false;
    return candidate >= lower && candidate <= upper;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProbabilityInterval &&
          lower == other.lower &&
          upper == other.upper;

  @override
  int get hashCode => Object.hash(lower, upper);

  @override
  String toString() => 'ProbabilityInterval($lower, $upper)';
}

/// Versions nécessaires pour reproduire et auditer une prédiction.
class PredictionVersions {
  factory PredictionVersions({
    required String model,
    required String data,
    required String calibration,
  }) {
    final normalizedModel = _requireVersion('model', model);
    final normalizedData = _requireVersion('data', data);
    final normalizedCalibration = _requireVersion('calibration', calibration);
    return PredictionVersions._(
      model: normalizedModel,
      data: normalizedData,
      calibration: normalizedCalibration,
    );
  }

  const PredictionVersions._({
    required this.model,
    required this.data,
    required this.calibration,
  });

  final String model;
  final String data;
  final String calibration;

  static String _requireVersion(String field, String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        value,
        field,
        'La version ne peut pas être vide',
      );
    }
    return normalized;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PredictionVersions &&
          model == other.model &&
          data == other.data &&
          calibration == other.calibration;

  @override
  int get hashCode => Object.hash(model, data, calibration);

  @override
  String toString() =>
      'PredictionVersions(model: $model, data: $data, '
      'calibration: $calibration)';
}

/// Estimation de disponibilité probabiliste, versionnée et immuable.
///
/// Une estimation sans aucune observation supervisée est volontairement
/// plafonnée sous 100 %. Ce garde-fou empêche un prior heuristique d'être
/// présenté comme une certitude.
class AvailabilityEstimate {
  factory AvailabilityEstimate({
    required num probability,
    required ProbabilityInterval interval,
    required AvailabilityConfidence confidence,
    required DateTime predictionFor,
    required DateTime generatedAt,
    required DateTime dataAsOf,
    required Duration validFor,
    required PredictionVersions versions,
    int supervisedObservationCount = 0,
  }) {
    if (supervisedObservationCount < 0) {
      throw ArgumentError.value(
        supervisedObservationCount,
        'supervisedObservationCount',
        'Le nombre d observations doit être positif ou nul',
      );
    }
    if (validFor <= Duration.zero) {
      throw ArgumentError.value(
        validFor,
        'validFor',
        'La durée de validité doit être strictement positive',
      );
    }

    final generatedUtc = generatedAt.toUtc();
    final dataUtc = dataAsOf.toUtc();
    if (dataUtc.isAfter(generatedUtc)) {
      throw ArgumentError.value(
        dataAsOf,
        'dataAsOf',
        'Les données ne peuvent pas être postérieures à la prédiction',
      );
    }

    final hasSupervisedEvidence = supervisedObservationCount > 0;
    final maximum = hasSupervisedEvidence ? 1.0 : maxUnsupervisedProbability;
    final boundedProbability = ProbabilityBounds.clamp(
      probability,
      maximum: maximum,
    );
    final boundedLower = ProbabilityBounds.clamp(
      interval.lower,
      maximum: boundedProbability,
    );
    final boundedUpper = ProbabilityBounds.clamp(
      interval.upper,
      maximum: maximum,
    ).clamp(boundedProbability, maximum).toDouble();

    return AvailabilityEstimate._(
      probability: boundedProbability,
      interval: ProbabilityInterval(lower: boundedLower, upper: boundedUpper),
      confidence: confidence,
      predictionFor: predictionFor.toUtc(),
      generatedAt: generatedUtc,
      dataAsOf: dataUtc,
      validFor: validFor,
      versions: versions,
      supervisedObservationCount: supervisedObservationCount,
    );
  }

  const AvailabilityEstimate._({
    required this.probability,
    required this.interval,
    required this.confidence,
    required this.predictionFor,
    required this.generatedAt,
    required this.dataAsOf,
    required this.validFor,
    required this.versions,
    required this.supervisedObservationCount,
  });

  /// Plafond produit pour une estimation qui ne repose que sur un prior.
  static const double maxUnsupervisedProbability = 0.95;

  final double probability;
  final ProbabilityInterval interval;
  final AvailabilityConfidence confidence;
  final DateTime predictionFor;
  final DateTime generatedAt;
  final DateTime dataAsOf;
  final Duration validFor;
  final PredictionVersions versions;
  final int supervisedObservationCount;

  bool get hasSupervisedEvidence => supervisedObservationCount > 0;

  /// Recalibre le point estimé après un garde-fou produit (éligibilité,
  /// signal communautaire…) sans perdre les métadonnées d'audit.
  ///
  /// Sans intervalle explicite, l'intervalle initial est translaté du même
  /// delta que le point. L'appelant peut fournir `[0, 0]` lorsqu'une règle
  /// déterministe rend le tronçon inéligible.
  AvailabilityEstimate withProbability(
    num value, {
    ProbabilityInterval? interval,
  }) {
    final delta = value.toDouble() - probability;
    final adjustedInterval =
        interval ??
        ProbabilityInterval(
          lower: this.interval.lower + delta,
          upper: this.interval.upper + delta,
        );
    return AvailabilityEstimate(
      probability: value,
      interval: adjustedInterval,
      confidence: confidence,
      predictionFor: predictionFor,
      generatedAt: generatedAt,
      dataAsOf: dataAsOf,
      validFor: validFor,
      versions: versions,
      supervisedObservationCount: supervisedObservationCount,
    );
  }

  DateTime get expiresAt => dataAsOf.add(validFor);

  Duration ageAt(DateTime now) {
    final age = now.toUtc().difference(dataAsOf);
    return age.isNegative ? Duration.zero : age;
  }

  bool isFreshAt(DateTime now) {
    final instant = now.toUtc();
    return instant.isBefore(expiresAt) || instant.isAtSameMomentAs(expiresAt);
  }

  AvailabilityFreshness freshnessAt(DateTime now) {
    final ageMicros = ageAt(now).inMicroseconds;
    final validityMicros = validFor.inMicroseconds;
    if (ageMicros <= validityMicros ~/ 3) {
      return AvailabilityFreshness.live;
    }
    if (ageMicros <= validityMicros) {
      return AvailabilityFreshness.recent;
    }
    if (ageMicros <= validityMicros * 2) {
      return AvailabilityFreshness.stale;
    }
    return AvailabilityFreshness.expired;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AvailabilityEstimate &&
          probability == other.probability &&
          interval == other.interval &&
          confidence == other.confidence &&
          predictionFor == other.predictionFor &&
          generatedAt == other.generatedAt &&
          dataAsOf == other.dataAsOf &&
          validFor == other.validFor &&
          versions == other.versions &&
          supervisedObservationCount == other.supervisedObservationCount;

  @override
  int get hashCode => Object.hash(
    probability,
    interval,
    confidence,
    predictionFor,
    generatedAt,
    dataAsOf,
    validFor,
    versions,
    supervisedObservationCount,
  );

  @override
  String toString() =>
      'AvailabilityEstimate(probability: $probability, interval: $interval, '
      'confidence: $confidence, freshness: ${freshnessAt(generatedAt)}, '
      'versions: $versions)';
}

/// Utilitaire partagé pour empêcher NaN et les valeurs hors de [0, 1].
abstract final class ProbabilityBounds {
  static double clamp(num value, {double maximum = 1.0}) {
    var boundedMaximum = 0.0;
    if (maximum == double.infinity) {
      boundedMaximum = 1.0;
    } else if (maximum.isFinite) {
      boundedMaximum = maximum.clamp(0.0, 1.0).toDouble();
    }
    final candidate = value.toDouble();
    if (candidate.isNaN || candidate == double.negativeInfinity) return 0;
    if (candidate == double.infinity) return boundedMaximum;
    return candidate.clamp(0.0, boundedMaximum).toDouble();
  }
}
