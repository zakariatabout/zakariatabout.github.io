import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parking_app/services/geocoding_service.dart';

void main() {
  test(
    'recherche adresses et lieux avec le contrat IGN Géoplateforme',
    () async {
      late Uri requestedUri;
      final service = GeocodingService(
        endpoint: 'https://data.geopf.fr/geocodage/search',
        client: MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            jsonEncode({
              'type': 'FeatureCollection',
              'features': [
                {
                  'type': 'Feature',
                  'geometry': {
                    'type': 'Point',
                    'coordinates': [2.29424, 48.858264],
                  },
                  'properties': {
                    'toponym': 'Tour Eiffel',
                    'postcode': ['75007'],
                    'city': ['Paris'],
                    '_type': 'poi',
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final results = await service.search('Tour Eiffel');

      expect(requestedUri.queryParameters['q'], 'Tour Eiffel');
      expect(requestedUri.queryParameters['index'], 'address,poi');
      expect(requestedUri.queryParameters['limit'], '6');
      expect(requestedUri.queryParameters['citycode'], '75056');
      expect(results.single.displayName, 'Tour Eiffel, 75007 Paris');
      expect(results.single.location.longitude, 2.29424);
    },
  );

  test('parse encore l ancien endpoint IGN completion injecté', () async {
    final service = GeocodingService(
      endpoint: 'https://data.geopf.fr/geocodage/completion/',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 'OK',
            'results': [
              {
                'fulltext': '10 rue de Rivoli 75004 Paris',
                'x': 2.3572,
                'y': 48.8555,
              },
            ],
          }),
          200,
        ),
      ),
    );

    final results = await service.search('rue de Rivoli');

    expect(results.single.displayName, contains('Rivoli'));
  });

  test('parse encore Nominatim uniquement avec endpoint explicite', () async {
    late Uri requestedUri;
    final service = GeocodingService(
      endpoint: 'https://nominatim.example.test/search',
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode([
            {
              'display_name': 'Paris, France',
              'lat': '48.8566',
              'lon': '2.3522',
            },
          ]),
          200,
        );
      }),
    );

    final results = await service.search('Paris');

    expect(requestedUri.queryParameters['q'], 'Paris');
    expect(requestedUri.queryParameters, isNot(contains('text')));
    expect(results.single.displayName, 'Paris, France');
  });
}
