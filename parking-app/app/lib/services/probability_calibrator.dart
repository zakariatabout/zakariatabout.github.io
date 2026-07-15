import 'dart:math' as math;

import '../models/availability_estimate.dart';

/// Résultat immuable d'une étape de calibration.
class CalibrationResult {
  CalibrationResult({
    required num probability,
    required String version,
    required this.supervisedObservationCount,
  }) : probability = ProbabilityBounds.clamp(probability),
       version = version.trim() {
    if (this.version.isEmpty) {
      throw ArgumentError.value(version, 'version', 'Version vide');
    }
    if (supervisedObservationCount < 0) {
      throw ArgumentError.value(
        supervisedObservationCount,
        'supervisedObservationCount',
      );
    }
  }

  final double probability;
  final String version;
  final int supervisedObservationCount;
}

/// Contrat injectable pour calibrer le prior produit par le moteur.
abstract class ProbabilityCalibrator {
  const ProbabilityCalibrator();

  String get version;
  int get supervisedObservationCount;

  CalibrationResult calibrate(double rawProbability);
}

/// Calibration identité : elle signale explicitement l'absence de données
/// supervisées au lieu de prétendre que le prior est calibré.
class IdentityProbabilityCalibrator extends ProbabilityCalibrator {
  const IdentityProbabilityCalibrator();

  @override
  String get version => 'uncalibrated-v1';

  @override
  int get supervisedObservationCount => 0;

  @override
  CalibrationResult calibrate(double rawProbability) => CalibrationResult(
    probability: rawProbability,
    version: version,
    supervisedObservationCount: supervisedObservationCount,
  );
}

/// Calibration logistique à deux paramètres, équivalente à un Platt scaling.
///
/// Les coefficients doivent être ajustés hors ligne sur un jeu de calibration
/// distinct du train et du test. Une pente positive garantit la monotonie :
/// une meilleure probabilité brute ne peut pas devenir moins bonne après
/// calibration.
class LogisticProbabilityCalibrator extends ProbabilityCalibrator {
  LogisticProbabilityCalibrator({
    required this.slope,
    required this.intercept,
    required String version,
    required this.supervisedObservationCount,
  }) : version = version.trim() {
    if (!slope.isFinite || slope < 0) {
      throw ArgumentError.value(
        slope,
        'slope',
        'La pente doit être finie et positive ou nulle',
      );
    }
    if (!intercept.isFinite) {
      throw ArgumentError.value(intercept, 'intercept', 'Valeur non finie');
    }
    if (this.version.isEmpty) {
      throw ArgumentError.value(version, 'version', 'Version vide');
    }
    if (supervisedObservationCount <= 0) {
      throw ArgumentError.value(
        supervisedObservationCount,
        'supervisedObservationCount',
        'Une calibration apprise exige des observations supervisées',
      );
    }
  }

  static const double _epsilon = 1e-9;

  final double slope;
  final double intercept;

  @override
  final String version;

  @override
  final int supervisedObservationCount;

  @override
  CalibrationResult calibrate(double rawProbability) {
    final p = ProbabilityBounds.clamp(
      rawProbability,
    ).clamp(_epsilon, 1.0 - _epsilon).toDouble();
    final logit = math.log(p / (1.0 - p));
    final z = intercept + slope * logit;
    final calibrated = z >= 0
        ? 1.0 / (1.0 + math.exp(-z))
        : math.exp(z) / (1.0 + math.exp(z));
    return CalibrationResult(
      probability: calibrated,
      version: version,
      supervisedObservationCount: supervisedObservationCount,
    );
  }
}
