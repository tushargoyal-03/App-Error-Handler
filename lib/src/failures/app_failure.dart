import 'package:meta/meta.dart';

/// Every failure the app can surface. Sealed → exhaustive switch everywhere.
@immutable
sealed class AppFailure {
  final String message;
  final int? statusCode;
  final StackTrace? stackTrace;
  final String? correlationId;
  final Map<String, List<String>>? fieldErrors;

  const AppFailure(
    this.message, {
    this.statusCode,
    this.stackTrace,
    this.correlationId,
    this.fieldErrors,
  });

  /// Copy-with for enriching a failure after the fact (e.g. attach stack).
  AppFailure withContext({StackTrace? stackTrace, String? correlationId});

  @override
  String toString() =>
      '$runtimeType(status: $statusCode, corr: $correlationId): $message';
}

// ---------- Network & transport ----------

final class NetworkFailure extends AppFailure {
  const NetworkFailure([
    super.message = 'No internet connection. Please check your network.',
    StackTrace? stackTrace,
  ]) : super(statusCode: null, correlationId: null, fieldErrors: null);

  @override
  NetworkFailure withContext({StackTrace? stackTrace, String? correlationId}) =>
      NetworkFailure(message, stackTrace ?? this.stackTrace);
}

final class TimeoutFailure extends AppFailure {
  const TimeoutFailure([
    super.message = 'The request timed out. Please try again.',
    StackTrace? stackTrace,
  ]) : super(statusCode: null, correlationId: null, fieldErrors: null);

  @override
  TimeoutFailure withContext({StackTrace? stackTrace, String? correlationId}) =>
      TimeoutFailure(message, stackTrace ?? this.stackTrace);
}

final class CancelledFailure extends AppFailure {
  const CancelledFailure([
    super.message = 'Request was cancelled.',
    StackTrace? stackTrace,
  ]) : super(statusCode: null, correlationId: null, fieldErrors: null);

  @override
  CancelledFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => CancelledFailure(message, stackTrace ?? this.stackTrace);
}

// ---------- HTTP status failures ----------

final class ServerFailure extends AppFailure {
  const ServerFailure(
    super.message, {
    super.statusCode,
    super.stackTrace,
    super.correlationId,
    super.fieldErrors,
  });

  @override
  ServerFailure withContext({StackTrace? stackTrace, String? correlationId}) =>
      ServerFailure(
        message,
        statusCode: statusCode,
        stackTrace: stackTrace ?? this.stackTrace,
        correlationId: correlationId ?? this.correlationId,
        fieldErrors: fieldErrors,
      );
}

final class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure([
    super.message = 'Session expired. Please log in again.',
    StackTrace? stackTrace,
  ]) : super(statusCode: 401, correlationId: null, fieldErrors: null);

  @override
  UnauthorizedFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => UnauthorizedFailure(message, stackTrace ?? this.stackTrace);
}

final class ForbiddenFailure extends AppFailure {
  const ForbiddenFailure([
    super.message = "You don't have permission to do that.",
    StackTrace? stackTrace,
  ]) : super(statusCode: 403, correlationId: null, fieldErrors: null);

  @override
  ForbiddenFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => ForbiddenFailure(message, stackTrace ?? this.stackTrace);
}

final class NotFoundFailure extends AppFailure {
  const NotFoundFailure([
    super.message = 'The requested resource was not found.',
    StackTrace? stackTrace,
  ]) : super(statusCode: 404, correlationId: null, fieldErrors: null);

  @override
  NotFoundFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => NotFoundFailure(message, stackTrace ?? this.stackTrace);
}

final class ValidationFailure extends AppFailure {
  const ValidationFailure(
    super.message, {
    super.fieldErrors,
    super.correlationId,
    super.stackTrace,
  }) : super(statusCode: 422);

  @override
  ValidationFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => ValidationFailure(
    message,
    fieldErrors: fieldErrors,
    correlationId: correlationId ?? this.correlationId,
    stackTrace: stackTrace ?? this.stackTrace,
  );
}

final class ConflictFailure extends AppFailure {
  const ConflictFailure([
    super.message = 'This action conflicts with existing data.',
    StackTrace? stackTrace,
  ]) : super(statusCode: 409, correlationId: null, fieldErrors: null);

  @override
  ConflictFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => ConflictFailure(message, stackTrace ?? this.stackTrace);
}

// ---------- Local / parsing / unknown ----------

final class ParsingFailure extends AppFailure {
  const ParsingFailure([
    super.message = 'Received invalid data from the server.',
    StackTrace? stackTrace,
  ]) : super(statusCode: null, correlationId: null, fieldErrors: null);

  @override
  ParsingFailure withContext({StackTrace? stackTrace, String? correlationId}) =>
      ParsingFailure(message, stackTrace ?? this.stackTrace);
}

final class LocalStorageFailure extends AppFailure {
  const LocalStorageFailure([
    super.message = 'Could not read or save local data.',
    StackTrace? stackTrace,
  ]) : super(statusCode: null, correlationId: null, fieldErrors: null);

  @override
  LocalStorageFailure withContext({
    StackTrace? stackTrace,
    String? correlationId,
  }) => LocalStorageFailure(message, stackTrace ?? this.stackTrace);
}

final class UnknownFailure extends AppFailure {
  const UnknownFailure([
    super.message = 'An unexpected error occurred.',
    StackTrace? stackTrace,
  ]) : super(statusCode: null, correlationId: null, fieldErrors: null);

  @override
  UnknownFailure withContext({StackTrace? stackTrace, String? correlationId}) =>
      UnknownFailure(message, stackTrace ?? this.stackTrace);
}
