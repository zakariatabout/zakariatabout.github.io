import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'route_progress_tracker.dart';
import 'routing_service.dart';

/// Moteur de synthèse vocale abstrait : la logique d'annonce reste testable
/// sans plugin natif, et la plateforme (flutter_tts) est un détail injecté.
abstract class SpeechEngine {
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> dispose();
}

/// Implémentation réelle sur flutter_tts (fr-FR). Les moteurs TTS varient
/// fortement entre iOS et Android : à valider sur appareil physique.
class FlutterTtsSpeechEngine implements SpeechEngine {
  FlutterTtsSpeechEngine() : _tts = FlutterTts() {
    _configured = _configure();
  }

  final FlutterTts _tts;
  late final Future<void> _configured;

  Future<void> _configure() async {
    try {
      await _tts.setLanguage('fr-FR');
      await _tts.setSpeechRate(0.5);
      await _tts.awaitSpeakCompletion(false);
    } catch (_) {
      // Un moteur absent (web sans voix FR, simulateur muet) ne doit jamais
      // casser le guidage visuel.
    }
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _configured;
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // Silencieux par conception : la voix est un plus, pas un prérequis.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() => stop();
}

/// Décide quoi annoncer et quand, à la manière d'un GPS : pré-annonce à
/// distance, rappel à l'approche, ordre au moment de tourner. Chaque palier
/// n'est prononcé qu'une fois par étape, et un changement d'étape réarme tout.
class VoiceGuidanceService {
  VoiceGuidanceService({required this.engine});

  final SpeechEngine engine;

  /// Paliers d'annonce (mètres) : pré-annonce, approche, imminence.
  static const farThresholdMeters = 400.0;
  static const nearThresholdMeters = 120.0;
  static const nowThresholdMeters = 30.0;

  bool muted = false;

  int? _announcedStepIndex;
  final Set<double> _announcedThresholds = {};

  /// Annonce de départ du guidage.
  Future<void> announceStart() async {
    if (muted) return;
    await engine.speak('Le guidage démarre. Suivez les instructions.');
  }

  /// À appeler sur chaque mise à jour de progression. [step] est l'étape dont
  /// on approche la manœuvre.
  Future<void> onProgress(RouteProgressSnapshot snapshot, RouteStep step) async {
    if (muted) return;

    if (_announcedStepIndex != snapshot.stepIndex) {
      _announcedStepIndex = snapshot.stepIndex;
      _announcedThresholds.clear();
    }

    final meters = snapshot.distanceToNextManeuverMeters;
    final threshold = _dueThreshold(meters);
    if (threshold == null || _announcedThresholds.contains(threshold)) return;
    // Une arrivée directe sous un palier « saute » les paliers supérieurs :
    // on ne rattrape jamais une annonce devenue obsolète.
    _announcedThresholds
      ..add(threshold)
      ..addAll(_skippedAbove(threshold));

    await engine.speak(_phrase(step, threshold, meters));
  }

  Future<void> announceRerouting() async {
    if (muted) return;
    await engine.speak('Recalcul de l’itinéraire.');
  }

  Future<void> announceGpsLost() async {
    if (muted) return;
    await engine.speak('Signal GPS perdu. Recherche en cours.');
  }

  Future<void> stop() => engine.stop();

  Future<void> dispose() => engine.dispose();

  double? _dueThreshold(double meters) {
    if (meters <= nowThresholdMeters) return nowThresholdMeters;
    if (meters <= nearThresholdMeters) return nearThresholdMeters;
    if (meters <= farThresholdMeters) return farThresholdMeters;
    return null;
  }

  Iterable<double> _skippedAbove(double threshold) sync* {
    if (threshold <= nowThresholdMeters) yield nearThresholdMeters;
    if (threshold <= nearThresholdMeters) yield farThresholdMeters;
  }

  String _phrase(RouteStep step, double threshold, double meters) {
    if (threshold == nowThresholdMeters) return step.instruction;
    final rounded = _roundDistance(meters);
    return 'Dans $rounded mètres, ${_lowerFirst(step.instruction)}';
  }

  int _roundDistance(double meters) {
    if (meters >= 300) return (meters / 100).round() * 100;
    if (meters >= 100) return (meters / 50).round() * 50;
    return (meters / 10).round() * 10;
  }

  String _lowerFirst(String text) =>
      text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);
}
