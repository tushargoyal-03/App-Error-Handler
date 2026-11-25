// ignore_for_file: avoid_print
/// Tests for the **HTTP Server layer** – every status code, body shape,
/// field-error format, and correlation-id flow that ErrorMapper.fromResponse
/// and ApiClient handle.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal Dio adapter for ApiClient integration tests
// ---------------------------------------------------------------------------

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._handler);
  final Future<ResponseBody> Function(RequestOptions) _handler;
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
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(
  Object body,
  int status, {
  Map<String, List<String>>? headers,
}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...?headers,
      },
    );

ResponseBody _rawBody(String text, int status) => ResponseBody.fromString(
      text,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );

ApiClient _buildClient(
  Future<ResponseBody> Function(RequestOptions) handler, {
  void Function(AppFailure)? onFailure,
  bool retry = false,
}) {
  final adapter = _StubAdapter(handler);
  final dio = DioFactory.create(
    baseUrl: 'https://api.test',
    retryDelay: Duration.zero,
    enableRetry: retry,
  );
  dio.httpClientAdapter = adapter;
  return ApiClient(dio, onFailure: onFailure);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // A. ErrorMapper.fromResponse – pure unit tests (no network)
  // =========================================================================

  group('Server – ErrorMapper.fromResponse: HTTP status mapping', () {
    // --- 2xx (guard path, should not normally be called) --------------------
    test('200 with unknown message → fallback message, UnknownFailure', () {
      // fromResponse is only called for errors, so 200 returns UnknownFailure
      final f = ErrorMapper.fromResponse(200, null);
      expect(f, isA<UnknownFailure>());
    });

    // --- 400 ----------------------------------------------------------------
    test('400 plain string message → ServerFailure(400), not Validation', () {
      final f = ErrorMapper.fromResponse(400, {'message': 'Bad request'});
      expect(f, isA<ServerFailure>());
      expect(f.statusCode, 400);
    });

    test('400 with message list → ValidationFailure', () {
      final f = ErrorMapper.fromResponse(400, {
        'statusCode': 400,
        'message': ['email invalid', 'name too short'],
        'error': 'Bad Request',
      });
      expect(f, isA<ValidationFailure>());
      expect(f.message, 'email invalid\nname too short');
      expect(f.statusCode, 400);
    });

    test('400 with fieldErrors map → ValidationFailure with field map', () {
      final f = ErrorMapper.fromResponse(400, {
        'message': 'Invalid',
        'errors': {
          'email': ['must be an email'],
          'phone': 'invalid number',
        },
      });
      expect(f, isA<ValidationFailure>());
      expect((f as ValidationFailure).fieldErrors, {
        'email': ['must be an email'],
        'phone': ['invalid number'],
      });
    });

    // --- 401 ----------------------------------------------------------------
    test('401 → UnauthorizedFailure', () {
      final f = ErrorMapper.fromResponse(401, {'message': 'Token expired'});
      expect(f, isA<UnauthorizedFailure>());
      expect(f.statusCode, 401);
      expect(f.message, 'Token expired');
    });

    // --- 403 ----------------------------------------------------------------
    test('403 → ForbiddenFailure', () {
      final f = ErrorMapper.fromResponse(403, {'message': 'Forbidden'});
      expect(f, isA<ForbiddenFailure>());
      expect(f.statusCode, 403);
    });

    // --- 404 ----------------------------------------------------------------
    test('404 → NotFoundFailure', () {
      final f = ErrorMapper.fromResponse(404, {'message': 'Not found'});
      expect(f, isA<NotFoundFailure>());
      expect(f.statusCode, 404);
    });

    test('404 with nested error object → extracts message', () {
      final f = ErrorMapper.fromResponse(404, {
        'error': {'code': 'USR_404', 'message': 'User gone'},
      });
      expect(f, isA<NotFoundFailure>());
      expect(f.message, 'User gone');
    });

    // --- 409 ----------------------------------------------------------------
    test('409 → ConflictFailure', () {
      final f = ErrorMapper.fromResponse(409, {'message': 'Duplicate'});
      expect(f, isA<ConflictFailure>());
      expect(f.statusCode, 409);
    });

    // --- 422 ----------------------------------------------------------------
    test('422 → ValidationFailure', () {
      final f = ErrorMapper.fromResponse(422, {'message': 'Unprocessable'});
      expect(f, isA<ValidationFailure>());
      expect(f.statusCode, 422);
    });

    test('422 with class-validator list errors', () {
      final f = ErrorMapper.fromResponse(422, {
        'message': 'Validation failed',
        'errors': [
          {
            'property': 'email',
            'constraints': {'isEmail': 'must be email'},
          },
          {
            'property': 'age',
            'constraints': {'min': 'must be >= 18'},
          },
        ],
      });
      expect(f, isA<ValidationFailure>());
      final fe = (f as ValidationFailure).fieldErrors!;
      expect(fe['email'], ['must be email']);
      expect(fe['age'], ['min: must be >= 18'.split(': ').last]);
    });

    // --- 429 ----------------------------------------------------------------
    test('429 → RateLimitedFailure with retryAfter', () {
      final f = ErrorMapper.fromResponse(
        429,
        {'message': 'Too many requests'},
        retryAfter: const Duration(seconds: 30),
      );
      expect(f, isA<RateLimitedFailure>());
      expect((f as RateLimitedFailure).retryAfter, const Duration(seconds: 30));
      expect(f.isRetryable, isTrue);
    });

    test('429 without retryAfter → retryAfter is null', () {
      final f = ErrorMapper.fromResponse(429, '');
      expect((f as RateLimitedFailure).retryAfter, isNull);
    });

    // --- 5xx ----------------------------------------------------------------
    test('500 → ServerFailure with statusCode', () {
      final f = ErrorMapper.fromResponse(500, {'message': 'Internal error'});
      expect(f, isA<ServerFailure>());
      expect(f.statusCode, 500);
      expect(f.isRetryable, isTrue);
    });

    test('502 → ServerFailure (retryable)', () {
      final f = ErrorMapper.fromResponse(502, {'message': 'Bad gateway'});
      expect(f, isA<ServerFailure>());
      expect(f.isRetryable, isTrue);
    });

    test('503 → ServerFailure (retryable)', () {
      final f = ErrorMapper.fromResponse(503, '');
      expect(f, isA<ServerFailure>());
    });

    test('504 → ServerFailure (retryable)', () {
      final f = ErrorMapper.fromResponse(504, '');
      expect(f, isA<ServerFailure>());
      expect(f.isRetryable, isTrue);
    });

    test('418 (unknown 4xx) → ServerFailure with statusCode', () {
      final f = ErrorMapper.fromResponse(418, {'message': "I'm a teapot"});
      expect(f, isA<ServerFailure>());
      expect(f.statusCode, 418);
    });

    // --- Body shapes --------------------------------------------------------
    test('String JSON body is decoded and message extracted', () {
      final f = ErrorMapper.fromResponse(500, '{"message":"boom"}');
      expect(f.message, 'boom');
    });

    test('pre-decoded Map body works directly', () {
      final f = ErrorMapper.fromResponse(500, {'message': 'decoded'});
      expect(f.message, 'decoded');
    });

    test('empty string body → fallback message, no crash', () {
      final f = ErrorMapper.fromResponse(503, '');
      expect(f.message.isNotEmpty, isTrue);
    });

    test('null body → fallback message', () {
      final f = ErrorMapper.fromResponse(503, null);
      expect(f.message.isNotEmpty, isTrue);
    });

    test('short plain-text 4xx body is used as message', () {
      final f = ErrorMapper.fromResponse(400, 'email already exists');
      expect(f.message, 'email already exists');
    });

    test('long plain text body is NOT used as message', () {
      final longText = 'x' * 300;
      final f = ErrorMapper.fromResponse(400, longText);
      expect(f.message, isNot(equals(longText)));
    });

    test('HTML error page is never used as message', () {
      final f = ErrorMapper.fromResponse(404, '<html>nginx 404</html>');
      expect(f.message, isNot(contains('<')));
    });

    test('malformed JSON string → fallback message, no throw', () {
      final f = ErrorMapper.fromResponse(500, '{not json}');
      expect(f.message.isNotEmpty, isTrue);
    });

    test('body with "detail" key (DRF style) is extracted', () {
      final f = ErrorMapper.fromResponse(400, {'detail': 'Permission denied'});
      expect(f.message, 'Permission denied');
    });

    test('body with "title" key (Problem Details RFC 7807) is extracted', () {
      final f = ErrorMapper.fromResponse(
        422,
        {'title': 'Unprocessable Entity', 'status': 422},
      );
      expect(f.message, 'Unprocessable Entity');
    });

    test('body with "reason" key is extracted', () {
      final f = ErrorMapper.fromResponse(503, {'reason': 'Maintenance'});
      expect(f.message, 'Maintenance');
    });

    test('empty "message" key falls through to next key', () {
      final f = ErrorMapper.fromResponse(
        403,
        {'message': '', 'error': 'Forbidden'},
      );
      expect(f.message, 'Forbidden');
    });

    // --- Correlation IDs ----------------------------------------------------
    test('correlationId from header is attached', () {
      final f = ErrorMapper.fromResponse(
        500,
        {'message': 'err'},
        correlationId: 'hdr-123',
      );
      expect(f.correlationId, 'hdr-123');
    });

    test('correlationId from body is used when header is absent', () {
      final f = ErrorMapper.fromResponse(
        500,
        '{"message":"x","correlationId":"body-456"}',
      );
      expect(f.correlationId, 'body-456');
    });

    test('correlation_id snake_case variant is also read from body', () {
      final f = ErrorMapper.fromResponse(
        500,
        {'message': 'x', 'correlation_id': 'snake-789'},
      );
      expect(f.correlationId, 'snake-789');
    });

    test('header correlationId takes precedence over body', () {
      final f = ErrorMapper.fromResponse(
        500,
        {'message': 'x', 'correlationId': 'body-id'},
        correlationId: 'hdr-id',
      );
      expect(f.correlationId, 'hdr-id');
    });

    test('all standard status codes carry correlationId when provided', () {
      for (final code in [400, 401, 403, 404, 409, 422, 429, 500, 502, 503]) {
        final f = ErrorMapper.fromResponse(
          code,
          {'message': 'x'},
          correlationId: 'corr-$code',
        );
        expect(f.correlationId, 'corr-$code', reason: 'status $code');
      }
    });
  });

  // =========================================================================
  // B. ApiClient integration – HTTP verbs + error flows through Dio
  // =========================================================================

  group('Server – ApiClient HTTP verbs and error mapping', () {
    test('GET 200 with parser → Success<T>', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'id': 1, 'name': 'Alice'}, 200),
      );
      final r = await api.get<String>(
        '/users/1',
        parser: (j) => (j as Map<String, dynamic>)['name'] as String,
      );
      expect(r, const Success<String>('Alice'));
      expect(r.isSuccess, isTrue);
      expect(r.dataOrNull, 'Alice');
    });

    test('GET 200 without parser, matching raw type → Success', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'ok': true}, 200),
      );
      final r = await api.get<Map<String, dynamic>>('/ping');
      expect(r.isSuccess, isTrue);
    });

    test('GET 200 without parser, mismatched type → ParsingFailure', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'ok': true}, 200),
      );
      final r = await api.get<List<dynamic>>('/ping');
      expect(r.failureOrNull, isA<ParsingFailure>());
    });

    test('POST 201 → Success', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'created': true}, 201),
      );
      final r = await api.post<Map<String, dynamic>>('/items', body: {'x': 1});
      expect(r.isSuccess, isTrue);
    });

    test('PUT 200 → Success', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'updated': true}, 200),
      );
      final r = await api.put<Map<String, dynamic>>('/items/1', body: {'x': 2});
      expect(r.isSuccess, isTrue);
    });

    test('PATCH 200 → Success', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'patched': true}, 200),
      );
      final r =
          await api.patch<Map<String, dynamic>>('/items/1', body: {'y': 3});
      expect(r.isSuccess, isTrue);
    });

    test('DELETE 200 → Success', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'deleted': true}, 200),
      );
      final r = await api.delete<Map<String, dynamic>>('/items/1');
      expect(r.isSuccess, isTrue);
    });

    // --- HTTP error codes via Dio -------------------------------------------
    test('400 NestJS message list → ValidationFailure', () async {
      final api = _buildClient((_) async => _jsonBody({
            'statusCode': 400,
            'message': ['email must be valid', 'password too short'],
            'error': 'Bad Request',
          }, 400));
      final r = await api.post<void>('/register', body: {});
      expect(r.failureOrNull, isA<ValidationFailure>());
      expect(r.failureOrNull!.message, contains('email must be valid'));
    });

    test('401 → UnauthorizedFailure', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'Unauthorized'}, 401),
      );
      final r = await api.get<void>('/private');
      expect(r.failureOrNull, isA<UnauthorizedFailure>());
    });

    test('403 → ForbiddenFailure', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'Forbidden'}, 403),
      );
      final r = await api.get<void>('/admin');
      expect(r.failureOrNull, isA<ForbiddenFailure>());
    });

    test('404 → NotFoundFailure with correlationId from response header',
        () async {
      final api = _buildClient(
        (_) async => _jsonBody(
          {'message': 'Resource missing'},
          404,
          headers: {'x-correlation-id': ['srv-abc']},
        ),
      );
      final r = await api.get<void>('/items/99');
      final f = r.failureOrNull!;
      expect(f, isA<NotFoundFailure>());
      expect(f.correlationId, 'srv-abc');
    });

    test('409 → ConflictFailure', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'Already exists'}, 409),
      );
      final r = await api.post<void>('/users', body: {});
      expect(r.failureOrNull, isA<ConflictFailure>());
    });

    test('422 field errors → ValidationFailure with fieldErrors', () async {
      final api = _buildClient(
        (_) async => _jsonBody({
          'message': 'Validation failed',
          'errors': {
            'email': ['invalid format'],
          },
        }, 422),
      );
      final r = await api.post<void>('/form', body: {});
      final vf = r.failureOrNull as ValidationFailure?;
      expect(vf, isNotNull);
      expect(vf!.fieldErrors!['email'], ['invalid format']);
    });

    test('429 → RateLimitedFailure', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'slow down'}, 429),
      );
      final r = await api.get<void>('/items');
      expect(r.failureOrNull, isA<RateLimitedFailure>());
      expect(r.failureOrNull!.isRetryable, isTrue);
    });

    test('500 → ServerFailure (retryable)', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'Internal error'}, 500),
        retry: false,
      );
      final r = await api.get<void>('/crash');
      expect(r.failureOrNull, isA<ServerFailure>());
      expect(r.failureOrNull!.isRetryable, isTrue);
    });

    test('503 → ServerFailure, GET retries and can succeed', () async {
      var n = 0;
      final api = _buildClient(
        (_) async => n++ == 0
            ? _jsonBody({'message': 'down'}, 503)
            : _jsonBody({'ok': true}, 200),
        retry: true,
      );
      final r = await api.get<Map<String, dynamic>>('/health');
      expect(r.isSuccess, isTrue);
    });

    test('POST is never retried even on 503', () async {
      var calls = 0;
      final api = _buildClient(
        (_) async {
          calls++;
          return _jsonBody({'message': 'down'}, 503);
        },
        retry: true,
      );
      final r = await api.post<void>('/pay', body: {});
      expect(r.failureOrNull, isA<ServerFailure>());
      expect(calls, 1);
    });

    // --- Parser errors -------------------------------------------------------
    test('parser throws → ParsingFailure, not UnknownFailure', () async {
      final api = _buildClient((_) async => _jsonBody({'a': 1}, 200));
      final r = await api.get<String>(
        '/x',
        parser: (_) => throw const FormatException('bad shape'),
      );
      expect(r.failureOrNull, isA<ParsingFailure>());
    });

    test('parser casts null → ParsingFailure', () async {
      final api = _buildClient((_) async => _jsonBody({'a': 1}, 200));
      final r = await api.get<String>(
        '/x',
        parser: (j) => (j as Map<String, dynamic>)['missing'] as String,
      );
      expect(r.failureOrNull, isA<ParsingFailure>());
    });

    // --- onFailure hook ------------------------------------------------------
    test('onFailure hook fires on every non-cancel failure', () async {
      var hits = 0;
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'err'}, 500),
        retry: false,
        onFailure: (_) => hits++,
      );
      await api.get<void>('/a');
      await api.get<void>('/b');
      expect(hits, 2);
    });

    test('onFailure hook does NOT fire for CancelledFailure', () async {
      var hits = 0;
      final api = _buildClient(
        (o) async => throw DioException(
          requestOptions: o,
          type: DioExceptionType.cancel,
        ),
        onFailure: (_) => hits++,
      );
      await api.get<void>('/x');
      expect(hits, 0);
    });

    test('onFailure hook throwing cannot break the returned Result', () async {
      var hits = 0;
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'err'}, 500),
        retry: false,
        onFailure: (_) {
          hits++;
          throw StateError('hook explosion');
        },
      );
      final r = await api.get<void>('/x');
      expect(r.isFailure, isTrue);
      expect(hits, 1);
    });

    // --- userMessage safety --------------------------------------------------
    test('500 userMessage never leaks backend internals', () async {
      final api = _buildClient(
        (_) async =>
            _jsonBody({'message': 'SQL error at table users (line 42)'}, 500),
        retry: false,
      );
      final r = await api.get<void>('/x');
      expect(r.failureOrNull!.userMessage, isNot(contains('SQL')));
      expect(r.failureOrNull!.userMessage, contains('went wrong'));
    });

    test('422 userMessage exposes validation text safely', () async {
      final api = _buildClient(
        (_) async => _jsonBody({'message': 'Email is invalid'}, 422),
      );
      final r = await api.get<void>('/x');
      expect(r.failureOrNull!.userMessage, 'Email is invalid');
    });

    // --- request method (generic) -------------------------------------------
    test('request() with custom method HEAD returns Success on 200', () async {
      final api = _buildClient((_) async => _jsonBody({}, 200));
      final r = await api.request<Map<String, dynamic>>(
        path: '/ping',
        method: 'HEAD',
      );
      expect(r.isSuccess, isTrue);
    });
  });

  // =========================================================================
  // C. FailureMessages – user-facing copy for every failure type
  // =========================================================================

  group('Server – FailureMessages.userMessage per type', () {
    setUp(() => FailureMessageConfig.resolver = null);
    tearDown(() => FailureMessageConfig.resolver = null);

    test('NetworkFailure → mentions network', () {
      expect(
        const NetworkFailure().userMessage,
        contains('internet'),
      );
    });

    test('SecureConnectionFailure → mentions connection', () {
      expect(
        const SecureConnectionFailure().userMessage,
        contains('secure connection'),
      );
    });

    test('TimeoutFailure → mentions "too long"', () {
      expect(const TimeoutFailure().userMessage, contains('too long'));
    });

    test('CancelledFailure → mentions cancelled', () {
      expect(
        const CancelledFailure().userMessage.toLowerCase(),
        contains('cancel'),
      );
    });

    test('UnauthorizedFailure → mentions sign in', () {
      expect(const UnauthorizedFailure().userMessage, contains('sign in'));
    });

    test('ForbiddenFailure → mentions permission', () {
      expect(const ForbiddenFailure().userMessage, contains('permission'));
    });

    test('NotFoundFailure → mentions "not found" / "could not be found"', () {
      expect(
        const NotFoundFailure().userMessage.toLowerCase(),
        contains('found'),
      );
    });

    test('ValidationFailure → exposes the validation message', () {
      const f = ValidationFailure('Email must be valid');
      expect(f.userMessage, 'Email must be valid');
    });

    test('ConflictFailure → exposes the message', () {
      const f = ConflictFailure('Username taken');
      expect(f.userMessage, 'Username taken');
    });

    test('RateLimitedFailure → mentions wait / requests', () {
      final msg = const RateLimitedFailure().userMessage.toLowerCase();
      expect(msg, anyOf(contains('wait'), contains('requests')));
    });

    test('ParsingFailure → mentions "unexpected response"', () {
      expect(
        const ParsingFailure().userMessage.toLowerCase(),
        contains('unexpected'),
      );
    });

    test('LocalStorageFailure → mentions data / restart', () {
      final msg = const LocalStorageFailure().userMessage.toLowerCase();
      expect(msg, anyOf(contains('data'), contains('restart')));
    });

    test('ServerFailure 5xx → generic "went wrong", no backend text', () {
      const f = ServerFailure('DB locked', statusCode: 500);
      expect(f.userMessage, isNot(contains('DB locked')));
    });

    test('ServerFailure 4xx → exposes the message (safe)', () {
      const f = ServerFailure('Account not verified', statusCode: 403);
      expect(f.userMessage, 'Account not verified');
    });

    test('UnknownFailure → generic "went wrong"', () {
      expect(
        const UnknownFailure().userMessage.toLowerCase(),
        contains('went wrong'),
      );
    });

    test('custom resolver overrides copy', () {
      FailureMessageConfig.resolver =
          (f) => f is NetworkFailure ? 'Sin conexión' : null;
      expect(const NetworkFailure().userMessage, 'Sin conexión');
      expect(
        const TimeoutFailure().userMessage,
        isNot('Sin conexión'),
      ); // falls back
    });

    test('resolver returning empty string falls back to default', () {
      FailureMessageConfig.resolver = (_) => '   ';
      expect(
        const NetworkFailure().userMessage,
        isNot(equals('   ')),
      );
    });

    test('resolver that throws falls back gracefully', () {
      FailureMessageConfig.resolver = (_) => throw StateError('resolver boom');
      expect(() => const NetworkFailure().userMessage, returnsNormally);
      expect(const NetworkFailure().userMessage.isNotEmpty, isTrue);
    });
  });

  // =========================================================================
  // D. AppFailure value equality and hashCode
  // =========================================================================

  group('Server – AppFailure equality & hashCode', () {
    test('same type + message + statusCode → equal', () {
      expect(
        const ServerFailure('err', statusCode: 500),
        const ServerFailure('err', statusCode: 500),
      );
    });

    test('stackTrace is ignored in equality', () {
      expect(
        ServerFailure('err', statusCode: 500, stackTrace: StackTrace.current),
        const ServerFailure('err', statusCode: 500),
      );
    });

    test('cause is ignored in equality', () {
      expect(
        const ServerFailure('err', statusCode: 500).withContext(cause: 'x'),
        const ServerFailure('err', statusCode: 500),
      );
    });

    test('different type → not equal', () {
      expect(const NetworkFailure(), isNot(const TimeoutFailure()));
    });

    test('same type, different message → not equal', () {
      expect(
        const ServerFailure('a', statusCode: 500),
        isNot(const ServerFailure('b', statusCode: 500)),
      );
    });

    test('same type, different statusCode → not equal', () {
      expect(
        const ServerFailure('err', statusCode: 500),
        isNot(const ServerFailure('err', statusCode: 503)),
      );
    });

    test('hashCode matches for equal failures', () {
      const a = ServerFailure('err', statusCode: 500);
      const b = ServerFailure('err', statusCode: 500);
      expect(a.hashCode, b.hashCode);
    });

    test('ValidationFailure with same fieldErrors → equal', () {
      const a = ValidationFailure('v', fieldErrors: {
        'email': ['bad'],
      });
      const b = ValidationFailure('v', fieldErrors: {
        'email': ['bad'],
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('ValidationFailure with different fieldErrors → not equal', () {
      const a = ValidationFailure('v', fieldErrors: {
        'email': ['bad'],
      });
      const b = ValidationFailure('v', fieldErrors: {
        'phone': ['bad'],
      });
      expect(a, isNot(b));
    });

    test('toString includes runtimeType, statusCode and correlationId', () {
      const f = ServerFailure('boom', statusCode: 500);
      final s = f.toString();
      expect(s, contains('ServerFailure'));
      expect(s, contains('500'));
    });
  });
}

