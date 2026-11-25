import 'app_failure.dart';

/// Single source of truth for user-facing copy.
/// Never show raw backend messages to end users — log them instead.
extension FailureMessages on AppFailure {
  String get userMessage => switch (this) {
    NetworkFailure() =>
      'No internet connection. Please check your network and try again.',
    TimeoutFailure() => 'The request took too long. Please try again.',
    CancelledFailure() => 'Request was cancelled.',
    UnauthorizedFailure() => 'Your session expired. Please sign in again.',
    ForbiddenFailure() => "You don't have permission to perform this action.",
    NotFoundFailure() => 'The requested item could not be found.',
    ValidationFailure(:final message) => message, // safe to surface
    ConflictFailure(:final message) => message,
    ParsingFailure() => 'We received an unexpected response. Please try again.',
    LocalStorageFailure() =>
      'Could not access local data. Please restart the app.',
    ServerFailure(:final statusCode) when (statusCode ?? 500) >= 500 =>
      'Something went wrong on our end. Please try again later.',
    ServerFailure(:final message) => message, // 4xx is usually safe
    UnknownFailure() => 'Something went wrong. Please try again.',
  };
}
