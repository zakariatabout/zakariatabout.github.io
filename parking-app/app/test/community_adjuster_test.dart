import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/services/community_adjuster.dart';
import 'package:parking_app/services/community_service.dart';

final now = DateTime(2026, 7, 12, 18);
const segStart = LatLng(48.8566, 2.3522);

ScoredSegment scored({double pFree = 0.4, int capacity = 20}) {
  return ScoredSegment(
    segment: StreetSegment(
      id: 1,
      name: 'Rue de Test',
      highwayType: 'residential',
      points: [segStart, const LatLng(48.8566, 2.3542)],
    ),
    capacity: capacity,
    occupancy: 0.9,
    probabilityFree: pFree,
  );
}

ParkingEvent event(String type, {Duration age = Duration.zero, LatLng? at}) {
  return ParkingEvent(
    type: type,
    position: at ?? segStart,
    createdAt: now.subtract(age),
  );
}

void main() {
  const adjuster = CommunityAdjuster();

  test('une place libérée à côté augmente la probabilité', () {
    final out = adjuster.adjust([scored()], [event('freed')], now).single;
    expect(out.probabilityFree, greaterThan(0.4));
  });

  test('une place prise à côté baisse la probabilité', () {
    final out = adjuster.adjust([scored()], [event('parked')], now).single;
    expect(out.probabilityFree, lessThan(0.4));
  });

  test('un signalement trop vieux n a plus d effet', () {
    final out = adjuster.adjust(
      [scored()],
      [event('freed', age: const Duration(minutes: 20))],
      now,
    ).single;
    expect(out.probabilityFree, 0.4);
  });

  test('un signalement trop loin n a pas d effet', () {
    final out = adjuster.adjust(
      [scored()],
      [event('freed', at: const LatLng(48.87, 2.36))], // ~1,6 km
      now,
    ).single;
    expect(out.probabilityFree, 0.4);
  });

  test('l effet décroît avec l âge du signalement', () {
    final fresh = adjuster.adjust([scored()], [event('freed')], now).single;
    final older = adjuster.adjust(
      [scored()],
      [event('freed', age: const Duration(minutes: 8))],
      now,
    ).single;
    expect(fresh.probabilityFree, greaterThan(older.probabilityFree));
    expect(older.probabilityFree, greaterThan(0.4));
  });

  test('une rue interdite au stationnement reste à sa valeur', () {
    final out = adjuster.adjust(
      [scored(pFree: 0.0, capacity: 0)],
      [event('freed')],
      now,
    ).single;
    expect(out.probabilityFree, 0.0);
  });

  test('la probabilité reste bornée à 1 malgré plusieurs libérations', () {
    final out = adjuster.adjust(
      [scored(pFree: 0.9)],
      [for (var i = 0; i < 10; i++) event('freed')],
      now,
    ).single;
    expect(out.probabilityFree, lessThanOrEqualTo(1.0));
    expect(out.probabilityFree, greaterThan(0.9));
  });
}
