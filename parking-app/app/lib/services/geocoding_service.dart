import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'network_client.dart';

class GeocodingResult {
  GeocodingResult({required this.displayName, required this.location});

  final String displayName;
  final LatLng location;
}

/// Recherche d'adresses et de lieux via l'API officielle IGN Géoplateforme.
///
/// Les anciens endpoints IGN `completion` et Nominatim restent parsés
/// uniquement lorsqu'ils sont explicitement injectés pour une migration.
class GeocodingService {
  GeocodingService({http.Client? client, String? endpoint, Duration? timeout})
    : _endpoint = parseHttpEndpoint(
        endpoint ?? AppConfig.resolvedGeocodingSearchUrl,
        configName: 'GEOCODING_SEARCH_URL',
      ),
      _network = NetworkClient(
        client: client,
        timeout: timeout ?? AppConfig.networkTimeout,
      );

  final Uri _endpoint;
  final NetworkClient _network;

  Future<List<GeocodingResult>> search(String query) async {
    if (query.trim().length < 3) return const [];
    final legacyNominatim = _endpoint.host.toLowerCase().contains('nominatim');
    final legacyIgnCompletion = _endpoint.path.toLowerCase().contains(
      '/completion',
    );
    final uri = _endpoint.replace(
      queryParameters: legacyNominatim
          ? {
              'q': query,
              'format': 'jsonv2',
              'limit': '6',
              'addressdetails': '0',
              'accept-language': 'fr',
            }
          : legacyIgnCompletion
          ? {
              'text': query,
              'type': 'StreetAddress',
              'maximumResponses': '6',
              'bbox': '2.224,48.815,2.469,48.902',
            }
          : {
              'q': query,
              // L'API accepte cette liste CSV et renvoie dans un seul appel
              // les adresses BAN et les lieux/POI IGN. Cela couvre aussi bien
              // « 10 rue de Rivoli » que « Tour Eiffel » sans doubler le quota.
              'index': 'address,poi',
              'limit': '6',
              'citycode': '75056',
              'lat': '48.8566',
              'lon': '2.3522',
            },
    );
    final resp = await _network.get(
      uri,
      headers: const {'User-Agent': kUserAgent, 'Accept': 'application/json'},
    );
    _network.requireSuccess(resp, uri, acceptedStatusCodes: const {200});
    final decoded = _network.decodeJson(resp, uri);
    try {
      if (legacyNominatim) {
        final data = decoded as List;
        return [
          for (final raw in data)
            if (raw is Map)
              GeocodingResult(
                displayName: raw['display_name'] as String,
                location: LatLng(
                  double.parse(raw['lat'] as String),
                  double.parse(raw['lon'] as String),
                ),
              ),
        ];
      }

      final payload = (decoded as Map).cast<String, dynamic>();
      if (legacyIgnCompletion) {
        if (payload['status'] != 'OK') {
          throw const FormatException('Statut IGN différent de OK');
        }
        final results = payload['results'] as List? ?? const [];
        return [
          for (final raw in results)
            if (raw is Map && raw['x'] is num && raw['y'] is num)
              GeocodingResult(
                displayName:
                    (raw['fulltext'] ?? raw['label'] ?? raw['name']) as String,
                location: LatLng(
                  (raw['y'] as num).toDouble(),
                  (raw['x'] as num).toDouble(),
                ),
              ),
        ];
      }

      final features = payload['features'] as List? ?? const [];
      return features
          .map(_parseFeature)
          .whereType<GeocodingResult>()
          .toList(growable: false);
    } catch (error) {
      throw NetworkPayloadException(
        legacyNominatim
            ? 'Résultat Nominatim invalide'
            : 'Résultat IGN invalide',
        uri: uri,
        cause: error,
      );
    }
  }

  static GeocodingResult? _parseFeature(Object? raw) {
    if (raw is! Map) return null;
    final feature = raw.cast<String, dynamic>();
    final geometry = feature['geometry'];
    final properties = feature['properties'];
    if (geometry is! Map || properties is! Map) return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List ||
        coordinates.length < 2 ||
        coordinates[0] is! num ||
        coordinates[1] is! num) {
      return null;
    }
    final location = LatLng(
      (coordinates[1] as num).toDouble(),
      (coordinates[0] as num).toDouble(),
    );
    if (!_isInParis(location)) return null;

    final data = properties.cast<String, dynamic>();
    final label = _firstText(data['label']) ?? _firstText(data['toponym']);
    final name = label ?? _firstText(data['name']);
    if (name == null) return null;
    final postcode = _firstText(data['postcode']);
    final city = _firstText(data['city']);
    final displayName = label != null && data['label'] != null
        ? label
        : [
            name,
            if (postcode != null || city != null)
              [postcode, city].whereType<String>().join(' '),
          ].join(', ');
    return GeocodingResult(displayName: displayName, location: location);
  }

  static String? _firstText(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is List) {
      for (final item in value) {
        if (item is String && item.trim().isNotEmpty) return item.trim();
      }
    }
    return null;
  }

  static bool _isInParis(LatLng location) =>
      location.latitude >= 48.80 &&
      location.latitude <= 48.91 &&
      location.longitude >= 2.22 &&
      location.longitude <= 2.47;

  void close() => _network.close();

  void dispose() => close();
}
