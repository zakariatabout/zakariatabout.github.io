import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Issue réelle d'une session de guidage.
enum SearchOutcome { found, abandoned }

/// Contexte capturé au démarrage d'un guidage : la prédiction affichée à ce
/// moment-là, qui sera confrontée à l'issue réelle.
class PendingSearchContext {
  PendingSearchContext({
    required this.startedAt,
    required this.predictedProbability,
    required this.isCalibrated,
    required this.plannedHour,
  });

  final DateTime startedAt;
  final double predictedProbability;
  final bool isCalibrated;
  final int plannedHour;

  SearchObservation finish(SearchOutcome outcome, {DateTime? now}) {
    final endedAt = now ?? DateTime.now();
    return SearchObservation(
      startedAt: startedAt,
      predictedProbability: predictedProbability,
      isCalibrated: isCalibrated,
      plannedHour: plannedHour,
      outcome: outcome,
      searchSeconds: endedAt.difference(startedAt).inSeconds,
    );
  }
}

/// Observation supervisée : « le modèle annonçait p, voici ce qui s'est
/// réellement passé ». C'est la matière première du Brier score, du
/// reliability diagram et de la calibration (Platt) — le « mur n°1 » des
/// études. Aucune position n'est stockée : uniquement la prédiction, l'issue
/// et la durée.
class SearchObservation {
  SearchObservation({
    required this.startedAt,
    required this.predictedProbability,
    required this.isCalibrated,
    required this.plannedHour,
    required this.outcome,
    required this.searchSeconds,
  });

  final DateTime startedAt;
  final double predictedProbability;
  final bool isCalibrated;
  final int plannedHour;
  final SearchOutcome outcome;
  final int searchSeconds;

  Map<String, Object?> toJson() => {
    'started_at': startedAt.toUtc().toIso8601String(),
    'predicted_probability': predictedProbability,
    'is_calibrated': isCalibrated,
    'planned_hour': plannedHour,
    'outcome': outcome.name,
    'search_seconds': searchSeconds,
  };

  static SearchObservation? fromJson(Map<String, Object?> json) {
    final startedAt = DateTime.tryParse(json['started_at'] as String? ?? '');
    final probability = json['predicted_probability'];
    final outcomeName = json['outcome'];
    if (startedAt == null || probability is! num || outcomeName is! String) {
      return null;
    }
    final outcome = SearchOutcome.values.asNameMap()[outcomeName];
    if (outcome == null) return null;
    return SearchObservation(
      startedAt: startedAt,
      predictedProbability: probability.toDouble(),
      isCalibrated: json['is_calibrated'] == true,
      plannedHour: (json['planned_hour'] as num?)?.toInt() ?? startedAt.hour,
      outcome: outcome,
      searchSeconds: (json['search_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persistance locale des observations (bornée). Volontairement hors ligne :
/// l'export vers un backend d'entraînement sera un choix explicite, jamais un
/// envoi silencieux.
class SearchOutcomeStore {
  SearchOutcomeStore({this.maxStored = 500});

  static const _key = 'search_outcomes_v1';
  final int maxStored;

  Future<void> record(SearchObservation observation) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _decode(prefs.getString(_key))..add(observation.toJson());
    final trimmed = list.length > maxStored
        ? list.sublist(list.length - maxStored)
        : list;
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  Future<List<SearchObservation>> all() async {
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(_key))
        .map(SearchObservation.fromJson)
        .whereType<SearchObservation>()
        .toList();
  }

  /// Export JSON brut (pour analyse hors-ligne : Brier, reliability diagram,
  /// paramètres de calibration).
  Future<String> exportJson() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonEncode(_decode(prefs.getString(_key)));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  List<Map<String, Object?>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, Object?>>();
    } catch (_) {
      return [];
    }
  }
}
