import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/services/probability_calibrator.dart';

void main() {
  group('IdentityProbabilityCalibrator', () {
    const calibrator = IdentityProbabilityCalibrator();

    test('signale explicitement l absence de calibration supervisée', () {
      final result = calibrator.calibrate(0.42);

      expect(result.probability, 0.42);
      expect(result.version, 'uncalibrated-v1');
      expect(result.supervisedObservationCount, 0);
    });

    test('borne aussi les entrées invalides', () {
      expect(calibrator.calibrate(-1).probability, 0);
      expect(calibrator.calibrate(2).probability, 1);
      expect(calibrator.calibrate(double.nan).probability, 0);
      expect(calibrator.calibrate(double.infinity).probability, 1);
    });
  });

  group('LogisticProbabilityCalibrator', () {
    final identity = LogisticProbabilityCalibrator(
      slope: 1,
      intercept: 0,
      version: 'platt-test-v1',
      supervisedObservationCount: 1000,
    );

    test('pente 1 et intercept 0 préservent la probabilité', () {
      for (final probability in [0.01, 0.2, 0.5, 0.8, 0.99]) {
        expect(
          identity.calibrate(probability).probability,
          closeTo(probability, 1e-12),
        );
      }
    });

    test('reste monotone avec une pente positive', () {
      final calibrator = LogisticProbabilityCalibrator(
        slope: 0.7,
        intercept: -0.2,
        version: 'platt-test-v2',
        supervisedObservationCount: 800,
      );
      final calibrated = [
        for (final probability in [0.0, 0.1, 0.4, 0.7, 1.0])
          calibrator.calibrate(probability).probability,
      ];

      for (var index = 1; index < calibrated.length; index++) {
        expect(calibrated[index], greaterThanOrEqualTo(calibrated[index - 1]));
      }
      expect(calibrated.every((value) => value >= 0 && value <= 1), isTrue);
    });

    test('un intercept positif augmente une probabilité médiane', () {
      final calibrator = LogisticProbabilityCalibrator(
        slope: 1,
        intercept: 0.5,
        version: 'platt-test-v3',
        supervisedObservationCount: 500,
      );

      final result = calibrator.calibrate(0.5);
      expect(result.probability, greaterThan(0.5));
      expect(result.version, 'platt-test-v3');
      expect(result.supervisedObservationCount, 500);
    });

    test('normalise la version exposée pour l audit', () {
      final calibrator = LogisticProbabilityCalibrator(
        slope: 1,
        intercept: 0,
        version: ' platt-test-v4 ',
        supervisedObservationCount: 10,
      );

      expect(calibrator.version, 'platt-test-v4');
      expect(calibrator.calibrate(0.5).version, 'platt-test-v4');
    });

    test('neutralise NaN et les infinis sans sortir des bornes', () {
      for (final value in [
        double.nan,
        double.negativeInfinity,
        double.infinity,
      ]) {
        final probability = identity.calibrate(value).probability;
        expect(probability.isNaN, isFalse);
        expect(probability, inInclusiveRange(0.0, 1.0));
      }
    });

    test('refuse des paramètres non apprenables ou non auditables', () {
      expect(
        () => LogisticProbabilityCalibrator(
          slope: -0.1,
          intercept: 0,
          version: 'v1',
          supervisedObservationCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => LogisticProbabilityCalibrator(
          slope: double.nan,
          intercept: 0,
          version: 'v1',
          supervisedObservationCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => LogisticProbabilityCalibrator(
          slope: 1,
          intercept: double.infinity,
          version: 'v1',
          supervisedObservationCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => LogisticProbabilityCalibrator(
          slope: 1,
          intercept: 0,
          version: ' ',
          supervisedObservationCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => LogisticProbabilityCalibrator(
          slope: 1,
          intercept: 0,
          version: 'v1',
          supervisedObservationCount: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
