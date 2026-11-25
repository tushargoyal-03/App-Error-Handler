import 'package:meta/meta.dart';

/// Every failure the app can surface. Sealed → exhaustive switch everywhere.
///
/// Implements [Exception] so it can be thrown / caught without lint noise
/// (see `Result.getOrThrow`).
@immutable
sealed class AppFailure implements Exception {
  /// Developer-facing message (may contain raw backend text). Never show it
  /// directly to end users — use `failure.userMessage` instead.
  final String message;
  final int? statusCode;
  final StackTrace? stackTrace;
  final String? correlationId;
  final Map<String, List<String>>? fieldErrors;

  /// The original exception that caused this failure (for Sentry/Crashlytics).
  final Object? cause;

  const AppFailure(
    this.message, {
    this.statusCode,
    this.stackTrace,
    this.correlationId,
    this.fieldErrors,
    this.cause,
  });

  /// Rebuilds this failure with the same type/message but extra context.
  /// Values passed here win over the existing ones; `null` keeps the old one.
  @protected
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  });

  /// Enrich a failure after the fact (attach stack, correlation id, cause).
  AppFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => copyWithContext(
    stackTrace: stackTrace ?? this.stackTrace,
    correlationId: correlationId ?? this.correlationId,
    cause: cause ?? this.cause,
  );

  /// Whether retrying the same request could plausibly succeed.
  bool get isRetryable => switch (this) {
    NetworkFailure() || TimeoutFailure() || RateLimitedFailure() => true,
    ServerFailure(:final statusCode) => (statusCode ?? 0) >= 500,
    _ => false,
  };

  /// Value equality (stack trace and cause are intentionally ignored) so
  /// failures behave correctly inside Bloc/Cubit states.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppFailure &&
          other.runtimeType == runtimeType &&
          other.message == message &&
          other.statusCode == statusCode &&
          other.correlationId == correlationId &&
          _fieldErrorsEqual(other.fieldErrors, fieldErrors));

  @override
  int get hashCode {
    final fe = fieldErrors;
    return Object.hash(
      runtimeType,
      message,
      statusCode,
      correlationId,
      fe == null
          ? null
          : Object.hashAllUnordered(
              fe.entries.map((e) => Object.hash(e.key, Object.hashAll(e.value))),
            ),
    );
  }

  @override
  String toString() =>
      '$runtimeType(status: $statusCode, corr: $correlationId): $message';
}

bool _fieldErrorsEqual(
  Map<String, List<String>>? a,
  Map<String, List<String>>? b,
) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (final e in a.entries) {
    final other = b[e.key];
    if (other == null || other.length != e.value.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (other[i] != e.value[i]) return false;
    }
  }
  return true;
}

// ---------- Network & transport ----------

final class NetworkFailure extends AppFailure {
  const NetworkFailure([
    String message = 'No internet connection. Please check your network.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const NetworkFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => NetworkFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

/// TLS / certificate problems — distinct from "no internet" so users get a
/// useful message (wrong device date, captive portal, MITM proxy...).
final class SecureConnectionFailure extends AppFailure {
  const SecureConnectionFailure([
    String message = 'A secure connection could not be established.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const SecureConnectionFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => SecureConnectionFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

final class TimeoutFailure extends AppFailure {
  const TimeoutFailure([
    String message = 'The request timed out. Please try again.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const TimeoutFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => TimeoutFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

final class CancelledFailure extends AppFailure {
  const CancelledFailure([
    String message = 'Request was cancelled.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const CancelledFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => CancelledFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

// ---------- HTTP status failures ----------

/// Generic HTTP failure: any 5xx, and any 4xx without a dedicated type.
final class ServerFailure extends AppFailure {
  const ServerFailure(
    super.message, {
    super.statusCode,
    super.stackTrace,
    super.correlationId,
    super.fieldErrors,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => ServerFailure(
    message,
    statusCode: statusCode,
    stackTrace: stackTrace,
    correlationId: correlationId,
    fieldErrors: fieldErrors,
    cause: cause,
  );
}

final class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure([
    String message = 'Session expired. Please log in again.',
    StackTrace? stackTrace,
  ]) : super(message, statusCode: 401, stackTrace: stackTrace);

  const UnauthorizedFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  }) : super(statusCode: 401);

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => UnauthorizedFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

final class ForbiddenFailure extends AppFailure {
  const ForbiddenFailure([
    String message = "You don't have permission to do that.",
    StackTrace? stackTrace,
  ]) : super(message, statusCode: 403, stackTrace: stackTrace);

  const ForbiddenFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  }) : super(statusCode: 403);

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => ForbiddenFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

final class NotFoundFailure extends AppFailure {
  const NotFoundFailure([
    String message = 'The requested resource was not found.',
    StackTrace? stackTrace,
  ]) : super(message, statusCode: 404, stackTrace: stackTrace);

  const NotFoundFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  }) : super(statusCode: 404);

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => NotFoundFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

/// 422, or a 400 that carries validation messages (NestJS class-validator).
final class ValidationFailure extends AppFailure {
  const ValidationFailure(
    super.message, {
    super.statusCode = 422,
    super.fieldErrors,
    super.correlationId,
    super.stackTrace,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => ValidationFailure(
    message,
    statusCode: statusCode,
    fieldErrors: fieldErrors,
    correlationId: correlationId,
    stackTrace: stackTrace,
    cause: cause,
  );
}

final class ConflictFailure extends AppFailure {
  const ConflictFailure([
    String message = 'This action conflicts with existing data.',
    StackTrace? stackTrace,
  ]) : super(message, statusCode: 409, stackTrace: stackTrace);

  const ConflictFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  }) : super(statusCode: 409);

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => ConflictFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

/// 429 Too Many Requests. [retryAfter] is read from the `Retry-After` header.
final class RateLimitedFailure extends AppFailure {
  final Duration? retryAfter;

  const RateLimitedFailure([
    String message = 'Too many requests. Please try again later.',
    StackTrace? stackTrace,
    this.retryAfter,
  ]) : super(message, statusCode: 429, stackTrace: stackTrace);

  const RateLimitedFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
    this.retryAfter,
  }) : super(statusCode: 429);

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => RateLimitedFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
    retryAfter: retryAfter,
  );
}

// ---------- Local / parsing / unknown ----------

final class ParsingFailure extends AppFailure {
  const ParsingFailure([
    String message = 'Received invalid data from the server.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const ParsingFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => ParsingFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

final class LocalStorageFailure extends AppFailure {
  const LocalStorageFailure([
    String message = 'Could not read or save local data.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const LocalStorageFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => LocalStorageFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}

final class UnknownFailure extends AppFailure {
  const UnknownFailure([
    String message = 'An unexpected error occurred.',
    StackTrace? stackTrace,
  ]) : super(message, stackTrace: stackTrace);

  const UnknownFailure._full(
    super.message, {
    super.stackTrace,
    super.correlationId,
    super.cause,
  });

  @override
  AppFailure copyWithContext({
    StackTrace? stackTrace,
    String? correlationId,
    Object? cause,
  }) => UnknownFailure._full(
    message,
    stackTrace: stackTrace,
    correlationId: correlationId,
    cause: cause,
  );
}
