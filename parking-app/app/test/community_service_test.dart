import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/community_service.dart';

const center = LatLng(48.8566, 2.3522);
final now = DateTime.utc(2026, 7, 15, 12);

CommunityService remoteService(
  http.Client client, {
  Duration eventTtl = const Duration(minutes: 15),
  Duration pollInterval = const Duration(milliseconds: 5),
  bool legacyFallback = false,
}) {
  return CommunityService(
    client: client,
    supabaseUrl: 'https://project.supabase.co',
    supabaseAnonKey: 'publishable-test-key',
    eventTtl: eventTtl,
    pollInterval: pollInterval,
    legacyFallback: legacyFallback,
    clock: () => now,
    clientTokenProvider: () async => List.filled(32, 'x').join(),
  );
}

void main() {
  test('signale via l Edge Function avec coordonnées quantifiées', () async {
    late Uri requestedUri;
    late Map<String, dynamic> requestedBody;
    final service = remoteService(
      MockClient((request) async {
        requestedUri = request.url;
        requestedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('true', 200);
      }),
    );

    expect(
      await service.report('freed', const LatLng(48.8566123, 2.3522456)),
      isTrue,
    );
    expect(requestedUri.path, '/functions/v1/report-parking-event');
    expect(requestedBody['lat'], 48.857);
    expect(requestedBody['lon'], 2.352);
    expect(requestedBody['client_token'], hasLength(32));
  });

  test('refuse un type invalide sans appel réseau', () async {
    var calls = 0;
    final service = remoteService(
      MockClient((_) async {
        calls++;
        return http.Response('true', 200);
      }),
    );

    expect(await service.report('maybe', center), isFalse);
    expect(calls, 0);
    await expectLater(
      service.reportOrThrow('maybe', center),
      throwsA(isA<CommunityValidationException>()),
    );
  });

  test('refuse un signalement hors de la couverture Paris', () async {
    var calls = 0;
    final service = remoteService(
      MockClient((_) async {
        calls++;
        return http.Response('true', 200);
      }),
    );

    expect(await service.report('parked', const LatLng(45.76, 4.84)), isFalse);
    expect(calls, 0);
  });

  test('repli compatible vers la table si l Edge manque', () async {
    final paths = <String>[];
    final service = remoteService(
      MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.contains('/functions/')) {
          return http.Response('{"code":"PGRST202"}', 404);
        }
        return http.Response('', 201);
      }),
      legacyFallback: true,
    );

    expect(await service.report('parked', center), isTrue);
    expect(paths, [
      '/functions/v1/report-parking-event',
      '/rest/v1/parking_events',
    ]);
  });

  test('échoue fermé par défaut si l Edge sécurisée manque', () async {
    final paths = <String>[];
    final service = remoteService(
      MockClient((request) async {
        paths.add(request.url.path);
        return http.Response('{"code":"PGRST202"}', 404);
      }),
    );

    expect(await service.report('parked', center), isFalse);
    expect(paths, ['/functions/v1/report-parking-event']);
    service.close();
  });

  test('applique TTL, rayon et agrégat côté client', () async {
    late Map<String, dynamic> requestBody;
    final service = remoteService(
      MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode([
            {
              'event_type': 'freed',
              'lat': center.latitude,
              'lon': center.longitude,
              'created_at': now
                  .subtract(const Duration(minutes: 2))
                  .toIso8601String(),
              'report_count': 3,
            },
            {
              'event_type': 'parked',
              'lat': center.latitude,
              'lon': center.longitude,
              'created_at': now
                  .subtract(const Duration(minutes: 20))
                  .toIso8601String(),
              'report_count': 1,
            },
            {
              'event_type': 'freed',
              'lat': 48.88,
              'lon': 2.38,
              'created_at': now.toIso8601String(),
              'report_count': 8,
            },
          ]),
          200,
        );
      }),
      eventTtl: const Duration(minutes: 10),
    );

    final events = await service.recentEventsNearOrThrow(
      center,
      radiusMeters: 600,
      maxAge: const Duration(minutes: 30),
    );

    expect(requestBody['p_max_age_seconds'], 600);
    expect(events, hasLength(1));
    expect(events.single.reportCount, 3);
    expect(events.single.isFreed, isTrue);
  });

  test('le polling ne chevauche pas et s arrête à l annulation', () async {
    var calls = 0;
    var inFlight = 0;
    var maxInFlight = 0;
    final service = CommunityService(
      client: MockClient((_) async {
        calls++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 8));
        inFlight--;
        return http.Response('[]', 200);
      }),
      supabaseUrl: 'https://project.supabase.co',
      supabaseAnonKey: 'publishable-test-key',
      pollInterval: const Duration(milliseconds: 2),
      clock: () => now,
      clientTokenProvider: () async => List.filled(32, 'x').join(),
    );
    final subscription = service.watchRecentEventsNear(center).listen((_) {});

    await Future<void>.delayed(const Duration(milliseconds: 24));
    expect(calls, greaterThanOrEqualTo(2));
    expect(maxInFlight, 1);
    await subscription.cancel();
    final callsAtCancel = calls;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(calls, callsAtCancel);
    service.close();
  });
}
