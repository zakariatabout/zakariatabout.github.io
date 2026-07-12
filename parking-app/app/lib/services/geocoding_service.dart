import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class GeocodingResult {
  GeocodingResult({required this.displayName, required this.location});

  final String displayName;
  final LatLng location;
}

/// Recherche d'adresse via Nominatim (OpenStreetMap).
class GeocodingService {
  GeocodingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<GeocodingResult>> search(String query) async {
    if (query.trim().length < 3) return const [];
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'jsonv2',
      'limit': '6',
      'addressdetails': '0',
      'accept-language': 'fr',
    });
    final resp = await _client.get(uri);
    if (resp.statusCode != 200) {
      throw Exception('Nominatim HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as List;
    return [
      for (final e in data.cast<Map<String, dynamic>>())
        GeocodingResult(
          displayName: e['display_name'] as String,
          location: LatLng(
            double.parse(e['lat'] as String),
            double.parse(e['lon'] as String),
          ),
        ),
    ];
  }
}
