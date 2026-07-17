import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/models/availability_estimate.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/services/probability_calibrator.dart';
import 'package:parking_app/services/probability_engine.dart';

StreetSegment segment({
  int id = 1,
  String highway = 'residential',
  bool oneWay = false,
  bool forbidden = false,
  int? sides,
  int? knownCapacity,
  double lengthDegrees = 0.002, // ~220 m en longitude à Paris
}) {
  return StreetSegment(
    id: id,
    name: 'Rue de Test',
    highwayType: highway,
    isOneWay: oneWay,
    parkingForbidden: forbidden,
    parkingSides: sides,
    knownCapacity: knownCapacity,
    points: [
      const LatLng(48.8566, 2.3522),
      LatLng(48.8566, 2.3522 + lengthDegrees),
    ],
  );
}

void main() {
  const engine = ProbabilityEngine();
  // Mardi 11h et mardi 3h du matin.
  final tuesdayMorning = DateTime(2026, 7, 14, 11);
  final tuesdayNight = DateTime(2026, 7, 14, 3);

  group('estimateCapacity', () {
    test('rue interdite au stationnement -> capacité nulle', () {
      expect(engine.estimateCapacity(segment(forbidden: true)), 0);
    });

    test('rue à double sens compte deux côtés', () {
      final twoSides = engine.estimateCapacity(segment(oneWay: false));
      final oneSide = engine.estimateCapacity(segment(oneWay: true));
      expect(twoSides, greaterThan(oneSide));
      expect(twoSides, equals(oneSide * 2));
    });

    test('les tags parking:lane explicites priment sur l heuristique', () {
      expect(engine.estimateCapacity(segment(sides: 0)), 0);
      final one = engine.estimateCapacity(segment(sides: 1, oneWay: false));
      final two = engine.estimateCapacity(segment(sides: 2, oneWay: true));
      expect(two, equals(one * 2));
    });

    test('une rue plus longue a plus de places', () {
      final short = engine.estimateCapacity(segment(lengthDegrees: 0.001));
      final long = engine.estimateCapacity(segment(lengthDegrees: 0.003));
      expect(long, greaterThan(short));
    });

    test('une capacité officielle prime sur la longueur estimée', () {
      expect(engine.estimateCapacity(segment(knownCapacity: 7)), 7);
      expect(
        engine.estimateCapacity(segment(knownCapacity: 7, forbidden: true)),
        0,
      );
    });
  });

  group('estimateOccupancy', () {
    test('rue résidentielle plus occupée la nuit qu en journée', () {
      final s = segment(highway: 'residential');
      expect(
        engine.estimateOccupancy(s, tuesdayNight),
        greaterThan(engine.estimateOccupancy(s, tuesdayMorning)),
      );
    });

    test('rue mixte plus occupée au pic du dîner qu au petit matin', () {
      final s = segment(highway: 'tertiary');
      final dinnerPeak = DateTime(2026, 7, 14, 19);
      final earlyMorning = DateTime(2026, 7, 14, 5);
      expect(
        engine.estimateOccupancy(s, dinnerPeak),
        greaterThan(engine.estimateOccupancy(s, earlyMorning)),
      );
    });

    test('à 19h une rue animée est plus dure qu une rue résidentielle', () {
      // Le test terrain de l'utilisateur (19h) : les deux types de rue sont
      // sous pression, mais la rue à restaurants doit être la pire.
      final dinner = DateTime(2026, 7, 14, 19);
      final residential = engine.estimateOccupancy(
        segment(highway: 'residential'),
        dinner,
      );
      final mixed = engine.estimateOccupancy(
        segment(highway: 'unclassified'),
        dinner,
      );
      expect(residential, greaterThan(0.9));
      expect(mixed, greaterThan(residential));
    });

    test('dimanche une rue résidentielle reste saturée toute la journée', () {
      final sundayNoon = DateTime(2026, 7, 19, 11);
      expect(
        engine.estimateOccupancy(segment(highway: 'residential'), sundayNoon),
        greaterThanOrEqualTo(0.95),
      );
    });

    test('vendredi soir la pression résidentielle monte encore', () {
      final fridayEvening = DateTime(2026, 7, 17, 19);
      final tuesdayEvening = DateTime(2026, 7, 14, 19);
      final s = segment(highway: 'residential');
      expect(
        engine.estimateOccupancy(s, fridayEvening),
        greaterThan(engine.estimateOccupancy(s, tuesdayEvening)),
      );
    });

    test('occupation toujours dans [0, 1]', () {
      for (final hw in ['residential', 'secondary', 'tertiary']) {
        for (var h = 0; h < 24; h++) {
          for (var d = 1; d <= 7; d++) {
            final when = DateTime(2026, 7, 5 + d, h);
            final occ = engine.estimateOccupancy(segment(highway: hw), when);
            expect(occ, inInclusiveRange(0.0, 1.0));
          }
        }
      }
    });
  });

  group('score', () {
    test('probabilité nulle si capacité nulle', () {
      final scored = engine.score(segment(forbidden: true), tuesdayMorning);
      expect(scored.probabilityFree, 0);
    });

    test('une longue rue bat une courte à occupation égale', () {
      final short = engine.score(
        segment(lengthDegrees: 0.0008),
        tuesdayMorning,
      );
      final long = engine.score(segment(lengthDegrees: 0.004), tuesdayMorning);
      expect(long.probabilityFree, greaterThan(short.probabilityFree));
    });

    test('une longue rue très occupée reste estimée avec prudence', () {
      final s = engine.score(segment(highway: 'residential'), tuesdayNight);
      expect(s.occupancy, greaterThan(0.9));
      expect(s.probabilityFree, greaterThan(0));
      expect(s.probabilityFree, lessThan(0.3));
    });

    test('scoreAll conserve l API historique et l ordre des tronçons', () {
      final segments = [segment(id: 1), segment(id: 2, oneWay: true)];
      final scores = engine.scoreAll(segments, tuesdayMorning);

      expect(scores, hasLength(2));
      expect(scores[0].segment.id, 1);
      expect(scores[1].segment.id, 2);
    });
  });

  group('estimateRawAvailability', () {
    test('est bornée et croît de façon monotone avec la capacité', () {
      var previous = -1.0;
      for (final capacity in [0, 1, 2, 5, 20, 100, 10000]) {
        final probability = engine.estimateRawAvailability(
          capacity: capacity,
          occupancy: 0.9,
        );
        expect(probability, inInclusiveRange(0.0, 1.0));
        expect(probability, greaterThanOrEqualTo(previous));
        previous = probability;
      }
    });

    test('décroît de façon monotone avec l occupation', () {
      var previous = 1.1;
      for (final occupancy in [0.0, 0.2, 0.5, 0.9, 1.0]) {
        final probability = engine.estimateRawAvailability(
          capacity: 20,
          occupancy: occupancy,
        );
        expect(probability, lessThanOrEqualTo(previous));
        previous = probability;
      }
    });

    test('le rendement de capacité est strictement décroissant', () {
      final one = engine.effectiveOpportunityCount(1);
      final ten = engine.effectiveOpportunityCount(10);
      final hundred = engine.effectiveOpportunityCount(100);

      expect(one, 1);
      expect(ten, greaterThan(one));
      expect(hundred, greaterThan(ten));
      expect((ten - one) / 9, greaterThan((hundred - ten) / 90));
      expect(hundred, lessThan(100));
    });
  });

  group('estimateAvailability', () {
    final generatedAt = DateTime.utc(2026, 7, 14, 10);
    final dataAsOf = generatedAt.subtract(const Duration(minutes: 2));

    test('expose point, intervalle, confiance, fraîcheur et versions', () {
      final result = engine.estimateAvailability(
        segment(),
        tuesdayMorning,
        generatedAt: generatedAt,
        dataAsOf: dataAsOf,
        dataVersion: 'osm-snapshot-test',
      );

      expect(result.probability, inInclusiveRange(0.0, 0.95));
      expect(result.interval.contains(result.probability), isTrue);
      expect(result.confidence, AvailabilityConfidence.veryLow);
      expect(result.freshnessAt(generatedAt), AvailabilityFreshness.live);
      expect(result.predictionFor, tuesdayMorning.toUtc());
      expect(result.generatedAt, generatedAt);
      expect(result.dataAsOf, dataAsOf);
      expect(result.versions.model, ProbabilityEngine.modelVersion);
      expect(result.versions.data, 'osm-snapshot-test');
      expect(result.versions.calibration, 'uncalibrated-v1');
      expect(result.supervisedObservationCount, 0);
    });

    test('ne renvoie jamais 100 % sans calibration supervisée', () {
      for (final highway in ['residential', 'secondary', 'tertiary']) {
        for (final hour in [0, 6, 12, 18, 23]) {
          final result = engine.estimateAvailability(
            segment(highway: highway, lengthDegrees: 1),
            DateTime(2026, 7, 14, hour),
            generatedAt: generatedAt,
          );

          expect(
            result.probability,
            lessThanOrEqualTo(AvailabilityEstimate.maxUnsupervisedProbability),
          );
          expect(result.interval.upper, lessThan(1));
        }
      }
    });

    test('une donnée de stationnement explicite améliore la confiance', () {
      final inferred = engine.estimateAvailability(
        segment(),
        tuesdayMorning,
        generatedAt: generatedAt,
      );
      final explicit = engine.estimateAvailability(
        segment(sides: 1),
        tuesdayMorning,
        generatedAt: generatedAt,
      );

      expect(inferred.confidence, AvailabilityConfidence.veryLow);
      expect(explicit.confidence, AvailabilityConfidence.low);
      expect(explicit.interval.width, lessThan(inferred.interval.width));
    });

    test('une calibration apprise est injectée et auditée', () {
      final learnedEngine = ProbabilityEngine(
        calibrator: LogisticProbabilityCalibrator(
          slope: 1,
          intercept: 0.5,
          version: 'platt-paris-test-v1',
          supervisedObservationCount: 1000,
        ),
      );
      final candidate = segment(lengthDegrees: 0.0005, sides: 1);
      final prior = engine.estimateAvailability(
        candidate,
        tuesdayMorning,
        generatedAt: generatedAt,
      );
      final calibrated = learnedEngine.estimateAvailability(
        candidate,
        tuesdayMorning,
        generatedAt: generatedAt,
      );

      expect(calibrated.probability, greaterThan(prior.probability));
      expect(calibrated.confidence, AvailabilityConfidence.medium);
      expect(calibrated.interval.width, lessThan(prior.interval.width));
      expect(calibrated.versions.calibration, 'platt-paris-test-v1');
      expect(calibrated.supervisedObservationCount, 1000);
      expect(calibrated.hasSupervisedEvidence, isTrue);
    });

    test('aucune calibration ne rend disponible un tronçon interdit', () {
      final learnedEngine = ProbabilityEngine(
        calibrator: LogisticProbabilityCalibrator(
          slope: 1,
          intercept: 2,
          version: 'platt-paris-test-v1',
          supervisedObservationCount: 1000,
        ),
      );

      final result = learnedEngine.estimateAvailability(
        segment(forbidden: true),
        tuesdayMorning,
        generatedAt: generatedAt,
      );
      expect(result.probability, 0);
      expect(
        learnedEngine
            .score(segment(forbidden: true), tuesdayMorning)
            .probabilityFree,
        0,
      );
    });

    test('score et la nouvelle estimation restent compatibles', () {
      final candidate = segment(sides: 1);
      final legacy = engine.score(candidate, tuesdayMorning);
      final estimate = engine.estimateAvailability(
        candidate,
        tuesdayMorning,
        generatedAt: generatedAt,
      );

      expect(legacy.probabilityFree, closeTo(estimate.probability, 1e-12));
    });
  });
}
