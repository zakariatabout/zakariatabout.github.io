import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/paris_parking_service.dart';

const paris = LatLng(48.8566, 2.3522);
const ailleurs = LatLng(43.2965, 5.3698); // Marseille

http.Client mockReturning(Object json) {
  return MockClient((req) async => http.Response(jsonEncode(json), 200,
      headers: {'content-type': 'application/json'}));
}

Map<String, dynamic> lineFeature(String regpri) => {
      'regpri': regpri,
      'geo_shape': {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [2.3522, 48.8566],
            [2.3530, 48.8566],
          ],
        },
      },
    };

void main() {
  test('hors de Paris : aucun appel, liste vide', () async {
    final service = ParisParkingService(
        client: mockReturning({'results': [lineFeature('Payant')]}));
    expect(await service.fetchSpots(ailleurs), isEmpty);
  });

  test('classe correctement les régimes', () async {
    final service = ParisParkingService(
      client: mockReturning({
        'results': [
          lineFeature('Payant rotatif'),
          lineFeature('Zone résidentielle'),
          lineFeature('Gratuit'),
          lineFeature('Deux roues motorisées'),
          lineFeature('Livraison'),
          lineFeature('GIG-GIC'),
        ],
      }),
    );
    final spots = await service.fetchSpots(paris);
    final regimes = spots.map((s) => s.regime).toList();
    expect(regimes, contains(ParkingRegime.payant));
    expect(regimes, contains(ParkingRegime.resident));
    expect(regimes, contains(ParkingRegime.gratuit));
    expect(regimes, contains(ParkingRegime.moto));
    expect(regimes, contains(ParkingRegime.livraison));
    expect(regimes, contains(ParkingRegime.handicap));
  });

  test('gère MultiLineString', () async {
    final service = ParisParkingService(
      client: mockReturning({
        'results': [
          {
            'regpri': 'Payant',
            'geo_shape': {
              'type': 'Feature',
              'geometry': {
                'type': 'MultiLineString',
                'coordinates': [
                  [
                    [2.35, 48.85],
                    [2.351, 48.85],
                  ],
                  [
                    [2.352, 48.856],
                    [2.353, 48.856],
                  ],
                ],
              },
            },
          },
        ],
      }),
    );
    final spots = await service.fetchSpots(paris);
    expect(spots.length, 2);
  });

  test('champ de régime alternatif (typsta) reconnu', () async {
    final service = ParisParkingService(
      client: mockReturning({
        'results': [
          {
            'typsta': 'Gratuit',
            'geo_shape': {
              'type': 'LineString',
              'coordinates': [
                [2.3522, 48.8566],
                [2.3530, 48.8566],
              ],
            },
          },
        ],
      }),
    );
    final spots = await service.fetchSpots(paris);
    expect(spots.single.regime, ParkingRegime.gratuit);
  });

  test('réponse invalide : dégradation propre (liste vide)', () async {
    final service = ParisParkingService(
        client: mockReturning({'results': 'oops'}));
    expect(await service.fetchSpots(paris), isEmpty);
  });

  test('erreur HTTP : liste vide, pas d exception', () async {
    final service = ParisParkingService(
      client: MockClient((req) async => http.Response('nope', 500)),
    );
    expect(await service.fetchSpots(paris), isEmpty);
  });

  test('isInParis borne correctement', () {
    expect(ParisParkingService.isInParis(paris), isTrue);
    expect(ParisParkingService.isInParis(ailleurs), isFalse);
  });
}
