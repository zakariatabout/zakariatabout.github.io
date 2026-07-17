import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/services/calibration_store.dart';
import 'package:parking_app/services/probability_calibrator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('sans paramètres appris : calibrateur identité', () async {
    final calibrator = await CalibrationStore().load();
    expect(calibrator, isA<IdentityProbabilityCalibrator>());
    expect(calibrator.supervisedObservationCount, 0);
  });

  test('des paramètres sauvegardés reconstruisent le calibrateur appris',
      () async {
    final store = CalibrationStore();
    await store.save(
      slope: 1.2,
      intercept: -0.3,
      version: 'platt-2026-07',
      observations: 84,
    );
    final calibrator = await store.load();
    expect(calibrator, isA<LogisticProbabilityCalibrator>());
    expect(calibrator.version, 'platt-2026-07');
    expect(calibrator.supervisedObservationCount, 84);
  });

  test('des paramètres corrompus retombent sur l identité', () async {
    SharedPreferences.setMockInitialValues({
      'probability_calibration_v1': '{"slope":"pas-un-nombre"}',
    });
    final calibrator = await CalibrationStore().load();
    expect(calibrator, isA<IdentityProbabilityCalibrator>());
  });

  test('zéro observation ne peut pas produire un calibrateur appris',
      () async {
    SharedPreferences.setMockInitialValues({
      'probability_calibration_v1':
          '{"slope":1.0,"intercept":0.0,"version":"x","observations":0}',
    });
    final calibrator = await CalibrationStore().load();
    expect(calibrator, isA<IdentityProbabilityCalibrator>());
  });

  test('clear ramène à l identité', () async {
    final store = CalibrationStore();
    await store.save(
      slope: 1,
      intercept: 0,
      version: 'v',
      observations: 10,
    );
    await store.clear();
    expect(await store.load(), isA<IdentityProbabilityCalibrator>());
  });
}
