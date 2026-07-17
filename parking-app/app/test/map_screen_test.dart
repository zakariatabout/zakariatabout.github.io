import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/controllers/parking_map_controller.dart';
import 'package:parking_app/design_system/design_system.dart';
import 'package:parking_app/models/street_segment.dart';
import 'package:parking_app/screens/map_screen.dart';
import 'package:parking_app/services/community_service.dart';
import 'package:parking_app/services/geocoding_service.dart';
import 'package:parking_app/services/location_service.dart';
import 'package:parking_app/services/paris_parking_service.dart';
import 'package:parking_app/services/parking_session_store.dart';
import 'package:parking_app/services/routing_service.dart';

const position = LatLng(48.8566, 2.3522);

class _FakeLocationService implements LocationService {
  _FakeLocationService({List<LocationResult>? results})
    : _results =
          results ??
          [
            LocationResult.success(
              LocationSample(
                position: position,
                timestamp: DateTime.now(),
                accuracyMeters: 5,
              ),
            ),
          ];

  final List<LocationResult> _results;
  var _currentCalls = 0;

  @override
  Future<LocationResult> current() async {
    final index = _currentCalls.clamp(0, _results.length - 1);
    _currentCalls++;
    return _results[index];
  }

  @override
  Future<bool> openSettings() async => true;

  @override
  Stream<LocationSample> watch() => const Stream.empty();
}

class _FakeSessionStore implements ParkingSessionStore {
  _FakeSessionStore(this.session);

  ParkedSession? session;
  bool cleared = false;

  @override
  Future<void> clear() async {
    cleared = true;
    session = null;
  }

  @override
  Future<ParkedSession?> load() async => session;

  @override
  Future<void> save(
    LatLng position,
    DateTime parkedAt, {
    bool sharedWithCommunity = false,
  }) async {
    session = ParkedSession(
      position: position,
      parkedAt: parkedAt,
      sharedWithCommunity: sharedWithCommunity,
    );
  }
}

class _DelayedSharedSessionStore extends _FakeSessionStore {
  _DelayedSharedSessionStore() : super(null);

  final sharedSaveStarted = Completer<void>();
  final completeSharedSave = Completer<void>();

  @override
  Future<void> save(
    LatLng position,
    DateTime parkedAt, {
    bool sharedWithCommunity = false,
  }) async {
    if (sharedWithCommunity) {
      if (!sharedSaveStarted.isCompleted) sharedSaveStarted.complete();
      await completeSharedSave.future;
    }
    await super.save(
      position,
      parkedAt,
      sharedWithCommunity: sharedWithCommunity,
    );
  }
}

ParkingMapController _controller({
  Future<bool> Function(String type, LatLng position)? report,
}) {
  return ParkingMapController(
    searchAddresses: (_) async => const [],
    fetchSegments: (_) async => const <StreetSegment>[],
    fetchSpots: (_) async => const <ParkingSpot>[],
    fetchEvents: (_) async => const <ParkingEvent>[],
    fetchRoute: (_) async => null,
    reportEvent: report ?? (_, _) async => true,
    communityPollInterval: Duration.zero,
  );
}

Future<ParkingMapController> _readyController({
  Future<bool> Function(String type, LatLng position)? report,
}) async {
  final segment = StreetSegment(
    id: 7,
    name: 'Rue de Test',
    highwayType: 'residential',
    knownCapacity: 5,
    points: const [position, LatLng(48.8566, 2.3530)],
  );
  final controller = ParkingMapController(
    searchAddresses: (_) async => const [],
    fetchSegments: (_) async => [segment],
    fetchSpots: (_) async => [
      ParkingSpot(regime: ParkingRegime.payant, points: segment.points),
    ],
    fetchEvents: (_) async => const [],
    fetchRoute: (waypoints) async => DrivingRoute(
      points: waypoints,
      durationSeconds: 180,
      distanceMeters: 700,
      steps: [
        RouteStep(
          instruction: 'Démarrez sur Rue de Test',
          maneuver: 'depart',
          location: position,
          durationSeconds: 20,
          distanceMeters: 100,
        ),
      ],
    ),
    reportEvent: report ?? (_, _) async => true,
    communityPollInterval: Duration.zero,
  );
  await controller.selectDestination(
    GeocodingResult(displayName: 'Rue de Test, Paris', location: position),
  );
  expect(await controller.previewRoute(), isTrue);
  return controller;
}

