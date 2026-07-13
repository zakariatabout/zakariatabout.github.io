/// Configuration du backend communautaire (Supabase, comme Tennis AI Coach).
///
/// Les valeurs sont injectées à la compilation :
///   flutter build web --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///                     --dart-define=SUPABASE_ANON_KEY=eyJ...
///
/// Sans ces valeurs, l'app fonctionne normalement mais sans la couche
/// temps réel communautaire (signalements de places).
class AppConfig {
  // Valeurs par défaut = projet Supabase de ParkRadar. La clé "publishable"
  // est publique par conception (protégée par les règles RLS côté serveur),
  // donc l'inscrire ici est sans risque et permet aux builds d'archive Xcode
  // (TestFlight) d'inclure la couche communautaire sans --dart-define.
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
}

/// En-tête d'identification exigé par Nominatim/Overpass (les User-Agent par
/// défaut des bibliothèques HTTP sont bloqués). Ignoré côté web (le navigateur
/// impose le sien), indispensable sur mobile.
const String kUserAgent =
    'ParkRadar/1.0 (https://zakariatabout.github.io/parking)';

