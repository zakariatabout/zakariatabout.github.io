import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/network_client.dart';
import 'package:parking_app/services/routing_service.dart';

void main() {
  const waypoints = [LatLng(48.8566, 2.3522), LatLng(48.8570, 2.3540)];

  test('demande et parse les étapes OSRM sans casser DrivingRoute', () async {
    late Uri requestedUri;
    final service = RoutingService(
      endpoint: 'https://routing.example.test/route/v1/driving',
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode({
            'routes': [
              {
                'duration': 90,
                'distance': 420,
                'geometry': {
                  'coordinates': [
                    [2.3522, 48.8566],
                    [2.3540, 48.8570],
                  ],
                },
                'legs': [
                  {
                    'steps': [
                      {
                        'duration': 20,
                        'distance': 80,
                        'name': 'Rue de Rivoli',
                        'maneuver': {
                          'type': 'turn',
                          'modifier': 'right',
                          'location': [2.3522, 48.8566],
                        },
                      },
                      {
                        'duration': 70,
                        'distance': 340,
                        'name': '',
                        'maneuver': {
                          'type': 'arrive',
                          'location': [2.3540, 48.8570],
                        },
                      },
                    ],
                  },
                ],
              },
            ],
          }),
          200,
        );
      }),
    );

    final route = await service.routeOrThrow(waypoints);

    expect(requestedUri.host, 'routing.example.test');
    expect(requestedUri.queryParameters['steps'], 'true');
    expect(route, isNotNull);
    expect(route!.steps, hasLength(2));
    expect(route.steps.first.maneuver, 'turn:right');
    expect(route.steps.first.instruction, contains('Rue de Rivoli'));
    expect(route.steps.last.instruction, 'Vous êtes arrivé');
    expect(route.distanceMeters, 420);
  });

  test('route reste tolérante mais routeOrThrow expose le statut', () async {
    final service = RoutingService(
      client: MockClient((_) async => http.Response('down', 503)),
    );

    expect(await service.route(waypoints), isNull);
    await expectLater(
      service.routeOrThrow(waypoints),
      throwsA(isA<NetworkHttpException>()),
    );
  });

  test('refuse une géométrie trop courte pour guider', () async {
    final service = RoutingService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'routes': [
              {
                'duration': 10,
                'distance': 40,
                'geometry': {
                  'coordinates': [
                    [2.3522, 48.8566],
                  ],
                },
                'legs': const [],
              },
            ],
          }),
          200,
        ),
      ),
    );

    await expectLater(
      service.routeOrThrow(waypoints),
      throwsA(isA<NetworkPayloadException>()),
    );
    expect(await service.route(waypoints), isNull);
  });
}
