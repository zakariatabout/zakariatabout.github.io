import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/services/search_outcome_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  PendingSearchContext pending({double probability = 0.7}) =>
      PendingSearchContext(
        startedAt: DateTime.utc(2026, 7, 16, 18),
        predictedProbability: probability,
        isCalibrated: false,
        plannedHour: 18,
      );

  test('enregistre l issue avec la prédiction capturée au départ', () async {
    final store = SearchOutcomeStore();
    final observation = pending().finish(
      SearchOutcome.found,
      now: DateTime.utc(2026, 7, 16, 18, 4, 30),
    );
    await store.record(observation);

    final all = await store.all();
    expect(all, hasLength(1));
    expect(all.single.outcome, SearchOutcome.found);
    expect(all.single.predictedProbability, 0.7);
    expect(all.single.searchSeconds, 270);
    expect(all.single.isCalibrated, isFalse);
  });

  test('borne le nombre d observations conservées', () async {
    final store = SearchOutcomeStore(maxStored: 3);
    for (var i = 0; i < 5; i++) {
      await store.record(
        pending(probability: i / 10).finish(SearchOutcome.abandoned),
      );
    }
    final all = await store.all();
    expect(all, hasLength(3));
    expect(all.first.predictedProbability, closeTo(0.2, 1e-9));
  });

  test('ignore les entrées corrompues au lieu d échouer', () async {
    SharedPreferences.setMockInitialValues({
      'search_outcomes_v1':
          '[{"started_at":"pas-une-date","outcome":"found"},'
          '{"started_at":"2026-07-16T18:00:00Z",'
          '"predicted_probability":0.5,"outcome":"found"}]',
    });
    final store = SearchOutcomeStore();
    final all = await store.all();
    expect(all, hasLength(1));
    expect(all.single.predictedProbability, 0.5);
  });

  test('l export JSON restitue les observations brutes', () async {
    final store = SearchOutcomeStore();
    await store.record(pending().finish(SearchOutcome.found));
    final json = await store.exportJson();
    expect(json, contains('predicted_probability'));
    expect(json, contains('found'));
  });
}
