import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parking_app/services/network_client.dart';

void main() {
  final uri = Uri.parse('https://example.org/data');

  test('un GET réessaie sur 5xx puis réussit', () async {
    var calls = 0;
    final client = NetworkClient(
      client: MockClient((request) async {
        calls++;
        return calls < 3
            ? http.Response('boom', 500)
            : http.Response('ok', 200);
      }),
      maxGetRetries: 2,
      retryBaseDelay: Duration.zero,
    );
    final response = await client.get(uri);
    expect(response.statusCode, 200);
    expect(calls, 3);
  });

  test('le 5xx persistant est rendu après épuisement des tentatives',
      () async {
    var calls = 0;
    final client = NetworkClient(
      client: MockClient((request) async {
        calls++;
        return http.Response('boom', 503);
      }),
      maxGetRetries: 2,
      retryBaseDelay: Duration.zero,
    );
    final response = await client.get(uri);
    expect(response.statusCode, 503);
    expect(calls, 3);
  });

  test('une erreur de transport est réessayée', () async {
    var calls = 0;
    final client = NetworkClient(
      client: MockClient((request) async {
        calls++;
        if (calls == 1) throw http.ClientException('réseau coupé');
        return http.Response('ok', 200);
      }),
      maxGetRetries: 2,
      retryBaseDelay: Duration.zero,
    );
    final response = await client.get(uri);
    expect(response.statusCode, 200);
    expect(calls, 2);
  });

  test('une erreur 4xx n est jamais réessayée', () async {
    var calls = 0;
    final client = NetworkClient(
      client: MockClient((request) async {
        calls++;
        return http.Response('interdit', 403);
      }),
      maxGetRetries: 2,
      retryBaseDelay: Duration.zero,
    );
    final response = await client.get(uri);
    expect(response.statusCode, 403);
    expect(calls, 1);
  });

  test('un POST n est jamais rejoué, même sur 5xx', () async {
    var calls = 0;
    final client = NetworkClient(
      client: MockClient((request) async {
        calls++;
        return http.Response('boom', 500);
      }),
      maxGetRetries: 2,
      retryBaseDelay: Duration.zero,
    );
    final response = await client.post(uri, body: '{}');
    expect(response.statusCode, 500);
    expect(calls, 1);
  });
}
