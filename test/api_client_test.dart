import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  int calls = 0;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls++;
    seen.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, int status, {Map<String, List<String>>? headers}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...?headers,
      },
    );

void main() {
  late _FakeAdapter adapter;

  ApiClient build(
    Future<ResponseBody> Function(RequestOptions) handler, {
    bool retry = true,
    void Function(AppFailure)? onFailure,
    Future<String?> Function()? getToken,
  }) {
    adapter = _FakeAdapter(handler);
    final dio = DioFactory.create(
      baseUrl: 'https://api.test',
      retryDelay: Duration.zero,
      enableRetry: retry,
      getToken: getToken,
    );
    dio.httpClientAdapter = adapter;
    return ApiClient(dio, onFailure: onFailure);
  }

  test('2xx + parser → Success', () async {
    final api = build((_) async => _json({'name': 'Tushar'}, 200));
    final r = await api.get<String>(
      '/me',
      parser: (j) => (j as Map<String, dynamic>)['name'] as String,
    );
    expect(r, const Success<String>('Tushar'));
  });

  test('404 JSON → NotFoundFailure with server correlation id', () async {
    final api = build(
      (_) async => _json(
        {'message': 'User missing'},
        404,
        headers: {'x-correlation-id': ['srv-1']},
      ),
    );
    final r = await api.get<Map<String, dynamic>>('/users/1');
    final f = r.failureOrNull;
    expect(f, isA<NotFoundFailure>());
    expect(f!.correlationId, 'srv-1');
    expect(f.message, 'User missing');
  });

  test('NestJS validation error → ValidationFailure', () async {
    final api = build(
      (_) async => _json({
        'statusCode': 400,
        'message': ['email must be an email'],
        'error': 'Bad Request',
      }, 400),
    );
    final r = await api.post<Map<String, dynamic>>('/signup', body: {});
    expect(r.failureOrNull, isA<ValidationFailure>());
    expect(r.failureOrNull!.userMessage, 'email must be an email');
  });

  test('GET retries once on 503 and succeeds', () async {
    var n = 0;
    final api = build(
      (_) async =>
          n++ == 0 ? _json({'message': 'down'}, 503) : _json({'ok': true}, 200),
    );
    final r = await api.get<Map<String, dynamic>>('/x');
    expect(r.isSuccess, isTrue);
    expect(adapter.calls, 2);
    // Same correlation id across the retry → one trace on the server.
    expect(
      adapter.seen[0].headers['x-correlation-id'],
      adapter.seen[1].headers['x-correlation-id'],
    );
  });

  test('POST is never retried', () async {
    final api = build((_) async => _json({'message': 'down'}, 503));
    final r = await api.post<Map<String, dynamic>>('/pay', body: {});
    expect(r.failureOrNull, isA<ServerFailure>());
    expect(adapter.calls, 1);
  });

  test('GET gives up after maxRetries and returns a failure', () async {
    final api = build((_) async => _json({'message': 'down'}, 503));
    final r = await api.get<Map<String, dynamic>>('/x');
    expect(r.failureOrNull, isA<ServerFailure>());
    expect(adapter.calls, 2); // 1 attempt + 1 retry
  });

  test('connection error → NetworkFailure carrying the sent correlation id', () async {
    final api = build(
      (o) async => throw DioException(
        requestOptions: o,
        type: DioExceptionType.connectionError,
      ),
      retry: false,
    );
    final r = await api.get<Map<String, dynamic>>('/x');
    expect(r.failureOrNull, isA<NetworkFailure>());
    expect(r.failureOrNull!.correlationId, isNotNull);
  });

  test('any parser error → ParsingFailure', () async {
    final api = build((_) async => _json({'a': 1}, 200));
    final r = await api.get<String>(
      '/x',
      parser: (j) => (j as Map<String, dynamic>)['missing'] as String,
    );
    expect(r.failureOrNull, isA<ParsingFailure>());

    final r2 = await api.get<String>('/x', parser: (_) => throw StateError('x'));
    expect(r2.failureOrNull, isA<ParsingFailure>());
  });

  test('wrong raw type → ParsingFailure instead of a thrown cast error', () async {
    final api = build((_) async => _json({'a': 1}, 200));
    final r = await api.get<List<dynamic>>('/x');
    expect(r.failureOrNull, isA<ParsingFailure>());
  });

  test('onFailure hook fires, and a throwing hook cannot break Result', () async {
    var hits = 0;
    final api = build(
      (_) async => _json({'message': 'x'}, 500),
      retry: false,
      onFailure: (_) {
        hits++;
        throw StateError('hook');
      },
    );
    final r = await api.get<Map<String, dynamic>>('/x');
    expect(r.isFailure, isTrue);
    expect(hits, 1);
  });

  test('bearer token is attached but never overrides explicit Authorization', () async {
    final api = build(
      (_) async => _json({'ok': true}, 200),
      getToken: () async => 'tok',
    );
    await api.get<Map<String, dynamic>>('/a');
    expect(adapter.seen.last.headers['Authorization'], 'Bearer tok');

    await api.get<Map<String, dynamic>>(
      '/b',
      headers: {'Authorization': 'Bearer refresh'},
    );
    expect(adapter.seen.last.headers['Authorization'], 'Bearer refresh');
  });

  test('a failing token provider does not break the request', () async {
    final api = build(
      (_) async => _json({'ok': true}, 200),
      getToken: () async => throw StateError('keystore'),
    );
    final r = await api.get<Map<String, dynamic>>('/a');
    expect(r.isSuccess, isTrue);
  });
}
