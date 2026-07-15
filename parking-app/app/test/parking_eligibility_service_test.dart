import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/services/paris_parking_service.dart';
import 'package:parking_app/services/parking_eligibility_service.dart';

StreetSegment street({bool forbidden = false}) => StreetSegment(
  id: 7,
  name: 'Rue test',
  highwayType: 'residential',
  parkingForbidden: forbidden,
  points: const [LatLng(48.8566, 2.3510), LatLng(48.8566, 2.3540)],
);

ParkingSpot spot(ParkingRegime regime, {double latitude = 48.85665}) =>
    ParkingSpot(
      regime: regime,
      points: [LatLng(latitude, 2.3520), LatLng(latitude, 2.3521)],
    );

void main() {
  const service = ParkingEligibilityService();
  const visitor = ParkingUserProfile();

  test('un emplacement payant proche est éligible au visiteur', () {
    final result = service.assess(street(), [
      spot(ParkingRegime.payant),
    ], visitor);
    expect(result.status, EligibilityStatus.eligible);
  });

  test('une zone résidentielle exige le permis', () {
    final spots = [spot(ParkingRegime.resident)];
    expect(
      service.assess(street(), spots, visitor).status,
      EligibilityStatus.ineligible,
    );
    expect(
      service
          .assess(
            street(),
            spots,
            const ParkingUserProfile(hasResidentPermit: true),
          )
          .status,
      EligibilityStatus.eligible,
    );
  });

  test('une donnée absente reste inconnue', () {
    final result = service.assess(street(), const [], visitor);
    expect(result.status, EligibilityStatus.unknown);
    expect(result.canRecommend, isFalse);
  });

  test('un régime réservé annule le score en mode strict', () {
    final segment = street();
    final score = ScoredSegment(
      segment: segment,
      capacity: 20,
      occupancy: 0.8,
      probabilityFree: 0.7,
    );
    final assessments = service.assessAll(
      [segment],
      [spot(ParkingRegime.livraison)],
      visitor,
    );
    final constrained = service.applyToScores([score], assessments).single;
    expect(constrained.capacity, 0);
    expect(constrained.probabilityFree, 0);
  });

  test('une interdiction OSM reste prioritaire', () {
    final result = service.assess(street(forbidden: true), [
      spot(ParkingRegime.payant),
    ], visitor);
    expect(result.status, EligibilityStatus.ineligible);
  });

  test('construit un réseau de secours avec la capacité officielle', () {
    final segments = service.segmentsFromSpots([
      ParkingSpot(
        regime: ParkingRegime.payant,
        points: const [LatLng(48.8566, 2.3520), LatLng(48.8566, 2.3521)],
        streetName: 'RUE DE TEST',
        capacity: 6,
        sourceId: '42',
      ),
    ]);

    expect(segments, hasLength(1));
    expect(segments.single.name, 'RUE DE TEST');
    expect(segments.single.knownCapacity, 6);
    expect(segments.single.parkingSides, 1);
    expect(segments.single.id, isNegative);
    expect(segments.single.parkingSourceKey, isNotEmpty);
  });

  test('une unité réservée n hérite jamais du payant voisin', () {
    final delivery = ParkingSpot(
      regime: ParkingRegime.livraison,
      points: const [LatLng(48.854203, 2.355907), LatLng(48.85421, 2.35592)],
      capacity: 20,
      sourceId: 'livraison-20',
    );
    final paid = ParkingSpot(
      regime: ParkingRegime.payant,
      points: const [LatLng(48.85424, 2.35594), LatLng(48.85425, 2.35595)],
      capacity: 1,
      sourceId: 'payant-1',
    );
    final spots = [delivery, paid];
    final segments = service.segmentsFromSpots(spots);

    final reserved = service.assess(segments.first, spots, visitor);
    final eligible = service.assess(segments.last, spots, visitor);

    expect(reserved.status, EligibilityStatus.ineligible);
    expect(reserved.regimes, {ParkingRegime.livraison});
    expect(segments.first.knownCapacity, 20);
    expect(eligible.status, EligibilityStatus.eligible);
    expect(eligible.regimes, {ParkingRegime.payant});
  });
}
