import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Base commune des erreurs réseau exposées par les services ParkRadar.
///
/// Les écrans peuvent rester tolérants (liste vide / `null`) tandis que les
/// appels `...OrThrow` conservent une cause exploitable par la télémétrie et
/// les tests.
sealed class NetworkException implements Exception {
  const NetworkException(this.message, {required this.uri, this.cause});

  final String message;
  final Uri uri;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message ($uri)';
}

final class NetworkConfigurationException extends NetworkException {
  const NetworkConfigurationException(
    super.message, {
    required super.uri,
    super.cause,
  });
}

final class NetworkTimeoutException extends NetworkException {
  const NetworkTimeoutException(
    super.message, {
    required super.uri,
    required this.timeout,
    super.cause,
  });

  final Duration timeout;
}

final class NetworkTransportException extends NetworkException {
  const NetworkTransportException(
    super.message, {
    required super.uri,
    super.cause,
  });
}

final class NetworkHttpException extends NetworkException {
  const NetworkHttpException(
    super.message, {
    required super.uri,
    required this.statusCode,
    this.responseExcerpt,
  });

  final int statusCode;
  final String? responseExcerpt;
}

final class NetworkPayloadException extends NetworkException {
  const NetworkPayloadException(
    super.message, {
    required super.uri,
    super.cause,
  });
}

final class NetworkClientClosedException extends NetworkException {
  const NetworkClientClosedException(super.message, {required super.uri});
}

/// Petit adaptateur autour de `package:http` : timeout uniforme, erreurs
/// typées, décodage défensif et ownership explicite du client.
class NetworkClient {
  NetworkClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxGetRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 400),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// Nouvelles tentatives sur GET uniquement (idempotent) : timeout,
  /// erreur de transport ou 5xx. Les POST ne sont jamais rejoués — un
  /// signalement dupliqué serait pire qu'un signalement perdu.
  final int maxGetRetries;
  final Duration retryBaseDelay;
  bool _closed = false;

  bool get ownsClient => _ownsClient;
  bool get isClosed => _closed;

  Future<http.Response> get(Uri uri, {Map<String, String>? headers}) async {
    var attempt = 0;
    while (true) {
      final delayBeforeRetry = retryBaseDelay * (1 << attempt);
      try {
        final response = await _execute('GET', uri, headers: headers);
        if (response.statusCode >= 500 && attempt < maxGetRetries) {
          attempt++;
          await Future<void>.delayed(delayBeforeRetry);
          continue;
        }
        return response;
      } on NetworkTimeoutException {
        if (attempt >= maxGetRetries) rethrow;
        attempt++;
        await Future<void>.delayed(delayBeforeRetry);
      } on NetworkTransportException {
        if (attempt >= maxGetRetries) rethrow;
        attempt++;
        await Future<void>.delayed(delayBeforeRetry);
      }
    }
  }

  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _execute('POST', uri, headers: headers, body: body, encoding: encoding);

  Future<http.Response> _execute(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    if (_closed) {
      throw NetworkClientClosedException(
        'Le client réseau est déjà fermé',
        uri: uri,
      );
    }
    final abort = Completer<void>();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    );
    if (headers != null) request.headers.addAll(headers);
    if (encoding != null) request.encoding = encoding;
    if (body is String) {
      request.body = body;
    } else if (body is List<int>) {
      request.bodyBytes = body;
    } else if (body is Map) {
      request.bodyFields = {
        for (final entry in body.entries) '${entry.key}': '${entry.value}',
      };
    } else if (body != null) {
      request.body = '$body';
    }
    try {
      final streamed = await _client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException catch (error) {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
      throw NetworkTimeoutException(
        'La requête a dépassé ${timeout.inSeconds} s',
        uri: uri,
        timeout: timeout,
        cause: error,
      );
    } on http.RequestAbortedException catch (error) {
      if (timedOut) {
        throw NetworkTimeoutException(
          'La requête a dépassé ${timeout.inSeconds} s',
          uri: uri,
          timeout: timeout,
          cause: error,
        );
      }
      throw NetworkTransportException(
        'La requête a été interrompue',
        uri: uri,
        cause: error,
      );
    } on NetworkException {
      rethrow;
    } catch (error) {
      throw NetworkTransportException(
        'Impossible de joindre le service distant',
        uri: uri,
        cause: error,
      );
    } finally {
      timer.cancel();
    }
  }

  void requireSuccess(
    http.Response response,
    Uri uri, {
    Set<int>? acceptedStatusCodes,
  }) {
    final accepted =
        acceptedStatusCodes?.contains(response.statusCode) ??
        (response.statusCode >= 200 && response.statusCode < 300);
    if (accepted) return;
    final compactBody = response.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    throw NetworkHttpException(
      'Réponse HTTP ${response.statusCode}',
      uri: uri,
      statusCode: response.statusCode,
      responseExcerpt: compactBody.isEmpty
          ? null
          : compactBody.length <= 240
          ? compactBody
          : compactBody.substring(0, 240),
    );
  }

  dynamic decodeJson(http.Response response, Uri uri) {
    try {
      String body;
      try {
        // JSON est normalement UTF-8, même si certains mocks/proxys omettent
        // le charset. Le repli respecte alors l'encodage choisi par `http`.
        body = utf8.decode(response.bodyBytes);
      } on FormatException {
        body = response.body;
      }
      return jsonDecode(body);
    } catch (error) {
      throw NetworkPayloadException(
        'Réponse JSON invalide',
        uri: uri,
        cause: error,
      );
    }
  }

  Map<String, dynamic> decodeObject(http.Response response, Uri uri) {
    final decoded = decodeJson(response, uri);
    if (decoded is! Map) {
      throw NetworkPayloadException('Un objet JSON était attendu', uri: uri);
    }
    try {
      return decoded.cast<String, dynamic>();
    } catch (error) {
      throw NetworkPayloadException(
        'Les clés de la réponse JSON sont invalides',
        uri: uri,
        cause: error,
      );
    }
  }

  List<dynamic> decodeList(http.Response response, Uri uri) {
    final decoded = decodeJson(response, uri);
    if (decoded is! List) {
      throw NetworkPayloadException('Une liste JSON était attendue', uri: uri);
    }
    return decoded;
  }

  /// Ferme uniquement le client créé par cet adaptateur. Un client injecté
  /// reste la propriété de l'appelant, mais l'adaptateur ne l'utilise plus.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }
}

Uri parseHttpEndpoint(String raw, {required String configName}) {
  final uri = Uri.tryParse(raw.trim());
  final hasHttpScheme =
      uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
  final host = uri?.host.toLowerCase() ?? '';
  final isLoopback =
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == '::1' ||
      _isIpv4Loopback(host);
  final isSecure =
      uri?.scheme == 'https' || (uri?.scheme == 'http' && isLoopback);
  if (!hasHttpScheme || host.isEmpty || !isSecure) {
    throw NetworkConfigurationException(
      'Endpoint $configName invalide ou non sécurisé',
      uri: uri ?? Uri(),
    );
  }
  return uri;
}

bool _isIpv4Loopback(String host) {
  final parts = host.split('.');
  if (parts.length != 4 || parts.first != '127') return false;
  return parts.every((part) {
    if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
    final value = int.tryParse(part);
    return value != null && value >= 0 && value <= 255;
  });
}
