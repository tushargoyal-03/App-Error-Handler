import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppFailure', () {
    test('constructors keep the stack trace (original code dropped it)', () {
      final st = StackTrace.current;
      expect(NetworkFailure('x', st).stackTrace, st);
      expect(UnknownFailure('x', st).stackTrace, st);
      expect(NotFoundFailure('x', st).stackTrace, st);
    });

    test('withContext attaches stack + correlationId + cause on every type', () {
      final st = StackTrace.current;
      final failures = <AppFailure>[
        const NetworkFailure(),
        const TimeoutFailure(),
        const CancelledFailure(),
        const UnauthorizedFailure(),
        const ForbiddenFailure(),
        const NotFoundFailure(),
        const ConflictFailure(),
        const RateLimitedFailure(),
        const ParsingFailure(),
        const LocalStorageFailure(),
        const UnknownFailure(),
        const SecureConnectionFailure(),
        const ServerFailure('boom', statusCode: 500),
        const ValidationFailure('bad'),
      ];
      for (final f in failures) {
        final enriched = f.withContext(
          stackTrace: st,
          correlationId: 'corr-1',
          cause: 'root',
        );
        expect(enriched.runtimeType, f.runtimeType, reason: '$f');
        expect(enriched.stackTrace, st, reason: '$f');
        expect(enriched.correlationId, 'corr-1', reason: '$f');
        expect(enriched.cause, 'root', reason: '$f');
        expect(enriched.statusCode, f.statusCode, reason: '$f');
      }
    });

    test('value equality ignores stack trace', () {
      expect(
        ServerFailure('a', statusCode: 500, stackTrace: StackTrace.current),
        const ServerFailure('a', statusCode: 500),
      );
      expect(const NetworkFailure(), isNot(const TimeoutFailure()));
    });

    test('isRetryable', () {
      expect(const NetworkFailure().isRetryable, isTrue);
      expect(const ServerFailure('x', statusCode: 503).isRetryable, isTrue);
      expect(const ServerFailure('x', statusCode: 400).isRetryable, isFalse);
      expect(const UnauthorizedFailure().isRetryable, isFalse);
    });

    test('userMessage never leaks 5xx backend text', () {
      const f = ServerFailure('SQL error at table users', statusCode: 500);
      expect(f.userMessage, isNot(contains('SQL')));
    });

    test('FailureMessageConfig.resolver overrides copy', () {
      FailureMessageConfig.resolver = (f) => f is NetworkFailure ? 'offline!' : null;
      addTearDown(() => FailureMessageConfig.resolver = null);
      expect(const NetworkFailure().userMessage, 'offline!');
      expect(const TimeoutFailure().userMessage, contains('too long'));
    });
  });

  group('ErrorMapper.fromResponse', () {
    test('NestJS validation: 400 + message list → ValidationFailure', () {
      final f = ErrorMapper.fromResponse(400, {
        'statusCode': 400,
        'message': ['email must be an email', 'password is too short'],
        'error': 'Bad Request',
      });
      expect(f, isA<ValidationFailure>());
      expect(f.statusCode, 400);
      expect(f.message, 'email must be an email\npassword is too short');
    });

    test('plain 400 with string message → ServerFailure(400)', () {
      final f = ErrorMapper.fromResponse(400, '{"message":"Nope"}');
      expect(f, isA<ServerFailure>());
      expect(f.message, 'Nope');
    });

    test('empty message falls through to the next key', () {
      final f = ErrorMapper.fromResponse(
        403,
        '{"message":"","error":"Forbidden"}',
      );
      expect(f.message, 'Forbidden');
    });

    test('nested error object', () {
      final f = ErrorMapper.fromResponse(
        404,
        {'error': {'code': 'X', 'message': 'User missing'}},
      );
      expect(f, isA<NotFoundFailure>());
      expect(f.message, 'User missing');
    });

    test('correlationId is kept for 401/403/404/409 (was silently lost)', () {
      for (final code in [401, 403, 404, 409, 422, 500]) {
        final f = ErrorMapper.fromResponse(
          code,
          '{"message":"x"}',
          correlationId: 'abc',
        );
        expect(f.correlationId, 'abc', reason: 'status $code');
      }
    });

    test('correlationId is read from the body when no header', () {
      final f = ErrorMapper.fromResponse(
        500,
        '{"message":"x","correlationId":"from-body"}',
      );
      expect(f.correlationId, 'from-body');
    });

    test('422 with field errors (map and class-validator list shapes)', () {
      final a = ErrorMapper.fromResponse(422, {
        'message': 'Invalid',
        'errors': {'email': ['bad'], 'age': 'too low'},
      });
      expect(a.fieldErrors, {'email': ['bad'], 'age': ['too low']});

      final b = ErrorMapper.fromResponse(422, {
        'message': 'Invalid',
        'errors': [
          {'property': 'email', 'constraints': {'isEmail': 'must be email'}},
        ],
      });
      expect(b.fieldErrors, {'email': ['must be email']});
    });

    test('429 carries retryAfter', () {
      final f = ErrorMapper.fromResponse(
        429,
        '',
        retryAfter: const Duration(seconds: 7),
      );
      expect(f, isA<RateLimitedFailure>());
      expect((f as RateLimitedFailure).retryAfter, const Duration(seconds: 7));
    });

    test('HTML error pages are never used as the message', () {
      final f = ErrorMapper.fromResponse(404, '<html>nginx 404</html>');
      expect(f.message, isNot(contains('<')));
    });

    test('already-decoded Map body works (old code produced "{message: x}")', () {
      final f = ErrorMapper.fromResponse(500, {'message': 'boom'});
      expect(f.message, 'boom');
    });

    test('5xx keeps raw message for logs but not a "Server error:" prefix', () {
      final f = ErrorMapper.fromResponse(503, '{"message":"down"}');
      expect(f, isA<ServerFailure>());
      expect(f.message, 'down');
      expect(f.statusCode, 503);
    });
  });

  group('ErrorMapper.fromException / from', () {
    test('SocketException → NetworkFailure with stack', () {
      final st = StackTrace.current;
      final f = ErrorMapper.fromException(const SocketException('no route'), st);
      expect(f, isA<NetworkFailure>());
      expect(f.stackTrace, st);
      expect(f.cause, isA<SocketException>());
    });

    test('TimeoutException → TimeoutFailure', () {
      final f = ErrorMapper.fromException(
        TimeoutException('t', const Duration(seconds: 3)),
      );
      expect(f, isA<TimeoutFailure>());
    });

    test('FormatException → ParsingFailure; TypeError stays Unknown', () {
      expect(
        ErrorMapper.fromException(const FormatException('bad')),
        isA<ParsingFailure>(),
      );
      Object? err;
      try {
        // ignore: unnecessary_cast
        (1 as Object) as String;
      } catch (e) {
        err = e;
      }
      expect(ErrorMapper.fromException(err!), isA<UnknownFailure>());
    });

    test('from() handles DioException and never throws on odd objects', () {
      final dio = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(ErrorMapper.from(dio), isA<TimeoutFailure>());
      expect(ErrorMapper.from(_BadToString()), isA<UnknownFailure>());
    });

    test('does not double-wrap and attaches a missing stack', () {
      final st = StackTrace.current;
      final f = ErrorMapper.from(const NotFoundFailure(), st);
      expect(f, isA<NotFoundFailure>());
      expect(f.stackTrace, st);
    });
  });

  group('ErrorMapper.fromDio', () {
    test('every DioExceptionType maps without throwing', () {
      for (final type in DioExceptionType.values) {
        final e = DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: type,
          response: type == DioExceptionType.badResponse
              ? Response(
                  requestOptions: RequestOptions(path: '/x'),
                  statusCode: 500,
                  data: {'message': 'x'},
                )
              : null,
        );
        expect(() => ErrorMapper.fromDio(e), returnsNormally, reason: '$type');
      }
    });

    test('sent correlation id is attached to client-side failures', () {
      final e = DioException(
        requestOptions: RequestOptions(
          path: '/x',
          headers: {'x-correlation-id': 'sent-1'},
        ),
        type: DioExceptionType.connectionError,
      );
      final f = ErrorMapper.fromDio(e);
      expect(f, isA<NetworkFailure>());
      expect(f.correlationId, 'sent-1');
    });

    test('AppFailure thrown from an interceptor is preserved', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.unknown,
        error: const UnauthorizedFailure(),
      );
      expect(ErrorMapper.fromDio(e), isA<UnauthorizedFailure>());
    });
  });
}

class _BadToString {
  @override
  String toString() => throw StateError('nope');
}
