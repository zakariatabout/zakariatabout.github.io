import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/services/search_loop_planner.dart';

const dest = LatLng(48.8566, 2.3522);

ScoredSegment scored({
  required int id,
  required double pFree,
  double offsetDegrees = 0.001, // ~110 m
}) {
  final seg = StreetSegment(
    id: id,
    name: 'Rue $id',
    highwayType: 'residential',
    points: [
      LatLng(dest.latitude + offsetDegrees, dest.longitude),
      LatLng(dest.latitude + offsetDegrees, dest.longitude + 0.002),
    ],
  );
  return ScoredSegment(
    segment: seg,
    capacity: 20,
    occupancy: 0.9,
    probabilityFree: pFree,
  );
}

void main() {
  const planner = SearchLoopPlanner();

  test('s arrête dès que la probabilité cumulée atteint le seuil', () {
    final loop = planner.plan(
      [for (var i = 0; i < 20; i++) scored(id: i, pFree: 0.7)],
      dest,
    );
    // 1-(0.3)^2 = 0.91 >= 0.90 : deux tronçons suffisent.
    expect(loop.orderedSegments.length, 2);
    expect(loop.cumulativeProbability, greaterThanOrEqualTo(0.90));
  });

  test('respecte le nombre maximal de tronçons', () {
    final loop = planner.plan(
      [for (var i = 0; i < 30; i++) scored(id: i, pFree: 0.1)],
      dest,
    );
    expect(loop.orderedSegments.length, lessThanOrEqualTo(8));
  });

  test('exclut les rues trop loin pour marcher', () {
    final near = scored(id: 1, pFree: 0.5, offsetDegrees: 0.001);
    final far = scored(id: 2, pFree: 0.99, offsetDegrees: 0.02); // ~2,2 km
    final loop = planner.plan([near, far], dest);
    expect(loop.orderedSegments.map((s) => s.segment.id), contains(1));
    expect(loop.orderedSegments.map((s) => s.segment.id), isNot(contains(2)));
  });

  test('privilégie les rues proches à probabilité égale', () {
    final near = scored(id: 1, pFree: 0.5, offsetDegrees: 0.001);
    final farther = scored(id: 2, pFree: 0.5, offsetDegrees: 0.004);
    final loop = planner.plan([near, farther], dest);
    expect(loop.orderedSegments.first.segment.id, 1);
  });

  test('probabilité cumulée = 1 - produit des échecs', () {
    final loop = planner.plan(
      [scored(id: 1, pFree: 0.5), scored(id: 2, pFree: 0.5)],
      dest,
    );
    expect(loop.cumulativeProbability, closeTo(0.75, 1e-9));
  });

  test('temps de recherche espéré positif et borné par la boucle', () {
    final loop = planner.plan(
      [for (var i = 0; i < 5; i++) scored(id: i, pFree: 0.4)],
      dest,
    );
    final minutes = planner.expectedSearchMinutes(loop);
    expect(minutes, greaterThan(0));
    expect(minutes, lessThan(30));
  });
}
