import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'probability_calibrator.dart';

/// Persistance des paramètres de calibration supervisée.
///
/// Le calcul des paramètres (Platt : pente + ordonnée) se fait hors-ligne à
/// partir des observations du [SearchOutcomeStore]. Ce store ne fait que les
/// conserver et reconstruire le calibrateur au démarrage : tant qu'aucun
/// paramètre n'a été appris, l'app reste sur le calibrateur identité —
/// honnêtement non calibrée, jamais faussement confiante.
class CalibrationStore {
  static const _key = 'probability_calibration_v1';

  Future<ProbabilityCalibrator> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) {
        return const IdentityProbabilityCalibrator();
      }
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      final slope = json['slope'];
      final intercept = json['intercept'];
      final version = json['version'];
      final observations = json['observations'];
      if (slope is! num ||
          intercept is! num ||
          version is! String ||
          observations is! num ||
          observations.toInt() <= 0) {
        return const IdentityProbabilityCalibrator();
      }
      return LogisticProbabilityCalibrator(
        slope: slope.toDouble(),
        intercept: intercept.toDouble(),
        version: version,
        supervisedObservationCount: observations.toInt(),
      );
    } catch (_) {
      // Des paramètres illisibles ne doivent jamais empêcher le démarrage :
      // retour au comportement non calibré, le plus conservateur.
      return const IdentityProbabilityCalibrator();
    }
  }

  Future<void> save({
    required double slope,
    required double intercept,
    required String version,
    required int observations,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'slope': slope,
        'intercept': intercept,
        'version': version,
        'observations': observations,
      }),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
