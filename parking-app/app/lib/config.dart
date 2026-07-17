/// Configuration du backend communautaire Supabase de ParkRadar.
///
/// Les valeurs sont injectées à la compilation :
///   flutter build web --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///                     --dart-define=SUPABASE_ANON_KEY=eyJ...
///
/// Les valeurs ne suffisent pas à prouver que le backend est opérationnel :
/// le déploiement doit aussi passer `verify_backend.sh`.
class AppConfig {
  // Valeurs par défaut = projet Supabase de ParkRadar. La clé "publishable"
  // est publique par conception. Son inclusion n'est sûre que si Edge, RPC,
  // RLS et cron ont été déployés et vérifiés ; elle permet aux archives Xcode
  // de configurer le client sans --dart-define.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://xkhsvwqzuzmrvdrghshv.supabase.co',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_KmxkQQjvFmvblhBX3WBwHw__of4oMsF',
  );

  static bool get communityEnabled =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  // Endpoints publics remplaçables par environnement, sans modifier le code.
  // Les valeurs sont des URLs complètes (sauf OSRM : racine du profil route).
  static const String parisDataBaseUrl = String.fromEnvironment(
    'PARIS_DATA_BASE_URL',
    defaultValue: 'https://opendata.paris.fr/api/explore/v2.1/catalog/datasets',
  );
  static const String geocodingSearchUrl = String.fromEnvironment(
    'GEOCODING_SEARCH_URL',
    defaultValue: 'https://data.geopf.fr/geocodage/search',
  );
  static const String _legacyNominatimSearchUrl = String.fromEnvironment(
    'NOMINATIM_SEARCH_URL',
  );
  static const String overpassUrl = String.fromEnvironment(
    'OVERPASS_URL',
    defaultValue: 'https://overpass-api.de/api/interpreter',
  );
  static const String overpassFallbackUrl = String.fromEnvironment(
    'OVERPASS_FALLBACK_URL',
    // Aucun second opérateur ne reçoit la destination sans configuration
    // explicite. Injecter ici un service contractuel ou autohébergé.
    defaultValue: '',
  );
  static const String osrmDrivingBaseUrl = String.fromEnvironment(
    'OSRM_DRIVING_BASE_URL',
    defaultValue: 'https://router.project-osrm.org/route/v1/driving',
  );
  /// Template OSM « standard » (criard, très détaillé). Conservé comme
  /// référence : quand il est actif, l'app applique un filtre de couleur
  /// pour l'adoucir ; les fonds pré-stylés (CARTO, Stadia) n'en ont pas
  /// besoin.
  static const String osmStandardTileTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Fond minimaliste façon Waze : CARTO Positron (clair) / Dark Matter
  /// (sombre) — uniquement rues et libellés, pas de bruit visuel. Convient à
  /// l'usage de développement/test actuel ; pour une diffusion publique,
  /// injecter un fournisseur contractuel (ex. Stadia avec clé gratuite) via
  /// ces variables d'environnement.
  static const String mapTileUrlTemplate = String.fromEnvironment(
    'MAP_TILE_URL_TEMPLATE',
    defaultValue:
        'https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}@2x.png',
  );

  /// Template dédié au thème sombre, en paire avec le clair.
  /// Vide = on réutilise le template clair (assombri par filtre si OSM brut).
  static const String _mapTileUrlTemplateDark = String.fromEnvironment(
    'MAP_TILE_URL_TEMPLATE_DARK',
    defaultValue:
        'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png',
  );
  static String get mapTileUrlTemplateDark => _mapTileUrlTemplateDark.isEmpty
      ? mapTileUrlTemplate
      : _mapTileUrlTemplateDark;
  static const String mapTileAttribution = String.fromEnvironment(
    'MAP_TILE_ATTRIBUTION',
    defaultValue: '© OpenStreetMap · © CARTO',
  );

  // ── Rendu vectoriel (VectorTileLayer GPU, styles ParkRadar) ─────────────
  /// Tuiles vectorielles OpenFreeMap : gratuites, sans clé, usage commercial
  /// autorisé, schéma OpenMapTiles. Seuls {z} {x} {y} sont substitués.
  /// Le maxzoom réel du tileset planet est 14 (voir map_screen.dart).
  static const String vectorTileUrlTemplate = String.fromEnvironment(
    'VECTOR_TILE_URL_TEMPLATE',
    defaultValue: 'https://tiles.openfreemap.org/planet/{z}/{x}/{y}.pbf',
  );

  /// 'vector' (défaut) = fond vectoriel GPU stylé ParkRadar.
  /// 'raster' = repli CARTO actuel (TileLayer), strictement inchangé.
  /// Ex. : flutter run --dart-define=MAP_RENDERER=raster
  static const String mapRenderer = String.fromEnvironment(
    'MAP_RENDERER',
    defaultValue: 'vector',
  );
  static bool get useVectorRenderer => mapRenderer != 'raster';

  /// Attribution du fond vectoriel (obligation OSM + mention OpenFreeMap).
  static const String vectorTileAttribution = String.fromEnvironment(
    'VECTOR_TILE_ATTRIBUTION',
    defaultValue: '© OpenStreetMap · OpenFreeMap',
  );

  static const int networkTimeoutSeconds = int.fromEnvironment(
    'NETWORK_TIMEOUT_SECONDS',
    defaultValue: 30,
  );
  static const int overpassTimeoutSeconds = int.fromEnvironment(
    'OVERPASS_TIMEOUT_SECONDS',
    defaultValue: 18,
  );
  static const int communityTimeoutSeconds = int.fromEnvironment(
    'COMMUNITY_TIMEOUT_SECONDS',
    defaultValue: 12,
  );
  static const int communityEventTtlMinutes = int.fromEnvironment(
    'COMMUNITY_EVENT_TTL_MINUTES',
    defaultValue: 15,
  );
  static const int communityRetentionHours = int.fromEnvironment(
    'COMMUNITY_RETENTION_HOURS',
    defaultValue: 24,
  );
  static const int communityPollIntervalSeconds = int.fromEnvironment(
    'COMMUNITY_POLL_INTERVAL_SECONDS',
    defaultValue: 20,
  );
  static const bool communityLegacyFallback = bool.fromEnvironment(
    'COMMUNITY_LEGACY_FALLBACK',
    // Fail closed by default: the legacy table exposes unaggregated reports.
    // It may only be re-enabled during a short, controlled migration.
    defaultValue: false,
  );
  static const String communityReportUrl = String.fromEnvironment(
    'COMMUNITY_REPORT_URL',
  );
  static const int parisDataMaxPages = int.fromEnvironment(
    'PARIS_DATA_MAX_PAGES',
    defaultValue: 100,
  );

  static Duration get networkTimeout =>
      Duration(seconds: networkTimeoutSeconds.clamp(1, 120));
  static Duration get overpassTimeout =>
      Duration(seconds: overpassTimeoutSeconds.clamp(5, 60));
  static Duration get communityTimeout =>
      Duration(seconds: communityTimeoutSeconds.clamp(1, 60));
  static Duration get communityEventTtl =>
      Duration(minutes: communityEventTtlMinutes.clamp(1, 60));
  static Duration get communityRetention =>
      Duration(hours: communityRetentionHours.clamp(1, 168));
  static Duration get communityPollInterval =>
      Duration(seconds: communityPollIntervalSeconds.clamp(5, 300));

  /// Un ancien endpoint Nominatim explicitement injecté reste utilisable le
  /// temps d'une migration. Sans define, la recherche adresse + lieu passe
  /// par l'API officielle IGN Géoplateforme.
  static String get resolvedGeocodingSearchUrl =>
      _legacyNominatimSearchUrl.isNotEmpty
      ? _legacyNominatimSearchUrl
      : geocodingSearchUrl;
}

/// En-tête d'identification des appels publics (notamment Overpass).
const String kUserAgent =
    'ParkRadar/1.0 (https://zakariatabout.github.io/parking)';
