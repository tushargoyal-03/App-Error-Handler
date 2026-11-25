import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Result', () {
    test('fold / map / flatMap / getOrElse', () {
      const ok = Success<int>(2);
      const bad = Failure<int>(NetworkFailure());

      expect(ok.fold(onSuccess: (d) => d * 2, onFailure: (_) => -1), 4);
      expect(bad.fold(onSuccess: (d) => d * 2, onFailure: (_) => -1), -1);
      expect(ok.map((d) => d + 1), const Success<int>(3));
      expect(bad.map((d) => d + 1).failureOrNull, isA<NetworkFailure>());
      expect(ok.flatMap((d) => Success<String>('v$d')).dataOrNull, 'v2');
      expect(bad.getOrElse((_) => 0), 0);
    });

    test('getOrThrow throws an AppFailure (which is an Exception)', () {
      expect(
        () => const Failure<int>(NotFoundFailure()).getOrThrow(),
        throwsA(isA<NotFoundFailure>()),
      );
    });

    test('equality works for Bloc states', () {
      expect(
        const Failure<int>(ServerFailure('x', statusCode: 500)),
        const Failure<int>(ServerFailure('x', statusCode: 500)),
      );
    });

    test('guard converts thrown errors, keeps successes', () async {
      final ok = await Result.guard(() async => 5);
      expect(ok, const Success<int>(5));

      final bad = await Result.guard<int>(
        () async => throw const FormatException('nope'),
      );
      expect(bad.failureOrNull, isA<ParsingFailure>());
    });
  });

  group('ErrorHandler', () {
    test('never throws even when logger and listener throw', () async {
      final handler = ErrorHandler(
        logger: (_) async => throw StateError('logger'),
        onFailure: (_, __) => throw StateError('listener'),
      );
      final failure = await handler.handle(Exception('boom'));
      expect(failure, isA<UnknownFailure>());
    });

    test('maps raw exceptions (old handler returned UnknownFailure for all)', () async {
      final failure = await const ErrorHandler().handle(
        const FormatException('bad json'),
      );
      expect(failure, isA<ParsingFailure>());
    });

    test('ignores cancellations by default', () async {
      var logged = 0;
      final handler = ErrorHandler(logger: (_) async => logged++);
      await handler.handle(const CancelledFailure());
      expect(logged, 0);
    });

    test('drops the same error object reported twice', () async {
      var logged = 0;
      final handler = ErrorHandler(logger: (_) async => logged++);
      final err = Exception('dup');
      await handler.handle(err);
      await handler.handle(err);
      expect(logged, 1);
    });

    test('passes the user message to onFailure', () async {
      String? shown;
      final handler = ErrorHandler(onFailure: (_, msg) => shown = msg);
      await handler.handle(const UnauthorizedFailure());
      expect(shown, contains('sign in'));
    });

    test('format never throws', () {
      expect(ErrorHandler.format(Exception('Exception: x')), isNotEmpty);
      expect(ErrorHandler.format(const NetworkFailure()), isNotEmpty);
    });
  });
}
