// ignore_for_file: avoid_print
/// Tests for the **Socket / Network transport layer**.
///
/// Covers every failure that can originate from dart:io sockets and from the
/// Dio connection pipeline, before an HTTP status code is involved.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

DioException _dioErr(
  DioExceptionType type, {
  Response<dynamic>? response,
  Object? error,
  String path = '/test',
  Map<String, dynamic>? headers,
}) =>
    DioException(
      requestOptions: RequestOptions(path: path, headers: headers ?? {}),
      type: type,
      response: response,
      error: error,
    );

// ---------------------------------------------------------------------------
// 1. dart:io socket exceptions → ErrorMapper.fromException
// ---------------------------------------------------------------------------

void main() {
  group('Socket – dart:io exceptions → AppFailure', () {
    test('SocketException (no route) → NetworkFailure preserves stack', () {
      final st = StackTrace.current;
      final f = ErrorMapper.fromException(
        const SocketException('Network is unreachable'),
        st,
      );
      expect(f, isA<NetworkFailure>());
      expect(f.stackTrace, st);
      expect(f.cause, isA<SocketException>());
      expect(f.isRetryable, isTrue);
    });

    test('SocketException with empty message gets a default message', () {
      final f = ErrorMapper.fromException(const SocketException(''));
      expect(f, isA<NetworkFailure>());
      expect(f.message.isNotEmpty, isTrue);
    });

    test('TlsException (HandshakeException) → SecureConnectionFailure', () {
      final f = ErrorMapper.fromException(
        const TlsException('Handshake failed'),
      );
      expect(f, isA<SecureConnectionFailure>());
      expect(f.isRetryable, isFalse);
    });

    test('HttpException → NetworkFailure', () {
      final f = ErrorMapper.fromException(const HttpException('Bad HTTP'));
      expect(f, isA<NetworkFailure>());
    });

    test('WebSocketException → NetworkFailure', () {
      final f = ErrorMapper.fromException(
        const WebSocketException('WebSocket closed'),
      );
      expect(f, isA<NetworkFailure>());
    });

    test('TimeoutException without duration → TimeoutFailure', () {
      final f = ErrorMapper.fromException(TimeoutException('timed out'));
      expect(f, isA<TimeoutFailure>());
      expect(f.isRetryable, isTrue);
    });

    test('TimeoutException with duration includes seconds in message', () {
      final f = ErrorMapper.fromException(
        TimeoutException('slow', const Duration(seconds: 15)),
      );
      expect(f, isA<TimeoutFailure>());
      expect(f.message, contains('15'));
    });

    test('FileSystemException → LocalStorageFailure', () {
      final f = ErrorMapper.fromException(
        const FileSystemException('No space', '/data/app'),
      );
      expect(f, isA<LocalStorageFailure>());
    });

    test('FormatException → ParsingFailure', () {
      final f = ErrorMapper.fromException(
        const FormatException('invalid UTF-8'),
      );
      expect(f, isA<ParsingFailure>());
    });

    test('TypeError (programmer bug) → UnknownFailure, not ParsingFailure', () {
      Object? err;
      try {
        // ignore: unnecessary_cast
        (1 as Object) as String;
      } catch (e) {
        err = e;
      }
      final f = ErrorMapper.fromException(err!);
      expect(f, isA<UnknownFailure>());
    });

    test('arbitrary object → UnknownFailure with cause attached', () {
      final f = ErrorMapper.fromException(42);
      expect(f, isA<UnknownFailure>());
      expect(f.cause, 42);
    });

    test('AppFailure passed in is returned as-is (no double-wrap)', () {
      const original = NotFoundFailure();
      final f = ErrorMapper.fromException(original);
      expect(f, same(original));
    });

    test('AppFailure without stack gets stack attached when provided', () {
      final st = StackTrace.current;
      final f = ErrorMapper.from(const TimeoutFailure(), st);
      expect(f, isA<TimeoutFailure>());
      expect(f.stackTrace, st);
    });

    test('from() never throws even when toString() throws', () {
      expect(
        () => ErrorMapper.from(_BrokenToString()),
        returnsNormally,
      );
      expect(ErrorMapper.from(_BrokenToString()), isA<UnknownFailure>());
    });
  });

  // -------------------------------------------------------------------------
  // 2. Dio exception types → ErrorMapper.fromDio
  // -------------------------------------------------------------------------

  group('Network – Dio exception types → AppFailure', () {
    test('connectionTimeout → TimeoutFailure (retryable)', () {
      final f = ErrorMapper.fromDio(
        _dioErr(DioExceptionType.connectionTimeout),
      );
      expect(f, isA<TimeoutFailure>());
      expect(f.isRetryable, isTrue);
    });

    test('sendTimeout → TimeoutFailure', () {
      final f = ErrorMapper.fromDio(_dioErr(DioExceptionType.sendTimeout));
      expect(f, isA<TimeoutFailure>());
    });

    test('receiveTimeout → TimeoutFailure', () {
      final f = ErrorMapper.fromDio(_dioErr(DioExceptionType.receiveTimeout));
      expect(f, isA<TimeoutFailure>());
    });

    test('connectionError → NetworkFailure (retryable)', () {
      final f = ErrorMapper.fromDio(_dioErr(DioExceptionType.connectionError));
      expect(f, isA<NetworkFailure>());
      expect(f.isRetryable, isTrue);
    });

    test('cancel → CancelledFailure (not retryable)', () {
      final f = ErrorMapper.fromDio(_dioErr(DioExceptionType.cancel));
      expect(f, isA<CancelledFailure>());
      expect(f.isRetryable, isFalse);
    });

    test('badCertificate → SecureConnectionFailure', () {
      final f = ErrorMapper.fromDio(_dioErr(DioExceptionType.badCertificate));
      expect(f, isA<SecureConnectionFailure>());
    });

    test('unknown with SocketException inside → NetworkFailure', () {
      final f = ErrorMapper.fromDio(
        _dioErr(
          DioExceptionType.unknown,
          error: const SocketException('dropped'),
        ),
      );
      expect(f, isA<NetworkFailure>());
    });

    test('unknown with AppFailure inside → that same AppFailure', () {
      final f = ErrorMapper.fromDio(
        _dioErr(
          DioExceptionType.unknown,
          error: const UnauthorizedFailure(),
        ),
      );
      expect(f, isA<UnauthorizedFailure>());
    });

    test('unknown with no inner error → UnknownFailure', () {
      final f = ErrorMapper.fromDio(_dioErr(DioExceptionType.unknown));
      expect(f, isA<UnknownFailure>());
    });

    test('sent correlation-id is attached to client-side failures', () {
      final f = ErrorMapper.fromDio(
        _dioErr(
          DioExceptionType.connectionError,
          headers: {ErrorMapper.correlationHeader: 'req-id-99'},
        ),
      );
      expect(f.correlationId, 'req-id-99');
    });

    test('all DioExceptionType values map without throwing', () {
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
        expect(
          () => ErrorMapper.fromDio(e),
          returnsNormally,
          reason: 'type=$type must not throw',
        );
      }
    });

    test('fromDio attaches cause even when failure already has one', () {
      // Failure already has a cause set (e.g. from an interceptor).
      final existing = const UnauthorizedFailure().withContext(cause: 'old');
      final e = _dioErr(DioExceptionType.unknown, error: existing);
      // Should preserve it rather than clobber with the DioException.
      expect(ErrorMapper.fromDio(e).cause, 'old');
    });
  });

  // -------------------------------------------------------------------------
  // 3. isRetryable across the full type hierarchy
  // -------------------------------------------------------------------------

  group('isRetryable – every type', () {
    test('retryable failures', () {
      expect(const NetworkFailure().isRetryable, isTrue);
      expect(const TimeoutFailure().isRetryable, isTrue);
      expect(const RateLimitedFailure().isRetryable, isTrue);
      expect(
        const ServerFailure('x', statusCode: 500).isRetryable,
        isTrue,
      );
      expect(
        const ServerFailure('x', statusCode: 503).isRetryable,
        isTrue,
      );
    });

    test('non-retryable failures', () {
      expect(const SecureConnectionFailure().isRetryable, isFalse);
      expect(const CancelledFailure().isRetryable, isFalse);
      expect(const UnauthorizedFailure().isRetryable, isFalse);
      expect(const ForbiddenFailure().isRetryable, isFalse);
      expect(const NotFoundFailure().isRetryable, isFalse);
      expect(const ValidationFailure('v').isRetryable, isFalse);
      expect(const ConflictFailure().isRetryable, isFalse);
      expect(const ParsingFailure().isRetryable, isFalse);
      expect(const LocalStorageFailure().isRetryable, isFalse);
      expect(const UnknownFailure().isRetryable, isFalse);
      expect(
        const ServerFailure('x', statusCode: 400).isRetryable,
        isFalse,
      );
      expect(
        const ServerFailure('x', statusCode: 404).isRetryable,
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // 4. withContext / copyWithContext on every subclass
  // -------------------------------------------------------------------------

  group('withContext enrichment – all failure types', () {
    final st = StackTrace.empty;
    const corr = 'corr-abc';
    const cause = 'root-cause';

    final allFailures = <AppFailure>[
      const NetworkFailure(),
      const SecureConnectionFailure(),
      const TimeoutFailure(),
      const CancelledFailure(),
      const ServerFailure('err', statusCode: 500),
      const UnauthorizedFailure(),
      const ForbiddenFailure(),
      const NotFoundFailure(),
      const ValidationFailure('v', fieldErrors: {'f': ['e']}),
      const ConflictFailure(),
      const RateLimitedFailure('x', null, Duration(seconds: 5)),
      const ParsingFailure(),
      const LocalStorageFailure(),
      const UnknownFailure(),
      // Device / Location / HRMS-specific
      const OutOfRadiusFailure(),
      const OutOfRadiusFailure('Outside', 350.5),
      const DeviceIntegrityFailure(),
      const LocationPermissionFailure(),
      const LocationPermissionFailure(isPermanentlyDenied: true),
      const LocationServiceFailure(),
    ];

    for (final f in allFailures) {
      test('${f.runtimeType}.withContext preserves type and enriches fields',
          () {
        final enriched = f.withContext(
          stackTrace: st,
          correlationId: corr,
          cause: cause,
        );
        expect(enriched.runtimeType, f.runtimeType);
        expect(enriched.stackTrace, st);
        expect(enriched.correlationId, corr);
        expect(enriched.cause, cause);
        expect(enriched.message, f.message);
        expect(enriched.statusCode, f.statusCode);
      });
    }

    test('withContext: null args keep existing values', () {
      final f = const NetworkFailure().withContext(
        stackTrace: st,
        correlationId: corr,
      );
      final f2 = f.withContext(); // all null → keep
      expect(f2.stackTrace, st);
      expect(f2.correlationId, corr);
    });

    test('RateLimitedFailure.withContext preserves retryAfter', () {
      const original = RateLimitedFailure('x', null, Duration(seconds: 10));
      final enriched = original.withContext(stackTrace: st);
      expect((enriched as RateLimitedFailure).retryAfter,
          const Duration(seconds: 10));
    });

    test('ValidationFailure.withContext preserves fieldErrors', () {
      const original = ValidationFailure('v', fieldErrors: {
        'email': ['invalid'],
      });
      final enriched = original.withContext(correlationId: 'c');
      expect((enriched as ValidationFailure).fieldErrors,
          {'email': ['invalid']});
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _BrokenToString {
  @override
  String toString() => throw StateError('toString() is broken');
}

