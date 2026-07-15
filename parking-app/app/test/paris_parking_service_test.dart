import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:parking_app/services/network_client.dart';
import 'package:parking_app/services/paris_parking_service.dart';

const paris = LatLng(48.8566, 2.3522);
const ailleurs = LatLng(43.2965, 5.3698); // Marseille

http.Client mockReturning(Object json) {
  return MockClient(
    (req) async => http.Response(
      jsonEncode(json),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );
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
      client: mockReturning({
        'results': [lineFeature('Payant')],
      }),
    );
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

  test('valeurs réelles du dataset Paris (majuscules)', () async {
    final service = ParisParkingService(
      client: mockReturning({
        'results': [
          lineFeature('2 ROUES'),
          lineFeature('LIVRAISON'),
          lineFeature('PAYANT'),
          lineFeature('TAXI'),
          lineFeature('AUTOCAR'),
        ],
      }),
    );
    final regimes = (await service.fetchSpots(
      paris,
    )).map((s) => s.regime).toList();
    expect(regimes, contains(ParkingRegime.moto)); // « 2 ROUES »
    expect(regimes, contains(ParkingRegime.livraison));
    expect(regimes, contains(ParkingRegime.payant));
    expect(regimes, contains(ParkingRegime.taxi));
    expect(regimes, contains(ParkingRegime.autocar));
    expect(regimes, isNot(contains(ParkingRegime.autre)));
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
      client: mockReturning({'results': 'oops'}),
    );
    expect(await service.fetchSpots(paris), isEmpty);
  });

  test('erreur HTTP : liste vide, pas d exception', () async {
    final service = ParisParkingService(
      client: MockClient((req) async => http.Response('nope', 500)),
    );
    expect(await service.fetchSpots(paris), isEmpty);
  });

  test('charge toutes les pages Paris Data', () async {
    final offsets = <String?>[];
    final service = ParisParkingService(
      client: MockClient((request) async {
        final offset = request.url.queryParameters['offset'];
        offsets.add(offset);
        final results = offset == '0'
            ? [lineFeature('Payant'), lineFeature('Gratuit')]
            : [lineFeature('Résident')];
        return http.Response(
          jsonEncode({'total_count': 3, 'results': results}),
          200,
        );
      }),
    );

    final spots = await service.fetchSpotsOrThrow(paris, limit: 2);

    expect(spots, hasLength(3));
    expect(offsets, ['0', '2']);
  });

  test('conserve voie, capacité et identifiant du référentiel', () async {
    final feature = lineFeature(
      'Payant',
    )..addAll({'id': 42, 'typevoie': 'RUE', 'nomvoie': 'DE TEST', 'placal': 8});
    final service = ParisParkingService(
      client: mockReturning({
        'results': [feature],
      }),
    );

    final spot = (await service.fetchSpotsOrThrow(paris)).single;

    expect(spot.streetName, 'RUE DE TEST');
    expect(spot.capacity, 8);
    expect(spot.capacitySource, ParkingCapacitySource.calculated);
    expect(spot.sourceId, '42');
  });

  test('préfère les places réelles et conserve leur provenance', () async {
    final feature = lineFeature('Payant')..addAll({'plarel': 3, 'placal': 8});
    final service = ParisParkingService(
      client: mockReturning({
        'results': [feature],
      }),
    );

    final spot = (await service.fetchSpotsOrThrow(paris)).single;

    expect(spot.capacity, 3);
    expect(spot.capacitySource, ParkingCapacitySource.actual);
  });

  test('conserve la date métier et le champ source Paris Data', () async {
    final feature = lineFeature('Payant')
      ..addAll({
        'mtlast_edit_date_field': '2025-03-10',
        'datereleve': '2024-12-01',
      });
    final service = ParisParkingService(
      client: mockReturning({
        'results': [feature],
      }),
    );

    final spot = (await service.fetchSpotsOrThrow(paris)).single;

    expect(spot.sourceUpdatedAt, DateTime.utc(2025, 3, 10));
    expect(spot.sourceUpdatedField, 'mtlast_edit_date_field');
  });

  test('les régimes de marché restent inconnus et échouent fermés', () async {
    final mixte = lineFeature('PAYANT')..['regpar'] = 'Mixte Marché';
    final rotatif = lineFeature('PAYANT')..['regpar'] = 'Rotatif Marché';
    final service = ParisParkingService(
      client: mockReturning({
        'results': [mixte, rotatif],
      }),
    );

    final spots = await service.fetchSpotsOrThrow(paris);

    expect(spots.map((spot) => spot.regime), everyElement(ParkingRegime.autre));
    expect(spots.first.rawLabel, contains('Mixte Marché'));
  });

  test('une plage horaire non interprétée reste inconnue', () async {
    final feature = lineFeature('PAYANT')
      ..addAll({'regpar': 'Rotatif', 'plage_hor1_debut': '08:00'});
    final service = ParisParkingService(
      client: mockReturning({
        'results': [feature],
      }),
    );

    final spot = (await service.fetchSpotsOrThrow(paris)).single;

    expect(spot.regime, ParkingRegime.autre);
  });

  test('regpar distingue les vélos des motos sous 2 ROUES', () async {
    final velos = lineFeature('2 ROUES')..['regpar'] = 'Vélos';
    final velib = lineFeature('2 ROUES')..['regpar'] = 'Vélib vélo-cargo';
    final motos = lineFeature('2 ROUES')..['regpar'] = 'Motos payant Mixte';
    final service = ParisParkingService(
      client: mockReturning({
        'results': [velos, velib, motos],
      }),
    );

    final regimes = (await service.fetchSpotsOrThrow(
      paris,
    )).map((spot) => spot.regime).toList();

    expect(regimes, [
      ParkingRegime.velo,
      ParkingRegime.velo,
      ParkingRegime.moto,
    ]);
  });

  test('la variante diagnostique expose l erreur HTTP typée', () async {
    final service = ParisParkingService(
      client: MockClient((_) async => http.Response('nope', 503)),
    );

    await expectLater(
      service.fetchSpotsOrThrow(paris),
      throwsA(
        isA<NetworkHttpException>().having(
          (error) => error.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
  });

  test('isInParis borne correctement', () {
    expect(ParisParkingService.isInParis(paris), isTrue);
    expect(ParisParkingService.isInParis(ailleurs), isFalse);
  });
}
