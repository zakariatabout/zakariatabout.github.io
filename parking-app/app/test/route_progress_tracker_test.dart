import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/route_progress_tracker.dart';
import 'package:parking_app/services/routing_service.dart';

DrivingRoute route() => DrivingRoute(
  points: const [
    LatLng(48.8560, 2.3500),
    LatLng(48.8570, 2.3500),
    LatLng(48.8580, 2.3500),
  ],
  durationSeconds: 120,
  distanceMeters: 222,
  steps: [
    RouteStep(
      instruction: 'Démarrez',
      maneuver: 'depart',
      location: const LatLng(48.8560, 2.3500),
      durationSeconds: 20,
      distanceMeters: 80,
    ),
    RouteStep(
      instruction: 'Continuez',
      maneuver: 'continue',
      location: const LatLng(48.8570, 2.3500),
      durationSeconds: 50,
      distanceMeters: 100,
    ),
    RouteStep(
      instruction: 'Arrivée',
      maneuver: 'arrive',
      location: const LatLng(48.8580, 2.3500),
      durationSeconds: 50,
      distanceMeters: 42,
    ),
  ],
);

void main() {
  test('avance même si le GPS saute le point de manœuvre', () {
    final tracker = RouteProgressTracker();
    final result = tracker.update(route(), const LatLng(48.8575, 2.3500));

    expect(result.stepIndex, 2);
    expect(result.alongRouteMeters, greaterThan(150));
  });

  test('un départ OSRM décalé ne bloque pas la première instruction', () {
    final tracker = RouteProgressTracker();
    final result = tracker.update(route(), const LatLng(48.8560, 2.34945));

    expect(result.distanceToRouteMeters, greaterThan(35));
    expect(result.stepIndex, 1);
  });

  test('la progression ne recule jamais après un bruit GPS', () {
    final tracker = RouteProgressTracker();
    final drivingRoute = route();
    final advanced = tracker.update(
      drivingRoute,
      const LatLng(48.8576, 2.3500),
    );
    final noisy = tracker.update(drivingRoute, const LatLng(48.8565, 2.3500));

    expect(noisy.alongRouteMeters, advanced.alongRouteMeters);
    expect(noisy.stepIndex, advanced.stepIndex);
  });

  test('une boucle fermée ne projette pas le départ sur l arrivée', () {
    const start = LatLng(48.8560, 2.3500);
    final closedRoute = DrivingRoute(
      points: const [
        start,
        LatLng(48.8570, 2.3500),
        LatLng(48.8570, 2.3510),
        start,
      ],
      durationSeconds: 180,
      distanceMeters: 330,
      steps: [
        RouteStep(
          instruction: 'Démarrez',
          maneuver: 'depart',
          location: start,
          durationSeconds: 20,
          distanceMeters: 100,
        ),
        RouteStep(
          instruction: 'Tournez',
          maneuver: 'turn:right',
          location: const LatLng(48.8570, 2.3500),
          durationSeconds: 80,
          distanceMeters: 120,
        ),
        RouteStep(
          instruction: 'Arrivée',
          maneuver: 'arrive',
          location: start,
          durationSeconds: 80,
          distanceMeters: 110,
        ),
      ],
    );

    final result = RouteProgressTracker().update(closedRoute, start);

    expect(result.alongRouteMeters, closeTo(0, 0.1));
    expect(result.stepIndex, 1);
  });
}
