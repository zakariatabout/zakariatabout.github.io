import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../models/street_segment.dart';

/// Récupère les tronçons de rue stationnables autour d'un point via
/// l'API Overpass (OpenStreetMap).
class OverpassService {
  OverpassService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _endpoint = 'https://overpass-api.de/api/interpreter';

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
    final query = '''
[out:json][timeout:25];
way(around:$radiusMeters,${center.latitude},${center.longitude})
  ["highway"~"^(residential|living_street|unclassified|tertiary|secondary)\$"]
  ["area"!="yes"];
out geom tags;
''';

    final resp = await _client.post(
      Uri.parse(_endpoint),
      headers: const {'User-Agent': kUserAgent},
      body: {'data': query},
    );
    if (resp.statusCode != 200) {
      throw Exception('Overpass HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final elements = (data['elements'] as List?) ?? const [];

    final segments = <StreetSegment>[];
    for (final e in elements) {
      final el = e as Map<String, dynamic>;
      final geometry = (el['geometry'] as List?) ?? const [];
      if (geometry.length < 2) continue;
      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};

      segments.add(
        StreetSegment(
          id: el['id'] as int,
          name: (tags['name'] as String?) ?? 'Rue sans nom',
          highwayType: (tags['highway'] as String?) ?? 'residential',
          isOneWay: tags['oneway'] == 'yes' || tags['oneway'] == '-1',
          parkingForbidden: _isParkingForbidden(tags),
          parkingSides: _explicitParkingSides(tags),
          points: [
            for (final g in geometry)
              LatLng(
                (g['lat'] as num).toDouble(),
                (g['lon'] as num).toDouble(),
              ),
          ],
        ),
      );
    }
    return segments;
  }

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
