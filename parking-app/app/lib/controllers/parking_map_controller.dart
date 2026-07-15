// The public dependency names intentionally differ from the private fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/availability_estimate.dart';
import '../models/street_segment.dart';
import '../services/community_adjuster.dart';
import '../services/community_service.dart';
import '../services/geocoding_service.dart';
import '../services/paris_parking_service.dart';
import '../services/paris_time.dart';
import '../services/parking_eligibility_service.dart';
import '../services/probability_engine.dart';
import '../services/routing_service.dart';
import '../services/search_loop_planner.dart';

enum ParkingMapPhase { idle, loading, ready, preview, guiding, failure }

enum DataLayerStatus { idle, loading, fresh, stale, unavailable, unsupported }

typedef AddressSearch = Future<List<GeocodingResult>> Function(String query);
typedef SegmentFetcher = Future<List<StreetSegment>> Function(LatLng center);
typedef SpotFetcher = Future<List<ParkingSpot>> Function(LatLng center);
typedef EventFetcher = Future<List<ParkingEvent>> Function(LatLng center);
typedef RouteFetcher = Future<DrivingRoute?> Function(List<LatLng> waypoints);
typedef EventReporter = Future<bool> Function(String type, LatLng position);

class ParkingMapState {
  const ParkingMapState({
    this.phase = ParkingMapPhase.idle,
    this.query = '',
    this.searching = false,
    this.suggestions = const [],
    this.destination,
    this.destinationLabel,
    this.userPosition,
    this.parkedPosition,
    this.parkedAt,
    this.rawSegments = const [],
    this.scoredSegments = const [],
    this.availabilityEstimates = const {},
    this.eligibility = const {},
    this.loop,
    this.route,
    this.parisSpots = const [],
    this.legalDataAsOf,
    this.legalDatedSpotCount = 0,
    this.communityEvents = const [],
    this.communityUpdatedAt,
    this.plannedArrival,
    this.streetStatus = DataLayerStatus.idle,
    this.legalStatus = DataLayerStatus.idle,
    this.communityStatus = DataLayerStatus.idle,
    this.notice,
    this.showLegalLayer = false,
    this.reporting = false,
    this.routing = false,
  });

  final ParkingMapPhase phase;
  final String query;
  final bool searching;
  final List<GeocodingResult> suggestions;
  final LatLng? destination;
  final String? destinationLabel;
  final LatLng? userPosition;
  final LatLng? parkedPosition;
  final DateTime? parkedAt;
  final List<StreetSegment> rawSegments;
  final List<ScoredSegment> scoredSegments;

  /// Estimation complète par identifiant de tronçon. [scoredSegments] reste
  /// exposé pour la compatibilité du rendu existant.
  final Map<int, AvailabilityEstimate> availabilityEstimates;
  final Map<int, SegmentEligibility> eligibility;
  final SearchLoop? loop;
  final DrivingRoute? route;
  final List<ParkingSpot> parisSpots;
  final DateTime? legalDataAsOf;
  final int legalDatedSpotCount;
  final List<ParkingEvent> communityEvents;
  final DateTime? communityUpdatedAt;
  final DateTime? plannedArrival;
  final DataLayerStatus streetStatus;
  final DataLayerStatus legalStatus;
  final DataLayerStatus communityStatus;
  final String? notice;
  final bool showLegalLayer;
  final bool reporting;
  final bool routing;

