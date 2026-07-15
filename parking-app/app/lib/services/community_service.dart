import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'local_community_store.dart';
import 'network_client.dart';

/// Un signalement communautaire agrégé : un ou plusieurs conducteurs se sont
/// garés ou ont libéré une place dans la même petite cellule géographique.
class ParkingEvent {
  ParkingEvent({
    required this.type,
    required this.position,
    required this.createdAt,
    this.reportCount = 1,
  });

  /// `parked` (place prise) ou `freed` (place libérée).
  final String type;
  final LatLng position;
  final DateTime createdAt;

  /// Nombre de signalements regroupés par le backend. Un événement historique
  /// ou local garde la valeur 1. Cette valeur ne doit pas être assimilée à un
  /// nombre de places libres.
  final int reportCount;

  bool get isFreed => type == 'freed';
}

class CommunityValidationException implements Exception {
  const CommunityValidationException(this.message);

  final String message;

  @override
  String toString() => 'CommunityValidationException: $message';
}

/// Couche communautaire Supabase/PostgREST.
///
/// Le schéma P0 expose une RPC de lecture agrégée, quantifie les coordonnées et
/// masque la table brute. Les écritures passent par une Edge Function qui seule
/// détient le droit d'appeler la RPC privée. Un repli temporaire vers l'ancien
/// schéma reste activable pour une migration contrôlée uniquement.
class CommunityService {
  CommunityService({
    http.Client? client,
    LocalCommunityStore? localStore,
    String? supabaseUrl,
    String? supabaseAnonKey,
    String? reportUrl,
    Duration? timeout,
    Duration? eventTtl,
    Duration? pollInterval,
    bool? legacyFallback,
    DateTime Function()? clock,
    Future<String> Function()? clientTokenProvider,
  }) : _network = NetworkClient(
         client: client,
         timeout: timeout ?? AppConfig.communityTimeout,
       ),
       _local = localStore ?? LocalCommunityStore(now: clock),
       _supabaseUrl = supabaseUrl ?? AppConfig.supabaseUrl,
       _supabaseAnonKey = supabaseAnonKey ?? AppConfig.supabaseAnonKey,
       _reportUrl = reportUrl ?? AppConfig.communityReportUrl,
       _eventTtl = eventTtl ?? AppConfig.communityEventTtl,
       _pollInterval = pollInterval ?? AppConfig.communityPollInterval,
       _legacyFallback = legacyFallback ?? AppConfig.communityLegacyFallback,
       _clock = clock ?? DateTime.now,
       _providedClientToken = clientTokenProvider;

  static const _clientTokenKey = 'community_client_token_v1';
  static const _maxRemoteEvents = 200;
  static const _coordinatePrecision = 1000.0; // cellule ~70–110 m à Paris.

  final NetworkClient _network;
  final LocalCommunityStore _local;
  final String _supabaseUrl;
  final String _supabaseAnonKey;
  final String _reportUrl;
  final Duration _eventTtl;
  final Duration _pollInterval;
  final bool _legacyFallback;
  final DateTime Function() _clock;
  final Future<String> Function()? _providedClientToken;
  final Set<_CommunityPollingHandle> _polls = {};

  /// La couche communautaire reste disponible en mode local sans backend.
  bool get isEnabled => true;

  bool get isRemote =>
      _supabaseUrl.trim().isNotEmpty && _supabaseAnonKey.trim().isNotEmpty;

  Map<String, String> get _headers => {
    'apikey': _supabaseAnonKey,
    'Authorization': 'Bearer $_supabaseAnonKey',
    'Content-Type': 'application/json',
  };

  Uri _restEndpoint(String resource, [Map<String, dynamic>? queryParameters]) {
    final base = parseHttpEndpoint(_supabaseUrl, configName: 'SUPABASE_URL');
    final root = base.path.replaceFirst(RegExp(r'/$'), '');
    return base.replace(
      path: '$root/rest/v1/$resource',
      queryParameters: queryParameters,
    );
  }

  Uri _rpc(String functionName) => _restEndpoint('rpc/$functionName');

  Uri _reportEndpoint() {
    if (_reportUrl.trim().isNotEmpty) {
      return parseHttpEndpoint(_reportUrl, configName: 'COMMUNITY_REPORT_URL');
    }
    final base = parseHttpEndpoint(_supabaseUrl, configName: 'SUPABASE_URL');
    final root = base.path.replaceFirst(RegExp(r'/$'), '');
    return base.replace(path: '$root/functions/v1/report-parking-event');
  }

