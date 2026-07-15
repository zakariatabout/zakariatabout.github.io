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
  static const String mapTileUrlTemplate = String.fromEnvironment(
    'MAP_TILE_URL_TEMPLATE',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const String mapTileAttribution = String.fromEnvironment(
    'MAP_TILE_ATTRIBUTION',
    defaultValue: '© contributeurs OpenStreetMap',
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
