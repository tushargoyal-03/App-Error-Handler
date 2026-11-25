import 'package:flutter/foundation.dart';

import '../failures/app_failure.dart';
import '../failures/failure_messages.dart';
import '../mapping/error_mapper.dart';

/// Signature for a log sink (Crashlytics, Sentry, custom logger).
typedef FailureLogger = Future<void> Function(AppFailure failure);

/// Signature for a global onFailure callback (e.g. show a SnackBar).
typedef FailureListener = void Function(AppFailure failure, String userMessage);

/// Central place where every error ends up: mapped → de-duplicated → logged →
/// surfaced. **[handle] never throws**, so it is safe inside global hooks.
class ErrorHandler {
  final FailureLogger? logger;
  final FailureListener? onFailure;

  /// Failures for which this returns `true` are neither logged nor surfaced.
  /// Defaults to ignoring [CancelledFailure] (user navigated away, etc.).
  final bool Function(AppFailure failure)? shouldIgnore;

  /// The same error object reported again within this window is dropped
  /// (Flutter reports many errors twice: framework hook + zone).
  final Duration dedupeWindow;

  const ErrorHandler({
    this.logger,
    this.onFailure,
    this.shouldIgnore,
    this.dedupeWindow = const Duration(seconds: 1),
  });

  static Object? _lastError;
  static DateTime? _lastAt;

  // ---------- INSTANCE ----------

  /// Maps, logs and surfaces [error]; returns the resulting failure.
  Future<AppFailure> handle(Object error, [StackTrace? stackTrace]) async {
    final AppFailure failure = ErrorMapper.from(error, stackTrace);
    try {
      if (_isIgnored(failure) || _isDuplicate(error)) return failure;

      if (!kReleaseMode) {
        debugPrint('[Failure] $failure');
        if (failure.stackTrace != null) {
          debugPrintStack(stackTrace: failure.stackTrace);
        }
      }

      try {
        await logger?.call(failure);
      } catch (e) {
        if (!kReleaseMode) debugPrint('[ErrorHandler] logger threw: $e');
      }

      try {
        onFailure?.call(failure, failure.userMessage);
      } catch (e) {
        if (!kReleaseMode) debugPrint('[ErrorHandler] onFailure threw: $e');
      }
    } catch (_) {
      // Last line of defence: an error handler must not raise errors.
    }
    return failure;
  }

  bool _isIgnored(AppFailure failure) =>
      (shouldIgnore ?? (f) => f is CancelledFailure)(failure);

  bool _isDuplicate(Object error) {
    final now = DateTime.now();
    final last = _lastAt;
    final dup =
        identical(_lastError, error) &&
        last != null &&
        now.difference(last) < dedupeWindow;
    _lastError = error;
    _lastAt = now;
    return dup;
  }

  // ---------- STATIC ----------

  /// Human-readable one-liner for any thrown object — safe to log,
  /// safe to drop into a Failure message. Never throws.
  static String format(Object error) {
    try {
      if (error is AppFailure) {
        return error.message.isEmpty
            ? error.runtimeType.toString()
            : error.message;
      }
      final type = error.runtimeType.toString();
      final raw = ErrorMapper.safeToString(error);
      if (error is Exception) {
        // Best-effort: strip "Exception: " prefix and trailing "(OS Error…)".
        final stripped = raw
            .replaceFirst(RegExp(r'^(Exception|Error):\s*'), '')
            .replaceFirst(RegExp(r'\s*\(.*?\)\s*$'), '')
            .trim();
        return stripped.isEmpty ? type : stripped;
      }
      return raw.isEmpty ? 'Unknown error' : raw;
    } catch (_) {
      return 'Unknown error';
    }
  }
}