  bool get isNow => plannedArrival == null;
  bool get hasVerifiedLegalCoverage =>
      parisSpots.isNotEmpty &&
      (legalStatus == DataLayerStatus.fresh ||
          legalStatus == DataLayerStatus.stale);
  bool get hasKnownLegalDataAsOf =>
      legalDataAsOf != null &&
      parisSpots.isNotEmpty &&
      legalDatedSpotCount == parisSpots.length;
  double get legalDataTimestampCoverage =>
      parisSpots.isEmpty ? 0 : legalDatedSpotCount / parisSpots.length;
  DateTime? get predictionGeneratedAt => availabilityEstimates.isEmpty
      ? null
      : availabilityEstimates.values.first.generatedAt;
  DateTime? get predictionDataAsOf =>
      hasKnownLegalDataAsOf ? legalDataAsOf : null;
  PredictionVersions? get predictionVersions => availabilityEstimates.isEmpty
      ? null
      : availabilityEstimates.values.first.versions;
  AvailabilityConfidence? get predictionConfidence {
    AvailabilityConfidence? result;
    for (final estimate in availabilityEstimates.values) {
      if (result == null || estimate.confidence.index < result.index) {
        result = estimate.confidence;
      }
    }
    return result;
  }

  Duration? legalDataAgeAt(DateTime now) {
    final asOf = predictionDataAsOf;
    if (asOf == null) return null;
    final age = now.toUtc().difference(asOf);
    return age.isNegative ? Duration.zero : age;
  }

  AvailabilityFreshness? predictionFreshnessAt(DateTime now) {
    if (!hasKnownLegalDataAsOf || availabilityEstimates.isEmpty) return null;
    AvailabilityFreshness? result;
    for (final estimate in availabilityEstimates.values) {
      final freshness = estimate.freshnessAt(now);
      if (result == null || freshness.index > result.index) result = freshness;
    }
    return result;
  }

  AvailabilityEstimate? estimateForSegment(int segmentId) =>
      availabilityEstimates[segmentId];
  bool get canStartGuidance =>
      loop != null && hasVerifiedLegalCoverage && !routing;

  ParkingMapState copyWith({
    ParkingMapPhase? phase,
    String? query,
    bool? searching,
    List<GeocodingResult>? suggestions,
    Object? destination = _unset,
    Object? destinationLabel = _unset,
    Object? userPosition = _unset,
    Object? parkedPosition = _unset,
    Object? parkedAt = _unset,
    List<StreetSegment>? rawSegments,
    List<ScoredSegment>? scoredSegments,
    Map<int, AvailabilityEstimate>? availabilityEstimates,
    Map<int, SegmentEligibility>? eligibility,
    Object? loop = _unset,
    Object? route = _unset,
    List<ParkingSpot>? parisSpots,
    Object? legalDataAsOf = _unset,
    int? legalDatedSpotCount,
    List<ParkingEvent>? communityEvents,
    Object? communityUpdatedAt = _unset,
    Object? plannedArrival = _unset,
    DataLayerStatus? streetStatus,
    DataLayerStatus? legalStatus,
    DataLayerStatus? communityStatus,
    Object? notice = _unset,
    bool? showLegalLayer,
    bool? reporting,
    bool? routing,
  }) {
    return ParkingMapState(
      phase: phase ?? this.phase,
      query: query ?? this.query,
      searching: searching ?? this.searching,
      suggestions: suggestions ?? this.suggestions,
      destination: destination == _unset
          ? this.destination
          : destination as LatLng?,
      destinationLabel: destinationLabel == _unset
          ? this.destinationLabel
          : destinationLabel as String?,
      userPosition: userPosition == _unset
          ? this.userPosition
          : userPosition as LatLng?,
      parkedPosition: parkedPosition == _unset
          ? this.parkedPosition
          : parkedPosition as LatLng?,
      parkedAt: parkedAt == _unset ? this.parkedAt : parkedAt as DateTime?,
      rawSegments: rawSegments ?? this.rawSegments,
      scoredSegments: scoredSegments ?? this.scoredSegments,
      availabilityEstimates:
          availabilityEstimates ?? this.availabilityEstimates,
      eligibility: eligibility ?? this.eligibility,
      loop: loop == _unset ? this.loop : loop as SearchLoop?,
      route: route == _unset ? this.route : route as DrivingRoute?,
      parisSpots: parisSpots ?? this.parisSpots,
      legalDataAsOf: legalDataAsOf == _unset
          ? this.legalDataAsOf
          : legalDataAsOf as DateTime?,
      legalDatedSpotCount: legalDatedSpotCount ?? this.legalDatedSpotCount,
      communityEvents: communityEvents ?? this.communityEvents,
      communityUpdatedAt: communityUpdatedAt == _unset
          ? this.communityUpdatedAt
          : communityUpdatedAt as DateTime?,
      plannedArrival: plannedArrival == _unset
          ? this.plannedArrival
          : plannedArrival as DateTime?,
      streetStatus: streetStatus ?? this.streetStatus,
      legalStatus: legalStatus ?? this.legalStatus,
      communityStatus: communityStatus ?? this.communityStatus,
      notice: notice == _unset ? this.notice : notice as String?,
      showLegalLayer: showLegalLayer ?? this.showLegalLayer,
      reporting: reporting ?? this.reporting,
      routing: routing ?? this.routing,
    );
  }
}

