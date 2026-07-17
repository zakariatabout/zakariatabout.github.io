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
import '../services/location_service.dart';
import '../services/overpass_service.dart';
import '../services/paris_parking_service.dart';
import '../services/paris_time.dart';
import '../services/parking_eligibility_service.dart';
import '../services/parking_session_store.dart';
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
  });

  final ParkingMapController? controller;
  final LocationService? locationService;
  final ParkingSessionStore? parkingSessionStore;

  /// Moteur vocal injectable pour les tests (défaut : TTS de la plateforme).
  final SpeechEngine? speechEngine;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const _parisCenter = LatLng(48.8566, 2.3522);
  static const _distance = Distance();

  final _mapController = MapController();
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
  (Object?, Object?, ParkRadarColors)? _memoAvailabilityKey;
  List<Polyline>? _memoLoopOnly;
  (Object?, Object?, ParkRadarColors)? _memoLoopOnlyKey;
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
        communityPollInterval: AppConfig.communityPollInterval,
      );
    }

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
      _afterMapReady(() => _mapController.move(next.destination!, 16));
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
    _mapController.fitCamera(
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
      if (moveCamera && _mapReady) _mapController.move(sample.position, 17);
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
    _enterGuidanceSideEffects();
    _capturePendingSearch();
    if (_mapReady) _mapController.move(origin, 17);
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
    if (speed > 1.5 && heading.isFinite && heading >= 0 && heading <= 360) {
      _mapController.moveAndRotate(sample.position, zoom, -heading);
    } else {
      _mapController.move(sample.position, zoom);
    }
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

  void _zoomBy(double delta) {
    if (!_mapReady) return;
    final camera = _mapController.camera;
    final nextZoom = (camera.zoom + delta).clamp(11.0, 20.0);
    _mapController.move(camera.center, nextZoom);
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
    final scaffold = Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final sidePanel = ParkRadarBreakpoints.usesSidePanel(
            constraints.biggest,
          );
          final mode = _layerMode(state);
          return Stack(
            children: [
              Positioned.fill(child: _buildMap(state, mode, sidePanel)),
              _buildMapControls(state, sidePanel),
              _buildTopOverlay(state, mode),
              if (state.phase == ParkingMapPhase.loading)
                const _MapLoadingCard(),
              if (state.phase != ParkingMapPhase.loading)
                _buildResponsivePanel(state),
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
    final colors = context.parkRadarColors;
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _parisCenter,
        initialZoom: 13,
        minZoom: 11,
        maxZoom: 20,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        onMapReady: _onMapReady,
        onTap: (_, _) {
          _searchFocusNode.unfocus();
          _controller.dismissSuggestions();
        },
        // Un pan manuel pendant le guidage rend la main à l'utilisateur ;
        // le bouton « Recentrer » réactive le suivi caméra.
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture &&
              _cameraFollowing &&
              _controller.state.phase == ParkingMapPhase.guiding) {
            setState(() => _cameraFollowing = false);
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: AppConfig.mapTileUrlTemplate,
          userAgentPackageName: 'fr.zakariatabout.parking_app',
          maxNativeZoom: 19,
          evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
          errorTileCallback: (_, _, _) => _onTileError(),
        ),
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
            PolylineLayer(
              polylines: [
                Polyline(
                  points: state.route!.points,
                  strokeWidth: 7,
                  borderStrokeWidth: 3,
                  borderColor: colors.routeCasing,
                  color: colors.route,
                ),
              ],
            ),
        ],
        MarkerLayer(markers: _staticMarkersMemo(state, mode, colors)),
        // Le marqueur véhicule vit dans sa propre couche : c'est le seul
        // élément carte qui change à chaque échantillon GPS.
        if (state.userPosition != null)
          MarkerLayer(markers: [_userMarker(state.userPosition!, colors)]),
        _MapAttribution(
          alignment: sidePanel
              ? Alignment.bottomLeft
              : const Alignment(-1, -0.25),
          label: '${AppConfig.mapTileAttribution} · Ville de Paris',
          onTap: _openMapAttribution,
        ),
      ],
    );
  }

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
        !identical(_memoAvailabilityKey!.$3, colors);
    if (fresh) {
      _memoAvailability = _availabilityPolylines(state, colors);
      _memoAvailabilityKey = (state.scoredSegments, state.loop, colors);
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
        !identical(_memoLoopOnlyKey!.$3, colors);
    if (fresh) {
      _memoLoopOnly = _availabilityPolylines(state, colors, loopOnly: true);
      _memoLoopOnlyKey = (state.scoredSegments, state.loop, colors);
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

  Marker _userMarker(LatLng position, ParkRadarColors colors) {
    return Marker(
      point: position,
      width: 28,
      height: 28,
      child: Semantics(
        label: 'Votre position',
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.route,
              shape: BoxShape.circle,
              border: Border.all(color: colors.routeCasing, width: 4),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)],
            ),
          ),
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
        if (state.eligibility[scored.segment.id]?.canRecommend == true &&
            scored.probabilityFree > 0.01 &&
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
    final tone = switch (level) {
      _AvailabilityLevel.low => colors.confidenceLow,
      _AvailabilityLevel.medium => colors.confidenceMedium,
      _AvailabilityLevel.high => colors.confidenceHigh,
    };
    final pattern = switch (level) {
      _AvailabilityLevel.low => StrokePattern.dashed(segments: const [8, 7]),
      _AvailabilityLevel.medium => const StrokePattern.dotted(
        spacingFactor: 1.8,
      ),
      _AvailabilityLevel.high => const StrokePattern.solid(),
    };
    return Polyline(
      points: scored.segment.points,
      strokeWidth: emphasized ? 7 : 5,
      borderStrokeWidth: level == _AvailabilityLevel.high ? 2 : 0,
      borderColor: tone.background,
      color: tone.foreground.withValues(alpha: emphasized ? 0.96 : 0.82),
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
          borderColor: Theme.of(context).colorScheme.surface,
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
          width: 48,
          height: 48,
          alignment: Alignment.topCenter,
          child: Semantics(
            label: 'Destination',
            child: ExcludeSemantics(
              child: Icon(
                Icons.location_pin,
                size: 48,
                color: colors.brand,
                shadows: const [Shadow(color: Colors.black38, blurRadius: 4)],
              ),
            ),
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
          width: 44,
          height: 44,
          child: Semantics(
            label: 'Votre voiture est garée ici',
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.brand,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38, blurRadius: 4),
                  ],
                ),
                child: const Icon(
                  Icons.directions_car,
                  color: Colors.white,
                  size: 22,
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
        final tone = switch (level) {
          _AvailabilityLevel.low => colors.confidenceLow,
          _AvailabilityLevel.medium => colors.confidenceMedium,
          _AvailabilityLevel.high => colors.confidenceHigh,
        };
        markers.add(
          Marker(
            point: scored.segment.midpoint,
            width: 30,
            height: 30,
            child: Semantics(
              label: 'Étape ${index + 1}, ${scored.segment.name}',
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tone.background,
                    shape: BoxShape.circle,
                    border: Border.all(color: tone.foreground, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: tone.foreground,
                        fontWeight: FontWeight.w800,
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

  Widget _buildMapControls(ParkingMapState state, bool sidePanel) {
    if (state.suggestions.isNotEmpty || (!sidePanel && state.notice != null)) {
      return const SizedBox.shrink();
    }
    final colors = context.parkRadarColors;
    final showLegalToggle =
        state.parisSpots.isNotEmpty &&
        state.phase != ParkingMapPhase.preview &&
        state.phase != ParkingMapPhase.guiding;
    return Align(
      alignment: sidePanel ? Alignment.centerLeft : const Alignment(1, -0.48),
      child: SafeArea(
        minimum: const EdgeInsets.all(ParkRadarSpacing.sm),
        child: SizedBox(
          width: ParkRadarSizes.minimumTouchTarget,
          child: Material(
            color: colors.mapControlSurface,
            elevation: 3,
            borderRadius: ParkRadarRadii.control,
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: _mapReady ? () => _zoomBy(1) : null,
                  tooltip: 'Zoomer',
                  color: colors.mapControlForeground,
                  constraints: const BoxConstraints.tightFor(
                    width: ParkRadarSizes.minimumTouchTarget,
                    height: ParkRadarSizes.minimumTouchTarget,
                  ),
                  icon: const Icon(Icons.add),
                ),
                Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                IconButton(
                  onPressed: _mapReady ? () => _zoomBy(-1) : null,
                  tooltip: 'Dézoomer',
                  color: colors.mapControlForeground,
                  constraints: const BoxConstraints.tightFor(
                    width: ParkRadarSizes.minimumTouchTarget,
                    height: ParkRadarSizes.minimumTouchTarget,
                  ),
                  icon: const Icon(Icons.remove),
                ),
                Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                IconButton(
                  onPressed: () =>
                      unawaited(_requestCurrentLocation(moveCamera: true)),
                  tooltip: 'Afficher ma position',
                  color: colors.mapControlForeground,
                  constraints: const BoxConstraints.tightFor(
                    width: ParkRadarSizes.minimumTouchTarget,
                    height: ParkRadarSizes.minimumTouchTarget,
                  ),
                  icon: const Icon(Icons.my_location),
                ),
                if (state.phase == ParkingMapPhase.guiding &&
                    !_cameraFollowing) ...[
                  Divider(
                    height: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() => _cameraFollowing = true);
                      final position = state.userPosition;
                      if (position != null && _mapReady) {
                        _mapController.move(position, 17);
                      }
                    },
                    tooltip: 'Recentrer sur ma position',
                    color: colors.brand,
                    constraints: const BoxConstraints.tightFor(
                      width: ParkRadarSizes.minimumTouchTarget,
                      height: ParkRadarSizes.minimumTouchTarget,
                    ),
                    icon: const Icon(Icons.navigation),
                  ),
                ],
                if (showLegalToggle) ...[
                  Divider(
                    height: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  Semantics(
                    selected: state.showLegalLayer,
                    child: IconButton(
                      onPressed: _controller.toggleLegalLayer,
                      tooltip: state.showLegalLayer
                          ? 'Afficher les estimations'
                          : 'Afficher la réglementation',
                      color: state.showLegalLayer
                          ? colors.brand
                          : colors.mapControlForeground,
                      constraints: const BoxConstraints.tightFor(
                        width: ParkRadarSizes.minimumTouchTarget,
                        height: ParkRadarSizes.minimumTouchTarget,
                      ),
                      icon: Icon(
                        state.showLegalLayer ? Icons.rule : Icons.rule_outlined,
                      ),
                    ),
                  ),
                ],
                if (state.parkedPosition != null) ...[
                  Divider(
                    height: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  IconButton(
                    onPressed: _findMyCar,
                    tooltip: 'Retrouver ma voiture',
                    color: colors.brand,
                    constraints: const BoxConstraints.tightFor(
                      width: ParkRadarSizes.minimumTouchTarget,
                      height: ParkRadarSizes.minimumTouchTarget,
                    ),
                    icon: const Icon(Icons.directions_car),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Recentre la carte sur la place mémorisée et annonce la distance et la
  /// direction à pied depuis la position courante. Réutilise la « session
  /// garée » déjà persistée par [_reportParked].
  void _findMyCar() {
    final state = _controller.state;
    final parked = state.parkedPosition;
    if (parked == null) return;
    if (_mapReady) _mapController.move(parked, 17);
    final user = state.userPosition;
    if (user == null) {
      _showSnack(
        'Voiture garée ici. Activez votre position pour connaître la distance.',
      );
      return;
    }
    final meters = _distance(user, parked);
    _showSnack('Voiture à ${_formatDistance(meters)} ${_bearingLabel(user, parked)} (à pied).');
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
          if (!_tileUnavailable &&
              (state.notice == null || mode == _MapLayerMode.legal) &&
              state.suggestions.isEmpty &&
              state.scoredSegments.isNotEmpty) ...[
            const SizedBox(height: ParkRadarSpacing.xs),
            Align(alignment: Alignment.center, child: _buildLegend(mode)),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestions(List<GeocodingResult> suggestions) {
    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: suggestions.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        final label = _structuredAddress(suggestion.displayName);
        return ListTile(
          minTileHeight: ParkRadarSizes.minimumTouchTarget,
          leading: const Icon(Icons.location_on_outlined),
          title: Text(
            label.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: label.subtitle.isEmpty
              ? null
              : Text(
                  label.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      container: true,
      liveRegion: true,
      label: step?.instruction ?? 'Suivez l’itinéraire',
      child: Material(
        color: scheme.surface,
        elevation: 6,
        borderRadius: ParkRadarRadii.card,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(ParkRadarSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: colors.brand,
                        borderRadius: ParkRadarRadii.control,
                      ),
                      child: Icon(
                        _maneuverIcon(step?.maneuver),
                        color: colors.onBrand,
                        size: 36,
                      ),
                    ),
                  ),
                  const SizedBox(width: ParkRadarSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          meters == null
                              ? 'Itinéraire en cours'
                              : _formatDistance(meters),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: colors.brand,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        Text(
                          step?.instruction ?? 'Suivez l’itinéraire',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (nextStep != null)
                          Text(
                            'Puis : ${nextStep.instruction}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: _stopGuidance,
                        tooltip: 'Arrêter le guidage',
                        icon: const Icon(Icons.close),
                      ),
                      IconButton(
                        onPressed: _toggleVoiceMuted,
                        tooltip: _voiceMuted
                            ? 'Réactiver le guidage vocal'
                            : 'Couper le guidage vocal',
                        icon: Icon(
                          _voiceMuted ? Icons.volume_off : Icons.volume_up,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (snapshot != null) ...[
                const SizedBox(height: ParkRadarSpacing.xs),
                Row(
                  children: [
                    Icon(Icons.schedule, size: 16, color: scheme.outline),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Arrivée ${_formatEta(snapshot.remainingDurationSeconds)}'
                        ' · ${_formatDistance(snapshot.remainingRouteMeters)}'
                        ' restants',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
              if (_gpsLost) ...[
                const SizedBox(height: ParkRadarSpacing.xs),
                Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ParkRadarSpacing.sm,
                      vertical: ParkRadarSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: colors.danger.background,
                      borderRadius: ParkRadarRadii.control,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.gps_off,
                          size: 16,
                          color: colors.danger.foreground,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Signal GPS perdu — reprise automatique en cours…',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.danger.foreground),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggleVoiceMuted() {
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
      _MapLayerMode.availability || _MapLayerMode.route => [
        _LegendEntry(
          'Faible',
          colors.confidenceLow.foreground,
          _LineKind.dashed,
        ),
        _LegendEntry(
          'Modéré',
          colors.confidenceMedium.foreground,
          _LineKind.dotted,
        ),
        _LegendEntry(
          'Favorable',
          colors.confidenceHigh.foreground,
          _LineKind.solid,
        ),
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
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
      elevation: 2,
      borderRadius: ParkRadarRadii.pill,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ParkRadarSpacing.sm,
          vertical: ParkRadarSpacing.xs,
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: ParkRadarSpacing.sm,
          runSpacing: ParkRadarSpacing.xxs,
          children: [
            for (final entry in entries) _LegendItem(entry: entry),
            if (mode == _MapLayerMode.legal)
              Text(
                'Touchez une ligne pour les détails',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResponsivePanel(ParkingMapState state) {
    return ParkResponsiveMapPanel(
      sideAlignment: Alignment.centerRight,
      child: switch (state.phase) {
        _
            when state.parkedPosition != null &&
                state.phase != ParkingMapPhase.guiding =>
          _buildParkedPanel(state),
        ParkingMapPhase.idle => _buildWelcomePanel(),
        ParkingMapPhase.failure => _buildFailurePanel(state),
        _ when state.destination != null && state.loop == null =>
          _buildNoLoopPanel(state),
        _ when state.loop != null => _buildLoopPanel(state),
        _ => _buildWelcomePanel(),
      },
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.local_parking, color: context.parkRadarColors.brand),
            const SizedBox(width: ParkRadarSpacing.xs),
            Expanded(
              child: Text(
                'Trouvez une rue, pas une promesse',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        Text(
          'Recherchez une destination à Paris. ParkRadar croise l’inventaire '
          'des régimes avant de proposer une boucle. La signalisation sur '
          'place prévaut toujours.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildFailurePanel(ParkingMapState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Analyse indisponible',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        const Text(
          'Les rues ou l’inventaire des régimes n’ont pas pu être chargés. '
          'Aucun guidage n’est proposé tant que ces données manquent.',
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
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: ParkRadarSpacing.xs),
        Text(
          legalUnavailable
              ? 'ParkRadar applique un garde-fou strict : sans inventaire '
                    'Paris Data disponible, aucune rue n’est recommandée.'
              : 'Les rues compatibles autour de cette destination ne donnent '
                    'pas un signal suffisant. Élargissez la recherche ou '
                    'réessayez plus tard.',
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

  Widget _buildLoopPanel(ParkingMapState state) {
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
    final guiding = state.phase == ParkingMapPhase.guiding;
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
                    guiding
                        ? 'Recherche guidée en cours'
                        : _availabilityLabel(best.probabilityFree),
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
            if (!guiding)
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
        const SizedBox(height: ParkRadarSpacing.xs),
        Text(
          _predictionAuditLabel(state),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Text(
          _communityFreshnessLabel(state),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: ParkRadarSpacing.sm),
        _legalSummary(state),
        if (!guiding) ...[
          const SizedBox(height: ParkRadarSpacing.sm),
          _arrivalControl(state),
        ],
        if (route != null) ...[
          const SizedBox(height: ParkRadarSpacing.sm),
          _routeSummary(route, preview: preview, guiding: guiding),
        ],
        const SizedBox(height: ParkRadarSpacing.md),
        if (guiding) ...[
          FilledButton.icon(
            onPressed: state.reporting ? null : _reportParked,
            icon: state.reporting
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.local_parking),
            label: const Text('Place trouvée'),
          ),
          TextButton.icon(
            onPressed: _stopGuidance,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Arrêter le guidage'),
          ),
        ] else if (preview) ...[
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
        if (!state.hasVerifiedLegalCoverage && !guiding) ...[
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

  String _predictionAuditLabel(ParkingMapState state) {
    final versions = state.predictionVersions;
    if (versions == null) return 'Prédiction non disponible et non versionnée.';
    return 'Modèle ${versions.model} · données ${versions.data} · '
        'calibration ${versions.calibration}';
  }

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

  Widget _legalSummary(ParkingMapState state) {
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
              '${regimeText.isEmpty ? '' : '\nRégimes présents : $regimeText'}';
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

  _AvailabilityLevel _availabilityLevel(double value) {
    if (value < 0.33) return _AvailabilityLevel.low;
    if (value < 0.66) return _AvailabilityLevel.medium;
    return _AvailabilityLevel.high;
  }

  String _availabilityLabel(double value) {
    return switch (_availabilityLevel(value)) {
      _AvailabilityLevel.low => 'Signal estimé faible',
      _AvailabilityLevel.medium => 'Signal estimé modéré',
      _AvailabilityLevel.high => 'Signal estimé favorable',
    };
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
    return Center(
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: ParkRadarRadii.control,
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              button: true,
              label: 'Informations et licences cartographiques',
              child: InkWell(
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: ParkRadarSizes.minimumTouchTarget,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ParkRadarSpacing.xs,
                      vertical: ParkRadarSpacing.xxs,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
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
              width: 28,
              height: 12,
              child: CustomPaint(
                painter: _LineSwatchPainter(
                  color: entry.color,
                  kind: entry.kind,
                ),
              ),
            ),
            const SizedBox(width: ParkRadarSpacing.xxs),
            Text(entry.label, style: Theme.of(context).textTheme.labelSmall),
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
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    switch (kind) {
      case _LineKind.solid:
        canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
      case _LineKind.dashed:
        for (var x = 1.0; x < size.width; x += 10) {
          canvas.drawLine(
            Offset(x, y),
            Offset((x + 5).clamp(0, size.width), y),
            paint,
          );
        }
      case _LineKind.dotted:
        for (var x = 2.0; x < size.width; x += 7) {
          canvas.drawCircle(Offset(x, y), 2, paint);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _LineSwatchPainter oldDelegate) {
    return color != oldDelegate.color || kind != oldDelegate.kind;
  }
}
