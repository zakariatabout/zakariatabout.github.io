import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'network_client.dart';

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

/// Provenance de la capacité publiée par Paris Data.
enum ParkingCapacitySource {
  /// `plarel` : nombre de places réelles relevées.
  actual,

  /// `placal` : capacité calculée, utilisée seulement en repli.
  calculated,
}

class ParkingSpot {
  ParkingSpot({
    required this.regime,
    required this.points,
    this.rawLabel,
    this.streetName,
    this.capacity,
    this.capacitySource,
    this.sourceId,
    this.sourceUpdatedAt,
    this.sourceUpdatedField,
  });

  final ParkingRegime regime;
  final List<LatLng> points;

  /// Libellé brut renvoyé par l'open data (pour affichage / debug).
  final String? rawLabel;

  /// Libellé de voie et capacité déclarée par le référentiel, lorsqu'ils sont
  /// disponibles. Ils alimentent les unités de décision conservatrices.
  final String? streetName;
  final int? capacity;
  final ParkingCapacitySource? capacitySource;
  final String? sourceId;

  /// Dernière date métier publiée par la source pour cet enregistrement.
  /// Elle reste nullable : la date d'un appel HTTP ne prouve pas l'âge du
  /// contenu retourné.
  final DateTime? sourceUpdatedAt;

  /// Champ Paris Data ayant fourni [sourceUpdatedAt], pour audit.
  final String? sourceUpdatedField;
}

/// Récupère le référentiel officiel des emplacements de stationnement en
/// voirie à Paris (Opendatasoft Explore API v2.1).
///
/// Le parseur tolère les variantes de noms de champs et de géométries.
/// [fetchSpots] conserve un comportement historique tolérant ;
/// l'orchestration de production utilise [fetchSpotsOrThrow] afin qu'une panne
/// de cet inventaire de régimes bloque les recommandations (fail-closed).
class ParisParkingService {
  ParisParkingService({http.Client? client, String? baseUrl, Duration? timeout})
    : _baseUri = parseHttpEndpoint(
        baseUrl ?? AppConfig.parisDataBaseUrl,
        configName: 'PARIS_DATA_BASE_URL',
      ),
      _network = NetworkClient(
        client: client,
        timeout: timeout ?? AppConfig.networkTimeout,
      );

  final Uri _baseUri;
  final NetworkClient _network;