const Object _unset = Object();

class ParkingMapController extends ChangeNotifier {
  static const officialFallbackNotice =
      'Les zones sont dérivées de l’inventaire de stationnement de la Ville de Paris.';

  ParkingMapController({
    required AddressSearch searchAddresses,
    required SegmentFetcher fetchSegments,
    required SpotFetcher fetchSpots,
    required EventFetcher fetchEvents,
    required RouteFetcher fetchRoute,
    required EventReporter reportEvent,
    ProbabilityEngine engine = const ProbabilityEngine(),
    SearchLoopPlanner planner = const SearchLoopPlanner(),
    ParkingEligibilityService eligibilityService =
        const ParkingEligibilityService(),
    CommunityAdjuster communityAdjuster = const CommunityAdjuster(),
    ParkingUserProfile profile = const ParkingUserProfile(),
    DateTime Function()? clock,
    this.searchDebounce = const Duration(milliseconds: 550),
    this.communityPollInterval = const Duration(seconds: 20),
    this.streetLoadBudget = const Duration(seconds: 6),
    this.legalDataFreshnessWindow = const Duration(days: 30),
  }) : _searchAddresses = searchAddresses,
       _fetchSegments = fetchSegments,
       _fetchSpots = fetchSpots,
       _fetchEvents = fetchEvents,
       _fetchRoute = fetchRoute,
       _reportEvent = reportEvent,
       _engine = engine,
       _planner = planner,
       _eligibilityService = eligibilityService,
       _communityAdjuster = communityAdjuster,
       _profile = profile,
       _clock = clock ?? DateTime.now;

  final AddressSearch _searchAddresses;
  final SegmentFetcher _fetchSegments;
  final SpotFetcher _fetchSpots;
  final EventFetcher _fetchEvents;
  final RouteFetcher _fetchRoute;
  final EventReporter _reportEvent;
  final ProbabilityEngine _engine;
  final SearchLoopPlanner _planner;
  final ParkingEligibilityService _eligibilityService;
  final CommunityAdjuster _communityAdjuster;
  final ParkingUserProfile _profile;
  final DateTime Function() _clock;
  final Duration searchDebounce;
  final Duration communityPollInterval;
  final Duration streetLoadBudget;
  final Duration legalDataFreshnessWindow;

  ParkingMapState _state = const ParkingMapState();
  ParkingMapState get state => _state;

  Timer? _searchTimer;
  Timer? _communityTimer;
  var _searchGeneration = 0;
  var _destinationGeneration = 0;
  var _routeGeneration = 0;
  var _planGeneration = 0;
  DateTime? _lastRouteAt;
  bool _communityRefreshInFlight = false;
  bool _disposed = false;

