import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/network_client.dart';
import 'package:parking_app/services/overpass_service.dart';

const center = LatLng(48.8566, 2.3522);

String overpassPayload() => jsonEncode({
  'elements': [
    {
      'id': 42,
      'tags': {
        'name': 'Rue de Test',
        'highway': 'residential',
        'oneway': 'yes',
        'parking:lane:left': 'parallel',
        'parking:lane:right': 'no_parking',
      },
      'geometry': [
        {'lat': 48.8565, 'lon': 2.3521},
        {'lat': 48.8567, 'lon': 2.3524},
      ],
    },
  ],
});

void main() {
  test(
    'bascule sur le secours après une panne du fournisseur principal',
    () async {
      final hosts = <String>[];
      final service = OverpassService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host == 'primary.test') {
            return http.Response('indisponible', 504);
          }
          return http.Response(overpassPayload(), 200);
        }),
        endpoint: 'https://primary.test/api/interpreter',
        fallbackEndpoint: 'https://backup.test/api/interpreter',
      );

      final segments = await service.fetchSegments(center);

      expect(hosts, ['primary.test', 'backup.test']);
      expect(segments, hasLength(1));
      expect(segments.single.name, 'Rue de Test');
      expect(segments.single.isOneWay, isTrue);
      expect(segments.single.parkingSides, 1);
      expect(segments.single.points, hasLength(2));
      service.close();
    },
  );

  test('un endpoint injecté ne contacte aucun secours implicite', () async {
    var calls = 0;
    final service = OverpassService(
      client: MockClient((_) async {
        calls++;
        return http.Response('indisponible', 503);
      }),
      endpoint: 'https://private.test/api/interpreter',
    );

    await expectLater(
      service.fetchSegments(center),
      throwsA(isA<NetworkHttpException>()),
    );
    expect(calls, 1);
    service.close();
  });

  test('refuse un rayon abusif avant tout appel réseau', () async {
    var calls = 0;
    final service = OverpassService(
      client: MockClient((_) async {
        calls++;
        return http.Response(overpassPayload(), 200);
      }),
      endpoint: 'https://private.test/api/interpreter',
    );

    await expectLater(
      service.fetchSegments(center, radiusMeters: 10),
      throwsArgumentError,
    );
    expect(calls, 0);
    service.close();
  });
}
