import 'app_failure.dart';

/// Resolver for custom / localized copy. Return `null` to fall back to the
/// built-in English text.
typedef FailureMessageResolver = String? Function(AppFailure failure);

/// Global configuration for [FailureMessages].
class FailureMessageConfig {
  const FailureMessageConfig._();

  /// Set once at startup, e.g. to plug in `AppLocalizations`:
  /// ```dart
  /// FailureMessageConfig.resolver = (f) => switch (f) {
  ///   NetworkFailure() => l10n.noInternet,
  ///   _ => null,
  /// };
  /// ```
  static FailureMessageResolver? resolver;
}

/// Single source of truth for user-facing copy.
/// Never show raw backend messages to end users — log them instead.
extension FailureMessages on AppFailure {
  String get userMessage {
    try {
      final custom = FailureMessageConfig.resolver?.call(this);
      if (custom != null && custom.trim().isNotEmpty) return custom;
    } catch (_) {
      // A broken resolver must never break error reporting.
    }
    return _defaultMessage;
  }

  String get _defaultMessage => switch (this) {
    NetworkFailure() =>
      'No internet connection. Please check your network and try again.',
    SecureConnectionFailure() =>
      'A secure connection could not be established. Please check your '
          'network and your device date & time.',
    TimeoutFailure() => 'The request took too long. Please try again.',
    CancelledFailure() => 'Request was cancelled.',
    UnauthorizedFailure() => 'Your session expired. Please sign in again.',
    ForbiddenFailure() => "You don't have permission to perform this action.",
    NotFoundFailure() => 'The requested item could not be found.',
    ValidationFailure(:final message) => message, // safe to surface
    ConflictFailure(:final message) => message,
    RateLimitedFailure() =>
      'Too many requests. Please wait a moment and try again.',
    ParsingFailure() => 'We received an unexpected response. Please try again.',
    LocalStorageFailure() =>
      'Could not access local data. Please restart the app.',
    ServerFailure(:final statusCode) when (statusCode ?? 500) >= 500 =>
      'Something went wrong on our end. Please try again later.',
    ServerFailure(:final message) => message, // 4xx is usually safe
    UnknownFailure() => 'Something went wrong. Please try again.',
  };
}
