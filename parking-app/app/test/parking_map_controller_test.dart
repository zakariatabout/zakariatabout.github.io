import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/controllers/parking_map_controller.dart';
import 'package:parking_app/models/availability_estimate.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/services/community_service.dart';
import 'package:parking_app/services/geocoding_service.dart';
import 'package:parking_app/services/paris_parking_service.dart';
import 'package:parking_app/services/routing_service.dart';

const firstPoint = LatLng(48.8566, 2.3522);
const secondPoint = LatLng(48.8600, 2.3400);

StreetSegment candidate(int id, LatLng center) => StreetSegment(
  id: id,
  name: 'Rue $id',
  highwayType: 'residential',
  points: [
    LatLng(center.latitude, center.longitude - 0.001),
    LatLng(center.latitude, center.longitude + 0.001),
  ],
);

ParkingSpot eligibleSpot(LatLng center, {DateTime? sourceUpdatedAt}) =>
    ParkingSpot(
      regime: ParkingRegime.payant,
      points: [center, LatLng(center.latitude, center.longitude + 0.0001)],
      sourceUpdatedAt: sourceUpdatedAt,
    );

ParkingMapController controller({
  required Future<List<StreetSegment>> Function(LatLng) segments,
  Future<List<GeocodingResult>> Function(String)? addresses,
  Future<List<ParkingSpot>> Function(LatLng)? spots,
  Future<List<ParkingEvent>> Function(LatLng)? events,
  Future<DrivingRoute?> Function(List<LatLng>)? route,
  DateTime Function()? clock,
  Duration communityPollInterval = const Duration(days: 1),
}) {
  return ParkingMapController(
    searchAddresses: addresses ?? (_) async => const [],
    fetchSegments: segments,
    fetchSpots: spots ?? (center) async => [eligibleSpot(center)],
    fetchEvents: events ?? (_) async => const <ParkingEvent>[],
    fetchRoute: route ?? (_) async => null,
    reportEvent: (_, _) async => true,
    clock: clock,
    searchDebounce: Duration.zero,
    communityPollInterval: communityPollInterval,
  );
}

