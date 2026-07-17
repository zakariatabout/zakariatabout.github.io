import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config.dart';
import '../controllers/parking_map_controller.dart';
import '../design_system/design_system.dart';
import '../models/availability_estimate.dart';
import '../models/street_segment.dart';
import '../services/community_service.dart';
import '../services/geocoding_service.dart';
import '../services/haptics_service.dart';
import '../services/location_service.dart';
import '../services/map_camera_animator.dart';
import '../services/overpass_service.dart';
import '../services/paris_parking_service.dart';
import '../services/paris_time.dart';
import '../services/parking_eligibility_service.dart';
import '../services/parking_session_store.dart';
import '../services/probability_calibrator.dart';
import '../services/probability_engine.dart';
import '../services/route_progress_tracker.dart';
import '../services/routing_service.dart';
import '../services/search_outcome_store.dart';
import '../services/voice_guidance_service.dart';
import '../widgets/widgets.dart';

enum _ParkingSaveMode { deviceOnly, shareZone }

/// Expérience cartographique principale de ParkRadar.
///
/// [ParkingMapController] reste l'unique source de vérité produit. Les seuls
/// états locaux concernent le rendu de la carte, le suivi GPS et le HUD de
/// navigation. Le constructeur injectable permet de tester l'écran sans GPS
/// ni appels réseau.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    this.controller,
    this.locationService,
    this.parkingSessionStore,
    this.speechEngine,
    this.calibrator,
  });

  final ParkingMapController? controller;
  final LocationService? locationService;
  final ParkingSessionStore? parkingSessionStore;

  /// Moteur vocal injectable pour les tests (défaut : TTS de la plateforme).
  final SpeechEngine? speechEngine;

  /// Calibrateur de probabilité appliqué au moteur de prédiction quand
  /// l'écran construit son propre contrôleur (chargé par [CalibrationStore]
  /// au démarrage). Ignoré si un contrôleur est injecté.
  final ProbabilityCalibrator? calibrator;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with TickerProviderStateMixin {
  static const _parisCenter = LatLng(48.8566, 2.3522);
  static const _distance = Distance();

  final _mapController = MapController();
  late final MapCameraAnimator _camera;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final LayerHitNotifier<ParkingSpot> _legalHitNotifier = ValueNotifier(null);

  late final ParkingMapController _controller;
  late final LocationService _locationService;
  late final ParkingSessionStore _parkingSessionStore;
  late final bool _ownsController;

  GeocodingService? _ownedGeocoding;
  OverpassService? _ownedOverpass;
  RoutingService? _ownedRouting;
  CommunityService? _ownedCommunity;
  ParisParkingService? _ownedParisParking;

  StreamSubscription<LocationSample>? _positionSubscription;
  int _trackingGeneration = 0;
  late ParkingMapState _lastState;
  final _routeProgressTracker = RouteProgressTracker();
  int _guidanceStepIndex = 0;
  RouteProgressSnapshot? _guidanceSnapshot;
  LocationSample? _lastSample;
  bool _celebrating = false;
  Timer? _celebrationTimer;
  late final VoiceGuidanceService _voiceGuidance;
  bool _voiceMuted = false;
  bool _cameraFollowing = true;
  bool _gpsLost = false;
  Timer? _gpsRetryTimer;
  int _gpsRetryDelaySeconds = 3;
  final _outcomeStore = SearchOutcomeStore();
  PendingSearchContext? _pendingSearch;
  // Mémoïsation des couches carte : recalculées uniquement quand leurs
  // entrées changent, pas à chaque échantillon GPS (voir chantier A du plan
  // d'excellence).
  List<Polyline>? _memoAvailability;
  (Object?, Object?, ParkRadarColors, double)? _memoAvailabilityKey;
  List<Polyline>? _memoLoopOnly;
  (Object?, Object?, ParkRadarColors, double)? _memoLoopOnlyKey;

  /// Palier de largeur des traits selon le zoom (« la rue s'épaissit en
  /// approchant », façon Apple Plans). Initialisé pour initialZoom = 13.
  double _availabilityStrokeBase = 3.5;

  static double _strokeBaseForZoom(double zoom) => switch (zoom) {
    >= 17.0 => 8.0,
    >= 15.5 => 6.5,
    >= 14.0 => 5.0,
    _ => 3.5,
  };
  List<Marker>? _memoStaticMarkers;
  (Object?, Object?, Object?, Object?, _MapLayerMode, ParkRadarColors)?
  _memoStaticMarkersKey;
  List<Polyline<ParkingSpot>>? _memoLegal;
  (Object?, ParkRadarColors)? _memoLegalKey;
  bool _mapReady = false;
  bool _tileUnavailable = false;
  bool _parkedSharedWithCommunity = false;
  int _parkingSessionGeneration = 0;
  Future<void> _sessionStoreTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _locationService = widget.locationService ?? const DeviceLocationService();
    _parkingSessionStore =
        widget.parkingSessionStore ?? SharedPreferencesParkingSessionStore();
    _ownsController = widget.controller == null;

    if (widget.controller case final injected?) {
      _controller = injected;
    } else {
      final geocoding = _ownedGeocoding = GeocodingService();
      final overpass = _ownedOverpass = OverpassService();
      final routing = _ownedRouting = RoutingService();
      final community = _ownedCommunity = CommunityService();
      final parisParking = _ownedParisParking = ParisParkingService();

      _controller = ParkingMapController(
        searchAddresses: geocoding.search,
        fetchSegments: (center) => overpass.fetchSegments(center),
        fetchSpots: (center) => parisParking.fetchSpotsOrThrow(center),
        fetchEvents: (center) => community.recentEventsNearOrThrow(center),
        fetchRoute: routing.route,
        reportEvent: (type, position) async {
          await community.reportOrThrow(type, position);
          return true;
        },
        engine: ProbabilityEngine(
          calibrator: widget.calibrator ?? const IdentityProbabilityCalibrator(),
        ),
        communityPollInterval: AppConfig.communityPollInterval,
      );
    }

    _camera = MapCameraAnimator(vsync: this, controller: _mapController);
    _voiceGuidance = VoiceGuidanceService(
      engine: widget.speechEngine ?? FlutterTtsSpeechEngine(),
    );
    _lastState = _controller.state;
    _searchController.text = _lastState.query;
    _controller.addListener(_handleControllerChanged);
    unawaited(_restoreParkingSession());
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _trackingGeneration++;
    _gpsRetryTimer?.cancel();
    _celebrationTimer?.cancel();
    _camera.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(_voiceGuidance.dispose());
    final positionSubscription = _positionSubscription;
    _positionSubscription = null;
    unawaited(positionSubscription?.cancel());
    if (_ownsController) {
      _controller.dispose();
      _ownedGeocoding?.close();
      _ownedOverpass?.close();
      _ownedRouting?.close();
      _ownedCommunity?.close();
      _ownedParisParking?.close();
    }
    _mapController.dispose();
    _legalHitNotifier.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    final previous = _lastState;
    final next = _controller.state;
    _lastState = next;

    if (!_searchFocusNode.hasFocus && _searchController.text != next.query) {
      _searchController.value = TextEditingValue(
        text: next.query,
        selection: TextSelection.collapsed(offset: next.query.length),
      );
    }

    if (previous.destination != next.destination && next.destination != null) {
      _afterMapReady(() => _camera.animateTo(center: next.destination, zoom: 16));
    }
    if (!identical(previous.route, next.route) && next.route != null) {
      _syncGuidanceStep(next);
      if (next.phase == ParkingMapPhase.preview) {
        _afterMapReady(() => _fitCameraTo(next.route!.points));
      }
    } else if (next.phase == ParkingMapPhase.guiding) {
      _syncGuidanceStep(next);
    }

    if (previous.phase == ParkingMapPhase.guiding &&
        next.phase != ParkingMapPhase.guiding) {
      unawaited(_stopPositionTracking());
      _exitGuidanceSideEffects();
    }
    if (mounted) setState(() {});
  }

  /// Effets de bord d'entrée en conduite : écran maintenu allumé, caméra
  /// asservie, annonce vocale de départ.
  void _enterGuidanceSideEffects() {
    _cameraFollowing = true;
    _gpsLost = false;
    _gpsRetryDelaySeconds = 3;
    unawaited(WakelockPlus.enable());
    _voiceGuidance.muted = _voiceMuted;
    unawaited(_voiceGuidance.announceStart());
  }

  void _exitGuidanceSideEffects() {
    _gpsRetryTimer?.cancel();
    _gpsLost = false;
    unawaited(WakelockPlus.disable());
    unawaited(_voiceGuidance.stop());
    _finalizePendingSearch(SearchOutcome.abandoned);
  }

  void _afterMapReady(VoidCallback action) {
    if (_mapReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _mapReady) action();
      });
    }
  }

  void _onMapReady() {
    _mapReady = true;
    final state = _controller.state;
    if (state.route != null && state.phase == ParkingMapPhase.preview) {
      _fitCameraTo(state.route!.points);
    } else if (state.destination != null) {
      _mapController.move(state.destination!, 16);
    }
  }

  void _syncGuidanceStep(ParkingMapState state) {
    final route = state.route;
    if (route == null || route.steps.isEmpty || state.userPosition == null) {
      return;
    }
    final snapshot = _routeProgressTracker.update(route, state.userPosition!);
    _guidanceSnapshot = snapshot;
    _guidanceStepIndex = snapshot.stepIndex;
    if (state.phase == ParkingMapPhase.guiding) {
      final step =
          route.steps[snapshot.stepIndex.clamp(0, route.steps.length - 1)];
      unawaited(_voiceGuidance.onProgress(snapshot, step));
    }
  }

  void _fitCameraTo(List<LatLng> points) {
    if (!_mapReady || points.isEmpty) return;
    final size = MediaQuery.sizeOf(context);
    final sidePanel = ParkRadarBreakpoints.usesSidePanel(size);
    _camera.animateFit(
      CameraFit.coordinates(
        coordinates: points,
        padding: sidePanel
            ? const EdgeInsets.fromLTRB(72, 120, 472, 72)
            : const EdgeInsets.fromLTRB(40, 120, 40, 300),
      ),
    );
  }

  Future<LatLng?> _requestCurrentLocation({bool moveCamera = false}) async {
    late final LocationResult result;
    try {
      result = await _locationService.current();
    } catch (_) {
      if (mounted) _showSnack('Position indisponible pour le moment.');
      return null;
    }
    if (!mounted) return null;
    final sample = result.sample;
    if (sample != null) {
      if (!sample.isUsable(DateTime.now())) {
        _showSnack(
          'Précision GPS insuffisante (±${sample.accuracyMeters.round()} m). '
          'Réessayez à ciel ouvert.',
        );
        return null;
      }
      _controller.updateUserPosition(sample.position);
      if (moveCamera && _mapReady) {
        _camera.animateTo(center: sample.position, zoom: 17);
      }
      return sample.position;
    }

    final canOpenSettings =
        result.failure == LocationFailure.servicesDisabled ||
        result.failure == LocationFailure.permissionDeniedForever;
    _showSnack(
      result.userMessage,
      actionLabel: canOpenSettings ? 'Réglages' : null,
      onAction: canOpenSettings ? _locationService.openSettings : null,
    );
    return null;
  }

  Future<void> _previewRoute() async {
    final state = _controller.state;
    await _controller.previewRoute(origin: state.userPosition);
  }

  Future<void> _startGuidance() async {
    // Une vraie navigation part toujours d'une mesure GPS fraîche. La
    // destination n'est jamais utilisée comme origine de secours.
    final origin = await _requestCurrentLocation();
    if (origin == null || !mounted) return;
    final started = await _controller.startGuidance(origin);
    if (!started || !mounted) return;
    Haptics.medium();
    _enterGuidanceSideEffects();
    _capturePendingSearch();
    if (_mapReady) _camera.animateTo(center: origin, zoom: 17);
    await _startPositionTracking();
  }

  /// Mémorise la prédiction affichée au départ du guidage : c'est elle qui
  /// sera confrontée à l'issue réelle (trouvé / abandonné) pour la
  /// calibration supervisée.
  void _capturePendingSearch() {
    final state = _controller.state;
    final loop = state.loop;
    if (loop == null) return;
    _pendingSearch = PendingSearchContext(
      startedAt: DateTime.now(),
      predictedProbability: loop.cumulativeProbability,
      isCalibrated: loop.isCalibrated,
      plannedHour: (state.plannedArrival ?? DateTime.now()).hour,
    );
  }

  void _finalizePendingSearch(SearchOutcome outcome) {
    final pending = _pendingSearch;
    _pendingSearch = null;
    if (pending == null) return;
    unawaited(_outcomeStore.record(pending.finish(outcome)));
  }

  Future<void> _startPositionTracking() async {
    final generation = ++_trackingGeneration;
    final previous = _positionSubscription;
    _positionSubscription = null;
    await previous?.cancel();
    if (!mounted ||
        generation != _trackingGeneration ||
        _controller.state.phase != ParkingMapPhase.guiding) {
      return;
    }
    try {
      final subscription = _locationService.watch().listen(
        (sample) {
          if (!mounted ||
              generation != _trackingGeneration ||
              _controller.state.phase != ParkingMapPhase.guiding) {
            return;
          }
          if (!sample.isUsable(DateTime.now(), maxAccuracyMeters: 60)) return;
          if (_gpsLost) {
            _gpsLost = false;
            _gpsRetryDelaySeconds = 3;
          }
          _lastSample = sample;
          _controller.updateUserPosition(
            sample.position,
            accuracyMeters: sample.accuracyMeters,
          );
          _followCamera(sample);
        },
        onError: (Object _) => _handleGpsLoss(generation),
      );
      if (!mounted ||
          generation != _trackingGeneration ||
          _controller.state.phase != ParkingMapPhase.guiding) {
        await subscription.cancel();
        return;
      }
      _positionSubscription = subscription;
    } catch (_) {
      _handleGpsLoss(generation);
    }
  }

  /// Caméra de conduite : suit la position, s'oriente selon le cap dès que le
  /// véhicule roule, et adapte le zoom à la vitesse. Ne fait rien si
  /// l'utilisateur a repris la main (pan manuel).
  void _followCamera(LocationSample sample) {
    if (!_mapReady || !_cameraFollowing) return;
    final speed = sample.speedMetersPerSecond;
    final zoom = speed > 9 ? 16.0 : 17.0;
    final heading = sample.headingDegrees;
    // Le cap GPS n'est fiable qu'en mouvement : à l'arrêt on garde
    // l'orientation courante au lieu de faire tournoyer la carte.
    final rotate =
        speed > 1.5 && heading.isFinite && heading >= 0 && heading <= 360;
    // Linéaire + durée > cadence GPS : chaque échantillon relance le tween
    // depuis la position courante avant qu'il ne se termine — glissement
    // continu façon Waze, fin du stop-and-go du 450 ms easeOut.
    _camera.animateTo(
      center: sample.position,
      zoom: zoom,
      rotation: rotate ? -heading : null,
      duration: ParkRadarMotion.cameraFollow,
      curve: Curves.linear,
    );
  }

  /// Une coupure GPS (tunnel, parking couvert) n'arrête plus le guidage :
  /// bannière + reprise automatique avec backoff, tant que la phase dure.
  void _handleGpsLoss(int generation) {
    if (!mounted || generation != _trackingGeneration) return;
    if (_controller.state.phase != ParkingMapPhase.guiding) return;
    if (!_gpsLost) {
      _gpsLost = true;
      unawaited(_voiceGuidance.announceGpsLost());
      if (mounted) setState(() {});
    }
    _gpsRetryTimer?.cancel();
    _gpsRetryTimer = Timer(Duration(seconds: _gpsRetryDelaySeconds), () {
      if (!mounted || _controller.state.phase != ParkingMapPhase.guiding) {
        return;
      }
      _gpsRetryDelaySeconds = math.min(30, _gpsRetryDelaySeconds * 2);
      unawaited(_startPositionTracking());
    });
  }

  Future<void> _stopPositionTracking() async {
    _trackingGeneration++;
    final subscription = _positionSubscription;
    _positionSubscription = null;
    await subscription?.cancel();
  }

  void _stopGuidance() {
    unawaited(_stopPositionTracking());
    _controller.stopGuidance();
  }

  Future<void> _reportParked() async {
    if (_controller.state.phase != ParkingMapPhase.guiding) return;
    final position = await _requestCurrentLocation();
    if (position == null || !mounted) return;
    final saveMode = await _chooseParkingSaveMode();
    if (saveMode == null || !mounted) return;
    // Issue positive : la place a été trouvée pendant ce guidage. À
    // enregistrer avant le changement de phase (qui clôturerait la recherche
    // en « abandonnée »).
    _finalizePendingSearch(SearchOutcome.found);
    Haptics.medium();
    _showParkedCelebration();
    final parkedAt = DateTime.now();
    final share = saveMode == _ParkingSaveMode.shareZone;
    final sessionGeneration = ++_parkingSessionGeneration;
    // `sharedWithCommunity` décrit un fait confirmé par le backend, pas une
    // intention de partage. La session reste donc locale jusqu'au succès du
    // POST `parked`.
    _parkedSharedWithCommunity = false;
    _controller.rememberParkedLocally(position, parkedAt: parkedAt);
    try {
      await _enqueueSessionStore(
        () => _parkingSessionStore.save(
          position,
          parkedAt,
          sharedWithCommunity: false,
        ),
      );
    } catch (_) {
      if (mounted) {
        _showSnack(
          'Stationnement mémorisé pour cette session, mais la sauvegarde locale a échoué.',
        );
      }
    }
    await _stopPositionTracking();
    _controller.stopGuidance();
    final state = _controller.state;
    final isStillActive =
        sessionGeneration == _parkingSessionGeneration &&
        state.parkedPosition == position &&
        state.parkedAt == parkedAt;
    if (share && isStillActive) {
      unawaited(_shareParkedAndConfirm(position, parkedAt, sessionGeneration));
    }
  }

  Future<void> _reportFreed() async {
    final position = _controller.state.parkedPosition;
    if (position == null) return;
    Haptics.light();
    final share = _parkedSharedWithCommunity;
    _parkingSessionGeneration++;
    _parkedSharedWithCommunity = false;
    _controller.clearParkedLocally();
    try {
      await _enqueueSessionStore(_parkingSessionStore.clear);
    } catch (_) {
      if (mounted) {
        _showSnack('Place libérée, mais le nettoyage local a échoué.');
      }
    }
    if (share) {
      unawaited(_shareCommunityEvent('freed', position));
    }
  }

  Future<void> _shareParkedAndConfirm(
    LatLng position,
    DateTime parkedAt,
    int sessionGeneration,
  ) async {
    final success = await _shareCommunityEvent('parked', position);
    if (!success) return;

    final state = _controller.state;
    final isStillActive =
        sessionGeneration == _parkingSessionGeneration &&
        state.parkedPosition == position &&
        state.parkedAt == parkedAt;
    if (!isStillActive) {
      // La personne a pu libérer la place pendant le POST. Puisque `parked`
      // vient seulement d'être confirmé, compenser sans ressusciter la session.
      unawaited(_shareCommunityEvent('freed', position));
      return;
    }

    _parkedSharedWithCommunity = true;
    try {
      await _enqueueSessionStore(
        () => _parkingSessionStore.save(
          position,
          parkedAt,
          sharedWithCommunity: true,
        ),
      );
    } catch (_) {
      if (mounted) {
        _showSnack(
          'Partage confirmé, mais son état n’a pas pu être sauvegardé localement.',
        );
      }
    }

    final currentState = _controller.state;
    final remainsActive =
        sessionGeneration == _parkingSessionGeneration &&
        currentState.parkedPosition == position &&
        currentState.parkedAt == parkedAt;
    if (!remainsActive) {
      _parkedSharedWithCommunity = false;
      try {
        await _enqueueSessionStore(() async {
          final saved = await _parkingSessionStore.load();
          if (saved?.position == position && saved?.parkedAt == parkedAt) {
            await _parkingSessionStore.clear();
          }
        });
      } catch (_) {
        // Le nettoyage principal a déjà été tenté par `_reportFreed`.
      }
    }
  }

  Future<void> _enqueueSessionStore(Future<void> Function() operation) {
    final result = _sessionStoreTail.then((_) => operation());
    _sessionStoreTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<bool> _shareCommunityEvent(String type, LatLng position) async {
    final success = await _controller.shareCommunityEvent(type, position);
    if (!success && mounted) {
      _showSnack(
        type == 'parked'
            ? 'Stationnement mémorisé localement ; partage communautaire indisponible.'
            : 'Session terminée localement ; signal de libération non transmis.',
      );
    }
    return success;
  }

  Future<_ParkingSaveMode?> _chooseParkingSaveMode() {
    return showDialog<_ParkingSaveMode>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mémoriser votre stationnement'),
        content: const Text(
          'ParkRadar peut transmettre une zone arrondie d’environ 70 à 110 m. '
          'Le flux public ne montre pas votre GPS exact et tronque '
          'l’horodatage à la minute ; la ligne privée est supprimée après '
          'environ 24 heures. Vous pouvez aussi tout conserver uniquement sur cet '
          'appareil.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _ParkingSaveMode.deviceOnly),
            child: const Text('Sur cet appareil'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ParkingSaveMode.shareZone),
            child: const Text('Partager la zone'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreParkingSession() async {
    try {
      final session = await _parkingSessionStore.load();
      if (!mounted || session == null) return;
      _parkedSharedWithCommunity = session.sharedWithCommunity;
      _controller.restoreParkedSession(session.position, session.parkedAt);
    } catch (_) {
      // Une préférence locale corrompue ne doit jamais bloquer la carte.
    }
  }

  void _showSnack(
    String message, {
    String? actionLabel,
    Future<bool> Function()? onAction,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                onPressed: () => unawaited(onAction()),
              ),
      ),
    );
  }

  Future<void> _openMapAttribution() async {
    final opened = await launchUrl(
      Uri.parse('https://www.openstreetmap.org/copyright'),
    );
    if (!opened && mounted) {
      _showSnack('Impossible d’ouvrir les informations cartographiques.');
    }
  }

  Future<void> _pickArrivalHour() async {
    final state = _controller.state;
    final initial =
        state.plannedArrival ??
        atParis(DateTime.now()).add(const Duration(hours: 1));
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: 0),
      helpText: 'Heure d’arrivée (heure pleine)',
      confirmText: 'Planifier',
      cancelText: 'Annuler',
    );
    if (picked != null && mounted) {
      _controller.setArrivalHour(picked.hour);
    }
  }

  void _onTileError() {
    if (_tileUnavailable || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_tileUnavailable) {
        setState(() => _tileUnavailable = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    _camera.reduceMotion = MediaQuery.disableAnimationsOf(context);
    final scaffold = Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final sidePanel = ParkRadarBreakpoints.usesSidePanel(
            constraints.biggest,
          );
          final mode = _layerMode(state);
          // INVARIANT ANTI-« VOILE » — tout enfant non positionné de ce
          // Stack reçoit des contraintes lâches mais bornées : un Align /
          // Center / Container(alignment:) NON facturé s'y étire plein
          // écran. C'est voulu pour positionner (contrôles, overlay haut,
          // panneau, chargement) et sans danger tant que le widget étiré ne
          // porte AUCUNE couleur, décoration ni Semantics bloquant :
          //  - le fond vit sur un descendant shrink-wrappé (Align
          //    widthFactor/heightFactor: 1 — cf. _AttributionPill —, taille
          //    fixe, ou Column/Wrap en mainAxisSize.min) ;
          //  - les couches purement visuelles plein écran passent sous
          //    IgnorePointer (scrim, célébration, chargement).
          // Ne JAMAIS « corriger » en facturant les Align de positionnement
          // (_buildMapControls, ParkMapOverlayShell, ParkResponsiveMapPanel) :
          // le Stack les enverrait en haut-gauche. Régression couverte par le
          // test « anti-voile » de map_screen_test.dart.
          return Stack(
            children: [
              Positioned.fill(child: _buildMap(state, mode, sidePanel)),
              // Scrim dégradé : assoit la lisibilité de la recherche et de la
              // légende sur fond de tuiles claires (pattern Waze/Google Maps).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 120,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // Fonds CARTO natifs. Même condition que _buildMap :
                        // le guidage force Dark Matter même en thème clair.
                        // Sombre : noir pur (Dark Matter est achromatique).
                        // Clair : voile BLANC, pattern carte claire
                        // Apple/Google — il assoit aussi les icônes sombres
                        // de la status bar. (Le token mapScrim reste réservé
                        // aux barriers de modales.)
                        colors:
                            (state.phase == ParkingMapPhase.guiding ||
                                Theme.of(context).brightness ==
                                    Brightness.dark)
                            ? const [Color(0xD9000000), Color(0x00000000)]
                            : const [Color(0xBFFFFFFF), Color(0x00FFFFFF)],
                      ),
                    ),
                  ),
                ),
              ),
              _buildMapControls(state, sidePanel),
              _buildTopOverlay(state, mode),
              if (state.phase == ParkingMapPhase.loading)
                const _MapLoadingCard(),
              if (state.phase != ParkingMapPhase.loading)
                _buildResponsivePanel(state),
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedSwitcher(
                    duration: ParkRadarMotion.panel, // pop d'entrée
                    reverseDuration: ParkRadarMotion.standard, // sortie vive
                    transitionBuilder: (child, animation) {
                      // easeOutBack dépasse 1.0 : il ne pilote QUE l'échelle
                      // (une opacité > 1 lèverait un assert).
                      final scale = Tween<double>(begin: 0.4, end: 1).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutBack,
                          reverseCurve: Curves.easeIn,
                        ),
                      );
                      final fade = CurvedAnimation(
                        parent: animation,
                        curve: const Interval(0, 0.4, curve: Curves.easeOut),
                      );
                      return FadeTransition(
                        opacity: fade,
                        child: ScaleTransition(scale: scale, child: child),
                      );
                    },
                    child: _celebrating
                        ? Center(
                            key: const ValueKey('celebration'),
                            child: _celebrationBadge(),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('celebration-off'),
                          ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    // Thème conduite : contraste élevé forcé pendant le guidage, quelle que
    // soit la préférence système — l'écran est lu d'un coup d'œil au volant.
    if (state.phase == ParkingMapPhase.guiding) {
      return Theme(data: ParkRadarTheme.dark, child: scaffold);
    }
    return scaffold;
  }

  Widget _buildMap(ParkingMapState state, _MapLayerMode mode, bool sidePanel) {
    // Le thème conduite force ParkRadarTheme.dark AUTOUR du scaffold, mais ce
    // wrapper est SOUS le contexte du State : Theme.of(context) ne le voit
    // pas. On inclut donc la phase guiding pour ne jamais rendre un HUD
    // sombre sur une carte claire — et on prend la palette de couches
    // correspondante.
    final guiding = state.phase == ParkingMapPhase.guiding;
    final isDark = guiding || Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? ParkRadarColors.dark : ParkRadarColors.light;
    // Un template sombre dédié (env MAP_TILE_URL_TEMPLATE_DARK) est déjà
    // sombre : ne surtout pas l'inverser (la config retombe sur le template
    // clair OSM quand l'env est vide — cas prod).
    final hasNativeDarkTiles =
        AppConfig.mapTileUrlTemplateDark != AppConfig.mapTileUrlTemplate;
    // Le filtre d'adoucissement clair ne vaut que pour l'OSM standard : les
    // fonds pré-stylés (CARTO/Stadia) sont déjà propres.
    final osmStandardLight =
        AppConfig.mapTileUrlTemplate == AppConfig.osmStandardTileTemplate;
    final ColorFilter? tileFilter = isDark
        ? (hasNativeDarkTiles ? null : ParkRadarMapFilters.dark)
        : (osmStandardLight ? ParkRadarMapFilters.light : null);
    final tileLayer = TileLayer(
      urlTemplate: isDark
          ? AppConfig.mapTileUrlTemplateDark
          : AppConfig.mapTileUrlTemplate,
      userAgentPackageName: 'fr.zakariatabout.parking_app',
      maxNativeZoom: 19,
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
      errorTileCallback: (_, _, _) => _onTileError(),
      // Apparition soyeuse des tuiles, alignée sur ParkRadarMotion.standard.
      tileDisplay: const TileDisplay.fadeIn(
        duration: Duration(milliseconds: 200),
      ),
    );
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _parisCenter,
        initialZoom: 13,
        minZoom: 11,
        maxZoom: 20,
        // Peint par FlutterMap SOUS les children, donc HORS du ColorFiltered :
        // couleur assortie au fond réel des tuiles pour éviter tout flash.
        backgroundColor: isDark
            ? (hasNativeDarkTiles
                  // Fond CARTO Dark Matter RASTER (dark_all) : @landmass_fill
                  // #090909 du CartoCSS dark-matter.tm2 — achromatique.
                  ? const Color(0xFF090909)
                  : ParkRadarMapFilters.darkBackdrop)
            : (osmStandardLight
                  ? ParkRadarMapFilters.lightBackdrop
                  // Fond CARTO Positron (@landmass_fill #fafaf8).
                  : const Color(0xFFFAFAF8)),
        onMapReady: _onMapReady,
        onTap: (_, _) {
          _searchFocusNode.unfocus();
          _controller.dismissSuggestions();
        },
        // Un pan manuel pendant le guidage rend la main à l'utilisateur ;
        // le bouton « Recentrer » réactive le suivi caméra.
        onPositionChanged: (camera, hasGesture) {
          // Palier de largeur des traits selon le zoom : setState uniquement
          // au franchissement d'un palier (4 valeurs possibles).
          final base = _strokeBaseForZoom(camera.zoom);
          if (base != _availabilityStrokeBase) {
            setState(() => _availabilityStrokeBase = base);
          }
          if (hasGesture &&
              _cameraFollowing &&
              _controller.state.phase == ParkingMapPhase.guiding) {
            setState(() => _cameraFollowing = false);
          }
        },
      ),
      children: [
        if (tileFilter == null)
          tileLayer
        else
          ColorFiltered(colorFilter: tileFilter, child: tileLayer),
        if (mode == _MapLayerMode.availability)
          PolylineLayer(polylines: _availabilityPolylinesMemo(state, colors)),
        if (mode == _MapLayerMode.legal)
          GestureDetector(
            onTap: _openTouchedLegalSpot,
            child: PolylineLayer<ParkingSpot>(
              hitNotifier: _legalHitNotifier,
              minimumHitbox: ParkRadarSizes.minimumTouchTarget / 2,
              polylines: _legalPolylinesMemo(state, colors),
            ),
          ),
        if (mode == _MapLayerMode.route) ...[
          PolylineLayer(polylines: _loopPolylinesMemo(state, colors)),
          if (state.route != null)
            TweenAnimationBuilder<double>(
              // Nouvelle route => nouvelle clé => la révélation rejoue ;
              // simple rebuild => aucun redémarrage.
              key: ValueKey(state.route),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 350),
              curve: ParkRadarMotion.enter,
              builder: (context, t, _) => PolylineLayer(
                polylines: [
                  // 1. Halo lumineux (trait large translucide, pas de blur).
                  Polyline(
                    points: state.route!.points,
                    strokeWidth: 1 + 17 * t,
                    color: colors.routeGlow.withValues(
                      alpha: colors.routeGlow.a * t,
                    ),
                  ),
                  // 2. Corps du trait, casé bleu-nuit (sombre) / blanc (clair).
                  Polyline(
                    points: state.route!.points,
                    strokeWidth: 6 + 3 * t,
                    borderStrokeWidth: 3 * t,
                    borderColor: colors.routeCasing.withValues(alpha: t),
                    color: colors.route.withValues(alpha: 0.25 + 0.75 * t),
                  ),
                  // 3. Cœur clair : le « double-trait » façon Waze.
                  Polyline(
                    points: state.route!.points,
                    strokeWidth: 3,
                    color: colors.routeInner.withValues(alpha: t),
                  ),
                ],
              ),
            ),
        ],
        MarkerLayer(markers: _staticMarkersMemo(state, mode, colors)),
        // Le marqueur véhicule vit dans sa propre couche : c'est le seul
        // élément carte qui change à chaque échantillon GPS.
        if (state.userPosition != null) ...[
          // Halo de précision GPS réel (rayon en mètres).
          if (_lastSample case final sample?)
            CircleLayer(
              circles: [
                CircleMarker(
                  point: state.userPosition!,
                  radius: sample.accuracyMeters.clamp(5, 120),
                  useRadiusInMeter: true,
                  color: colors.route.withValues(alpha: 0.14),
                  borderColor: colors.route.withValues(alpha: 0.35),
                  borderStrokeWidth: 1.5,
                ),
              ],
            ),
          MarkerLayer(markers: [_userMarker(state, colors)]),
        ],
        // Téléphone : l'attribution vit au-dessus de la feuille basse
        // (aboveSheet). Ici : panneau latéral uniquement, plus un repli en
        // bas à gauche pendant le chargement (pas encore de feuille, mais
        // l'obligation OSM/CARTO demeure).
        if (sidePanel || state.phase == ParkingMapPhase.loading)
          _MapAttribution(
            alignment: Alignment.bottomLeft,
            label: _attributionLabel,
            onTap: _openMapAttribution,
          ),
      ],
    );
  }

  String get _attributionLabel =>
      '${AppConfig.mapTileAttribution} · Ville de Paris';

  // ── Mémoïsation des couches carte ────────────────────────────────────────
  // L'état du contrôleur est immuable : une comparaison d'identité suffit à
  // savoir si une couche doit être reconstruite. Un échantillon GPS ne
  // reconstruit ainsi plus que le marqueur véhicule.

  List<Polyline> _availabilityPolylinesMemo(
    ParkingMapState state,
    ParkRadarColors colors,
  ) {
    final fresh =
        _memoAvailabilityKey == null ||
        !identical(_memoAvailabilityKey!.$1, state.scoredSegments) ||
        !identical(_memoAvailabilityKey!.$2, state.loop) ||
        !identical(_memoAvailabilityKey!.$3, colors) ||
        _memoAvailabilityKey!.$4 != _availabilityStrokeBase;
    if (fresh) {
      _memoAvailability = _availabilityPolylines(state, colors);
      _memoAvailabilityKey = (
        state.scoredSegments,
        state.loop,
        colors,
        _availabilityStrokeBase,
      );
    }
    return _memoAvailability!;
  }

  List<Polyline> _loopPolylinesMemo(
    ParkingMapState state,
    ParkRadarColors colors,
  ) {
    final fresh =
        _memoLoopOnlyKey == null ||
        !identical(_memoLoopOnlyKey!.$1, state.scoredSegments) ||
        !identical(_memoLoopOnlyKey!.$2, state.loop) ||
        !identical(_memoLoopOnlyKey!.$3, colors) ||
        _memoLoopOnlyKey!.$4 != _availabilityStrokeBase;
    if (fresh) {
      _memoLoopOnly = _availabilityPolylines(state, colors, loopOnly: true);
      _memoLoopOnlyKey = (
        state.scoredSegments,
        state.loop,
        colors,
        _availabilityStrokeBase,
      );
    }
    return _memoLoopOnly!;
  }

  List<Polyline<ParkingSpot>> _legalPolylinesMemo(
    ParkingMapState state,
    ParkRadarColors colors,
  ) {
    final fresh =
        _memoLegalKey == null ||
        !identical(_memoLegalKey!.$1, state.parisSpots) ||
        !identical(_memoLegalKey!.$2, colors);
    if (fresh) {
      _memoLegal = _legalPolylines(state, colors);
      _memoLegalKey = (state.parisSpots, colors);
    }
    return _memoLegal!;
  }

  List<Marker> _staticMarkersMemo(
    ParkingMapState state,
    _MapLayerMode mode,
    ParkRadarColors colors,
  ) {
    final key = (
      state.communityEvents,
      state.destination,
      state.parkedPosition,
      state.loop,
      mode,
      colors,
    );
    final previous = _memoStaticMarkersKey;
    final fresh =
        previous == null ||
        !identical(previous.$1, key.$1) ||
        previous.$2 != key.$2 ||
        previous.$3 != key.$3 ||
        !identical(previous.$4, key.$4) ||
        previous.$5 != key.$5 ||
        !identical(previous.$6, key.$6);
    if (fresh) {
      _memoStaticMarkers = _markers(state, mode, colors);
      _memoStaticMarkersKey = key;
    }
    return _memoStaticMarkers!;
  }

  Marker _userMarker(ParkingMapState state, ParkRadarColors colors) {
    // Cap affiché uniquement en guidage et en mouvement : cap GPS + rotation
    // carte = angle écran.
    double? headingScreen;
    final sample = _lastSample;
    if (state.phase == ParkingMapPhase.guiding &&
        sample != null &&
        sample.speedMetersPerSecond > 1.5 &&
        sample.headingDegrees.isFinite &&
        sample.headingDegrees >= 0) {
      headingScreen = sample.headingDegrees +
          (_mapReady ? _mapController.camera.rotation : 0);
    }
    return Marker(
      point: state.userPosition!,
      width: 56,
      height: 56,
      child: Semantics(
        label: 'Votre position',
        child: ExcludeSemantics(
          child: ParkUserMarker(headingScreenDegrees: headingScreen),
        ),
      ),
    );
  }

  List<Polyline> _availabilityPolylines(
    ParkingMapState state,
    ParkRadarColors colors, {
    bool loopOnly = false,
  }) {
    final loopIds = {
      for (final segment
          in state.loop?.orderedSegments ?? const <ScoredSegment>[])
        segment.segment.id,
    };
    return [
      for (final scored in state.scoredSegments)
        if (_isDrawnAvailability(state, scored) &&
            (!loopOnly || loopIds.contains(scored.segment.id)))
          _availabilityPolyline(
            scored,
            colors,
            emphasized: loopIds.contains(scored.segment.id),
          ),
    ];
  }

  Polyline _availabilityPolyline(
    ScoredSegment scored,
    ParkRadarColors colors, {
    required bool emphasized,
  }) {
    final level = _availabilityLevel(scored.probabilityFree);
    final stroke = switch (level) {
      _AvailabilityLevel.low => colors.availabilityLow,
      _AvailabilityLevel.medium => colors.availabilityMedium,
      _AvailabilityLevel.high => colors.availabilityHigh,
    };
    // Motif par niveau (info jamais portée par la couleur seule), en tirets
    // longs : les pointillés serrés scintillent sur fond sombre.
    final pattern = switch (level) {
      _AvailabilityLevel.low => StrokePattern.dashed(segments: const [10, 9]),
      _AvailabilityLevel.medium => StrokePattern.dashed(
        segments: const [18, 7],
      ),
      _AvailabilityLevel.high => const StrokePattern.solid(),
    };
    // Fill OPAQUE obligatoire : color.a < 1 force un saveLayer PAR polyline
    // bordée et casse le batching. On pré-mélange l'atténuation vers
    // routeCasing (opaque : bleu-nuit en sombre / blanc en clair).
    final fill = emphasized
        ? stroke
        : Color.alphaBlend(stroke.withValues(alpha: 0.85), colors.routeCasing);
    return Polyline(
      points: scored.segment.points,
      strokeWidth: emphasized
          ? _availabilityStrokeBase + 1.5
          : _availabilityStrokeBase,
      // borderStrokeWidth s'AJOUTE à strokeWidth, réparti moitié par côté.
      borderStrokeWidth: emphasized ? 3.0 : 2.0,
      borderColor: colors.mapCasing,
      color: fill,
      pattern: pattern,
    );
  }

  List<Polyline<ParkingSpot>> _legalPolylines(
    ParkingMapState state,
    ParkRadarColors colors,
  ) {
    return [
      for (final spot in state.parisSpots)
        Polyline(
          points: spot.points,
          strokeWidth: 7,
          borderStrokeWidth: 2,
          borderColor: colors.mapCasing,
          color: _legalColor(spot.regime, colors),
          pattern: _legalPattern(spot.regime),
          hitValue: spot,
        ),
    ];
  }

  Color _legalColor(ParkingRegime regime, ParkRadarColors colors) {
    return switch (regime) {
      ParkingRegime.payant => colors.brand,
      ParkingRegime.gratuit => colors.success.foreground,
      ParkingRegime.resident => colors.confidenceLow.foreground,
      ParkingRegime.interdit => colors.danger.foreground,
      ParkingRegime.moto ||
      ParkingRegime.velo ||
      ParkingRegime.livraison ||
      ParkingRegime.handicap ||
      ParkingRegime.taxi ||
      ParkingRegime.autocar => colors.warning.foreground,
      ParkingRegime.autre => colors.neutral.foreground,
    };
  }

  StrokePattern _legalPattern(ParkingRegime regime) {
    return switch (regime) {
      ParkingRegime.payant => const StrokePattern.solid(),
      ParkingRegime.gratuit => const StrokePattern.dotted(spacingFactor: 2.2),
      ParkingRegime.resident => StrokePattern.dashed(segments: const [12, 4]),
      ParkingRegime.interdit => const StrokePattern.dotted(spacingFactor: 1.4),
      ParkingRegime.autre => const StrokePattern.solid(),
      _ => StrokePattern.dashed(segments: const [4, 5]),
    };
  }

  void _openTouchedLegalSpot() {
    final hits = _legalHitNotifier.value?.hitValues;
    if (hits == null || hits.isEmpty || !mounted) return;
    unawaited(_showLegalSpotDetails(hits.first));
  }

  Future<void> _showLegalSpotDetails(ParkingSpot spot) {
    final capacity = switch ((spot.capacity, spot.capacitySource)) {
      (final int count, ParkingCapacitySource.actual) =>
        '$count place${count > 1 ? 's' : ''} relevée${count > 1 ? 's' : ''}',
      (final int count, ParkingCapacitySource.calculated) =>
        '$count place${count > 1 ? 's' : ''} calculée${count > 1 ? 's' : ''} par la source',
      (final int count, null) =>
        '$count place${count > 1 ? 's' : ''} publiée${count > 1 ? 's' : ''}',
      _ => 'Capacité non renseignée',
    };
    final updatedAt = spot.sourceUpdatedAt;
    final sourceDate = updatedAt == null
        ? 'Date de mise à jour non renseignée'
        : 'Source mise à jour ${_formatSourceDate(updatedAt)} '
              '(${_formatDataAge(DateTime.now().difference(updatedAt))})';
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          key: const Key('legal-spot-details-sheet'),
          padding: const EdgeInsets.fromLTRB(
            ParkRadarSpacing.md,
            0,
            ParkRadarSpacing.md,
            ParkRadarSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                spot.regime.label,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: ParkRadarSpacing.xs),
              Text(spot.streetName ?? 'Voie non renseignée'),
              const SizedBox(height: ParkRadarSpacing.xs),
              Text(capacity),
              Text(sourceDate),
              if (spot.rawLabel case final rawLabel?)
                Text(
                  'Régime source : $rawLabel',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: ParkRadarSpacing.sm),
              Text(
                'Inventaire Ville de Paris. Vérifiez toujours la '
                'signalisation présente sur place.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Marker> _markers(
    ParkingMapState state,
    _MapLayerMode mode,
    ParkRadarColors colors,
  ) {
    final markers = <Marker>[];
    for (final event in state.communityEvents.take(24)) {
      final age = _formatAge(DateTime.now().difference(event.createdAt));
      final tone = event.isFreed ? colors.success : colors.danger;
      final sign = event.isFreed ? '+' : '−';
      markers.add(
        Marker(
          point: event.position,
          width: 88,
          height: 34,
          child: Semantics(
            label: event.isFreed
                ? 'Signal de place libérée dans cette zone il y a $age'
                : 'Signal de place prise dans cette zone il y a $age',
            child: ExcludeSemantics(
              child: Material(
                color: tone.background,
                shape: StadiumBorder(side: BorderSide(color: tone.border)),
                elevation: 2,
                child: Center(
                  child: Text(
                    'P $sign · $age',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: tone.foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (state.destination case final destination?) {
      markers.add(
        Marker(
          point: destination,
          width: 40,
          height: 52,
          alignment: Alignment.topCenter,
          child: Semantics(
            label: 'Destination',
            child: const ExcludeSemantics(child: ParkDestinationPin()),
          ),
        ),
      );
    }

    // Le marqueur de position vit dans sa propre couche (voir _userMarker) :
    // il est le seul à changer à chaque échantillon GPS.

    if (state.parkedPosition case final parked?) {
      markers.add(
        Marker(
          point: parked,
          width: 46,
          height: 46,
          child: Semantics(
            label: 'Votre voiture est garée ici',
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFFFFFFF), width: 3),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x59000000),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                    BoxShadow(
                      color: Color(0x402563EB),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.directions_car_filled,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (mode != _MapLayerMode.legal && state.loop != null) {
      for (final (index, scored) in state.loop!.orderedSegments.indexed) {
        final level = _availabilityLevel(scored.probabilityFree);
        final stroke = switch (level) {
          _AvailabilityLevel.low => colors.availabilityLow,
          _AvailabilityLevel.medium => colors.availabilityMedium,
          _AvailabilityLevel.high => colors.availabilityHigh,
        };
        // Étape 1 = prochaine action : légèrement grossie.
        final size = index == 0 ? 34.0 : 28.0;
        markers.add(
          Marker(
            point: scored.segment.midpoint,
            width: size,
            height: size,
            child: Semantics(
              label: 'Étape ${index + 1}, ${scored.segment.name}',
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: stroke,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.mapCasing, width: 2.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: const Color(0xFF0D0E0F),
                        fontSize: index == 0 ? 15 : 13,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  /// Recentre la carte sur la place mémorisée et annonce la distance et la
  /// direction à pied depuis la position courante. Réutilise la « session
  /// garée » déjà persistée par [_reportParked].
  void _findMyCar() {
    final state = _controller.state;
    final parked = state.parkedPosition;
    if (parked == null) return;
    if (_mapReady) _camera.animateTo(center: parked, zoom: 17);
    final user = state.userPosition;
    if (user == null) {
      _showSnack(
        'Voiture garée ici. Activez votre position pour connaître la distance.',
      );
      return;
    }
    final meters = _distance(user, parked);
    _showSnack(
      'Voiture à ${_formatDistance(meters)} ${_bearingLabel(user, parked)} (à pied).',
    );
  }

  /// Direction cardinale approximative de [from] vers [to] (8 secteurs).
  String _bearingLabel(LatLng from, LatLng to) {
    final dLon = (to.longitude - from.longitude) * math.pi / 180;
    final lat1 = from.latitude * math.pi / 180;
    final lat2 = to.latitude * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final degrees = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    const labels = [
      'au nord',
      'au nord-est',
      'à l’est',
      'au sud-est',
      'au sud',
      'au sud-ouest',
      'à l’ouest',
      'au nord-ouest',
    ];
    return labels[(((degrees + 22.5) ~/ 45) % 8).toInt()];
  }

  Widget _buildMapControls(ParkingMapState state, bool sidePanel) {
    if (state.suggestions.isNotEmpty || (!sidePanel && state.notice != null)) {
      return const SizedBox.shrink();
    }
    // Pinch et double-tap zoom sont actifs par défaut dans flutter_map :
    // aucun bouton de zoom nécessaire, comme Waze/Apple Plans.
    final guiding = state.phase == ParkingMapPhase.guiding;
    final showLegalToggle =
        state.parisSpots.isNotEmpty &&
        state.phase != ParkingMapPhase.preview &&
        !guiding;
    return Align(
      alignment: sidePanel ? Alignment.centerLeft : const Alignment(1, -0.48),
      child: SafeArea(
        minimum: const EdgeInsets.all(ParkRadarSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Conduite façon Waze : zéro FAB tant que la caméra suit ; seul
            // « Recentrer » apparaît après un pan manuel.
            if (!guiding)
              ParkMapFab(
                icon: const Icon(Icons.my_location),
                tooltip: 'Afficher ma position',
                onPressed: () =>
                    unawaited(_requestCurrentLocation(moveCamera: true)),
              ),
            if (guiding && !_cameraFollowing)
              ParkMapFab(
                icon: const Icon(Icons.navigation),
                tooltip: 'Recentrer sur ma position',
                active: true,
                opaque: true,
                onPressed: () {
                  Haptics.selection();
                  setState(() => _cameraFollowing = true);
                  final position = state.userPosition;
                  if (position != null && _mapReady) {
                    _camera.animateTo(center: position, zoom: 17);
                  }
                },
              ),
            if (showLegalToggle) ...[
              const SizedBox(height: ParkRadarSpacing.sm),
              Semantics(
                selected: state.showLegalLayer,
                child: ParkMapFab(
                  icon: AnimatedSwitcher(
                    duration: ParkRadarMotion.standard,
                    switchInCurve: ParkRadarMotion.enter,
                    switchOutCurve: ParkRadarMotion.exit,
                    transitionBuilder: (child, animation) =>
                        ScaleTransition(scale: animation, child: child),
                    child: Icon(
                      state.showLegalLayer ? Icons.rule : Icons.rule_outlined,
                      key: ValueKey<bool>(state.showLegalLayer),
                    ),
                  ),
                  tooltip: state.showLegalLayer
                      ? 'Afficher les estimations'
                      : 'Afficher la réglementation',
                  active: state.showLegalLayer,
                  onPressed: _controller.toggleLegalLayer,
                ),
              ),
            ],
            if (state.parkedPosition != null && !guiding) ...[
              const SizedBox(height: ParkRadarSpacing.sm),
              ParkMapFab(
                icon: const Icon(Icons.directions_car),
                tooltip: 'Retrouver ma voiture',
                onPressed: _findMyCar,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTopOverlay(ParkingMapState state, _MapLayerMode mode) {
    return ParkMapOverlayShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.phase == ParkingMapPhase.guiding)
            _buildNavigationHud(state)
          else
            ParkSearchShell(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: _controller.search,
              onSubmitted: (_) {
                if (state.suggestions.isNotEmpty) {
                  unawaited(
                    _controller.selectDestination(state.suggestions.first),
                  );
                  _searchFocusNode.unfocus();
                }
              },
              onClear: () {
                unawaited(_stopPositionTracking());
                _controller.clearDestination();
              },
              isLoading: state.searching,
              suggestions: state.suggestions.isEmpty
                  ? null
                  : _buildSuggestions(state.suggestions),
            ),
          if (state.notice != null) ...[
            const SizedBox(height: ParkRadarSpacing.xs),
            ParkStatusBanner(
              title: _noticeTitle(state),
              message: state.notice,
              tone: _noticeTone(state),
              actionLabel:
                  state.destination != null &&
                      (state.phase == ParkingMapPhase.failure ||
                          state.streetStatus == DataLayerStatus.unavailable)
                  ? 'Réessayer'
                  : null,
              onAction:
                  state.destination != null &&
                      (state.phase == ParkingMapPhase.failure ||
                          state.streetStatus == DataLayerStatus.unavailable)
                  ? () => unawaited(_controller.retryDestination())
                  : null,
              onDismiss: _controller.dismissNotice,
            ),
          ],
          if (_tileUnavailable) ...[
            const SizedBox(height: ParkRadarSpacing.xs),
            ParkStatusBanner(
              title: 'Fond de carte partiellement indisponible',
              message: 'Les données ParkRadar restent visibles.',
              tone: ParkStatusTone.warning,
              onDismiss: () => setState(() => _tileUnavailable = false),
            ),
          ],
          if (_legendVisible(state, mode)) ...[
            const SizedBox(height: ParkRadarSpacing.xs),
            Align(alignment: Alignment.center, child: _buildLegend(mode)),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestions(List<GeocodingResult> suggestions) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.parkRadarColors;
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: ParkRadarSpacing.xxs),
      itemCount: suggestions.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: 56, // aligné sur le texte, pas sur la pastille
        color: scheme.outlineVariant.withValues(alpha: 0.45),
      ),
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        final label = _structuredAddress(suggestion.displayName);
        return ListTile(
          minTileHeight: ParkRadarSizes.minimumTouchTarget,
          horizontalTitleGap: ParkRadarSpacing.sm,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: ParkRadarSpacing.sm,
          ),
          leading: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.brand.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.place_outlined,
              size: ParkRadarSizes.compactIcon,
              color: colors.brand,
            ),
          ),
          title: Text(
            label.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
              color: scheme.onSurface,
            ),
          ),
          subtitle: label.subtitle.isEmpty
              ? null
              : Text(
                  label.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
          onTap: () {
            _searchFocusNode.unfocus();
            unawaited(_controller.selectDestination(suggestion));
          },
        );
      },
    );
  }

  ({String title, String subtitle}) _structuredAddress(String displayName) {
    final parts = displayName
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return (title: displayName, subtitle: '');
    if (parts.length >= 2 && int.tryParse(parts.first) != null) {
      return (
        title: '${parts.first} ${parts[1]}',
        subtitle: parts.skip(2).join(', '),
      );
    }
    return (title: parts.first, subtitle: parts.skip(1).join(', '));
  }

  Widget _buildNavigationHud(ParkingMapState state) {
    final route = state.route;
    final step = route == null || route.steps.isEmpty
        ? null
        : route.steps[_guidanceStepIndex.clamp(0, route.steps.length - 1)];
    final nextStep =
        route != null &&
            route.steps.isNotEmpty &&
            _guidanceStepIndex + 1 < route.steps.length
        ? route.steps[_guidanceStepIndex + 1]
        : null;
    final snapshot = _guidanceSnapshot;
    // Distance le long de l'itinéraire (précise) plutôt qu'à vol d'oiseau.
    final meters =
        snapshot?.distanceToNextManeuverMeters ??
        (step == null || state.userPosition == null
            ? null
            : _distance(state.userPosition!, step.location));
    final colors = context.parkRadarColors;

    return Semantics(
      container: true,
      liveRegion: true,
      label: step?.instruction ?? 'Suivez l’itinéraire',
      child: Material(
        color: ParkRadarHud.surface,
        elevation: 10,
        shadowColor: Colors.black54,
        borderRadius: ParkRadarHud.radius,
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [ParkRadarHud.surfaceTop, ParkRadarHud.surface],
            ),
            borderRadius: ParkRadarHud.radius,
            border: Border.all(color: ParkRadarHud.rim),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ParkRadarSpacing.md,
                  ParkRadarSpacing.sm,
                  ParkRadarSpacing.xs,
                  ParkRadarSpacing.sm,
                ),
                child: AnimatedSwitcher(
                  duration: ParkRadarMotion.standard,
                  switchInCurve: ParkRadarMotion.enter,
                  switchOutCurve: ParkRadarMotion.exit,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.35),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_guidanceStepIndex),
                    child: _hudInstructionRow(step, nextStep, meters, colors),
                  ),
                ),
              ),
              if (snapshot != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ParkRadarSpacing.md,
                    vertical: 10,
                  ),
                  decoration: const BoxDecoration(
                    color: ParkRadarHud.footer,
                    border: Border(
                      top: BorderSide(color: ParkRadarHud.divider),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.schedule,
                        size: 16,
                        color: ParkRadarHud.muted,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Arrivée ${_formatEta(snapshot.remainingDurationSeconds)}',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: ParkRadarHud.onSurface,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: ParkRadarSpacing.xs),
                      Expanded(
                        child: Text(
                          '· ${_formatDistance(snapshot.remainingRouteMeters)} restants',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: ParkRadarHud.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              AnimatedSize(
                duration: ParkRadarMotion.standard,
                curve: ParkRadarMotion.enter,
                alignment: Alignment.topCenter,
                child: !_gpsLost
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(
                          ParkRadarSpacing.sm,
                          ParkRadarSpacing.xs,
                          ParkRadarSpacing.sm,
                          ParkRadarSpacing.sm,
                        ),
                        child: _gpsLostBanner(colors),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Micro-célébration « place trouvée » : le moment banal devient une petite
  /// victoire (cœur du delight Waze). Brève, non bloquante, respecte les
  /// animations réduites.
  void _showParkedCelebration() {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _celebrationTimer?.cancel();
    setState(() => _celebrating = true);
    _celebrationTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _celebrating = false);
    });
  }

  Widget _celebrationBadge() {
    final colors = context.parkRadarColors;
    return Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        color: colors.success.background,
        shape: BoxShape.circle,
        border: Border.all(color: colors.success.border, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      child: Icon(
        Icons.check_rounded,
        size: 64,
        color: colors.success.foreground,
      ),
    );
  }

  Widget _gpsLostBanner(ParkRadarColors colors) {
    // Contraste HUD : couleurs fixes lisibles sur la carte navy de conduite.
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ParkRadarSpacing.sm,
          vertical: ParkRadarSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF3D1412),
          border: Border.all(color: const Color(0xFFF97066)),
          borderRadius: ParkRadarRadii.control,
        ),
        child: const Row(
          children: [
            Icon(Icons.gps_off, size: 16, color: Color(0xFFF97066)),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'Signal GPS perdu — reprise automatique en cours…',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFFD9D4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hudInstructionRow(
    RouteStep? step,
    RouteStep? nextStep,
    double? meters,
    ParkRadarColors colors,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ExcludeSemantics(
          child: Container(
            width: ParkRadarSizes.hudManeuverTile,
            height: ParkRadarSizes.hudManeuverTile,
            decoration: const BoxDecoration(
              color: ParkRadarHud.maneuverTile,
              borderRadius: BorderRadius.all(Radius.circular(18)),
              boxShadow: [
                BoxShadow(
                  color: ParkRadarHud.maneuverGlow,
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              _maneuverIcon(step?.maneuver),
              color: ParkRadarHud.onManeuverTile,
              size: ParkRadarSizes.hudManeuverIcon,
            ),
          ),
        ),
        const SizedBox(width: ParkRadarSpacing.sm),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              meters == null
                  ? const Text(
                      'Itinéraire en cours',
                      style: TextStyle(
                        fontSize: 24,
                        height: 1.0,
                        fontWeight: FontWeight.w800,
                        color: ParkRadarHud.onSurface,
                        letterSpacing: -0.5,
                      ),
                    )
                  : _hudDistanceText(meters),
              const SizedBox(height: 2),
              Text(
                step?.instruction ?? 'Suivez l’itinéraire',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 19,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: ParkRadarHud.street,
                  letterSpacing: -0.2,
                ),
              ),
              if (nextStep != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: const BoxDecoration(
                      color: ParkRadarHud.nextChip,
                      borderRadius: ParkRadarRadii.pill,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _maneuverIcon(nextStep.maneuver),
                          size: 14,
                          color: ParkRadarHud.muted,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Puis : ${nextStep.instruction}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: ParkRadarHud.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: ParkRadarSpacing.xxs),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: _stopGuidance,
              tooltip: 'Arrêter le guidage',
              style: IconButton.styleFrom(
                backgroundColor: ParkRadarHud.control,
                foregroundColor: ParkRadarHud.onSurface,
                minimumSize: const Size(
                  ParkRadarSizes.minimumTouchTarget,
                  ParkRadarSizes.minimumTouchTarget,
                ),
                shape: const CircleBorder(),
              ),
              icon: const Icon(Icons.close, size: 22),
            ),
            const SizedBox(height: 6),
            IconButton(
              onPressed: _toggleVoiceMuted,
              tooltip: _voiceMuted
                  ? 'Réactiver le guidage vocal'
                  : 'Couper le guidage vocal',
              style: IconButton.styleFrom(
                backgroundColor: ParkRadarHud.control,
                foregroundColor: _voiceMuted
                    ? ParkRadarHud.muted
                    : ParkRadarHud.onSurface,
                minimumSize: const Size(
                  ParkRadarSizes.minimumTouchTarget,
                  ParkRadarSizes.minimumTouchTarget,
                ),
                shape: const CircleBorder(),
              ),
              icon: Icon(
                _voiceMuted ? Icons.volume_off : Icons.volume_up,
                size: 22,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// « 350 m » : nombre énorme, unité rétrogradée. [_formatDistance] émet
  /// toujours « N m » ou « N.N km » (espace garanti).
  Widget _hudDistanceText(double meters) {
    final label = _formatDistance(meters);
    final space = label.lastIndexOf(' ');
    final value = space == -1 ? label : label.substring(0, space);
    final unit = space == -1 ? '' : label.substring(space + 1);
    return Text.rich(
      TextSpan(
        text: value,
        style: const TextStyle(
          fontSize: 34,
          height: 1.0,
          fontWeight: FontWeight.w800,
          color: ParkRadarHud.onSurface,
          letterSpacing: -0.5,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        children: [
          if (unit.isNotEmpty)
            TextSpan(
              text: ' $unit',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: ParkRadarHud.unit,
              ),
            ),
        ],
      ),
      maxLines: 1,
    );
  }

  void _toggleVoiceMuted() {
    Haptics.selection();
    setState(() {
      _voiceMuted = !_voiceMuted;
      _voiceGuidance.muted = _voiceMuted;
    });
    if (_voiceMuted) unawaited(_voiceGuidance.stop());
  }

  /// Heure d'arrivée estimée (« 18h42 ») à partir de la durée restante.
  String _formatEta(double remainingSeconds) {
    final eta = DateTime.now().add(Duration(seconds: remainingSeconds.round()));
    final h = eta.hour.toString();
    final m = eta.minute.toString().padLeft(2, '0');
    return '${h}h$m';
  }

  Widget _buildLegend(_MapLayerMode mode) {
    final colors = context.parkRadarColors;
    final entries = switch (mode) {
      // Alignée sur les couleurs et motifs réels des traits de la carte.
      _MapLayerMode.availability || _MapLayerMode.route => [
        _LegendEntry('Faible', colors.availabilityLow, _LineKind.dashed),
        _LegendEntry('Modéré', colors.availabilityMedium, _LineKind.dashed),
        _LegendEntry('Favorable', colors.availabilityHigh, _LineKind.solid),
      ],
      _MapLayerMode.legal => [
        _LegendEntry('Payant', colors.brand, _LineKind.solid),
        _LegendEntry('Gratuit', colors.success.foreground, _LineKind.dotted),
        _LegendEntry(
          'Résident',
          colors.confidenceLow.foreground,
          _LineKind.dashed,
        ),
        _LegendEntry('Réservé', colors.warning.foreground, _LineKind.dashed),
        _LegendEntry('Interdit', colors.danger.foreground, _LineKind.dotted),
      ],
    };
    return ParkGlass(
      borderRadius: ParkRadarRadii.pill,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ParkRadarSpacing.md,
          vertical: 6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              spacing: ParkRadarSpacing.sm,
              runSpacing: ParkRadarSpacing.xxs,
              children: [
                for (final entry in entries) _LegendItem(entry: entry),
              ],
            ),
            if (mode == _MapLayerMode.legal) ...[
              const SizedBox(height: 2),
              Text(
                'Touchez une ligne pour les détails',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.2,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResponsivePanel(ParkingMapState state) {
    final (panelKey, panel) = switch (state.phase) {
      _
          when state.parkedPosition != null &&
              state.phase != ParkingMapPhase.guiding =>
        ('parked', _buildParkedPanel(state)),
      ParkingMapPhase.idle => ('welcome', _buildWelcomePanel()),
      ParkingMapPhase.failure => ('failure', _buildFailurePanel(state)),
      _ when state.destination != null && state.loop == null => (
        'no-loop',
        _buildNoLoopPanel(state),
      ),
      _ when state.loop != null => ('loop', _buildLoopPanel(state)),
      _ => ('welcome', _buildWelcomePanel()),
    };
    return ParkResponsiveMapPanel(
      sideAlignment: Alignment.centerRight,
      // Attribution discrète mais toujours accessible, au ras de la feuille.
      aboveSheet: _AttributionPill(
        label: _attributionLabel,
        onTap: _openMapAttribution,
      ),
      // Le changement d'état glisse et fond au lieu d'apparaître d'un coup ;
      // la clé ne change qu'entre types de panneau, pas à chaque rebuild.
      child: AnimatedSwitcher(
        duration: ParkRadarMotion.panel,
        switchInCurve: ParkRadarMotion.enter,
        switchOutCurve: ParkRadarMotion.exit,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(panelKey), child: panel),
      ),
    );
  }

  Widget _buildParkedPanel(ParkingMapState state) {
    final colors = context.parkRadarColors;
    final parkedAt = state.parkedAt;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.local_parking, color: colors.success.foreground),
            const SizedBox(width: ParkRadarSpacing.xs),
            Expanded(
              child: Text(
                'Stationnement enregistré',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        Text(
          parkedAt == null
              ? 'ParkRadar garde cette session uniquement sur cet appareil.'
              : 'Garé ${_formatParkedAt(parkedAt)}. Signalez votre départ '
                    'seulement lorsque la place est réellement libre.',
        ),
        const SizedBox(height: ParkRadarSpacing.md),
        FilledButton.icon(
          onPressed: state.reporting ? null : _reportFreed,
          icon: state.reporting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.directions_car_filled_outlined),
          label: const Text('Je libère ma place'),
        ),
      ],
    );
  }

  Widget _buildWelcomePanel() {
    final theme = Theme.of(context);
    final colors = context.parkRadarColors;
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.brand.withValues(alpha: isDark ? 0.18 : 0.10),
                borderRadius: ParkRadarRadii.control,
              ),
              child: Icon(Icons.local_parking, color: colors.brand, size: 22),
            ),
            const SizedBox(width: ParkRadarSpacing.sm),
            Expanded(
              child: Text(
                'Trouvez une rue, pas une promesse',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(left: 40 + ParkRadarSpacing.sm),
          child: Text(
            'Cherchez une adresse : ParkRadar trace une boucle de rues où '
            'une place est probable.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFailurePanel(ParkingMapState state) {
    final theme = Theme.of(context);
    final colors = context.parkRadarColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.danger.background,
                borderRadius: ParkRadarRadii.control,
              ),
              child: Icon(
                Icons.cloud_off_outlined,
                color: colors.danger.foreground,
                size: 22,
              ),
            ),
            const SizedBox(width: ParkRadarSpacing.sm),
            Expanded(
              child: Text(
                'Analyse indisponible',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        Text(
          'Les données de stationnement n’ont pas pu être chargées. '
          'Vérifiez la connexion, puis relancez.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: ParkRadarSpacing.md),
        FilledButton.icon(
          onPressed: state.destination == null
              ? null
              : () => unawaited(_controller.retryDestination()),
          icon: const Icon(Icons.refresh),
          label: const Text('Réessayer l’analyse'),
        ),
      ],
    );
  }

  Widget _buildNoLoopPanel(ParkingMapState state) {
    final legalUnavailable = !state.hasVerifiedLegalCoverage;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          legalUnavailable
              ? 'Inventaire des régimes indisponible'
              : 'Aucune boucle recommandable trouvée',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        Text(
          legalUnavailable
              ? 'Sans l’inventaire officiel Paris Data, aucune rue n’est '
                    'recommandée. Réessayez dans un instant.'
              : 'Pas de signal suffisant autour d’ici. Élargissez la zone '
                    'ou réessayez plus tard.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: ParkRadarSpacing.sm),
        _legalSummary(state),
        const SizedBox(height: ParkRadarSpacing.md),
        FilledButton.icon(
          onPressed: () => unawaited(_controller.retryDestination()),
          icon: const Icon(Icons.refresh),
          label: const Text('Actualiser les données'),
        ),
      ],
    );
  }

  /// Feuille de conduite minimale, façon Waze : le HUD porte déjà
  /// l'instruction, l'ETA et l'arrêt (croix « Arrêter le guidage ») ; la
  /// feuille se réduit à la cible et à l'action reine. La durée de boucle
  /// couvre le trou avant le premier snapshot GPS du HUD.
  Widget _buildGuidingSheet(ParkingMapState state) {
    final loop = state.loop!;
    final ranked = [...loop.orderedSegments]
      ..sort((a, b) => b.probabilityFree.compareTo(a.probabilityFree));
    final best = ranked.first;
    final minutes = state.route == null
        ? null
        : (state.route!.durationSeconds / 60).ceil().clamp(1, 999);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          minutes == null
              ? 'Visez ${best.segment.name}'
              : 'Visez ${best.segment.name} · $minutes min',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          // Thème conduite forcé sombre (ParkRadarTheme.dark) : token HUD
          // lisible sur la feuille (~5,2:1).
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: ParkRadarHud.muted,
          ),
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        FilledButton.icon(
          onPressed: state.reporting ? null : _reportParked,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF22C55E),
            foregroundColor: const Color(0xFF052E16),
            disabledBackgroundColor: const Color(0xFF14532D),
            disabledForegroundColor: const Color(0xFF86EFAC),
            minimumSize: const Size.fromHeight(ParkRadarSizes.hudActionHeight),
            shape: const RoundedRectangleBorder(
              borderRadius: ParkRadarRadii.card,
            ),
            textStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
            elevation: 4,
            shadowColor: const Color(0x8022C55E),
          ),
          icon: state.reporting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Color(0xFF86EFAC),
                  ),
                )
              : const Icon(Icons.local_parking, size: 26),
          label: const Text('Place trouvée'),
        ),
      ],
    );
  }

  Widget _buildLoopPanel(ParkingMapState state) {
    if (state.phase == ParkingMapPhase.guiding) {
      return _buildGuidingSheet(state);
    }
    final loop = state.loop!;
    final ranked = [...loop.orderedSegments]
      ..sort((a, b) => b.probabilityFree.compareTo(a.probabilityFree));
    final best = ranked.first;
    final route = state.route;
    final routeMinutes = route == null
        ? null
        : (route.durationSeconds / 60).ceil().clamp(1, 999);
    final loopSummary = routeMinutes == null
        ? '${loop.orderedSegments.length} zones à parcourir'
        : 'boucle routée d’environ $routeMinutes min';
    final difficulty = loop.difficulty;
    final preview = state.phase == ParkingMapPhase.preview;
    final canRoute = state.canStartGuidance;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${difficulty.label} · ${difficulty.expectedTimeLabel}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: ParkRadarSpacing.xxs),
                  Text(
                    'Visez ${best.segment.name} · $loopSummary',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _pickArrivalHour,
              tooltip: 'Changer l’heure d’arrivée',
              icon: const Icon(Icons.schedule),
            ),
          ],
        ),
        const SizedBox(height: ParkRadarSpacing.sm),
        Wrap(
          spacing: ParkRadarSpacing.xs,
          runSpacing: ParkRadarSpacing.xs,
          children: [
            _predictionConfidenceChip(state),
            _predictionFreshnessChip(state),
          ],
        ),
        if (_communityNoteworthy(state)) ...[
          const SizedBox(height: ParkRadarSpacing.xs),
          Text(
            _communityFreshnessLabel(state),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
        const SizedBox(height: ParkRadarSpacing.sm),
        _legalSummary(state, compact: true),
        const SizedBox(height: ParkRadarSpacing.sm),
        _arrivalControl(state),
        if (route != null) ...[
          const SizedBox(height: ParkRadarSpacing.sm),
          _routeSummary(route, preview: preview, guiding: false),
        ],
        const SizedBox(height: ParkRadarSpacing.md),
        if (preview) ...[
          FilledButton.icon(
            onPressed: canRoute && !state.routing ? _startGuidance : null,
            icon: state.routing
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.gps_fixed),
            label: const Text('Démarrer avec le GPS'),
          ),
          TextButton(
            onPressed: _controller.stopGuidance,
            child: const Text('Fermer l’aperçu'),
          ),
        ] else
          FilledButton.icon(
            onPressed: canRoute && !state.routing ? _previewRoute : null,
            icon: state.routing
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.alt_route),
            label: const Text('Prévisualiser la boucle'),
          ),
        if (!state.hasVerifiedLegalCoverage) ...[
          const SizedBox(height: ParkRadarSpacing.xs),
          Text(
            'Guidage désactivé tant que l’inventaire des régimes n’est pas disponible.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _predictionConfidenceChip(ParkingMapState state) {
    final confidence = state.predictionConfidence;
    final level = switch (confidence) {
      AvailabilityConfidence.veryLow ||
      AvailabilityConfidence.low => ParkConfidenceLevel.low,
      AvailabilityConfidence.medium => ParkConfidenceLevel.medium,
      AvailabilityConfidence.high => ParkConfidenceLevel.high,
      null => ParkConfidenceLevel.unknown,
    };
    final estimates = state.availabilityEstimates.values;
    final supervisedCount = estimates.isEmpty
        ? 0
        : estimates
              .map((estimate) => estimate.supervisedObservationCount)
              .reduce((a, b) => a < b ? a : b);
    final calibration = state.predictionVersions?.calibration ?? '';
    final calibrationLabel = calibration.toLowerCase().contains('uncalibrated')
        ? 'non calibré'
        : calibration.isEmpty
        ? 'calibration inconnue'
        : 'calibré';
    return ParkConfidenceChip(
      level: level,
      detail:
          '$calibrationLabel · $supervisedCount observation${supervisedCount > 1 ? 's' : ''} terrain',
    );
  }

  Widget _predictionFreshnessChip(ParkingMapState state) {
    final freshness = state.predictionFreshnessAt(DateTime.now());
    final level = switch (freshness) {
      AvailabilityFreshness.live => ParkFreshnessLevel.live,
      AvailabilityFreshness.recent => ParkFreshnessLevel.fresh,
      AvailabilityFreshness.stale ||
      AvailabilityFreshness.expired => ParkFreshnessLevel.stale,
      null => ParkFreshnessLevel.unavailable,
    };
    final age = state.legalDataAgeAt(DateTime.now());
    final coverage = (state.legalDataTimestampCoverage * 100).round();
    final detail = age == null
        ? state.parisSpots.isEmpty
              ? 'source métier absente'
              : 'date source incomplète · $coverage % horodaté'
        : 'source métier ${_formatDataAge(age)}';
    return ParkFreshnessChip(level: level, detail: detail);
  }

  /// La ligne communauté n'est affichée que quand elle change la lecture :
  /// signal ignoré (mise à jour échouée) ou arrivée future (non appliquée).
  /// Le cas nominal est déjà porté par le chip de fraîcheur.
  bool _communityNoteworthy(ParkingMapState state) =>
      !state.isNow || state.communityStatus == DataLayerStatus.stale;

  String _communityFreshnessLabel(ParkingMapState state) {
    if (!state.isNow) {
      return 'Communauté : non appliquée à une arrivée future.';
    }
    final updatedAt = state.communityUpdatedAt;
    return switch (state.communityStatus) {
      DataLayerStatus.fresh when updatedAt != null =>
        'Communauté : relevée il y a '
            '${_formatAge(DateTime.now().difference(updatedAt))}.',
      DataLayerStatus.loading => 'Communauté : mise à jour en cours.',
      DataLayerStatus.stale =>
        'Communauté : dernière mise à jour échouée, ancien signal ignoré.',
      _ => 'Communauté : aucun signal récent disponible.',
    };
  }

  Widget _legalSummary(ParkingMapState state, {bool compact = false}) {
    final colors = context.parkRadarColors;
    final available = state.hasVerifiedLegalCoverage;
    final stale = available && state.legalStatus == DataLayerStatus.stale;
    final eligible = state.eligibility.values
        .where((item) => item.status == EligibilityStatus.eligible)
        .length;
    final regimes = state.parisSpots.map((spot) => spot.regime.label).toSet();
    final regimeText = regimes.take(5).join(', ');
    final age = state.legalDataAgeAt(DateTime.now());
    final timestampCoverage = (state.legalDataTimestampCoverage * 100).round();
    final tone = !available
        ? colors.danger
        : stale
        ? colors.warning
        : colors.success;
    final statusText = !available
        ? 'Inventaire des régimes indisponible : recommandations bloquées'
        : stale
        ? 'Inventaire Paris chargé mais ancien'
              '${age == null ? ' · date source incomplète ($timestampCoverage % horodaté)' : ' · source ${_formatDataAge(age)}'}'
              ' · $eligible zone${eligible > 1 ? 's' : ''} compatible${eligible > 1 ? 's' : ''}'
              '${regimeText.isEmpty ? '' : '\nRégimes présents : $regimeText'}'
              '\nLa signalisation sur place prévaut.'
        : 'Inventaire Paris chargé · $eligible zone${eligible > 1 ? 's' : ''} '
              'jugée${eligible > 1 ? 's' : ''} compatible${eligible > 1 ? 's' : ''}'
              '${age == null ? '' : ' · source ${_formatDataAge(age)}'}'
              '${compact || regimeText.isEmpty ? '' : '\nRégimes présents : $regimeText'}';
    return Semantics(
      label: !available
          ? 'Inventaire des régimes Paris indisponible'
          : stale
          ? 'Inventaire des régimes Paris chargé mais ancien, $eligible zones compatibles, la signalisation sur place prévaut'
          : 'Inventaire des régimes Paris chargé, $eligible zones jugées compatibles',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tone.background,
          border: Border.all(color: tone.border),
          borderRadius: ParkRadarRadii.control,
        ),
        child: Padding(
          padding: const EdgeInsets.all(ParkRadarSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                !available
                    ? Icons.gpp_bad_outlined
                    : stale
                    ? Icons.history_toggle_off
                    : Icons.verified_outlined,
                color: tone.foreground,
                size: ParkRadarSizes.compactIcon,
              ),
              const SizedBox(width: ParkRadarSpacing.xs),
              Expanded(
                child: Text(
                  statusText,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tone.foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _arrivalControl(ParkingMapState state) {
    return Row(
      children: [
        const Icon(Icons.schedule, size: ParkRadarSizes.compactIcon),
        const SizedBox(width: ParkRadarSpacing.xs),
        Expanded(
          child: Text(
            state.plannedArrival == null
                ? 'Arrivée : maintenant'
                : 'Arrivée : ${_formatArrival(state.plannedArrival!)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        TextButton(onPressed: _pickArrivalHour, child: const Text('Modifier')),
        if (state.plannedArrival != null)
          IconButton(
            onPressed: () => _controller.setArrivalHour(null),
            tooltip: 'Revenir à maintenant',
            icon: const Icon(Icons.restart_alt),
          ),
      ],
    );
  }

  Widget _routeSummary(
    DrivingRoute route, {
    required bool preview,
    required bool guiding,
  }) {
    final firstInstruction = route.steps.isEmpty
        ? null
        : route.steps.first.instruction;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          guiding ? Icons.navigation : Icons.route_outlined,
          size: ParkRadarSizes.compactIcon,
          color: context.parkRadarColors.route,
        ),
        const SizedBox(width: ParkRadarSpacing.xs),
        Expanded(
          child: Text(
            '${preview ? 'Aperçu' : 'Itinéraire'} · '
            '${_formatDistance(route.distanceMeters)} · '
            '${_formatDuration(route.durationSeconds)}'
            '${firstInstruction == null ? '' : '\n$firstInstruction'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  _MapLayerMode _layerMode(ParkingMapState state) {
    if (state.phase == ParkingMapPhase.guiding ||
        state.phase == ParkingMapPhase.preview) {
      return _MapLayerMode.route;
    }
    if (state.showLegalLayer) return _MapLayerMode.legal;
    return _MapLayerMode.availability;
  }

  /// Un tronçon de disponibilité n'est dessiné que s'il est recommandable et
  /// porte un signal. Même prédicat pour la couche ET pour la légende.
  static bool _isDrawnAvailability(
    ParkingMapState state,
    ScoredSegment scored,
  ) =>
      state.eligibility[scored.segment.id]?.canRecommend == true &&
      scored.probabilityFree > 0.01;

  /// La légende n'apparaît que quand elle décode réellement l'écran :
  /// - réglementation : dès qu'il existe des tronçons officiels (la couche
  ///   dessinée lit parisSpots, pas scoredSegments) ;
  /// - disponibilité : seulement si au moins un trait est dessiné ;
  /// - aperçu/guidage (mode route) : jamais — choix produit façon Waze,
  ///   pastilles numérotées, triple trait et feuille basse portent déjà
  ///   l'information.
  bool _legendVisible(ParkingMapState state, _MapLayerMode mode) {
    if (_tileUnavailable || state.suggestions.isNotEmpty) return false;
    return switch (mode) {
      _MapLayerMode.legal => state.parisSpots.isNotEmpty,
      _MapLayerMode.availability =>
        state.notice == null &&
            state.scoredSegments.any(
              (scored) => _isDrawnAvailability(state, scored),
            ),
      _MapLayerMode.route => false,
    };
  }

  _AvailabilityLevel _availabilityLevel(double value) {
    if (value < 0.33) return _AvailabilityLevel.low;
    if (value < 0.66) return _AvailabilityLevel.medium;
    return _AvailabilityLevel.high;
  }


  String _noticeTitle(ParkingMapState state) {
    if (state.phase == ParkingMapPhase.failure ||
        state.streetStatus == DataLayerStatus.unavailable) {
      return 'Analyse indisponible';
    }
    if (state.legalStatus == DataLayerStatus.unavailable ||
        state.legalStatus == DataLayerStatus.unsupported) {
      return 'Couverture réglementaire insuffisante';
    }
    return 'Information ParkRadar';
  }

  ParkStatusTone _noticeTone(ParkingMapState state) {
    if (state.phase == ParkingMapPhase.failure ||
        state.streetStatus == DataLayerStatus.unavailable) {
      return ParkStatusTone.error;
    }
    if (state.legalStatus == DataLayerStatus.unavailable ||
        state.legalStatus == DataLayerStatus.unsupported) {
      return ParkStatusTone.warning;
    }
    return ParkStatusTone.info;
  }

  IconData _maneuverIcon(String? maneuver) {
    if (maneuver == null) return Icons.navigation;
    if (maneuver.contains('uturn')) return Icons.u_turn_left;
    if (maneuver.contains('left')) return Icons.turn_left;
    if (maneuver.contains('right')) return Icons.turn_right;
    if (maneuver.startsWith('arrive')) return Icons.flag;
    if (maneuver.contains('roundabout') || maneuver.contains('rotary')) {
      return Icons.roundabout_right;
    }
    return Icons.straight;
  }

  String _formatArrival(DateTime arrival) {
    final now = atParis(DateTime.now());
    final parisArrival = atParis(arrival);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(
      parisArrival.year,
      parisArrival.month,
      parisArrival.day,
    );
    final prefix = day == today
        ? 'aujourd’hui'
        : day == today.add(const Duration(days: 1))
        ? 'demain'
        : '${parisArrival.day.toString().padLeft(2, '0')}/'
              '${parisArrival.month.toString().padLeft(2, '0')}';
    return '$prefix à ${parisArrival.hour.toString().padLeft(2, '0')} h';
  }

  String _formatParkedAt(DateTime parkedAt) {
    final age = DateTime.now().difference(parkedAt);
    if (!age.isNegative && age < const Duration(hours: 24)) {
      return 'il y a ${_formatAge(age)}';
    }
    final parisParkedAt = atParis(parkedAt);
    return 'le ${parisParkedAt.day.toString().padLeft(2, '0')}/'
        '${parisParkedAt.month.toString().padLeft(2, '0')} à '
        '${parisParkedAt.hour.toString().padLeft(2, '0')}:'
        '${parisParkedAt.minute.toString().padLeft(2, '0')}';
  }

  String _formatSourceDate(DateTime value) {
    final parisDate = atParis(value);
    return 'le ${parisDate.day.toString().padLeft(2, '0')}/'
        '${parisDate.month.toString().padLeft(2, '0')}/${parisDate.year}';
  }

  String _formatDataAge(Duration age) {
    final safeAge = age.isNegative ? Duration.zero : age;
    if (safeAge.inDays >= 730) return 'il y a ${safeAge.inDays ~/ 365} ans';
    if (safeAge.inDays >= 365) return 'il y a 1 an';
    if (safeAge.inDays >= 2) return 'il y a ${safeAge.inDays} jours';
    return 'il y a ${_formatAge(safeAge)}';
  }

  String _formatAge(Duration age) {
    final safeAge = age.isNegative ? Duration.zero : age;
    if (safeAge.inSeconds < 60) return '${safeAge.inSeconds} s';
    if (safeAge.inMinutes < 60) return '${safeAge.inMinutes} min';
    return '${safeAge.inHours} h';
  }

  String _formatDistance(num meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _formatDuration(double seconds) {
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest';
  }
}

enum _MapLayerMode { availability, legal, route }

enum _AvailabilityLevel { low, medium, high }

enum _LineKind { solid, dashed, dotted }

class _MapLoadingCard extends StatelessWidget {
  const _MapLoadingCard();

  @override
  Widget build(BuildContext context) {
    // Plein écran via Center (enfant non positionné du Stack) mais
    // strictement informatif : IgnorePointer garantit que ni le Center
    // étiré ni la Card ne volent les gestes de la carte pendant le
    // chargement (famille « voile », variante hit-test).
    return IgnorePointer(
      child: Center(
        child: Semantics(
          container: true,
          liveRegion: true,
          label: 'Analyse des rues et de l’inventaire des régimes en cours',
          child: ExcludeSemantics(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(ParkRadarSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: ParkRadarSpacing.sm),
                    Text(
                      'Analyse des rues et des régimes…',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapAttribution extends StatelessWidget {
  const _MapAttribution({
    required this.alignment,
    required this.label,
    required this.onTap,
  });

  final Alignment alignment;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(ParkRadarSpacing.xs),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: _AttributionPill(label: label, onTap: onTap),
          ),
        ),
      ),
    );
  }
}

/// Pilule d'attribution : cible tactile de 48 pt garantie (obligation
/// OSM/CARTO), visuel réduit à une petite étiquette translucide. L'InkWell
/// déborde en zone transparente au-dessus de l'étiquette.
class _AttributionPill extends StatelessWidget {
  const _AttributionPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        button: true,
        label: 'Informations et licences cartographiques',
        child: InkWell(
          onTap: onTap,
          borderRadius: ParkRadarRadii.pill,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: ParkRadarSizes.minimumTouchTarget,
            ),
            // widthFactor OBLIGATOIRE : sans lui la pilule s'étirerait sur
            // toute la largeur disponible (leçon du « voile » corrigé).
            child: Align(
              alignment: Alignment.bottomLeft,
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.88),
                  borderRadius: ParkRadarRadii.pill,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ParkRadarSpacing.xs,
                    vertical: 3,
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      height: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LegendEntry {
  const _LegendEntry(this.label, this.color, this.kind);

  final String label;
  final Color color;
  final _LineKind kind;
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.entry});

  final _LegendEntry entry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: entry.label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 10,
              child: CustomPaint(
                painter: _LineSwatchPainter(
                  color: entry.color,
                  kind: entry.kind,
                ),
              ),
            ),
            const SizedBox(width: ParkRadarSpacing.xxs),
            Text(
              entry.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.parkRadarColors.mapControlForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineSwatchPainter extends CustomPainter {
  const _LineSwatchPainter({required this.color, required this.kind});

  final Color color;
  final _LineKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    switch (kind) {
      case _LineKind.solid:
        canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
      case _LineKind.dashed:
        for (var x = 1.0; x < size.width; x += 8) {
          canvas.drawLine(
            Offset(x, y),
            Offset((x + 4).clamp(0, size.width), y),
            paint,
          );
        }
      case _LineKind.dotted:
        for (var x = 2.0; x < size.width; x += 5) {
          canvas.drawCircle(Offset(x, y), 1.5, paint);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _LineSwatchPainter oldDelegate) {
    return color != oldDelegate.color || kind != oldDelegate.kind;
  }
}
