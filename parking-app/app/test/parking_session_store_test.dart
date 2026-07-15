import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/parking_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime(2026, 7, 15, 12);
  const position = LatLng(48.8566, 2.3522);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('sauvegarde, recharge puis efface la session locale', () async {
    final store = SharedPreferencesParkingSessionStore(clock: () => now);

    await store.save(position, now, sharedWithCommunity: true);
    final restored = await store.load();

    expect(restored?.position, const LatLng(48.857, 2.352));
    expect(restored?.parkedAt, now);
    expect(restored?.sharedWithCommunity, isTrue);
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('supprime une session trop ancienne', () async {
    final store = SharedPreferencesParkingSessionStore(clock: () => now);
    await store.save(position, now.subtract(const Duration(hours: 25)));

    expect(await store.load(), isNull);
  });

  test('refuse une position invalide', () async {
    final store = SharedPreferencesParkingSessionStore(clock: () => now);

    await expectLater(
      store.save(const LatLng(120, 2), now),
      throwsArgumentError,
    );
  });

  test('supprime une préférence corrompue sans lever d erreur', () async {
    SharedPreferences.setMockInitialValues({
      'active_parking_session_v1': '{json-invalide',
    });
    final store = SharedPreferencesParkingSessionStore(clock: () => now);

    expect(await store.load(), isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('active_parking_session_v1'), isFalse);
  });

  test('refuse une session datée trop loin dans le futur', () async {
    final store = SharedPreferencesParkingSessionStore(clock: () => now);
    await store.save(position, now.add(const Duration(minutes: 6)));

    expect(await store.load(), isNull);
  });
}
