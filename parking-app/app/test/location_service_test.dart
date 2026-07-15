import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/location_service.dart';

void main() {
  final now = DateTime.utc(2026, 7, 15, 12);

  LocationSample sample({double accuracy = 5, Duration age = Duration.zero}) =>
      LocationSample(
        position: const LatLng(48.8566, 2.3522),
        timestamp: now.subtract(age),
        accuracyMeters: accuracy,
      );

  test('accepte seulement une mesure GPS fraîche et précise', () {
    expect(sample().isUsable(now), isTrue);
    expect(sample(accuracy: 80).isUsable(now), isFalse);
    expect(sample(age: const Duration(seconds: 30)).isUsable(now), isFalse);
  });

  test('rejette une précision absente ou non finie', () {
    expect(sample(accuracy: 0).isUsable(now), isFalse);
    expect(sample(accuracy: double.nan).isUsable(now), isFalse);
  });

  test('rejette les coordonnées hors limites et une mesure trop future', () {
    expect(
      LocationSample(
        position: const LatLng(91, 2.3522),
        timestamp: now,
        accuracyMeters: 5,
      ).isUsable(now),
      isFalse,
    );
    expect(
      LocationSample(
        position: const LatLng(48.8566, -181),
        timestamp: now,
        accuracyMeters: 5,
      ).isUsable(now),
      isFalse,
    );
    expect(sample(age: const Duration(seconds: -6)).isUsable(now), isFalse);
  });

  test('accepte exactement les seuils de fraîcheur et de précision', () {
    expect(
      sample(accuracy: 45, age: const Duration(seconds: 20)).isUsable(now),
      isTrue,
    );
  });
}
