/// Configuration du backend communautaire (Supabase, comme Tennis AI Coach).
///
/// Les valeurs sont injectées à la compilation :
///   flutter build web --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///                     --dart-define=SUPABASE_ANON_KEY=eyJ...
///
/// Sans ces valeurs, l'app fonctionne normalement mais sans la couche
/// temps réel communautaire (signalements de places).
class AppConfig {
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get communityEnabled =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