  static const _dataset = 'stationnement-voie-publique-emplacements';

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
    int? maxRecords,
  }) async {
    if (!isInParis(center)) return const [];
    try {
      return await fetchSpotsOrThrow(
        center,
        radiusMeters: radiusMeters,
        limit: limit,
        maxRecords: maxRecords,
      );
    } catch (_) {
      return const [];
    }
  }

  /// Même requête que [fetchSpots], avec pagination complète et erreurs
  /// réseau typées. [limit] représente la taille d'une page (100 maximum),
  /// et non plus un plafond silencieux sur le nombre total de résultats.
  Future<List<ParkingSpot>> fetchSpotsOrThrow(
    LatLng center, {
    int radiusMeters = 400,
    int limit = 100,
    int? maxRecords,
  }) async {
    if (!isInParis(center)) return const [];
    if (radiusMeters <= 0 ||
        limit <= 0 ||
        (maxRecords != null && maxRecords <= 0)) {
      throw ArgumentError(
        'radiusMeters, limit et maxRecords doivent être positifs',
      );
    }

    final pageSize = limit.clamp(1, 100);
    final recordsUri = _baseUri.replace(
      path:
          '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/'
          '$_dataset/records',
    );
    final spots = <ParkingSpot>[];
    var offset = 0;
    var page = 0;
    int? totalCount;

    while (true) {
      if (page >= AppConfig.parisDataMaxPages.clamp(1, 1000)) {
        throw NetworkPayloadException(
          'Pagination Paris Data anormalement longue',
          uri: recordsUri,
        );
      }
      final remaining = maxRecords == null ? pageSize : maxRecords - offset;
      if (remaining <= 0) break;
      final currentPageSize = remaining < pageSize ? remaining : pageSize;
      final uri = recordsUri.replace(
        queryParameters: {
          'where':
              "within_distance(geo_shape, geom'POINT(${center.longitude} "
              "${center.latitude})', ${radiusMeters}m)",
          'limit': '$currentPageSize',
          'offset': '$offset',
        },
      );

      final resp = await _network.get(
        uri,
        headers: const {'User-Agent': kUserAgent},
      );
      _network.requireSuccess(resp, uri, acceptedStatusCodes: const {200});
      final data = _network.decodeObject(resp, uri);
      final rawResults = data['results'];
      if (rawResults is! List) {
        throw NetworkPayloadException(
          'Le champ results de Paris Data est invalide',
          uri: uri,
        );
      }
      final countValue = data['total_count'];
      if (countValue is num) totalCount = countValue.toInt();

      try {
        for (final raw in rawResults) {
          if (raw is! Map) continue;
          final record = raw.cast<String, dynamic>();
          final geometry = _extractGeometry(record['geo_shape']);
          if (geometry.isEmpty) continue;
          final label = _extractLabel(record);
          final streetName = _extractStreetName(record);
          final capacity = _extractCapacity(record);
          final capacitySource = _extractCapacitySource(record);
          final sourceId = _extractSourceId(record);
          final sourceUpdate = _extractSourceUpdate(record);
          for (final line in geometry) {
            if (line.length < 2) continue;
            spots.add(
              ParkingSpot(
                regime: _classify(label, record),
                points: line,
                rawLabel: label,
                streetName: streetName,
                capacity: capacity,
                capacitySource: capacitySource,
                sourceId: sourceId,
                sourceUpdatedAt: sourceUpdate.date,
                sourceUpdatedField: sourceUpdate.field,
              ),
            );
          }
        }
      } catch (error) {
        throw NetworkPayloadException(
          'Enregistrement Paris Data invalide',
          uri: uri,
          cause: error,
        );
      }

      final received = rawResults.length;
      offset += received;
      page++;
      if (received == 0 || received < currentPageSize) break;
      if (totalCount != null && offset >= totalCount) break;
      if (maxRecords != null && offset >= maxRecords) break;
    }
    return spots;
  }

  void close() => _network.close();

  void dispose() => close();

  // ── Parsing tolérant ────────────────────────────────────────────────────

  /// Cherche le libellé de régime dans plusieurs champs candidats.
  String? _extractLabel(Map<String, dynamic> r) {
    final labels = <String>[];
    for (final key in const ['regpri', 'regpar']) {
      final v = r[key];
      if (v is String && v.trim().isNotEmpty && !labels.contains(v.trim())) {
        labels.add(v.trim());
      }
    }
    if (labels.isNotEmpty) return labels.join(' · ');
    for (final key in const [
      'regime',
      'typ_usa',
      'typsta',
      'typ_reg',
      'categorie',
      'libelle',
    ]) {
      final value = r[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  String? _extractStreetName(Map<String, dynamic> record) {
    final name = record['nomvoie']?.toString().trim();
    if (name == null || name.isEmpty) return null;
    final type = record['typevoie']?.toString().trim();
    return type == null || type.isEmpty ? name : '$type $name';
  }

  int? _extractCapacity(Map<String, dynamic> record) {
    return _positiveInt(record['plarel']) ?? _positiveInt(record['placal']);
  }

  ParkingCapacitySource? _extractCapacitySource(Map<String, dynamic> record) {
    if (_positiveInt(record['plarel']) != null) {
      return ParkingCapacitySource.actual;
    }
    if (_positiveInt(record['placal']) != null) {
      return ParkingCapacitySource.calculated;
    }
    return null;
  }

  int? _positiveInt(Object? raw) {
    final value = raw is num ? raw.toInt() : int.tryParse('$raw');
    return value != null && value > 0 ? value : null;
  }

  String? _extractSourceId(Map<String, dynamic> record) {
    for (final key in const ['id', 'nummob', 'id_old']) {
      final value = record[key];
      if (value != null && '$value'.trim().isNotEmpty) return '$value';
    }
    return null;
  }

  ({DateTime? date, String? field}) _extractSourceUpdate(
    Map<String, dynamic> record,
  ) {
    for (final field in const [
      'mtlast_edit_date_field',
      'datereleve',
      'date_maj',
      'date_mise_a_jour',
      'updated_at',
      'last_update',
    ]) {
      final date = _parseSourceDate(record[field]);
      if (date != null) return (date: date, field: field);
    }
    return (date: null, field: null);
  }

  DateTime? _parseSourceDate(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw.toUtc();
    final text = '$raw'.trim();
    if (text.isEmpty) return null;
    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
    if (dateOnly != null) {
      return DateTime.utc(
        int.parse(dateOnly.group(1)!),
        int.parse(dateOnly.group(2)!),
        int.parse(dateOnly.group(3)!),
      );
    }
    return DateTime.tryParse(text)?.toUtc();
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

  ParkingRegime _classify(String? label, [Map<String, dynamic>? record]) {
    if (label == null) return ParkingRegime.autre;
    final l = label.toLowerCase();
    if (_hasUninterpretedTemporalRestriction(l, record)) {
      return ParkingRegime.autre;
    }
    if (l.contains('interdit') || l.contains('gêne') || l.contains('gene')) {
      return ParkingRegime.interdit;
    }
    if (l.contains('gig') ||
        l.contains('gic') ||
        l.contains('handicap') ||
        l.contains('pmr')) {
      return ParkingRegime.handicap;
    }
    if (l.contains('livraison') || l.contains('logistique')) {
      return ParkingRegime.livraison;
    }
    if (l.contains('taxi')) return ParkingRegime.taxi;
    if (l.contains('autocar') ||
        l.contains('autobus') ||
        l.contains('bus') ||
        l.contains('car ')) {
      return ParkingRegime.autocar;
    }
    // `regpri` vaut souvent « 2 ROUES » : le `regpar` plus précis doit donc
    // faire gagner les vélos, Vélib' et vélos-cargos avant le test « roues ».
    if (l.contains('vélo') ||
        l.contains('velo') ||
        l.contains('vélib') ||
        l.contains('velib') ||
        l.contains('cycle')) {
      return ParkingRegime.velo;
    }
    // Deux-roues motorisés : « 2 ROUES », « DEUX ROUES », « MOTO »…
    if (l.contains('moto') ||
        l.contains('roues') ||
        l.contains('2rm') ||
        l.contains('2 roues') ||
        l.contains('deux-roues')) {
      return ParkingRegime.moto;
    }
    if (l.contains('résident') || l.contains('resident')) {
      return ParkingRegime.resident;
    }
    if (l.contains('gratuit')) return ParkingRegime.gratuit;
    if (l.contains('payant') ||
        l.contains('rotatif') ||
        l.contains('mixte') ||
        l.contains('horodate')) {
      return ParkingRegime.payant;
    }
    return ParkingRegime.autre;
  }

  bool _hasUninterpretedTemporalRestriction(
    String normalizedLabel,
    Map<String, dynamic>? record,
  ) {
    if (normalizedLabel.contains('marché') ||
        normalizedLabel.contains('marche')) {
      return true;
    }
    if (record == null) return false;
    for (final field in const [
      'plage_hor1_debut',
      'plage_hor1_fin',
      'plage_hor2_debut',
      'plage_hor2_fin',
      'plage_hor3_debut',
      'plage_hor3_fin',
    ]) {
      final value = record[field];
      if (value != null && '$value'.trim().isNotEmpty) return true;
    }
    return false;
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
