import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/route_progress_tracker.dart';
import 'package:parking_app/services/routing_service.dart';
import 'package:parking_app/services/voice_guidance_service.dart';

class _RecordingEngine implements SpeechEngine {
  final List<String> spoken = [];
  int stops = 0;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}

RouteProgressSnapshot snapshot(double toManeuver, {int stepIndex = 0}) =>
    RouteProgressSnapshot(
      alongRouteMeters: 100,
      distanceToRouteMeters: 3,
      stepIndex: stepIndex,
      distanceToNextManeuverMeters: toManeuver,
      remainingRouteMeters: 500,
      remainingDurationSeconds: 120,
    );

RouteStep step(String instruction) => RouteStep(
  instruction: instruction,
  maneuver: 'turn:right',
  location: const LatLng(48.8566, 2.3522),
  durationSeconds: 30,
  distanceMeters: 200,
);

void main() {
  test('annonce chaque palier une seule fois, dans l ordre', () async {
    final engine = _RecordingEngine();
    final voice = VoiceGuidanceService(engine: engine);
    final turn = step('Tournez à droite sur Rue Oberkampf');

    await voice.onProgress(snapshot(600), turn); // trop loin : rien
    await voice.onProgress(snapshot(390), turn); // palier 400
    await voice.onProgress(snapshot(360), turn); // déjà annoncé
    await voice.onProgress(snapshot(110), turn); // palier 120
    await voice.onProgress(snapshot(20), turn); // palier 30 : ordre direct

    expect(engine.spoken, [
      'Dans 400 mètres, tournez à droite sur Rue Oberkampf',
      'Dans 100 mètres, tournez à droite sur Rue Oberkampf',
      'Tournez à droite sur Rue Oberkampf',
    ]);
  });

  test('arriver directement sous un palier saute les paliers supérieurs',
      () async {
    final engine = _RecordingEngine();
    final voice = VoiceGuidanceService(engine: engine);
    final turn = step('Tournez à gauche');

    await voice.onProgress(snapshot(25), turn);
    await voice.onProgress(snapshot(110), turn); // ne « rattrape » jamais

    expect(engine.spoken, ['Tournez à gauche']);
  });

  test('un changement d étape réarme les annonces', () async {
    final engine = _RecordingEngine();
    final voice = VoiceGuidanceService(engine: engine);

    await voice.onProgress(snapshot(100, stepIndex: 0), step('Première'));
    await voice.onProgress(snapshot(100, stepIndex: 1), step('Seconde'));

    expect(engine.spoken, hasLength(2));
    expect(engine.spoken.last, contains('seconde'.substring(1)));
  });

  test('muet : aucune annonce', () async {
    final engine = _RecordingEngine();
    final voice = VoiceGuidanceService(engine: engine)..muted = true;

    await voice.announceStart();
    await voice.onProgress(snapshot(20), step('Tournez'));
    await voice.announceRerouting();
    await voice.announceGpsLost();

    expect(engine.spoken, isEmpty);
  });

  test('annonces de service : départ, recalcul, GPS perdu', () async {
    final engine = _RecordingEngine();
    final voice = VoiceGuidanceService(engine: engine);

    await voice.announceStart();
    await voice.announceRerouting();
    await voice.announceGpsLost();

    expect(engine.spoken, hasLength(3));
    expect(engine.spoken.first, contains('guidage'));
  });
}
