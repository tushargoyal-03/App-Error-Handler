import 'package:error_handling/error_handling.dart';
import 'package:flutter/foundation.dart';

class ErrorHandler {
  final Future<void> Function(AppFailure)? logger;
  final void Function(AppFailure, String)? onFailure;

  const ErrorHandler({this.logger, this.onFailure});

  // ---------- INSTANCE (existing) ----------
  Future<void> handle(Object error, [StackTrace? stackTrace]) async {
    final failure = _toFailure(error, stackTrace);
    debugPrint('[Failure] $failure');
    if (!kReleaseMode && failure.stackTrace != null) {
      debugPrintStack(stackTrace: failure.stackTrace);
    }
    try {
      await logger?.call(failure);
    } catch (_) {}
    onFailure?.call(failure, failure.userMessage);
  }

  // ---------- STATIC (new) ----------

  /// Human-readable one-liner for any thrown object — safe to log,
  /// safe to drop into a Failure message. Never throws.
  static String format(Object error) {
    // If it's already a Failure, use its message (but skip raw 500s).
    if (error is AppFailure) {
      return error.message.isEmpty
          ? error.runtimeType.toString()
          : error.message;
    }
    // Recognise common Dart networking exceptions by type first...
    final type = error.runtimeType.toString();
    if (error is Exception) {
      // Best-effort: strip "Exception: " prefix and verbose toString noise.
      final raw = error.toString();
      final stripped = raw
          .replaceFirst(RegExp(r'^(Exception|Error):\s*'), '')
          .replaceFirst(RegExp(r'\s*\(.*?\)\s*$'), '') // drop trailing "(...)"
          .trim();
      return stripped.isEmpty ? type : stripped;
    }
    // Anything else (String, null, custom object) → safe string
    final s = error.toString();
    return s.isEmpty ? 'Unknown error' : s;
  }

  // ---------- INTERNAL ----------

  static AppFailure _toFailure(Object error, StackTrace? stackTrace) {
    if (error is AppFailure) {
      return stackTrace != null && error.stackTrace == null
          ? error.withContext(stackTrace: stackTrace)
          : error;
    }
    return UnknownFailure(format(error), stackTrace);
  }
}
