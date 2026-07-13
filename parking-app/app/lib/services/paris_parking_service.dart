import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

/// Régime d'une place de stationnement (règle d'usage).
enum ParkingRegime {
  payant,
  gratuit,
  resident,
  moto,
  velo,
  livraison,
  handicap,
  taxi,
  autocar,
  interdit,
  autre,
}

class ParkingSpot {
  ParkingSpot({required this.regime, required this.points, this.rawLabel});

  final ParkingRegime regime;
  final List<LatLng> points;

  /// Libellé brut renvoyé par l'open data (pour affichage / debug).
  final String? rawLabel;
}

/// Récupère les vraies places de stationnement en voirie à Paris depuis
/// l'open data de la Ville (Opendatasoft Explore API v2.1).
///
/// Défensif par conception : tolère les variantes de noms de champs et de
/// géométries, et renvoie une liste vide en cas de souci — l'app continue de
/// fonctionner avec son estimation heuristique.
class ParisParkingService {
  ParisParkingService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const _dataset = 'stationnement-voie-publique-emplacements';
  static const _base =
      'https://opendata.paris.fr/api/explore/v2.1/catalog/datasets';

  /// Boîte englobante approximative de Paris intra-muros.
  static bool isInParis(LatLng p) =>
      p.latitude >= 48.80 &&
      p.latitude <= 48.91 &&
      p.longitude >= 2.22 &&
      p.longitude <= 2.47;

  Future<List<ParkingSpot>> fetchSpots(
    LatLng center, {
    int radiusMeters = 400,
    int limit = 100,
  }) async {
    if (!isInParis(center)) return const [];
    final uri = Uri.parse('$_base/$_dataset/records').replace(
      queryParameters: {
        'where': "within_distance(geo_shape, geom'POINT(${center.longitude} "
            "${center.latitude})', ${radiusMeters}m)",
        'limit': '$limit',
      },
    );
    try {
      final resp =
          await _client.get(uri, headers: const {'User-Agent': kUserAgent});
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = (data['results'] as List?) ?? const [];
      final spots = <ParkingSpot>[];
      for (final r in results.cast<Map<String, dynamic>>()) {
        final geom = _extractGeometry(r['geo_shape']);
        if (geom.isEmpty) continue;
        final label = _extractLabel(r);
        for (final line in geom) {
          if (line.length < 2) continue;
          spots.add(ParkingSpot(
            regime: _classify(label),
            points: line,
            rawLabel: label,
          ));
        }
      }
      return spots;
    } catch (_) {
      return const [];
    }
  }

  // ── Parsing tolérant ────────────────────────────────────────────────────

  /// Cherche le libellé de régime dans plusieurs champs candidats.
  String? _extractLabel(Map<String, dynamic> r) {
    for (final key in const [
      'regpri',
      'regime',
      'typ_usa',
      'typsta',
      'typ_reg',
      'categorie',
      'libelle',
    ]) {
      final v = r[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  /// Extrait une liste de polylignes depuis un geo_shape GeoJSON
  /// (Feature / Geometry, LineString / MultiLineString / Point).
  List<List<LatLng>> _extractGeometry(dynamic geoShape) {
    if (geoShape is! Map) return const [];
    final geometry =
        (geoShape['geometry'] as Map?) ?? geoShape; // Feature ou Geometry brut
    final type = geometry['type'];
    final coords = geometry['coordinates'];
    if (coords == null) return const [];

    List<LatLng> asLine(List raw) => [
          for (final c in raw)
            if (c is List && c.length >= 2)
              LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ];

    switch (type) {
      case 'LineString':
        return [asLine(coords as List)];
      case 'MultiLineString':
        return [for (final l in coords as List) asLine(l as List)];
      case 'Point':
        final c = coords as List;
        if (c.length >= 2) {
          // Un point seul : petit segment fictif pour être visible.
          final p = LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
          return [
            [p, LatLng(p.latitude + 0.00002, p.longitude)],
          ];
        }
        return const [];
      case 'Polygon':
        final rings = coords as List;
        return rings.isEmpty ? const [] : [asLine(rings.first as List)];
      default:
        return const [];
    }
  }

  ParkingRegime _classify(String? label) {
    if (label == null) return ParkingRegime.autre;
    final l = label.toLowerCase();
    if (l.contains('interdit') || l.contains('gêne') || l.contains('gene')) {
      return ParkingRegime.interdit;
    }
    if (l.contains('gig') || l.contains('gic') || l.contains('handicap') ||
        l.contains('pmr')) {
      return ParkingRegime.handicap;
    }
    if (l.contains('livraison') || l.contains('logistique')) {
      return ParkingRegime.livraison;
    }
    if (l.contains('taxi')) return ParkingRegime.taxi;
    if (l.contains('autocar') || l.contains('autobus') || l.contains('bus') ||
        l.contains('car ')) {
      return ParkingRegime.autocar;
    }
    // Deux-roues motorisés : « 2 ROUES », « DEUX ROUES », « MOTO »…
    if (l.contains('moto') || l.contains('roues') || l.contains('2rm') ||
        l.contains('2 roues') || l.contains('deux-roues')) {
      return ParkingRegime.moto;
    }
    if (l.contains('vélo') || l.contains('velo') || l.contains('cycle')) {
      return ParkingRegime.velo;
    }
    if (l.contains('résident') || l.contains('resident')) {
      return ParkingRegime.resident;
    }
    if (l.contains('gratuit')) return ParkingRegime.gratuit;
    if (l.contains('payant') || l.contains('rotatif') || l.contains('mixte') ||
        l.contains('horodate')) {
      return ParkingRegime.payant;
    }
    return ParkingRegime.autre;
  }
}

extension ParkingRegimeInfo on ParkingRegime {
  String get label => switch (this) {
        ParkingRegime.payant => 'Payant',
        ParkingRegime.gratuit => 'Gratuit',
        ParkingRegime.resident => 'Résident',
        ParkingRegime.moto => 'Deux-roues',
        ParkingRegime.velo => 'Vélo',
        ParkingRegime.livraison => 'Livraison',
        ParkingRegime.handicap => 'GIG-GIC',
        ParkingRegime.taxi => 'Taxi',
        ParkingRegime.autocar => 'Autocar',
        ParkingRegime.interdit => 'Gêne / interdit',
        ParkingRegime.autre => 'Autre',
      };
}
