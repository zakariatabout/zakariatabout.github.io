import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/local_community_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const center = LatLng(48.8566, 2.3522);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('un signalement est relu à proximité', () async {
    final store = LocalCommunityStore();
    expect(await store.report('freed', center), isTrue);
    final events = await store.recentEventsNear(center);
    expect(events, hasLength(1));
    expect(events.single.isFreed, isTrue);
  });

  test('un signalement hors du rayon est exclu', () async {
    final store = LocalCommunityStore();
    await store.report('freed', const LatLng(48.90, 2.40)); // ~6 km
    final events = await store.recentEventsNear(center, radiusMeters: 600);
    expect(events, isEmpty);
  });

  test('plusieurs signalements sont conservés et triés du plus récent', () async {
    final store = LocalCommunityStore();
    await store.report('parked', center);
    await store.report('freed', center);
    final events = await store.recentEventsNear(center);
    expect(events.length, 2);
    expect(events.first.createdAt.isAfter(events.last.createdAt) ||
        events.first.createdAt.isAtSameMomentAs(events.last.createdAt), isTrue);
  });
}
