// ignore_for_file: avoid_print
/// Tests for the **App layer** – Result<T>, ErrorHandler, ErrorHandler.format,
/// and the guard() helper that ties repositories to the error pipeline.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void main() {
  // Reset static dedup state between tests.
  setUp(() async {
    // Run two distinct errors to flush the last-seen slot.
    const h = ErrorHandler();
    await h.handle(Exception('flush-a'));
    await h.handle(Exception('flush-b'));
  });

  // =========================================================================
  // A. Result<T> – constructors, accessors, equality
  // =========================================================================

  group('App – Result<T> constructors and accessors', () {
    test('Success.dataOrNull returns data; failureOrNull returns null', () {
      const r = Success<int>(42);
      expect(r.dataOrNull, 42);
      expect(r.failureOrNull, isNull);
      expect(r.isSuccess, isTrue);
      expect(r.isFailure, isFalse);
    });

    test('Failure.failureOrNull returns failure; dataOrNull returns null', () {
      const r = Failure<int>(NetworkFailure());
      expect(r.failureOrNull, isA<NetworkFailure>());
      expect(r.dataOrNull, isNull);
      expect(r.isFailure, isTrue);
      expect(r.isSuccess, isFalse);
    });

    test('Success equality and hashCode', () {
      expect(const Success<int>(1), const Success<int>(1));
      expect(const Success<int>(1).hashCode, const Success<int>(1).hashCode);
      expect(const Success<int>(1), isNot(const Success<int>(2)));
    });

    test('Failure equality and hashCode', () {
      const a = Failure<int>(ServerFailure('x', statusCode: 500));
      const b = Failure<int>(ServerFailure('x', statusCode: 500));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('Success<T> != Failure<T>', () {
      expect(
          const Success<int>(0), isNot(const Failure<int>(NetworkFailure())));
    });

    test('Success.toString includes the data', () {
      expect(const Success<int>(7).toString(), contains('7'));
    });

    test('Failure.toString includes the failure', () {
      expect(
        const Failure<int>(NotFoundFailure()).toString(),
        contains('NotFoundFailure'),
      );
    });
  });

  // =========================================================================
  // B. Result<T> – fold, map, flatMap, getOrElse, mapFailure
  // =========================================================================

  group('App – Result<T> combinators', () {
    const ok = Success<int>(10);
    const bad = Failure<int>(TimeoutFailure());

    test('fold: success branch', () {
      expect(ok.fold(onSuccess: (d) => d * 2, onFailure: (_) => -1), 20);
    });

    test('fold: failure branch', () {
      expect(bad.fold(onSuccess: (d) => d, onFailure: (_) => -1), -1);
    });

    test('map transforms Success value', () {
      expect(ok.map((d) => 'v$d'), const Success<String>('v10'));
    });

    test('map passes Failure through unchanged', () {
      expect(bad.map((d) => d + 1).failureOrNull, isA<TimeoutFailure>());
    });

    test('flatMap on Success chains to new Result', () {
      final r = ok.flatMap((d) => Success<String>('$d items'));
      expect(r.dataOrNull, '10 items');
    });

    test('flatMap on Success can produce a Failure', () {
      final r = ok.flatMap<String>((_) => const Failure(NetworkFailure()));
      expect(r.failureOrNull, isA<NetworkFailure>());
    });

    test('flatMap on Failure short-circuits', () {
      final r = bad.flatMap<String>((d) => Success('$d'));
      expect(r.failureOrNull, isA<TimeoutFailure>());
    });

    test('getOrElse returns data on Success', () {
      expect(ok.getOrElse((_) => 0), 10);
    });

    test('getOrElse calls orElse on Failure', () {
      expect(bad.getOrElse((_) => 99), 99);
    });

    test('mapFailure transforms failure, success passes through', () {
      final r = bad.mapFailure((_) => const NetworkFailure());
      expect(r.failureOrNull, isA<NetworkFailure>());
      expect(ok.mapFailure((_) => const NetworkFailure()).dataOrNull, 10);
    });

    test('onSuccess side-effect fires only for Success', () {
      var saw = -1;
      ok.onSuccess((d) => saw = d);
      expect(saw, 10);
      bad.onSuccess((d) => saw = d);
      expect(saw, 10); // unchanged
    });

    test('onFailure side-effect fires only for Failure', () {
      AppFailure? caught;
      bad.onFailure((f) => caught = f);
      expect(caught, isA<TimeoutFailure>());
      ok.onFailure((f) => caught = f);
      expect(caught, isA<TimeoutFailure>()); // unchanged
    });

    test('getOrThrow returns data on Success', () {
      expect(ok.getOrThrow(), 10);
    });

    test('getOrThrow throws the AppFailure on Failure', () {
      expect(
        () => const Failure<int>(NotFoundFailure()).getOrThrow(),
        throwsA(isA<NotFoundFailure>()),
      );
    });

    test('AppFailure implements Exception – catchable as Exception', () {
      expect(
        () => const Failure<int>(UnauthorizedFailure()).getOrThrow(),
        throwsA(isA<Exception>()),
      );
    });
  });

  // =========================================================================
  // C. Result<T> – async combinators (flatMapAsync)
  // =========================================================================

  group('App – Result<T> async combinators', () {
    test('flatMapAsync on Success returns transformed result', () async {
      const ok = Success<int>(5);
      final r = await ok.flatMapAsync(
        (d) async => Success<String>('got $d'),
      );
      expect(r.dataOrNull, 'got 5');
    });

    test('flatMapAsync on Failure short-circuits without calling transform',
        () async {
      var called = false;
      const bad = Failure<int>(NetworkFailure());
      final r = await bad.flatMapAsync<String>((d) async {
        called = true;
        return Success('$d');
      });
      expect(called, isFalse);
      expect(r.failureOrNull, isA<NetworkFailure>());
    });

    test('flatMapAsync can return a Failure from the transform', () async {
      const ok = Success<int>(1);
      final r = await ok.flatMapAsync<String>(
        (_) async => const Failure(UnauthorizedFailure()),
      );
      expect(r.failureOrNull, isA<UnauthorizedFailure>());
    });
  });

  // =========================================================================
  // D. Result.guard – converts throws into typed failures
  // =========================================================================

  group('App – Result.guard', () {
    test('successful action → Success with data', () async {
      final r = await Result.guard<int>(() async => 42);
      expect(r, const Success<int>(42));
    });

    test('FormatException → ParsingFailure via default mapper', () async {
      final r = await Result.guard<int>(
        () async => throw const FormatException('bad'),
      );
      expect(r.failureOrNull, isA<ParsingFailure>());
    });

    test('SocketException → NetworkFailure via default mapper', () async {
      final r = await Result.guard<int>(
        () async => throw const SocketException('dropped'),
      );
      expect(r.failureOrNull, isA<NetworkFailure>());
    });

    test('TimeoutException → TimeoutFailure via default mapper', () async {
      final r = await Result.guard<int>(
        () async => throw TimeoutException('slow'),
      );
      expect(r.failureOrNull, isA<TimeoutFailure>());
    });

    test('arbitrary exception → UnknownFailure via default mapper', () async {
      final r = await Result.guard<int>(
        () async => throw StateError('unexpected'),
      );
      expect(r.failureOrNull, isA<UnknownFailure>());
    });

    test('custom mapError overrides default mapping', () async {
      final r = await Result.guard<int>(
        () async => throw const SocketException('no wifi'),
        mapError: (_, __) => const UnauthorizedFailure(),
      );
      expect(r.failureOrNull, isA<UnauthorizedFailure>());
      expect(r.failureOrNull!.message, 'custom');
    });

    test('AppFailure thrown directly is returned as-is', () async {
      const f = ForbiddenFailure();
      final r = await Result.guard<int>(() async => throw f);
      expect(r.failureOrNull, isA<ForbiddenFailure>());
    });

    test('guard never throws even when action throws synchronously', () async {
      expect(
        () => Result.guard<int>(() async {
          throw StateError('sync-ish');
        }),
        returnsNormally,
      );
    });
  });

  // =========================================================================
  // E. ErrorHandler – handle(), dedup, ignore, format
  // =========================================================================

  group('App – ErrorHandler.handle()', () {
    test('maps SocketException → NetworkFailure', () async {
      final f =
          await const ErrorHandler().handle(const SocketException('no route'));
      expect(f, isA<NetworkFailure>());
    });

    test('maps FormatException → ParsingFailure', () async {
      final f = await const ErrorHandler().handle(const FormatException('bad'));
      expect(f, isA<ParsingFailure>());
    });

    test('maps TimeoutException → TimeoutFailure', () async {
      final f = await const ErrorHandler().handle(TimeoutException('slow'));
      expect(f, isA<TimeoutFailure>());
    });

    test('passes already-mapped AppFailure through without double-wrap',
        () async {
      const original = NotFoundFailure();
      final f = await const ErrorHandler().handle(original);
      expect(f, isA<NotFoundFailure>());
    });

    test('never throws when logger throws', () async {
      final handler = ErrorHandler(
        logger: (_) async => throw StateError('logger boom'),
      );
      expect(
        () => handler.handle(Exception('x')),
        returnsNormally,
      );
    });

    test('never throws when onFailure throws', () async {
      final handler = ErrorHandler(
        onFailure: (_, __) => throw StateError('listener boom'),
      );
      expect(
        () => handler.handle(Exception('x')),
        returnsNormally,
      );
    });

    test('logger is called with the mapped failure', () async {
      AppFailure? logged;
      final handler = ErrorHandler(logger: (f) async => logged = f);
      await handler.handle(const SocketException('down'));
      expect(logged, isA<NetworkFailure>());
    });

    test('onFailure receives failure and userMessage', () async {
      AppFailure? gotFailure;
      String? gotMsg;
      final handler = ErrorHandler(
        onFailure: (f, msg) {
          gotFailure = f;
          gotMsg = msg;
        },
      );
      await handler.handle(const UnauthorizedFailure());
      expect(gotFailure, isA<UnauthorizedFailure>());
      expect(gotMsg, contains('sign in'));
    });

    test('CancelledFailure is ignored by default (no log, no onFailure)',
        () async {
      var logged = 0;
      var fired = 0;
      final handler = ErrorHandler(
        logger: (_) async => logged++,
        onFailure: (_, __) => fired++,
      );
      await handler.handle(const CancelledFailure());
      expect(logged, 0);
      expect(fired, 0);
    });

    test('custom shouldIgnore suppresses specified failure', () async {
      var logged = 0;
      final handler = ErrorHandler(
        logger: (_) async => logged++,
        shouldIgnore: (f) => f is NetworkFailure,
      );
      await handler.handle(const SocketException(''));
      expect(logged, 0);
    });

    test('custom shouldIgnore does NOT suppress other failures', () async {
      var logged = 0;
      final handler = ErrorHandler(
        logger: (_) async => logged++,
        shouldIgnore: (f) => f is NetworkFailure,
      );
      await handler.handle(const FormatException('x'));
      expect(logged, 1);
    });

    test('same error object within dedupeWindow is logged only once', () async {
      var logged = 0;
      final handler = ErrorHandler(
        logger: (_) async => logged++,
        dedupeWindow: const Duration(seconds: 2),
      );
      final err = Exception('dup');
      await handler.handle(err);
      await handler.handle(err); // duplicate within window
      expect(logged, 1);
    });

    test('same error after dedupeWindow is logged again', () async {
      var logged = 0;
      final handler = ErrorHandler(
        logger: (_) async => logged++,
        dedupeWindow: Duration.zero, // window = 0 → never dedupe
      );
      final err = Exception('no-dup');
      await handler.handle(err);
      await handler.handle(err);
      expect(logged, 2);
    });

    test('two different error objects are both logged', () async {
      var logged = 0;
      final handler = ErrorHandler(logger: (_) async => logged++);
      await handler.handle(Exception('a'));
      await handler.handle(Exception('b'));
      expect(logged, 2);
    });
  });

  // =========================================================================
  // F. ErrorHandler.format – static helper
  // =========================================================================

  group('App – ErrorHandler.format()', () {
    test('AppFailure with message → returns that message', () {
      expect(
        ErrorHandler.format(const NetworkFailure('custom msg')),
        'custom msg',
      );
    });

    test('AppFailure with empty message → returns type name', () {
      // Create a failure whose message is empty (not standard, but guard path).
      final f = const NetworkFailure('').withContext();
      final s = ErrorHandler.format(f);
      expect(s.isNotEmpty, isTrue);
    });

    test('Exception string is stripped of "Exception: " prefix', () {
      final s = ErrorHandler.format(Exception('Something broke'));
      expect(s, isNot(startsWith('Exception:')));
      expect(s, contains('Something broke'));
    });

    test('arbitrary non-Exception object → toString()', () {
      expect(ErrorHandler.format(42), '42');
    });

    test('object whose toString() throws → falls back to type name', () {
      final result = ErrorHandler.format(_Kaboom());
      // safeToString catches the throw and returns the runtimeType name.
      expect(result.isNotEmpty, isTrue);
    });

    test('never throws', () {
      expect(() => ErrorHandler.format(42), returnsNormally);
      expect(() => ErrorHandler.format(_Kaboom()), returnsNormally);
    });
  });

  // =========================================================================
  // G. ErrorKit.report – convenience static (uses fallback handler)
  // =========================================================================

  group('App – ErrorKit.report before bootstrap', () {
    test('report() before bootstrap returns a mapped failure without throwing',
        () async {
      // ErrorKit._handler is null before bootstrap, falls back to
      // const ErrorHandler(). Should not throw.
      expect(
        () => ErrorKit.report(Exception('pre-boot')),
        returnsNormally,
      );
      final f = await ErrorKit.report(const SocketException('no wifi'));
      expect(f, isA<NetworkFailure>());
    });
  });

  // =========================================================================
  // H. DioFactory._backoff – not exported, tested via ApiClient behaviour
  // =========================================================================

  group('App – DioFactory retry backoff (observable via call count)', () {
    test('zero retryDelay still retries the right number of times', () async {
      var calls = 0;
      final dio = DioFactory.create(
        baseUrl: 'https://api.test',
        retryDelay: Duration.zero,
        maxRetries: 2,
        enableRetry: true,
      );
      // Always fail so all retries are exhausted.
      dio.httpClientAdapter = _AlwaysFailAdapter(503, calls: (n) => calls = n);
      final api = ApiClient(dio);
      await api.get<void>('/x');
      expect(calls, 3); // 1 attempt + 2 retries
    });

    test('retry disabled → exactly 1 call', () async {
      var calls = 0;
      final dio = DioFactory.create(
        baseUrl: 'https://api.test',
        retryDelay: Duration.zero,
        enableRetry: false,
      );
      dio.httpClientAdapter = _AlwaysFailAdapter(503, calls: (n) => calls = n);
      final api = ApiClient(dio);
      await api.get<void>('/x');
      expect(calls, 1);
    });
  });
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

class _Kaboom {
  @override
  String toString() => throw StateError('explodes');
}

class _AlwaysFailAdapter implements HttpClientAdapter {
  _AlwaysFailAdapter(this._status, {required this.calls});
  final int _status;
  final void Function(int) calls;
  int _n = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls(++_n);
    return Future.value(
      ResponseBody.fromString(
        '{"message":"down"}',
        _status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}