  void _emit(ParkingMapState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  void search(String rawQuery) {
    final query = rawQuery.trim();
    _searchTimer?.cancel();
    final generation = ++_searchGeneration;
    if (query.length < 3) {
      _emit(
        _state.copyWith(
          query: rawQuery,
          searching: false,
          suggestions: const [],
        ),
      );
      return;
    }
    _emit(
      _state.copyWith(
        query: rawQuery,
        searching: true,
        suggestions: const [],
        notice: null,
      ),
    );
    _searchTimer = Timer(searchDebounce, () async {
      final result = await _capture(() => _searchAddresses(query));
      if (_disposed || generation != _searchGeneration) return;
      if (result.error != null) {
        _emit(
          _state.copyWith(
            searching: false,
            suggestions: const [],
            notice: 'Recherche indisponible. Vérifiez votre connexion.',
          ),
        );
        return;
      }
      _emit(
        _state.copyWith(
          searching: false,
          suggestions: result.value ?? const [],
        ),
      );
    });
  }

  void dismissSuggestions() {
    _searchGeneration++;
    _searchTimer?.cancel();
    final destinationLabel = _state.destinationLabel;
    _emit(
      _state.copyWith(
        query: destinationLabel == null
            ? _state.query
            : _primaryAddressLabel(destinationLabel),
        searching: false,
        suggestions: const [],
      ),
    );
  }

  /// Revient à l'état initial et invalide toutes les réponses réseau en vol.
  void clearDestination() {
    _searchGeneration++;
    _destinationGeneration++;
    _routeGeneration++;
    _searchTimer?.cancel();
    _communityTimer?.cancel();
    _emit(
      ParkingMapState(
        parkedPosition: _state.parkedPosition,
        parkedAt: _state.parkedAt,
      ),
    );
  }

  /// Relance le chargement de la destination courante après une panne.
  Future<void> retryDestination() async {
    final destination = _state.destination;
    final label = _state.destinationLabel;
    if (destination == null || label == null) return;
    await selectDestination(
      GeocodingResult(displayName: label, location: destination),
    );
  }

  void dismissNotice() {
    _emit(_state.copyWith(notice: null));
  }

  Future<void> selectDestination(GeocodingResult result) async {
    final generation = ++_destinationGeneration;
    _routeGeneration++;
    _communityTimer?.cancel();
    final inParis = ParisParkingService.isInParis(result.location);
    _emit(
      ParkingMapState(
        phase: ParkingMapPhase.loading,
        query: _primaryAddressLabel(result.displayName),
        destination: result.location,
        destinationLabel: result.displayName,
        streetStatus: DataLayerStatus.loading,
        legalStatus: inParis
            ? DataLayerStatus.loading
            : DataLayerStatus.unsupported,
        communityStatus: DataLayerStatus.loading,
        plannedArrival: _state.plannedArrival,
        parkedPosition: _state.parkedPosition,
        parkedAt: _state.parkedAt,
        notice: inParis ? null : 'Destination hors de la couverture Paris.',
      ),
    );

    final streetsFuture = _capture(
      () => _fetchSegments(result.location).timeout(streetLoadBudget),
    );
    final spotsFuture = inParis
        ? _capture(() => _fetchSpots(result.location))
        : Future.value(const _Captured<List<ParkingSpot>>(value: []));
    final eventsFuture = _capture(() => _fetchEvents(result.location));

    // Chaque couche publie son résultat dès qu'elle arrive. Paris Data peut
    // ainsi rendre la recherche utilisable sans attendre un Overpass lent, et
    // la communauté optionnelle ne bloque jamais la réglementation.
    await Future.wait<void>([
      streetsFuture.then(
        (value) => _applyStreetLayer(value, generation: generation),
      ),
      spotsFuture.then(
        (value) =>
            _applyLegalLayer(value, inParis: inParis, generation: generation),
      ),
      eventsFuture.then(
        (value) => _applyCommunityLayer(value, generation: generation),
      ),
    ]);
    if (_disposed || generation != _destinationGeneration) return;

    if (_state.rawSegments.isEmpty) {
      _emit(
        _state.copyWith(
          phase: ParkingMapPhase.failure,
          streetStatus: DataLayerStatus.unavailable,
          notice: 'Impossible de charger les rues. Réessayez.',
        ),
      );
      return;
    }
    _startCommunityPolling(generation);
  }

  void _applyStreetLayer(
    _Captured<List<StreetSegment>> result, {
    required int generation,
  }) {
    if (_disposed || generation != _destinationGeneration) return;
    final segments = result.value ?? const <StreetSegment>[];
    if (result.error != null || segments.isEmpty) {
      if (_state.rawSegments.isEmpty) {
        _emit(_state.copyWith(streetStatus: DataLayerStatus.unavailable));
      }
      return;
    }
    // À Paris, les unités dérivées de l'inventaire Paris Data restent les
    // unités de décision conservatrices. Un way OSM parfois très long ne doit
    // jamais transformer un seul emplacement proche en autorisation pour
    // toute une rue.
    if (_state.hasVerifiedLegalCoverage &&
        _state.parisSpots.isNotEmpty &&
        _state.rawSegments.any((segment) => segment.id.isNegative)) {
      return;
    }
    final fallbackNotice = _state.notice == officialFallbackNotice;
    _emit(
      _state.copyWith(
        phase: ParkingMapPhase.ready,
        rawSegments: segments,
        streetStatus: DataLayerStatus.fresh,
        notice: fallbackNotice ? null : _state.notice,
      ),
    );
    _recompute();
  }

  void _applyLegalLayer(
    _Captured<List<ParkingSpot>> result, {
    required bool inParis,
    required int generation,
  }) {
    if (_disposed || generation != _destinationGeneration) return;
    if (!inParis) return;
    final spots = result.value ?? const <ParkingSpot>[];
    if (result.error != null || spots.isEmpty) {
      _emit(
        _state.copyWith(
          legalStatus: DataLayerStatus.unavailable,
          notice: 'Inventaire des régimes indisponible : guidage désactivé.',
        ),
      );
      if (_state.rawSegments.isNotEmpty) _recompute();
      return;
    }

    final segments = _eligibilityService.segmentsFromSpots(spots);
    if (segments.isEmpty) {
      _emit(
        _state.copyWith(
          legalStatus: DataLayerStatus.unavailable,
          notice:
              'Géométries réglementaires indisponibles : guidage désactivé.',
        ),
      );
      return;
    }
    final now = _clock().toUtc();
    final datedSpots = spots
        .where(
          (spot) =>
              spot.sourceUpdatedAt != null &&
              !spot.sourceUpdatedAt!.toUtc().isAfter(now),
        )
        .toList();
    DateTime? legalDataAsOf;
    if (datedSpots.length == spots.length) {
      legalDataAsOf = datedSpots
          .map((spot) => spot.sourceUpdatedAt!.toUtc())
          .reduce((oldest, date) => date.isBefore(oldest) ? date : oldest);
    }
    final legalDataAge = legalDataAsOf == null
        ? null
        : now.difference(legalDataAsOf);
    final legalDataStatus =
        legalDataAge != null && legalDataAge <= legalDataFreshnessWindow
        ? DataLayerStatus.fresh
        : DataLayerStatus.stale;
    _emit(
      _state.copyWith(
        phase: ParkingMapPhase.ready,
        rawSegments: segments,
        parisSpots: spots,
        legalDataAsOf: legalDataAsOf,
        legalDatedSpotCount: datedSpots.length,
        streetStatus: DataLayerStatus.fresh,
        legalStatus: legalDataStatus,
        notice: officialFallbackNotice,
      ),
    );
    _recompute();
  }

  void _applyCommunityLayer(
    _Captured<List<ParkingEvent>> result, {
    required int generation,
  }) {
    if (_disposed || generation != _destinationGeneration) return;
    if (result.error != null) {
      _emit(_state.copyWith(communityStatus: DataLayerStatus.unavailable));
      return;
    }
    _emit(
      _state.copyWith(
        communityEvents: result.value ?? const [],
        communityStatus: DataLayerStatus.fresh,
        communityUpdatedAt: _clock(),
      ),
    );
    if (_state.rawSegments.isNotEmpty) _recompute();
  }

  void setArrivalHour(int? hour) {
    DateTime? planned;
    if (hour != null) {
      planned = nextParisHour(_clock(), hour);
    }
    _emit(_state.copyWith(plannedArrival: planned, route: null));
    _recompute();
  }

  void toggleLegalLayer() {
    _emit(_state.copyWith(showLegalLayer: !_state.showLegalLayer));
  }

  void updateUserPosition(LatLng position) {
    _emit(_state.copyWith(userPosition: position));
    if (_state.phase == ParkingMapPhase.guiding) {
      _maybeReroute(position);
    }
  }

  /// Restaure une session locale après redémarrage, sans créer de signalement.
  void restoreParkedSession(LatLng position, DateTime parkedAt) {
    final age = _clock().difference(parkedAt);
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        position.longitude < -180 ||
        position.longitude > 180 ||
        age < const Duration(minutes: -5) ||
        age > const Duration(hours: 24)) {
      return;
    }
    _emit(_state.copyWith(parkedPosition: position, parkedAt: parkedAt));
  }

