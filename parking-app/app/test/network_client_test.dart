import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parking_app/services/network_client.dart';

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      200,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _AbortAwareClient extends http.BaseClient {
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    await abortable.abortTrigger!;
    aborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  final uri = Uri.parse('https://example.test/data');

  test('transforme un dépassement de délai en erreur typée', () async {
    final client = NetworkClient(
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return http.Response('{}', 200);
      }),
      timeout: const Duration(milliseconds: 5),
    );

    await expectLater(client.get(uri), throwsA(isA<NetworkTimeoutException>()));
  });

  test('annule réellement la requête sous-jacente au timeout', () async {
    final transport = _AbortAwareClient();
    final client = NetworkClient(
      client: transport,
      timeout: const Duration(milliseconds: 5),
    );

    await expectLater(client.get(uri), throwsA(isA<NetworkTimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(transport.aborted, isTrue);
  });

  test('distingue statut HTTP et payload JSON invalide', () async {
    final client = NetworkClient(
      client: MockClient((_) async {
        return http.Response('indisponible', 503);
      }),
    );
    final response = await client.get(uri);

    expect(
      () => client.requireSuccess(response, uri),
      throwsA(
        isA<NetworkHttpException>().having(
          (error) => error.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
    expect(
      () => client.decodeJson(response, uri),
      throwsA(isA<NetworkPayloadException>()),
    );
  });

  test(
    'ne ferme pas un client injecté mais interdit sa réutilisation',
    () async {
      final injected = _TrackingClient();
      final client = NetworkClient(client: injected);
      expect(client.ownsClient, isFalse);

      client.close();

      expect(injected.closed, isFalse);
      await expectLater(
        client.get(uri),
        throwsA(isA<NetworkClientClosedException>()),
      );
    },
  );

  test('refuse un endpoint non HTTP', () {
    expect(
      () => parseHttpEndpoint('not-an-url', configName: 'TEST_URL'),
      throwsA(isA<NetworkConfigurationException>()),
    );
  });

  test('exige HTTPS hors environnement local', () {
    expect(
      () =>
          parseHttpEndpoint('http://example.test/data', configName: 'TEST_URL'),
      throwsA(isA<NetworkConfigurationException>()),
    );
    expect(
      parseHttpEndpoint(
        'http://127.0.0.1:8080/data',
        configName: 'TEST_URL',
      ).host,
      '127.0.0.1',
    );
    for (final hostileHost in const [
      'http://127.attacker.example/data',
      'http://127.0.0.1.attacker.example/data',
      'http://127.999.0.1/data',
    ]) {
      expect(
        () => parseHttpEndpoint(hostileHost, configName: 'TEST_URL'),
        throwsA(isA<NetworkConfigurationException>()),
      );
    }
  });
}