  /// API historique : renvoie `false` au lieu de faire remonter une panne de
  /// la couche communautaire optionnelle.
  Future<bool> report(String type, LatLng position) async {
    try {
      await reportOrThrow(type, position);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Variante diagnostique avec validation et erreurs réseau typées. En mode
  /// distant, elle publie la cellule via l'Edge Function, jamais directement
  /// dans la table ni dans la RPC privée.
  Future<void> reportOrThrow(String type, LatLng position) async {
    _validateReport(type, position);
    if (!isRemote) {
      final stored = await _local.report(type, position);
      if (!stored) {
        throw const CommunityValidationException(
          'Le signalement local a été refusé',
        );
      }
      return;
    }

    final lat = _quantize(position.latitude);
    final lon = _quantize(position.longitude);
    final reportUri = _reportEndpoint();
    final response = await _network.post(
      reportUri,
      headers: _headers,
      body: jsonEncode({
        'event_type': type,
        'lat': lat,
        'lon': lon,
        'client_token': await _clientToken(),
      }),
    );
    if (_legacyFallback && _isMissingRpc(response)) {
      final legacyUri = _restEndpoint('parking_events');
      final legacyResponse = await _network.post(
        legacyUri,
        headers: {..._headers, 'Prefer': 'return=minimal'},
        body: jsonEncode({'event_type': type, 'lat': lat, 'lon': lon}),
      );
      _network.requireSuccess(legacyResponse, legacyUri);
      return;
    }
    _network.requireSuccess(response, reportUri);
  }

  /// API historique tolérante : une panne distante n'empêche pas le reste de
  /// la carte de fonctionner.
  Future<List<ParkingEvent>> recentEventsNear(
    LatLng center, {
    double radiusMeters = 600,
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    try {
      return await recentEventsNearOrThrow(
        center,
        radiusMeters: radiusMeters,
        maxAge: maxAge,
      );
    } catch (_) {
      return const [];
    }
  }

  /// Variante diagnostique. Le serveur renvoie des cellules agrégées, puis le
  /// client réapplique rayon et TTL afin de ne jamais faire confiance à une
  /// réponse périmée ou trop large.
  Future<List<ParkingEvent>> recentEventsNearOrThrow(
    LatLng center, {
    double radiusMeters = 600,
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    _validateQuery(center, radiusMeters, maxAge);
    final effectiveMaxAge = maxAge < _eventTtl ? maxAge : _eventTtl;
    if (!isRemote) {
      return _local.recentEventsNear(
        center,
        radiusMeters: radiusMeters,
        maxAge: effectiveMaxAge,
      );
    }

    final dLat = radiusMeters / 111320.0;
    final longitudeScale =
        (111320.0 * math.cos(center.latitude * math.pi / 180).abs()).clamp(
          1000.0,
          111320.0,
        );
    final dLon = radiusMeters / longitudeScale;
    final bounds = (
      minLat: center.latitude - dLat,
      maxLat: center.latitude + dLat,
      minLon: center.longitude - dLon,
      maxLon: center.longitude + dLon,
    );

    final rpcUri = _rpc('recent_parking_events');
    var response = await _network.post(
      rpcUri,
      headers: _headers,
      body: jsonEncode({
        'p_min_lat': bounds.minLat,
        'p_max_lat': bounds.maxLat,
        'p_min_lon': bounds.minLon,
        'p_max_lon': bounds.maxLon,
        'p_max_age_seconds': effectiveMaxAge.inSeconds,
        'p_limit': _maxRemoteEvents,
      }),
    );
    var responseUri = rpcUri;

    if (_legacyFallback && _isMissingRpc(response)) {
      final since = _clock()
          .toUtc()
          .subtract(effectiveMaxAge)
          .toIso8601String();
      responseUri = _restEndpoint('parking_events', {
        'select': 'event_type,lat,lon,created_at',
        'created_at': 'gte.$since',
        'and':
            '(lat.gte.${bounds.minLat},lat.lte.${bounds.maxLat},'
            'lon.gte.${bounds.minLon},lon.lte.${bounds.maxLon})',
        'order': 'created_at.desc',
        'limit': '$_maxRemoteEvents',
      });
      response = await _network.get(responseUri, headers: _headers);
    }

    _network.requireSuccess(
      response,
      responseUri,
      acceptedStatusCodes: const {200},
    );
    final rows = _network.decodeList(response, responseUri);
    return _parseEvents(
      rows,
      uri: responseUri,
      center: center,
      radiusMeters: radiusMeters,
      maxAge: effectiveMaxAge,
    );
  }

  /// Polling mono-abonné : pas de requêtes concurrentes, arrêt immédiat lors
  /// de l'annulation et fermeture par [close]. Il remplace avantageusement un
  /// `Timer.periodic` laissé dans un écran.
  Stream<List<ParkingEvent>> watchRecentEventsNear(
    LatLng center, {
    double radiusMeters = 600,
    Duration maxAge = const Duration(minutes: 15),
    Duration? interval,
  }) {
    final effectiveInterval = interval ?? _pollInterval;
    if (effectiveInterval <= Duration.zero) {
      throw const CommunityValidationException(
        'L intervalle de polling doit être positif',
      );
    }
    late _CommunityPollingHandle handle;
    late StreamController<List<ParkingEvent>> controller;
    controller = StreamController<List<ParkingEvent>>(
      onListen: () => handle.start(),
      onCancel: () {
        handle.stop();
        _polls.remove(handle);
      },
    );
    handle = _CommunityPollingHandle(
      controller: controller,
      interval: effectiveInterval,
      fetch: () => recentEventsNearOrThrow(
        center,
        radiusMeters: radiusMeters,
        maxAge: maxAge,
      ),
    );
    _polls.add(handle);
    return controller.stream;
  }

  List<ParkingEvent> _parseEvents(
    List<dynamic> rows, {
    required Uri uri,
    required LatLng center,
    required double radiusMeters,
    required Duration maxAge,
  }) {
    final now = _clock().toUtc();
    final events = <ParkingEvent>[];
    try {
      for (final raw in rows) {
        if (raw is! Map) continue;
        final row = raw.cast<String, dynamic>();
        final type = row['event_type'];
        final latValue = row['lat'];
        final lonValue = row['lon'];
        final createdValue = row['created_at'];
        if (type != 'parked' && type != 'freed') continue;
        if (latValue is! num || lonValue is! num || createdValue is! String) {
          continue;
        }
        final createdAt = DateTime.tryParse(createdValue)?.toUtc();
        if (createdAt == null) continue;
        final age = now.difference(createdAt);
        if (age > maxAge || age < const Duration(minutes: -2)) continue;
        final position = LatLng(latValue.toDouble(), lonValue.toDouble());
        if (_distanceMeters(center, position) > radiusMeters) continue;
        final countValue = row['report_count'];
        final count = countValue is num ? countValue.toInt().clamp(1, 100) : 1;
        events.add(
          ParkingEvent(
            type: type,
            position: position,
            createdAt: createdAt,
            reportCount: count,
          ),
        );
      }
    } catch (error) {
      throw NetworkPayloadException(
        'Événements communautaires invalides',
        uri: uri,
        cause: error,
      );
    }
    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return events;
  }

  void _validateReport(String type, LatLng position) {
    if (type != 'parked' && type != 'freed') {
      throw const CommunityValidationException(
        'event_type doit valoir parked ou freed',
      );
    }
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < 48.80 ||
        position.latitude > 48.91 ||
        position.longitude < 2.22 ||
        position.longitude > 2.47) {
      throw const CommunityValidationException('Coordonnées invalides');
    }
  }

  void _validateQuery(LatLng center, double radiusMeters, Duration maxAge) {
    _validateReport('parked', center);
    if (!radiusMeters.isFinite || radiusMeters <= 0 || radiusMeters > 2500) {
      throw const CommunityValidationException(
        'Le rayon doit être compris entre 0 et 2 500 mètres',
      );
    }
    if (maxAge <= Duration.zero) {
      throw const CommunityValidationException('Le TTL doit être positif');
    }
  }

  bool _isMissingRpc(http.Response response) {
    if (response.statusCode != 400 && response.statusCode != 404) return false;
    final body = response.body.toLowerCase();
    return response.statusCode == 404 ||
        body.contains('pgrst202') ||
        body.contains('could not find the function');
  }

  double _quantize(double value) =>
      (value * _coordinatePrecision).roundToDouble() / _coordinatePrecision;

  Future<String> _clientToken() async {
    final provider = _providedClientToken;
    if (provider != null) return provider();
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_clientTokenKey);
    if (existing != null && existing.length >= 32 && existing.length <= 128) {
      return existing;
    }
    final random = math.Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    await prefs.setString(_clientTokenKey, token);
    return token;
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = lat2 - lat1;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  void close() {
    for (final poll in _polls.toList()) {
      poll.stop(closeController: true);
    }
    _polls.clear();
    _network.close();
  }

  void dispose() => close();
}

class _CommunityPollingHandle {
  _CommunityPollingHandle({
    required this.controller,
    required this.fetch,
    required this.interval,
  });

  final StreamController<List<ParkingEvent>> controller;
  final Future<List<ParkingEvent>> Function() fetch;
  final Duration interval;
  Timer? _timer;
  bool _inFlight = false;
  bool _stopped = false;

  void start() {
    if (_stopped || _timer != null) return;
    unawaited(_poll());
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (_stopped || _inFlight || controller.isClosed) return;
    _inFlight = true;
    try {
      final events = await fetch();
      if (!_stopped && !controller.isClosed) controller.add(events);
    } catch (error, stackTrace) {
      if (!_stopped && !controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    } finally {
      _inFlight = false;
    }
  }

  void stop({bool closeController = false}) {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    if (closeController && !controller.isClosed) {
      unawaited(controller.close());
    }
  }
}