  /// Mémorise d'abord la session sur l'appareil. Le partage communautaire est
  /// une opération distincte et ne peut donc jamais bloquer la fin du guidage.
  void rememberParkedLocally(LatLng position, {DateTime? parkedAt}) {
    if (!_isValidPosition(position)) return;
    _emit(
      _state.copyWith(
        parkedPosition: position,
        parkedAt: parkedAt ?? _clock(),
        notice: 'Stationnement mémorisé sur cet appareil.',
      ),
    );
  }

  void clearParkedLocally() {
    _emit(
      _state.copyWith(
        parkedPosition: null,
        parkedAt: null,
        notice: 'Session de stationnement terminée.',
      ),
    );
  }

  Future<void> refreshCommunity() async {
    if (_communityRefreshInFlight) return;
    final destination = _state.destination;
    final generation = _destinationGeneration;
    if (destination == null) return;
    _communityRefreshInFlight = true;
    try {
      final result = await _capture(() => _fetchEvents(destination));
      if (_disposed || generation != _destinationGeneration) return;
      if (result.error != null) {
        _emit(
          _state.copyWith(
            communityEvents: const [],
            communityStatus: DataLayerStatus.stale,
            communityUpdatedAt: null,
          ),
        );
        _recompute();
        return;
      }
      _emit(
        _state.copyWith(
          communityEvents: result.value ?? const [],
          communityStatus: DataLayerStatus.fresh,
          communityUpdatedAt: _clock(),
        ),
      );
      _recompute();
    } finally {
      _communityRefreshInFlight = false;
    }
  }

