import 'dart:io' show Platform;

bool get isFlutterTestEnvironment =>
    Platform.environment.containsKey('FLUTTER_TEST');
