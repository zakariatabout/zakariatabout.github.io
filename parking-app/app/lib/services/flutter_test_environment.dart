/// `flutter test` pose la variable d'environnement FLUTTER_TEST. Détection
/// via conditional import : stub (false) sur le web où dart:io est absent.
///
/// Sert à forcer le fond RASTER dans les widget tests : le pipeline GPU de
/// vector_map_tiles ne peut pas s'initialiser sous flutter_test (shaders
/// flutter_gpu indisponibles) et tout échec de fetch de tuile y devient une
/// async error non rattrapée (MapTiles._start ne catch que
/// CancellationException) qui ferait échouer les widget tests existants.
library;

export 'flutter_test_environment_stub.dart'
    if (dart.library.io) 'flutter_test_environment_io.dart';
