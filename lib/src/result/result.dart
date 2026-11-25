import 'package:meta/meta.dart';

import '../failures/app_failure.dart';
import '../mapping/error_mapper.dart';

@immutable
sealed class Result<T> {
  const Result();

  /// Runs [action] and converts anything it throws into a [Failure] using
  /// [ErrorMapper]. Use it for non-HTTP work (storage, sockets, platform
  /// channels) so repositories never need `try/catch`.
  static Future<Result<T>> guard<T>(
    Future<T> Function() action, {
    AppFailure Function(Object error, StackTrace stackTrace)? mapError,
  }) async {
    try {
      return Success<T>(await action());
    } catch (e, st) {
      final AppFailure failure =
          mapError != null ? mapError(e, st) : ErrorMapper.from(e, st);
      return Failure<T>(failure);
    }
  }

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  T? get dataOrNull => switch (this) {
    Success<T>(data: final d) => d,
    Failure<T>() => null,
  };

  AppFailure? get failureOrNull => switch (this) {
    Success<T>() => null,
    Failure<T>(:final failure) => failure,
  };

  /// Exhaustive fold — the ergonomic workhorse.
  R fold<R>({
    required R Function(T data) onSuccess,
    required R Function(AppFailure failure) onFailure,
  }) => switch (this) {
    Success<T>(data: final d) => onSuccess(d),
    Failure<T>(:final failure) => onFailure(failure),
  };

  /// Success value, or [orElse] computed from the failure.
  T getOrElse(T Function(AppFailure failure) orElse) => switch (this) {
    Success<T>(data: final d) => d,
    Failure<T>(:final failure) => orElse(failure),
  };

  /// Map the success value; failures pass through.
  Result<R> map<R>(R Function(T data) transform) => switch (this) {
    Success<T>(data: final d) => Success<R>(transform(d)),
    Failure<T>(:final failure) => Failure<R>(failure),
  };

  /// Map the failure; successes pass through.
  Result<T> mapFailure(AppFailure Function(AppFailure failure) transform) =>
      switch (this) {
        Success<T>() => this,
        Failure<T>(:final failure) => Failure<T>(transform(failure)),
      };

  /// Chain an operation that itself returns a [Result].
  Result<R> flatMap<R>(Result<R> Function(T data) transform) => switch (this) {
    Success<T>(data: final d) => transform(d),
    Failure<T>(:final failure) => Failure<R>(failure),
  };

  /// Async variant of [flatMap].
  Future<Result<R>> flatMapAsync<R>(
    Future<Result<R>> Function(T data) transform,
  ) async => switch (this) {
    Success<T>(data: final d) => await transform(d),
    Failure<T>(:final failure) => Failure<R>(failure),
  };

  /// Run a side-effect on success — useful for logging/analytics.
  Result<T> onSuccess(void Function(T data) action) {
    if (this case Success<T>(:final data)) action(data);
    return this;
  }

  /// Run a side-effect on failure — useful for logging.
  Result<T> onFailure(void Function(AppFailure failure) action) {
    if (this case Failure<T>(:final failure)) action(failure);
    return this;
  }

  /// Throw the failure — only use at the boundary where exceptions are required
  /// (e.g. a third-party callback that can't return Result). Prefer fold.
  T getOrThrow() => switch (this) {
    Success<T>(data: final d) => d,
    Failure<T>(:final failure) => throw failure,
  };
}

@immutable
final class Success<T> extends Result<T> {
  final T data;
  const Success(this.data);

  @override
  bool operator ==(Object other) => other is Success<T> && other.data == data;

  @override
  int get hashCode => Object.hash(Success, data);

  @override
  String toString() => 'Success($data)';
}

@immutable
final class Failure<T> extends Result<T> {
  final AppFailure failure;
  const Failure(this.failure);

  @override
  bool operator ==(Object other) =>
      other is Failure<T> && other.failure == failure;

  @override
  int get hashCode => Object.hash(Failure, failure);

  @override
  String toString() => 'Failure($failure)';
}