  Future<bool> report(String type, LatLng position) async {
    if (type != 'parked' && type != 'freed') return false;
    if (type == 'freed' && _state.parkedPosition == null) {
      _emit(
        _state.copyWith(
          notice: 'Aucun stationnement ParkRadar actif à libérer.',
        ),
      );
      return false;
    }
    final success = await shareCommunityEvent(type, position);
    if (!success) return false;
    _emit(
      _state.copyWith(
        parkedPosition: type == 'parked' ? position : null,
        parkedAt: type == 'parked' ? _clock() : null,
      ),
    );
    return true;
  }

  /// Partage un événement sans créer ni supprimer la session locale. Cette
  /// séparation permet un mode « sur cet appareil » et une UX résiliente aux
  /// pannes Supabase.
  Future<bool> shareCommunityEvent(String type, LatLng position) async {
    if ((type != 'parked' && type != 'freed') || !_isValidPosition(position)) {
      return false;
    }
    _emit(_state.copyWith(reporting: true));
    final result = await _capture(() => _reportEvent(type, position));
    final success = result.error == null && result.value == true;
    _emit(
      _state.copyWith(
        reporting: false,
        notice: success
            ? 'Signalement pris en compte. Merci.'
            : 'Signalement impossible.',
      ),
    );
    if (success) unawaited(refreshCommunity());
    return success;
  }