void main() {
  test('ignore la réponse tardive de l ancienne destination', () async {
    final first = Completer<List<StreetSegment>>();
    final second = Completer<List<StreetSegment>>();
    final map = controller(
      segments: (center) => center == firstPoint ? first.future : second.future,
    );
    final firstSelection = map.selectDestination(
      GeocodingResult(displayName: '1 rue A, Paris', location: firstPoint),
    );
    final secondSelection = map.selectDestination(
      GeocodingResult(displayName: '2 rue B, Paris', location: secondPoint),
    );

    second.complete([candidate(2, secondPoint)]);
    await secondSelection;
    first.complete([candidate(1, firstPoint)]);
    await firstSelection;

    expect(map.state.destination, secondPoint);
    expect(map.state.rawSegments.single.id, isNegative);
    expect(map.state.rawSegments.single.distanceTo(secondPoint), lessThan(1));
    expect(map.state.query, '2 rue B');
    map.dispose();
  });

  test('vide immédiatement les suggestions devenues obsolètes', () async {
    final searches = <String, Completer<List<GeocodingResult>>>{};
    final map = controller(
      segments: (_) async => const [],
      addresses: (query) => searches.putIfAbsent(query, Completer.new).future,
    );

    map.search('ancienne');
    await Future<void>.delayed(Duration.zero);
    searches['ancienne']!.complete([
      GeocodingResult(displayName: 'Ancienne, Paris', location: firstPoint),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(map.state.suggestions, hasLength(1));

    map.search('nouvelle');

    expect(map.state.suggestions, isEmpty);
    map.dispose();
  });

  test('une recherche tardive ne remplace jamais la plus récente', () async {
    final oldSearch = Completer<List<GeocodingResult>>();
    final newSearch = Completer<List<GeocodingResult>>();
    final map = controller(
      segments: (_) async => const [],
      addresses: (query) =>
          query == 'ancienne' ? oldSearch.future : newSearch.future,
    );

    map.search('ancienne');
    await Future<void>.delayed(Duration.zero);
    map.search('nouvelle');
    await Future<void>.delayed(Duration.zero);
    newSearch.complete([
      GeocodingResult(displayName: 'Nouvelle, Paris', location: secondPoint),
    ]);
    await Future<void>.delayed(Duration.zero);
    oldSearch.complete([
      GeocodingResult(displayName: 'Ancienne, Paris', location: firstPoint),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(map.state.suggestions.single.displayName, 'Nouvelle, Paris');
    map.dispose();
  });

  test('bloque les recommandations quand le régime est réservé', () async {
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      spots: (center) async => [
        ParkingSpot(
          regime: ParkingRegime.livraison,
          points: [center, LatLng(center.latitude, center.longitude + 0.0001)],
        ),
      ],
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    expect(map.state.legalStatus, DataLayerStatus.stale);
    expect(map.state.hasVerifiedLegalCoverage, isTrue);
    expect(map.state.scoredSegments.single.probabilityFree, 0);
    expect(map.state.loop, isNull);
    expect(map.state.canStartGuidance, isFalse);
    map.dispose();
  });

  test(
    'conserve estimation, incertitude, fraîcheur et versions au state',
    () async {
      final now = DateTime.utc(2026, 7, 15, 12);
      final sourceAsOf = now.subtract(const Duration(minutes: 5));
      final map = controller(
        segments: (center) async => [candidate(1, center)],
        spots: (center) async => [
          eligibleSpot(center, sourceUpdatedAt: sourceAsOf),
        ],
        clock: () => now,
      );

      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );

      final score = map.state.scoredSegments.single;
      final estimate = map.state.estimateForSegment(score.segment.id)!;
      expect(map.state.availabilityEstimates, hasLength(1));
      expect(estimate.probability, score.probabilityFree);
      expect(estimate.interval.contains(estimate.probability), isTrue);
      expect(estimate.confidence, AvailabilityConfidence.low);
      expect(estimate.generatedAt, now);
      expect(estimate.dataAsOf, sourceAsOf);
      expect(estimate.versions.model, isNotEmpty);
      expect(estimate.versions.data, contains('source-dated'));
      expect(estimate.versions.calibration, isNotEmpty);
      expect(map.state.predictionGeneratedAt, now);
      expect(map.state.predictionDataAsOf, sourceAsOf);
      expect(map.state.predictionVersions, estimate.versions);
      expect(map.state.predictionConfidence, AvailabilityConfidence.low);
      expect(map.state.predictionFreshnessAt(now), AvailabilityFreshness.live);
      expect(map.state.legalDataAgeAt(now), const Duration(minutes: 5));
      expect(map.state.legalDataTimestampCoverage, 1);
      expect(map.state.legalStatus, DataLayerStatus.fresh);
      map.dispose();
    },
  );

  test(
    'un inventaire ancien reste utilisable mais jamais qualifié frais',
    () async {
      final now = DateTime.utc(2026, 7, 15, 12);
      final sourceAsOf = now.subtract(const Duration(days: 90));
      final map = controller(
        segments: (center) async => [candidate(1, center)],
        spots: (center) async => [
          eligibleSpot(center, sourceUpdatedAt: sourceAsOf),
        ],
        clock: () => now,
      );

      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );

      expect(map.state.legalStatus, DataLayerStatus.stale);
      expect(map.state.hasVerifiedLegalCoverage, isTrue);
      expect(map.state.canStartGuidance, isTrue);
      expect(map.state.loop, isNotNull);
      expect(map.state.predictionDataAsOf, sourceAsOf);
      expect(map.state.legalDataAgeAt(now), const Duration(days: 90));
      expect(
        map.state.predictionFreshnessAt(now),
        AvailabilityFreshness.expired,
      );
      expect(
        map.state.availabilityEstimates.values.single.dataAsOf,
        sourceAsOf,
      );
      map.dispose();
    },
  );

  test(
    'une date source inconnue reste explicite sans bloquer les régimes',
    () async {
      final now = DateTime.utc(2026, 7, 15, 12);
      final map = controller(
        segments: (center) async => [candidate(1, center)],
        clock: () => now,
      );

      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );

      expect(map.state.legalStatus, DataLayerStatus.stale);
      expect(map.state.hasVerifiedLegalCoverage, isTrue);
      expect(map.state.hasKnownLegalDataAsOf, isFalse);
      expect(map.state.predictionDataAsOf, isNull);
      expect(map.state.legalDataAgeAt(now), isNull);
      expect(map.state.predictionFreshnessAt(now), isNull);
      expect(map.state.legalDataTimestampCoverage, 0);
      expect(
        map.state.predictionVersions?.data,
        contains('source-date-unknown'),
      );
      expect(map.state.canStartGuidance, isTrue);
      map.dispose();
    },
  );

  test(
    'la date du lot est conservative et exige une couverture complète',
    () async {
      final now = DateTime.utc(2026, 7, 15, 12);
      final older = now.subtract(const Duration(days: 5));
      final newer = now.subtract(const Duration(days: 1));
      var includeUnknown = false;
      final map = controller(
        segments: (center) async => [candidate(1, center)],
        spots: (center) async => [
          eligibleSpot(center, sourceUpdatedAt: older),
          eligibleSpot(
            LatLng(center.latitude + 0.001, center.longitude),
            sourceUpdatedAt: includeUnknown ? null : newer,
          ),
        ],
        clock: () => now,
      );

      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );
      expect(map.state.predictionDataAsOf, older);
      expect(map.state.legalDataTimestampCoverage, 1);

      includeUnknown = true;
      await map.retryDestination();
      expect(map.state.predictionDataAsOf, isNull);
      expect(map.state.legalDataTimestampCoverage, 0.5);
      expect(map.state.legalStatus, DataLayerStatus.stale);
      map.dispose();
    },
  );

  test(
    'la prévisualisation route toutes les rues et revient à destination',
    () async {
      List<LatLng>? routedWaypoints;
      final map = controller(
        segments: (center) async => [
          candidate(1, center),
          candidate(2, LatLng(center.latitude + 0.001, center.longitude)),
        ],
        spots: (center) async => [
          eligibleSpot(center),
          eligibleSpot(LatLng(center.latitude + 0.001, center.longitude)),
        ],
        route: (waypoints) async {
          routedWaypoints = waypoints;
          return DrivingRoute(
            points: waypoints,
            durationSeconds: 120,
            distanceMeters: 600,
          );
        },
      );
      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );
      final success = await map.previewRoute(origin: secondPoint);

      expect(success, isTrue);
      expect(routedWaypoints!.first, secondPoint);
      expect(routedWaypoints!.last, firstPoint);
      expect(
        routedWaypoints,
        hasLength(map.state.loop!.orderedSegments.length + 2),
      );
      expect(map.state.phase, ParkingMapPhase.preview);
      map.dispose();
    },
  );

  test('un rafraîchissement communautaire conserve la route active', () async {
    var eventCalls = 0;
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      events: (_) async {
        eventCalls++;
        return const <ParkingEvent>[];
      },
      route: (waypoints) async => DrivingRoute(
        points: waypoints,
        durationSeconds: 120,
        distanceMeters: 600,
      ),
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );
    expect(await map.previewRoute(origin: secondPoint), isTrue);
    final route = map.state.route;

    await map.refreshCommunity();

    expect(eventCalls, 2);
    expect(map.state.phase, ParkingMapPhase.preview);
    expect(identical(map.state.route, route), isTrue);
    map.dispose();
  });

  test('seule la dernière route concurrente peut devenir active', () async {
    final firstRoute = Completer<DrivingRoute?>();
    final secondRoute = Completer<DrivingRoute?>();
    var calls = 0;
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      route: (_) => ++calls == 1 ? firstRoute.future : secondRoute.future,
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    final firstPreview = map.previewRoute(origin: firstPoint);
    await Future<void>.delayed(Duration.zero);
    final secondPreview = map.previewRoute(origin: secondPoint);
    final winning = DrivingRoute(
      points: const [secondPoint, firstPoint],
      durationSeconds: 80,
      distanceMeters: 300,
    );
    secondRoute.complete(winning);
    expect(await secondPreview, isTrue);
    firstRoute.complete(
      DrivingRoute(
        points: const [firstPoint, secondPoint],
        durationSeconds: 120,
        distanceMeters: 600,
      ),
    );

    expect(await firstPreview, isFalse);
    expect(identical(map.state.route, winning), isTrue);
    expect(map.state.phase, ParkingMapPhase.preview);
    map.dispose();
  });

  test('arrêter pendant une route en vol ignore sa réponse tardive', () async {
    final pending = Completer<DrivingRoute?>();
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      route: (_) => pending.future,
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    final preview = map.previewRoute(origin: secondPoint);
    await Future<void>.delayed(Duration.zero);
    map.stopGuidance();
    pending.complete(
      DrivingRoute(
        points: const [secondPoint, firstPoint],
        durationSeconds: 100,
        distanceMeters: 500,
      ),
    );

    expect(await preview, isFalse);
    expect(map.state.route, isNull);
    expect(map.state.routing, isFalse);
    expect(map.state.phase, ParkingMapPhase.ready);
    map.dispose();
  });

  test('invalide une route calculée sur un plan devenu obsolète', () async {
    final pendingRoute = Completer<DrivingRoute?>();
    var eventCalls = 0;
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      events: (_) async {
        eventCalls++;
        return eventCalls == 1
            ? const <ParkingEvent>[]
            : [
                ParkingEvent(
                  type: 'freed',
                  position: firstPoint,
                  createdAt: DateTime.now(),
                ),
              ];
      },
      route: (_) => pendingRoute.future,
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    final preview = map.previewRoute(origin: secondPoint);
    await Future<void>.delayed(Duration.zero);
    await map.refreshCommunity();
    pendingRoute.complete(
      DrivingRoute(
        points: const [secondPoint, firstPoint],
        durationSeconds: 120,
        distanceMeters: 600,
      ),
    );

    expect(await preview, isFalse);
    expect(map.state.route, isNull);
    expect(map.state.routing, isFalse);
    expect(map.state.notice, contains('données ont changé'));
    map.dispose();
  });

  test(
    'retire les signaux expirables après une panne de rafraîchissement',
    () async {
      var calls = 0;
      final now = DateTime(2026, 7, 15, 12);
      final map = controller(
        segments: (center) async => [candidate(1, center)],
        events: (_) async {
          calls++;
          if (calls > 1) throw StateError('communauté indisponible');
          return [
            ParkingEvent(
              type: 'freed',
              position: firstPoint,
              createdAt: now,
              reportCount: 4,
            ),
          ];
        },
        clock: () => now,
      );
      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );
      final boosted = map.state.scoredSegments.single.probabilityFree;
      expect(
        map.state.availabilityEstimates.values.single.probability,
        boosted,
      );

      await map.refreshCommunity();

      expect(map.state.communityStatus, DataLayerStatus.stale);
      expect(map.state.communityEvents, isEmpty);
      expect(
        map.state.scoredSegments.single.probabilityFree,
        lessThan(boosted),
      );
      expect(
        map.state.availabilityEstimates.values.single.probability,
        map.state.scoredSegments.single.probabilityFree,
      );
      map.dispose();
    },
  );

  test(
    'une panne communautaire en guidage conserve la route seulement',
    () async {
      var calls = 0;
      final map = controller(
        segments: (center) async => [candidate(1, center)],
        events: (_) async {
          if (++calls > 1) throw StateError('communauté indisponible');
          return [
            ParkingEvent(
              type: 'freed',
              position: firstPoint,
              createdAt: DateTime.now(),
            ),
          ];
        },
        route: (waypoints) async => DrivingRoute(
          points: waypoints,
          durationSeconds: 120,
          distanceMeters: 600,
        ),
      );
      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );
      expect(await map.startGuidance(secondPoint), isTrue);
      final activeRoute = map.state.route;

      await map.refreshCommunity();

      expect(map.state.phase, ParkingMapPhase.guiding);
      expect(identical(map.state.route, activeRoute), isTrue);
      expect(map.state.communityEvents, isEmpty);
      expect(map.state.communityStatus, DataLayerStatus.stale);
      map.dispose();
    },
  );

  test('deux rafraîchissements communautaires ne se chevauchent pas', () async {
    final pending = Completer<List<ParkingEvent>>();
    var eventCalls = 0;
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      events: (_) {
        eventCalls++;
        return eventCalls == 1
            ? Future.value(const <ParkingEvent>[])
            : pending.future;
      },
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    final firstRefresh = map.refreshCommunity();
    final secondRefresh = map.refreshCommunity();
    await Future<void>.delayed(Duration.zero);

    expect(eventCalls, 2);
    pending.complete(const <ParkingEvent>[]);
    await Future.wait([firstRefresh, secondRefresh]);
    expect(eventCalls, 2);
    map.dispose();
  });

  test('le reroutage attend un véritable écart à la polyligne', () async {
    var now = DateTime(2026, 7, 15, 12);
    final routedWaypoints = <List<LatLng>>[];
    final map = controller(
      segments: (center) async => [
        candidate(1, center),
        candidate(2, LatLng(center.latitude + 0.002, center.longitude)),
      ],
      spots: (center) async => [
        eligibleSpot(center),
        eligibleSpot(LatLng(center.latitude + 0.002, center.longitude)),
      ],
      route: (waypoints) async {
        routedWaypoints.add(List.of(waypoints));
        return DrivingRoute(
          points: waypoints,
          durationSeconds: 180,
          distanceMeters: 900,
        );
      },
      clock: () => now,
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );
    final origin = LatLng(firstPoint.latitude, firstPoint.longitude - 0.002);
    expect(await map.startGuidance(origin), isTrue);

    now = now.add(const Duration(seconds: 31));
    map.updateUserPosition(firstPoint);
    await Future<void>.delayed(Duration.zero);
    expect(routedWaypoints, hasLength(1));

    final offRoute = LatLng(firstPoint.latitude + 0.003, firstPoint.longitude);
    map.updateUserPosition(offRoute);
    await Future<void>.delayed(Duration.zero);
    expect(routedWaypoints, hasLength(2));
    expect(routedWaypoints.last.first, offRoute);
    map.dispose();
  });

  test('un reroutage en vol est unique et invalidé par l arrêt', () async {
    var now = DateTime(2026, 7, 15, 12);
    final reroute = Completer<DrivingRoute?>();
    var routeCalls = 0;
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      route: (waypoints) {
        routeCalls++;
        if (routeCalls == 1) {
          return Future.value(
            DrivingRoute(
              points: waypoints,
              durationSeconds: 120,
              distanceMeters: 600,
            ),
          );
        }
        return reroute.future;
      },
      clock: () => now,
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );
    expect(await map.startGuidance(secondPoint), isTrue);

    now = now.add(const Duration(seconds: 31));
    const offRouteA = LatLng(48.87, 2.37);
    const offRouteB = LatLng(48.871, 2.371);
    map.updateUserPosition(offRouteA);
    map.updateUserPosition(offRouteB);
    await Future<void>.delayed(Duration.zero);
    expect(routeCalls, 2);

    map.stopGuidance();
    reroute.complete(
      DrivingRoute(
        points: const [offRouteA, firstPoint],
        durationSeconds: 100,
        distanceMeters: 500,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(map.state.route, isNull);
    expect(map.state.phase, ParkingMapPhase.ready);
    map.dispose();
  });

  test('une heure déjà passée est planifiée au lendemain', () async {
    final now = DateTime.utc(2026, 7, 15, 16, 30); // 18 h 30 à Paris.
    final map = controller(
      segments: (center) async => [candidate(1, center)],
      clock: () => now,
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );
    map.setArrivalHour(17);

    expect(map.state.plannedArrival?.year, 2026);
    expect(map.state.plannedArrival?.month, 7);
    expect(map.state.plannedArrival?.day, 16);
    expect(map.state.plannedArrival?.hour, 17);
    map.dispose();
  });

  test('effacer invalide un chargement de destination encore en vol', () async {
    final pending = Completer<List<StreetSegment>>();
    final map = controller(segments: (_) => pending.future);
    final selection = map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    map.clearDestination();
    pending.complete([candidate(1, firstPoint)]);
    await selection;

    expect(map.state.phase, ParkingMapPhase.idle);
    expect(map.state.destination, isNull);
    expect(map.state.rawSegments, isEmpty);
    map.dispose();
  });

  test('réessayer recharge exactement la destination courante', () async {
    var calls = 0;
    final map = controller(
      segments: (center) async {
        calls++;
        if (calls == 1) throw StateError('panne temporaire');
        return [candidate(1, center)];
      },
      spots: (_) async => const [],
    );
    await map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );
    expect(map.state.phase, ParkingMapPhase.failure);

    await map.retryDestination();

    expect(calls, 2);
    expect(map.state.phase, ParkingMapPhase.ready);
    expect(map.state.destination, firstPoint);
    map.dispose();
  });

  test(
    'Paris Data maintient la recherche quand Overpass est en panne',
    () async {
      final map = controller(
        segments: (_) async => throw StateError('Overpass indisponible'),
        spots: (center) async => [
          ParkingSpot(
            regime: ParkingRegime.payant,
            points: [
              center,
              LatLng(center.latitude, center.longitude + 0.0001),
            ],
            streetName: 'RUE DE SECOURS',
            capacity: 5,
            sourceId: 'official-1',
          ),
        ],
      );

      await map.selectDestination(
        GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
      );

      expect(map.state.phase, ParkingMapPhase.ready);
      expect(map.state.rawSegments.single.name, 'RUE DE SECOURS');
      expect(map.state.scoredSegments.single.capacity, 5);
      expect(map.state.loop, isNotNull);
      expect(map.state.notice, contains('Ville de Paris'));
      map.dispose();
    },
  );

  test('la couche légale rend la carte prête sans attendre Overpass', () async {
    final streets = Completer<List<StreetSegment>>();
    final spots = Completer<List<ParkingSpot>>();
    final map = controller(
      segments: (_) => streets.future,
      spots: (_) => spots.future,
    );
    final selection = map.selectDestination(
      GeocodingResult(displayName: 'Rue test, Paris', location: firstPoint),
    );

    spots.complete([eligibleSpot(firstPoint)]);
    await Future<void>.delayed(Duration.zero);

    expect(map.state.phase, ParkingMapPhase.ready);
    expect(map.state.loop, isNotNull);
    expect(map.state.notice, contains('Ville de Paris'));

    streets.complete([candidate(99, firstPoint)]);
    await selection;
    expect(map.state.rawSegments.single.id, isNegative);
    expect(map.state.rawSegments.single.knownCapacity, 1);
    expect(map.state.notice, contains('Ville de Paris'));
    map.dispose();
  });

  test(
    'le cycle garé puis libéré est explicite et conservé au reset',
    () async {
      final map = controller(segments: (_) async => const []);

      expect(await map.report('parked', firstPoint), isTrue);
      expect(map.state.parkedPosition, firstPoint);
      expect(map.state.parkedAt, isNotNull);

      map.clearDestination();
      expect(map.state.parkedPosition, firstPoint);

      expect(await map.report('freed', firstPoint), isTrue);
      expect(map.state.parkedPosition, isNull);
      expect(map.state.parkedAt, isNull);
      map.dispose();
    },
  );

  test('une panne communautaire ne supprime pas la session locale', () async {
    final map = ParkingMapController(
      searchAddresses: (_) async => const [],
      fetchSegments: (_) async => const [],
      fetchSpots: (_) async => const [],
      fetchEvents: (_) async => const [],
      fetchRoute: (_) async => null,
      reportEvent: (_, _) async => throw StateError('Supabase indisponible'),
      communityPollInterval: const Duration(days: 1),
    );
    map.rememberParkedLocally(firstPoint);

    expect(await map.shareCommunityEvent('parked', firstPoint), isFalse);
    expect(map.state.parkedPosition, firstPoint);
    expect(map.state.parkedAt, isNotNull);
    map.dispose();
  });

  test('refuse de libérer une session inexistante', () async {
    final map = controller(segments: (_) async => const []);

    expect(await map.report('freed', firstPoint), isFalse);
    expect(map.state.notice, contains('Aucun stationnement'));
    map.dispose();
  });
}
