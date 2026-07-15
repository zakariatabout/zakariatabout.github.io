import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/models/availability_estimate.dart';

final generatedAt = DateTime.utc(2026, 7, 15, 12);
final versions = PredictionVersions(
  model: 'model-v1',
  data: 'data-v1',
  calibration: 'calibration-v1',
);

AvailabilityEstimate estimate({
  num probability = 0.5,
  ProbabilityInterval? interval,
  int supervisedObservationCount = 0,
  Duration validFor = const Duration(minutes: 10),
  DateTime? dataAsOf,
}) {
  return AvailabilityEstimate(
    probability: probability,
    interval: interval ?? ProbabilityInterval(lower: 0.3, upper: 0.7),
    confidence: AvailabilityConfidence.low,
    predictionFor: generatedAt.add(const Duration(minutes: 5)),
    generatedAt: generatedAt,
    dataAsOf: dataAsOf ?? generatedAt,
    validFor: validFor,
    versions: versions,
    supervisedObservationCount: supervisedObservationCount,
  );
}

void main() {
  group('ProbabilityBounds', () {
    test('borne toutes les valeurs dans l intervalle demandé', () {
      expect(ProbabilityBounds.clamp(-0.2), 0);
      expect(ProbabilityBounds.clamp(0.4), 0.4);
      expect(ProbabilityBounds.clamp(1.2), 1);
      expect(ProbabilityBounds.clamp(0.8, maximum: 0.6), 0.6);
      expect(ProbabilityBounds.clamp(0.8, maximum: -1), 0);
      expect(ProbabilityBounds.clamp(0.8, maximum: double.nan), 0);
      expect(ProbabilityBounds.clamp(0.8, maximum: double.infinity), 0.8);
    });

    test('neutralise NaN et les infinis', () {
      expect(ProbabilityBounds.clamp(double.nan), 0);
      expect(ProbabilityBounds.clamp(double.negativeInfinity), 0);
      expect(ProbabilityBounds.clamp(double.infinity), 1);
      expect(ProbabilityBounds.clamp(double.infinity, maximum: 0.95), 0.95);
    });
  });

  group('ProbabilityInterval', () {
    test('borne et remet dans l ordre des extrémités inversées', () {
      final interval = ProbabilityInterval(lower: 1.4, upper: -0.2);

      expect(interval.lower, 0);
      expect(interval.upper, 1);
      expect(interval.width, 1);
      expect(interval.contains(0.5), isTrue);
      expect(interval.contains(1.2), isFalse);
      expect(interval.contains(double.nan), isFalse);
    });

    test('est un objet valeur immuable', () {
      final first = ProbabilityInterval(lower: 0.2, upper: 0.8);
      final second = ProbabilityInterval(lower: 0.2, upper: 0.8);

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.toString(), contains('0.2'));
    });
  });

  group('PredictionVersions', () {
    test('normalise les espaces et compare les valeurs', () {
      final normalized = PredictionVersions(
        model: ' model-v1 ',
        data: ' data-v1 ',
        calibration: ' calibration-v1 ',
      );

      expect(normalized, versions);
    });

    test('refuse une version vide', () {
      expect(
        () => PredictionVersions(
          model: ' ',
          data: 'data-v1',
          calibration: 'calibration-v1',
        ),
        throwsArgumentError,
      );
    });
  });

  group('AvailabilityEstimate', () {
    test('ne présente jamais un prior non supervisé comme une certitude', () {
      final result = estimate(
        probability: 1,
        interval: ProbabilityInterval(lower: 0.8, upper: 1),
      );

      expect(
        result.probability,
        AvailabilityEstimate.maxUnsupervisedProbability,
      );
      expect(
        result.interval.upper,
        AvailabilityEstimate.maxUnsupervisedProbability,
      );
      expect(result.hasSupervisedEvidence, isFalse);
    });

    test('autorise 100 % uniquement avec une observation supervisée', () {
      final result = estimate(
        probability: 1,
        interval: ProbabilityInterval(lower: 0.8, upper: 1),
        supervisedObservationCount: 1,
      );

      expect(result.probability, 1);
      expect(result.interval.upper, 1);
      expect(result.hasSupervisedEvidence, isTrue);
    });

    test('normalise l intervalle pour qu il contienne toujours le point', () {
      final above = estimate(
        probability: 0.5,
        interval: ProbabilityInterval(lower: 0.7, upper: 0.9),
      );
      final below = estimate(
        probability: 0.5,
        interval: ProbabilityInterval(lower: 0.1, upper: 0.2),
      );

      expect(above.interval.contains(above.probability), isTrue);
      expect(above.interval.lower, 0.5);
      expect(below.interval.contains(below.probability), isTrue);
      expect(below.interval.upper, 0.5);
    });

    test('ajuste le point sans perdre les métadonnées d audit', () {
      final original = estimate(
        probability: 0.5,
        interval: ProbabilityInterval(lower: 0.3, upper: 0.7),
        dataAsOf: generatedAt.subtract(const Duration(minutes: 2)),
      );

      final adjusted = original.withProbability(0.6);

      expect(adjusted.probability, closeTo(0.6, 1e-12));
      expect(adjusted.interval.lower, closeTo(0.4, 1e-12));
      expect(adjusted.interval.upper, closeTo(0.8, 1e-12));
      expect(adjusted.confidence, original.confidence);
      expect(adjusted.predictionFor, original.predictionFor);
      expect(adjusted.generatedAt, original.generatedAt);
      expect(adjusted.dataAsOf, original.dataAsOf);
      expect(adjusted.validFor, original.validFor);
      expect(adjusted.versions, original.versions);
    });

    test('accepte un intervalle nul après exclusion réglementaire', () {
      final adjusted = estimate().withProbability(
        0,
        interval: ProbabilityInterval(lower: 0, upper: 0),
      );

      expect(adjusted.probability, 0);
      expect(adjusted.interval, ProbabilityInterval(lower: 0, upper: 0));
    });

    test('classe la fraîcheur aux seuils attendus', () {
      final result = estimate();

      expect(
        result.freshnessAt(generatedAt.add(const Duration(minutes: 2))),
        AvailabilityFreshness.live,
      );
      expect(
        result.freshnessAt(generatedAt.add(const Duration(minutes: 7))),
        AvailabilityFreshness.recent,
      );
      expect(
        result.freshnessAt(generatedAt.add(const Duration(minutes: 15))),
        AvailabilityFreshness.stale,
      );
      expect(
        result.freshnessAt(generatedAt.add(const Duration(minutes: 21))),
        AvailabilityFreshness.expired,
      );
    });

    test('considère le seuil de validité comme encore frais', () {
      final result = estimate();

      expect(result.expiresAt, generatedAt.add(const Duration(minutes: 10)));
      expect(result.isFreshAt(result.expiresAt), isTrue);
      expect(
        result.isFreshAt(result.expiresAt.add(const Duration(microseconds: 1))),
        isFalse,
      );
      expect(
        result.ageAt(generatedAt.subtract(const Duration(minutes: 1))),
        Duration.zero,
      );
    });

    test('refuse les métadonnées temporelles incohérentes', () {
      expect(() => estimate(validFor: Duration.zero), throwsArgumentError);
      expect(
        () => estimate(dataAsOf: generatedAt.add(const Duration(seconds: 1))),
        throwsArgumentError,
      );
      expect(
        () => estimate(supervisedObservationCount: -1),
        throwsArgumentError,
      );
    });

    test('est un objet valeur et stocke les dates en UTC', () {
      final first = estimate();
      final second = estimate();

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.generatedAt.isUtc, isTrue);
      expect(first.predictionFor.isUtc, isTrue);
      expect(first.dataAsOf.isUtc, isTrue);
    });
  });
}
