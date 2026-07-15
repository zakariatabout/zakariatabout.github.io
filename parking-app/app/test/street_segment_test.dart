import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/models/street_segment.dart';

void main() {
  test('distanceTo projette sur le milieu de la polyligne', () {
    final segment = StreetSegment(
      id: 1,
      name: 'Rue test',
      highwayType: 'residential',
      points: const [LatLng(48.8566, 2.3500), LatLng(48.8566, 2.3540)],
    );

    final point = const LatLng(48.8567, 2.3520);
    expect(segment.distanceTo(point), lessThan(15));
    expect(segment.distanceTo(point), greaterThan(5));
    expect(segment.nearestPointTo(point).longitude, closeTo(2.3520, 0.00001));
  });

  test('distanceTo reste correcte près d une extrémité', () {
    final segment = StreetSegment(
      id: 1,
      name: 'Rue test',
      highwayType: 'residential',
      points: const [LatLng(48.8566, 2.3520), LatLng(48.8570, 2.3520)],
    );

    expect(
      segment.distanceTo(const LatLng(48.8565, 2.3520)),
      inInclusiveRange(10, 13),
    );
  });
}
