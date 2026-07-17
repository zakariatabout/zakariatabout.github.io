import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/services/ttl_cache.dart';

void main() {
  test('restitue une valeur fraîche et expire après le TTL', () {
    var now = DateTime.utc(2026, 7, 16, 10);
    final cache = TtlCache<String, int>(
      ttl: const Duration(minutes: 10),
      clock: () => now,
    );
    cache.set('a', 1);
    expect(cache.get('a'), 1);

    now = now.add(const Duration(minutes: 11));
    expect(cache.get('a'), isNull);
    expect(cache.length, 0);
  });

  test('évince la plus ancienne entrée au-delà de maxEntries', () {
    final cache = TtlCache<String, int>(
      ttl: const Duration(hours: 1),
      maxEntries: 2,
      clock: () => DateTime.utc(2026, 7, 16),
    );
    cache.set('a', 1);
    cache.set('b', 2);
    cache.set('c', 3);
    expect(cache.get('a'), isNull);
    expect(cache.get('b'), 2);
    expect(cache.get('c'), 3);
  });

  test('un accès rafraîchit la position LRU sans prolonger le TTL', () {
    var now = DateTime.utc(2026, 7, 16, 10);
    final cache = TtlCache<String, int>(
      ttl: const Duration(minutes: 10),
      maxEntries: 2,
      clock: () => now,
    );
    cache.set('a', 1);
    cache.set('b', 2);
    cache.get('a'); // « a » redevient le plus récent
    cache.set('c', 3); // évince « b »
    expect(cache.get('b'), isNull);
    expect(cache.get('a'), 1);

    // Le TTL court toujours depuis le stockage initial.
    now = now.add(const Duration(minutes: 11));
    expect(cache.get('a'), isNull);
  });
}
