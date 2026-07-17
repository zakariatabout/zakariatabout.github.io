import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/route_progress_tracker.dart';
import 'package:parking_app/services/routing_service.dart';

void main() {
  // Itinéraire rectiligne ouest→est d'environ 733 m (0.01° de longitude à
  // Paris), une manœuvre à mi-parcours et l'arrivée au bout.
  const start = LatLng(48.8566, 2.3400);
  const middle = LatLng(48.8566, 2.3450);
  const end = LatLng(48.8566, 2.3500);

  DrivingRoute route() => DrivingRoute(
    points: const [start, middle, end],
    durationSeconds: 120,
    distanceMeters: 733,
    steps: [
      RouteStep(
        instruction: 'Tournez à droite',
        maneuver: 'turn:right',
        location: middle,
        durationSeconds: 60,
        distanceMeters: 366,
      ),
      RouteStep(
        instruction: 'Vous êtes arrivé',
        maneuver: 'arrive',
        location: end,
        durationSeconds: 60,
        distanceMeters: 367,
      ),
    ],
  );

  test('expose distance à la manœuvre, restant et durée restante', () {
    final tracker = RouteProgressTracker();
    final snapshot = tracker.update(route(), start);

    // Au départ : la manœuvre est à ~366 m, tout le parcours reste à faire.
    expect(snapshot.distanceToNextManeuverMeters, closeTo(366, 30));
    expect(snapshot.remainingRouteMeters, closeTo(733, 30));
    expect(snapshot.remainingDurationSeconds, closeTo(120, 6));
  });

  test('la durée restante décroît au prorata de la distance', () {
    final tracker = RouteProgressTracker();
    tracker.update(route(), start);
    final atMiddle = tracker.update(route(), middle);

    expect(atMiddle.remainingRouteMeters, closeTo(366, 30));
    expect(atMiddle.remainingDurationSeconds, closeTo(60, 6));
  });

  test('la distance à la manœuvre atteint zéro une fois dépassée', () {
    final tracker = RouteProgressTracker();
    tracker.update(route(), start);
    tracker.update(route(), middle);
    final nearEnd = tracker.update(route(), end);

    expect(nearEnd.remainingRouteMeters, closeTo(0, 25));
    expect(nearEnd.distanceToNextManeuverMeters, closeTo(0, 25));
  });
}