void main() {
  testWidgets('présente une promesse honnête avant toute recherche', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpMap(
      tester,
      controller: controller,
      store: _FakeSessionStore(null),
    );

    expect(find.text('Trouvez une rue, pas une promesse'), findsOneWidget);
    expect(find.text('Destination'), findsOneWidget);
    expect(find.byTooltip('Afficher ma position'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('Afficher ma position')).width,
      ParkRadarSizes.minimumTouchTarget,
    );
    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.textContaining('OpenStreetMap'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .height,
      greaterThanOrEqualTo(ParkRadarSizes.minimumTouchTarget),
    );
  });

  testWidgets('restaure une place garée et permet seulement de la libérer', (
    tester,
  ) async {
    String? reportedType;
    final controller = _controller(
      report: (type, _) async {
        reportedType = type;
        return true;
      },
    );
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(
      ParkedSession(
        position: position,
        parkedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        sharedWithCommunity: true,
      ),
    );
    await _pumpMap(tester, controller: controller, store: store);
    await tester.pump();

    expect(find.text('Stationnement enregistré'), findsOneWidget);
    expect(find.text('Je libère ma place'), findsOneWidget);
    expect(find.text('Place trouvée'), findsNothing);

    await tester.tap(find.text('Je libère ma place'));
    await tester.pump();
    await tester.pump();

    expect(reportedType, 'freed');
    expect(store.cleared, isTrue);
    expect(controller.state.parkedPosition, isNull);
  });

  testWidgets('reste utilisable sur petit écran avec le texte agrandi', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);

    await _pumpMap(
      tester,
      controller: controller,
      store: _FakeSessionStore(null),
      size: const Size(360, 640),
      textScaleFactor: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Destination'), findsOneWidget);
    expect(find.byTooltip('Afficher ma position'), findsOneWidget);
  });

  testWidgets(
    'distingue les régimes officiels et rend les lignes inspectables',
    (tester) async {
      final now = DateTime.now();
      const regimes = [
        ParkingRegime.payant,
        ParkingRegime.gratuit,
        ParkingRegime.resident,
        ParkingRegime.livraison,
        ParkingRegime.interdit,
      ];
      final spots = [
        for (var index = 0; index < regimes.length; index++)
          ParkingSpot(
            regime: regimes[index],
            points: [
              LatLng(48.8564 + index * 0.00005, 2.3520),
              LatLng(48.8564 + index * 0.00005, 2.3530),
            ],
            streetName: 'Rue $index',
            capacity: index + 1,
            capacitySource: ParkingCapacitySource.actual,
            rawLabel: regimes[index].label,
            sourceUpdatedAt: now.subtract(const Duration(minutes: 5)),
          ),
      ];
      final controller = ParkingMapController(
        searchAddresses: (_) async => const [],
        fetchSegments: (_) async => const <StreetSegment>[],
        fetchSpots: (_) async => spots,
        fetchEvents: (_) async => const [],
        fetchRoute: (_) async => null,
        reportEvent: (_, _) async => true,
        communityPollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.selectDestination(
        GeocodingResult(displayName: 'Paris', location: position),
      );
      controller.toggleLegalLayer();
      await _pumpMap(
        tester,
        controller: controller,
        store: _FakeSessionStore(null),
      );

      for (final label in [
        'Payant',
        'Gratuit',
        'Résident',
        'Réservé',
        'Interdit',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Touchez une ligne pour les détails'), findsOneWidget);

      final layer = tester.widget<PolylineLayer<ParkingSpot>>(
        find.byWidgetPredicate(
          (widget) => widget is PolylineLayer<ParkingSpot>,
        ),
      );
      expect(layer.polylines, hasLength(regimes.length));
      expect(layer.polylines.map((line) => line.color).toSet(), hasLength(5));
      expect(layer.polylines.every((line) => line.hitValue != null), isTrue);
      expect(layer.minimumHitbox, greaterThanOrEqualTo(24));
    },
  );

  testWidgets('passe de l’aperçu au GPS puis à la session garée', (
    tester,
  ) async {
    var communityReports = 0;
    final segment = StreetSegment(
      id: 7,
      name: 'Rue de Test',
      highwayType: 'residential',
      knownCapacity: 5,
      points: const [position, LatLng(48.8566, 2.3530)],
    );
    final controller = ParkingMapController(
      searchAddresses: (_) async => const [],
      fetchSegments: (_) async => [segment],
      fetchSpots: (_) async => [
        ParkingSpot(regime: ParkingRegime.payant, points: segment.points),
      ],
      fetchEvents: (_) async => const [],
      fetchRoute: (waypoints) async => DrivingRoute(
        points: waypoints,
        durationSeconds: 180,
        distanceMeters: 700,
        steps: [
          RouteStep(
            instruction: 'Démarrez sur Rue de Test',
            maneuver: 'depart',
            location: position,
            durationSeconds: 20,
            distanceMeters: 100,
          ),
        ],
      ),
      reportEvent: (_, _) async {
        communityReports++;
        return true;
      },
      communityPollInterval: const Duration(days: 1),
    );
    await controller.selectDestination(
      GeocodingResult(displayName: 'Rue de Test, Paris', location: position),
    );
    expect(await controller.previewRoute(), isTrue);
    final store = _FakeSessionStore(null);
    await _pumpMap(tester, controller: controller, store: store);

    expect(find.textContaining('Confiance faible'), findsOneWidget);
    expect(find.textContaining('0 observation terrain'), findsOneWidget);
    expect(
      find.textContaining('Inventaire Paris chargé mais ancien'),
      findsOneWidget,
    );
    expect(find.textContaining('date source incomplète'), findsWidgets);
    expect(find.text('Démarrer avec le GPS'), findsOneWidget);
    await tester.ensureVisible(find.text('Démarrer avec le GPS'));
    await tester.pump();
    await tester.tap(find.text('Démarrer avec le GPS'));
    await tester.pump();
    await tester.pump();
    expect(controller.state.phase, ParkingMapPhase.guiding);
    expect(find.text('Place trouvée'), findsOneWidget);

    await tester.ensureVisible(find.text('Place trouvée'));
    await tester.pump();
    await tester.tap(find.text('Place trouvée'));
    await tester.pump();
    expect(find.text('Mémoriser votre stationnement'), findsOneWidget);
    await tester.tap(find.text('Sur cet appareil'));
    await tester.pump();
    await tester.pump();
    expect(controller.state.parkedPosition, position);
    expect(store.session, isNotNull);
    expect(store.session?.sharedWithCommunity, isFalse);
    expect(communityReports, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('un GPS imprécis bloque le démarrage du guidage', (tester) async {
    final controller = await _readyController();
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(null);
    final location = _FakeLocationService(
      results: [
        LocationResult.success(
          LocationSample(
            position: position,
            timestamp: DateTime.now(),
            accuracyMeters: 90,
          ),
        ),
      ],
    );
    await _pumpMap(
      tester,
      controller: controller,
      store: store,
      locationService: location,
    );

    await tester.ensureVisible(find.text('Démarrer avec le GPS'));
    await tester.tap(find.text('Démarrer avec le GPS'));
    await tester.pump();

    expect(controller.state.phase, ParkingMapPhase.preview);
    expect(find.textContaining('Précision GPS insuffisante'), findsOneWidget);
    expect(store.session, isNull);
  });

  testWidgets('annuler le consentement conserve le guidage sans partage', (
    tester,
  ) async {
    var reports = 0;
    final controller = await _readyController(
      report: (_, _) async {
        reports++;
        return true;
      },
    );
    expect(await controller.startGuidance(position), isTrue);
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(null);
    await _pumpMap(tester, controller: controller, store: store);

    await tester.ensureVisible(find.text('Place trouvée'));
    await tester.tap(find.text('Place trouvée'));
    await tester.pump();
    await tester.tap(find.text('Annuler'));
    await tester.pump();

    expect(controller.state.phase, ParkingMapPhase.guiding);
    expect(controller.state.parkedPosition, isNull);
    expect(store.session, isNull);
    expect(reports, 0);
  });

  testWidgets('une panne du partage conserve la session locale', (
    tester,
  ) async {
    var reports = 0;
    final controller = await _readyController(
      report: (_, _) async {
        reports++;
        throw StateError('backend indisponible');
      },
    );
    expect(await controller.startGuidance(position), isTrue);
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(null);
    await _pumpMap(tester, controller: controller, store: store);

    await tester.ensureVisible(find.text('Place trouvée'));
    await tester.tap(find.text('Place trouvée'));
    await tester.pump();
    await tester.tap(find.text('Partager la zone'));
    await tester.pump();
    await tester.pump();

    expect(controller.state.parkedPosition, position);
    expect(controller.state.phase, ParkingMapPhase.ready);
    expect(store.session?.sharedWithCommunity, isFalse);
    expect(reports, 1);

    await tester.tap(find.text('Je libère ma place'));
    await tester.pump();
    await tester.pump();

    expect(store.cleared, isTrue);
    expect(controller.state.parkedPosition, isNull);
    expect(reports, 1);
  });

  testWidgets('un partage confirmé est persisté puis libéré sur le réseau', (
    tester,
  ) async {
    final reportedTypes = <String>[];
    final parkedReport = Completer<bool>();
    final controller = await _readyController(
      report: (type, _) {
        reportedTypes.add(type);
        return type == 'parked'
            ? parkedReport.future
            : Future<bool>.value(true);
      },
    );
    expect(await controller.startGuidance(position), isTrue);
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(null);
    await _pumpMap(tester, controller: controller, store: store);

    await tester.ensureVisible(find.text('Place trouvée'));
    await tester.tap(find.text('Place trouvée'));
    await tester.pump();
    await tester.tap(find.text('Partager la zone'));
    await tester.pump();

    expect(store.session?.sharedWithCommunity, isFalse);
    expect(reportedTypes, ['parked']);

    parkedReport.complete(true);
    await tester.pump();

    expect(store.session?.sharedWithCommunity, isTrue);
    expect(reportedTypes, ['parked']);

    await tester.tap(find.text('Je libère ma place'));
    await tester.pump();
    await tester.pump();

    expect(store.cleared, isTrue);
    expect(controller.state.parkedPosition, isNull);
    expect(reportedTypes, ['parked', 'freed']);
  });

  testWidgets('une session restaurée non partagée se libère sans réseau', (
    tester,
  ) async {
    var reports = 0;
    final controller = _controller(
      report: (_, _) async {
        reports++;
        return true;
      },
    );
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(
      ParkedSession(
        position: position,
        parkedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    );
    await _pumpMap(tester, controller: controller, store: store);
    await tester.pump();

    await tester.tap(find.text('Je libère ma place'));
    await tester.pump();

    expect(store.cleared, isTrue);
    expect(controller.state.parkedPosition, isNull);
    expect(reports, 0);
  });

  testWidgets(
    'libérer pendant la confirmation locale ne ressuscite pas la session',
    (tester) async {
      final reportedTypes = <String>[];
      final controller = await _readyController(
        report: (type, _) async {
          reportedTypes.add(type);
          return true;
        },
      );
      expect(await controller.startGuidance(position), isTrue);
      addTearDown(controller.dispose);
      final store = _DelayedSharedSessionStore();
      await _pumpMap(tester, controller: controller, store: store);

      await tester.ensureVisible(find.text('Place trouvée'));
      await tester.tap(find.text('Place trouvée'));
      await tester.pump();
      await tester.tap(find.text('Partager la zone'));
      await tester.pump();
      await store.sharedSaveStarted.future;

      expect(reportedTypes, ['parked']);
      expect(find.text('Je libère ma place'), findsOneWidget);
      await tester.tap(find.text('Je libère ma place'));
      await tester.pump();
      expect(controller.state.parkedPosition, isNull);

      store.completeSharedSave.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(store.session, isNull);
      expect(reportedTypes, ['parked', 'freed']);
    },
  );

  testWidgets('une seconde mesure GPS invalide bloque Place trouvée', (
    tester,
  ) async {
    final controller = await _readyController();
    addTearDown(controller.dispose);
    final store = _FakeSessionStore(null);
    final location = _FakeLocationService(
      results: [
        LocationResult.success(
          LocationSample(
            position: position,
            timestamp: DateTime.now(),
            accuracyMeters: 5,
          ),
        ),
        LocationResult.success(
          LocationSample(
            position: position,
            timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
            accuracyMeters: 5,
          ),
        ),
      ],
    );
    await _pumpMap(
      tester,
      controller: controller,
      store: store,
      locationService: location,
    );
    await tester.ensureVisible(find.text('Démarrer avec le GPS'));
    await tester.tap(find.text('Démarrer avec le GPS'));
    await tester.pump();
    expect(controller.state.phase, ParkingMapPhase.guiding);

    await tester.ensureVisible(find.text('Place trouvée'));
    await tester.tap(find.text('Place trouvée'));
    await tester.pump();

    expect(find.text('Mémoriser votre stationnement'), findsNothing);
    expect(controller.state.phase, ParkingMapPhase.guiding);
    expect(store.session, isNull);
  });
}

Future<void> _pumpMap(
  WidgetTester tester, {
  required ParkingMapController controller,
  required ParkingSessionStore store,
  LocationService? locationService,
  Size size = const Size(390, 844),
  double textScaleFactor = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ParkRadarTheme.light,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScaleFactor),
        ),
        child: MapScreen(
          controller: controller,
          locationService: locationService ?? _FakeLocationService(),
          parkingSessionStore: store,
        ),
      ),
    ),
  );
  await tester.pump();
}