  bool _isValidPosition(LatLng position) =>
      position.latitude.isFinite &&
      position.longitude.isFinite &&
      position.latitude >= -90 &&
      position.latitude <= 90 &&
      position.longitude >= -180 &&
      position.longitude <= 180;

  Future<bool> previewRoute({LatLng? origin}) {
    return _loadRoute(
      origin: origin ?? _state.destination,
      targetPhase: ParkingMapPhase.preview,
    );
  }

  Future<bool> startGuidance(LatLng origin) {
    return _loadRoute(origin: origin, targetPhase: ParkingMapPhase.guiding);
  }

  void stopGuidance() {
    _routeGeneration++;
    _emit(
      _state.copyWith(
        phase: _state.destination == null
            ? ParkingMapPhase.idle
            : ParkingMapPhase.ready,
        route: null,
        routing: false,
      ),
    );
  }

  Future<bool> _loadRoute({
    required LatLng? origin,
    required ParkingMapPhase targetPhase,
    bool resumeFromNearestSegment = false,
  }) async {
    final loop = _state.loop;
    final destination = _state.destination;
    if (origin == null || destination == null || loop == null) return false;
    if (!_state.hasVerifiedLegalCoverage) {
      _emit(
        _state.copyWith(
          notice:
              'Guidage bloqué : l’inventaire des régimes n’est pas disponible.',
        ),
      );
      return false;
    }
    final generation = ++_routeGeneration;
    final planGeneration = _planGeneration;
    _emit(_state.copyWith(routing: true, notice: null));
    var orderedSegments = loop.orderedSegments;
    if (resumeFromNearestSegment && orderedSegments.length > 1) {
      var nearestIndex = 0;
      var nearestDistance = double.infinity;
      for (var index = 0; index < orderedSegments.length; index++) {
        final distance = orderedSegments[index].segment.distanceTo(origin);
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearestIndex = index;
        }
      }
      orderedSegments = orderedSegments.sublist(nearestIndex);
    }
    final waypoints = <LatLng>[
      origin,
      for (final segment in orderedSegments) segment.segment.midpoint,
      destination,
    ];
    final result = await _capture(() => _fetchRoute(waypoints));
    if (_disposed || generation != _routeGeneration) return false;
    if (planGeneration != _planGeneration) {
      _emit(
        _state.copyWith(
          routing: false,
          notice: 'Les données ont changé. Relancez l’itinéraire.',
        ),
      );
      return false;
    }
    if (result.error != null || result.value == null) {
      _emit(
        _state.copyWith(
          routing: false,
          notice: 'Itinéraire indisponible. Réessayez.',
        ),
      );
      return false;
    }
    _lastRouteAt = _clock();
    _emit(
      _state.copyWith(phase: targetPhase, route: result.value, routing: false),
    );
    return true;
  }

  void _maybeReroute(LatLng position) {
    final lastAt = _lastRouteAt;
    final route = _state.route;
    if (_state.routing || lastAt == null || route == null) return;
    final elapsed = _clock().difference(lastAt);
    if (elapsed < const Duration(seconds: 30) || route.points.length < 2) {
      return;
    }
    final routeGeometry = StreetSegment(
      id: -1,
      name: 'Itinéraire actif',
      highwayType: 'route',
      points: route.points,
    );
    if (routeGeometry.distanceTo(position) < 60) {
      return;
    }
    unawaited(
      _loadRoute(
        origin: position,
        targetPhase: ParkingMapPhase.guiding,
        resumeFromNearestSegment: true,
      ),
    );
  }

  void _recompute() {
    final destination = _state.destination;
    if (destination == null || _state.rawSegments.isEmpty) return;
    final arrival = _state.plannedArrival ?? atParis(_clock());
    final generatedAt = _clock().toUtc();
    final sourceDataAsOf = _state.predictionDataAsOf;
    final dataVersion = sourceDataAsOf == null
        ? '${ProbabilityEngine.defaultDataVersion}-source-date-unknown'
        : '${ProbabilityEngine.defaultDataVersion}-source-dated';
    final estimates = <int, AvailabilityEstimate>{};
    var scores = <ScoredSegment>[];
    for (final segment in _state.rawSegments) {
      final estimate = _engine.estimateAvailability(
        segment,
        arrival,
        generatedAt: generatedAt,
        dataAsOf: sourceDataAsOf,
        dataVersion: dataVersion,
      );
      estimates[segment.id] = estimate;
      scores.add(
        ScoredSegment(
          segment: segment,
          capacity: _engine.estimateCapacity(segment),
          occupancy: _engine.estimateOccupancy(segment, arrival),
          probabilityFree: estimate.probability,
        ),
      );
    }
    var assessments = const <int, SegmentEligibility>{};

    if (_state.hasVerifiedLegalCoverage) {
      assessments = _eligibilityService.assessAll(
        _state.rawSegments,
        _state.parisSpots,
        _profile,
      );
      scores = _eligibilityService.applyToScores(scores, assessments);
    } else {
      scores = [
        for (final score in scores)
          ScoredSegment(
            segment: score.segment,
            capacity: 0,
            occupancy: score.occupancy,
            probabilityFree: 0,
          ),
      ];
    }

    if (_state.isNow &&
        _state.communityStatus == DataLayerStatus.fresh &&
        _state.communityEvents.isNotEmpty) {
      scores = _communityAdjuster.adjust(
        scores,
        _state.communityEvents,
        _clock(),
      );
    }

    final adjustedEstimates = <int, AvailabilityEstimate>{
      for (final score in scores)
        score.segment.id: estimates[score.segment.id]!.withProbability(
          score.probabilityFree,
          interval: score.capacity == 0
              ? ProbabilityInterval(lower: 0, upper: 0)
              : null,
        ),
    };
    final recomputedLoop = scores.any((score) => score.probabilityFree > 0.01)
        ? _planner.plan(scores, destination)
        : null;
    final keepActivePlan =
        _state.route != null &&
        (_state.phase == ParkingMapPhase.preview ||
            _state.phase == ParkingMapPhase.guiding);
    final loop = keepActivePlan ? _state.loop : recomputedLoop;
    if (!keepActivePlan) _planGeneration++;
    _emit(
      _state.copyWith(
        scoredSegments: scores,
        availabilityEstimates: adjustedEstimates,
        eligibility: assessments,
        loop: loop,
        phase: _state.phase == ParkingMapPhase.loading
            ? ParkingMapPhase.ready
            : _state.phase,
      ),
    );
  }

  void _startCommunityPolling(int generation) {
    _communityTimer?.cancel();
    if (communityPollInterval <= Duration.zero) return;
    _communityTimer = Timer.periodic(communityPollInterval, (_) {
      if (generation == _destinationGeneration) unawaited(refreshCommunity());
    });
  }

  String _primaryAddressLabel(String displayName) {
    final parts = displayName
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length >= 2 && int.tryParse(parts.first) != null) {
      return '${parts.first} ${parts[1]}';
    }
    return parts.isEmpty ? displayName : parts.first;
  }

  Future<_Captured<T>> _capture<T>(Future<T> Function() operation) async {
    try {
      return _Captured(value: await operation());
    } catch (error) {
      return _Captured(error: error);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    _communityTimer?.cancel();
    super.dispose();
  }
}

class _Captured<T> {
  const _Captured({this.value, this.error});

  final T? value;
  final Object? error;
}
