import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/services/probability_engine.dart';

StreetSegment segment({
  int id = 1,
  String highway = 'residential',
  bool oneWay = false,
  bool forbidden = false,
  int? sides,
  double lengthDegrees = 0.002, // ~220 m en longitude à Paris
}) {
  return StreetSegment(
    id: id,
    name: 'Rue de Test',
    highwayType: highway,
    isOneWay: oneWay,
    parkingForbidden: forbidden,
    parkingSides: sides,
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
  });

  group('estimateOccupancy', () {
    test('rue résidentielle plus occupée la nuit qu en journée', () {
      final s = segment(highway: 'residential');
      expect(
        engine.estimateOccupancy(s, tuesdayNight),
        greaterThan(engine.estimateOccupancy(s, tuesdayMorning)),
      );
    });

    test('rue mixte plus occupée en journée que la nuit', () {
      final s = segment(highway: 'tertiary');
      expect(
        engine.estimateOccupancy(s, tuesdayMorning),
        greaterThan(engine.estimateOccupancy(s, tuesdayNight)),
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

    test('P = 1 - rho^c : une longue rue bat une courte à occupation égale',
        () {
      final short =
          engine.score(segment(lengthDegrees: 0.0008), tuesdayMorning);
      final long = engine.score(segment(lengthDegrees: 0.004), tuesdayMorning);
      expect(long.probabilityFree, greaterThan(short.probabilityFree));
    });

    test('une rue de 20 places occupée à ~95% garde une proba correcte', () {
      // Cas cité dans l'étude : 1 - 0.95^20 ≈ 0.64.
      final s = engine.score(segment(highway: 'residential'), tuesdayNight);
      expect(s.occupancy, greaterThan(0.9));
      if (s.capacity >= 15) {
        expect(s.probabilityFree, greaterThan(0.3));
      }
    });
  });
}
