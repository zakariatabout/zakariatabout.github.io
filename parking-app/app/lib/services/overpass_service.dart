import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../models/street_segment.dart';
import 'network_client.dart';
import 'ttl_cache.dart';

/// Récupère les tronçons de rue stationnables autour d'un point via
/// l'API Overpass (OpenStreetMap).
class OverpassService {
  OverpassService({
    http.Client? client,
    String? endpoint,
    String? fallbackEndpoint,
    Duration? timeout,
    Duration cacheTtl = const Duration(hours: 24),
    DateTime Function()? clock,
  }) : _endpoints = _buildEndpoints(endpoint, fallbackEndpoint),
       _network = NetworkClient(
         client: client,
         timeout: timeout ?? AppConfig.overpassTimeout,
       ),
       _cache = TtlCache(ttl: cacheTtl, clock: clock);

  final List<Uri> _endpoints;
  final NetworkClient _network;

  /// La géométrie des rues bouge rarement : 24 h de cache évitent de
  /// re-télécharger le réseau viaire à chaque re-sélection de destination.
  final TtlCache<String, List<StreetSegment>> _cache;

  static const _noParkingValues = {
    'no_parking',
    'no_stopping',
    'no_standing',
    'no',
  };

  /// Rues autour de [center] dans un rayon de [radiusMeters], candidates
  /// au stationnement en voirie.
  Future<List<StreetSegment>> fetchSegments(
    LatLng center, {
    int radiusMeters = 400,
  }) async {
    if (!center.latitude.isFinite ||
        !center.longitude.isFinite ||
        center.latitude < -90 ||
        center.latitude > 90 ||
        center.longitude < -180 ||
        center.longitude > 180 ||
        radiusMeters < 50 ||
        radiusMeters > 2000) {
      throw ArgumentError('Centre ou rayon Overpass invalide');
    }
    final cacheKey =
        '${center.latitude.toStringAsFixed(4)},'
        '${center.longitude.toStringAsFixed(4)},$radiusMeters';
    if (_cache.get(cacheKey) case final cached?) return cached;

    NetworkException? lastError;
    for (final endpoint in _endpoints) {
      try {
        final segments = await _fetchSegmentsFrom(
          endpoint,
          center,
          radiusMeters: radiusMeters,
        );
        _cache.set(cacheKey, List.unmodifiable(segments));
        return segments;
      } on NetworkException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('Aucun endpoint Overpass configuré');
  }

  Future<List<StreetSegment>> _fetchSegmentsFrom(
    Uri endpoint,
    LatLng center, {
    required int radiusMeters,
  }) async {
    final query =
        '''
[out:json][timeout:25];
way(around:$radiusMeters,${center.latitude},${center.longitude})
  ["highway"~"^(residential|living_street|unclassified|tertiary|secondary)\$"]
  ["area"!="yes"];
out geom tags;
''';

    final resp = await _network.post(
      endpoint,
      headers: const {'User-Agent': kUserAgent},
      body: {'data': query},
    );
    _network.requireSuccess(resp, endpoint, acceptedStatusCodes: const {200});
    final data = _network.decodeObject(resp, endpoint);
    final elements = (data['elements'] as List?) ?? const [];

    try {
      final segments = <StreetSegment>[];
      for (final e in elements) {
        if (e is! Map) continue;
        final el = e.cast<String, dynamic>();
        final geometry = (el['geometry'] as List?) ?? const [];
        if (geometry.length < 2) continue;
        final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
        final points = <LatLng>[
          for (final rawPoint in geometry)
            if (rawPoint is Map &&
                rawPoint['lat'] is num &&
                rawPoint['lon'] is num)
              LatLng(
                (rawPoint['lat'] as num).toDouble(),
                (rawPoint['lon'] as num).toDouble(),
              ),
        ];
        if (points.length < 2) continue;

        segments.add(
          StreetSegment(
            id: (el['id'] as num).toInt(),
            name: (tags['name'] as String?) ?? 'Rue sans nom',
            highwayType: (tags['highway'] as String?) ?? 'residential',
            isOneWay: tags['oneway'] == 'yes' || tags['oneway'] == '-1',
            parkingForbidden: _isParkingForbidden(tags),
            parkingSides: _explicitParkingSides(tags),
            points: points,
          ),
        );
      }
      return segments;
    } catch (error) {
      throw NetworkPayloadException(
        'Réponse Overpass invalide',
        uri: endpoint,
        cause: error,
      );
    }
  }

  static List<Uri> _buildEndpoints(String? endpoint, String? fallbackEndpoint) {
    final primary = parseHttpEndpoint(
      endpoint ?? AppConfig.overpassUrl,
      configName: 'OVERPASS_URL',
    );
    // Un endpoint explicitement injecté est isolé par défaut, ce qui rend les
    // tests et les déploiements privés déterministes. Le fallback public ne
    // s'active automatiquement que pour la configuration embarquée.
    final fallbackRaw =
        fallbackEndpoint ??
        (endpoint == null ? AppConfig.overpassFallbackUrl : '');
    if (fallbackRaw.trim().isEmpty) return [primary];
    final fallback = parseHttpEndpoint(
      fallbackRaw,
      configName: 'OVERPASS_FALLBACK_URL',
    );
    return fallback == primary ? [primary] : [primary, fallback];
  }

  void close() => _network.close();

  void dispose() => close();

  static bool _isParkingForbidden(Map<String, dynamic> tags) {
    final both = tags['parking:lane:both'] ?? tags['parking:both'];
    final left = tags['parking:lane:left'] ?? tags['parking:left'];
    final right = tags['parking:lane:right'] ?? tags['parking:right'];
    if (both != null) return _noParkingValues.contains(both);
    if (left != null && right != null) {
      return _noParkingValues.contains(left) &&
          _noParkingValues.contains(right);
    }
    return false;
  }

  /// Nombre de côtés où le stationnement est explicitement possible,
  /// ou null si les tags ne le précisent pas.
  static int? _explicitParkingSides(Map<String, dynamic> tags) {
    final both = tags['parking:lane:both'] ?? tags['parking:both'];
    if (both != null) return _noParkingValues.contains(both) ? 0 : 2;
    final left = tags['parking:lane:left'] ?? tags['parking:left'];
    final right = tags['parking:lane:right'] ?? tags['parking:right'];
    if (left == null && right == null) return null;
    var sides = 0;
    if (left != null && !_noParkingValues.contains(left)) sides++;
    if (right != null && !_noParkingValues.contains(right)) sides++;
    return sides;
  }
}
