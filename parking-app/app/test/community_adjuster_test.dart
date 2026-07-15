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

ParkingEvent event(
  String type, {
  Duration age = Duration.zero,
  LatLng? at,
  int reportCount = 1,
}) {
  return ParkingEvent(
    type: type,
    position: at ?? segStart,
    createdAt: now.subtract(age),
    reportCount: reportCount,
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

  test('un signal isolé reste borné et une corroboration pèse davantage', () {
    final isolated = adjuster.adjust([scored()], [event('freed')], now).single;
    final corroborated = adjuster
        .adjust([scored()], [event('freed', reportCount: 4)], now)
        .single;

    expect(isolated.probabilityFree, lessThanOrEqualTo(0.52));
    expect(corroborated.probabilityFree, greaterThan(isolated.probabilityFree));
    expect(corroborated.probabilityFree, lessThanOrEqualTo(0.52));
  });

  test('un signalement trop vieux n a plus d effet', () {
    final out = adjuster
        .adjust(
          [scored()],
          [event('freed', age: const Duration(minutes: 20))],
          now,
        )
        .single;
    expect(out.probabilityFree, 0.4);
  });

  test('un signalement trop loin n a pas d effet', () {
    final out = adjuster
        .adjust(
          [scored()],
          [event('freed', at: const LatLng(48.87, 2.36))], // ~1,6 km
          now,
        )
        .single;
    expect(out.probabilityFree, 0.4);
  });

  test('l effet d une cellule arrondie décroît avec la distance', () {
    final close = adjuster.adjust([scored()], [event('freed')], now).single;
    final offset = adjuster
        .adjust(
          [scored()],
          [event('freed', at: const LatLng(48.8573, 2.3522))],
          now,
        )
        .single;

    expect(offset.probabilityFree, greaterThan(0.4));
    expect(offset.probabilityFree, lessThan(close.probabilityFree));
  });

  test('l effet décroît avec l âge du signalement', () {
    final fresh = adjuster.adjust([scored()], [event('freed')], now).single;
    final older = adjuster
        .adjust(
          [scored()],
          [event('freed', age: const Duration(minutes: 8))],
          now,
        )
        .single;
    expect(fresh.probabilityFree, greaterThan(older.probabilityFree));
    expect(older.probabilityFree, greaterThan(0.4));
  });

  test('une rue interdite au stationnement reste à sa valeur', () {
    final out = adjuster
        .adjust([scored(pFree: 0.0, capacity: 0)], [event('freed')], now)
        .single;
    expect(out.probabilityFree, 0.0);
  });

  test(
    'des preuves opposées donnent le même résultat quel que soit l ordre',
    () {
      final freed = event('freed', reportCount: 4);
      final parked = event('parked', reportCount: 4);
      final first = adjuster.adjust([scored()], [freed, parked], now).single;
      final second = adjuster.adjust([scored()], [parked, freed], now).single;

      expect(first.probabilityFree, closeTo(second.probabilityFree, 1e-12));
    },
  );

  test('les libérations ne créent jamais une certitude artificielle', () {
    final out = adjuster
        .adjust(
          [scored(pFree: 0.9)],
          [for (var i = 0; i < 10; i++) event('freed')],
          now,
        )
        .single;
    expect(out.probabilityFree, lessThanOrEqualTo(0.95));
    expect(out.probabilityFree, greaterThan(0.9));
  });
}
