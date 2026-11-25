import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:error_handling/error_handling.dart';

/// Transport-agnostic mapper. Nothing here depends on a specific HTTP client
/// except the small Dio adapter at the bottom — everything else works with
/// raw status codes + body strings so you can swap clients freely.
class ErrorMapper {
  const ErrorMapper._();

  // ---------- Exceptions ----------

  static AppFailure fromException(Object error, [StackTrace? stackTrace]) {
    // Never double-wrap — preserves original context (stack, correlationId).
    if (error is AppFailure) {
      return stackTrace != null && error.stackTrace == null
          ? error.withContext(stackTrace: stackTrace)
          : error;
    }
    if (error is SocketException) {
      return NetworkFailure(error.message, stackTrace);
    }
    if (error is TimeoutException) {
      return TimeoutFailure(
        'The request timed out after ${error.duration?.inSeconds ?? '?'}s.',
        stackTrace,
      );
    }
    if (error is FormatException || error is TypeError) {
      return ParsingFailure(
        'Received invalid data: ${error is FormatException ? error.message : 'type mismatch'}',
        stackTrace,
      );
    }
    if (error is PathNotFoundException || error is FileSystemException) {
      return LocalStorageFailure(error.toString(), stackTrace);
    }
    return UnknownFailure(
      error.toString().isEmpty
          ? 'An unexpected error occurred.'
          : error.toString(),
      stackTrace,
    );
  }

  // ---------- HTTP responses (any transport) ----------

  static AppFailure fromResponse(
    int statusCode,
    String body, {
    String? correlationId,
    StackTrace? stackTrace,
  }) {
    final parsed = _parseBody(statusCode, body);
    final message = parsed.message;
    final correlation = correlationId ?? parsed.correlationId;

    AppFailure failure = switch (statusCode) {
      401 => UnauthorizedFailure(message, stackTrace),
      403 => ForbiddenFailure(message, stackTrace),
      404 => NotFoundFailure(message, stackTrace),
      409 => ConflictFailure(message, stackTrace),
      422 => ValidationFailure(
        message,
        fieldErrors: parsed.fieldErrors,
        correlationId: correlation,
        stackTrace: stackTrace,
      ),
      >= 400 && < 500 => ServerFailure(
        message,
        statusCode: statusCode,
        stackTrace: stackTrace,
      ),
      >= 500 => ServerFailure(
        'Server error: $message',
        statusCode: statusCode,
        stackTrace: stackTrace,
      ),
      _ => UnknownFailure(message, stackTrace),
    };

    if (correlation != null) {
      failure = failure.withContext(correlationId: correlation);
    }
    return failure;
  }

  // ---------- Dio adapter ----------

  static AppFailure fromDio(DioException e) {
    final stack = e.stackTrace;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return TimeoutFailure(
          'The request timed out. Please try again.',
          stack,
        );
      case DioExceptionType.connectionError:
        return NetworkFailure(
          'No internet connection. Please check your network.',
          stack,
        );
      case DioExceptionType.cancel:
        return CancelledFailure('Request was cancelled.', stack);
      case DioExceptionType.badResponse:
        final res = e.response;
        if (res == null) {
          return UnknownFailure(e.message ?? 'Bad response', stack);
        }
        return fromResponse(
          res.statusCode ?? 0,
          res.data is String ? res.data as String : jsonEncode(res.data),
          correlationId: res.headers.value('x-correlation-id'),
          stackTrace: stack,
        );
      case DioExceptionType.badCertificate:
        return NetworkFailure('Secure connection failed.', stack);
      case DioExceptionType.unknown:
        final inner = e.error;
        if (inner is SocketException) {
          return NetworkFailure(inner.message, stack);
        }
        if (inner is TimeoutException) {
          return TimeoutFailure(inner.toString(), stack);
        }
        return UnknownFailure(e.message ?? 'Unknown network error', stack);
      case DioExceptionType.transformTimeout:
        throw UnimplementedError();
    }
  }

  // ---------- Body parsing ----------

  static _ParsedBody _parseBody(int status, String body) {
    String message = 'Something went wrong (Code: $status)';
    Map<String, List<String>>? fieldErrors;
    String? correlationId;

    if (body.isEmpty) return _ParsedBody(message);

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        message = _extractMessage(decoded) ?? message;
        correlationId = decoded['correlationId']?.toString();
        fieldErrors = _extractFieldErrors(decoded);
      }
    } catch (_) {
      // Non-JSON body. For 4xx, short text is often useful; for 5xx, hide it.
      final trimmed = body.trim();
      if (status >= 400 && status < 500 && trimmed.length < 200) {
        message = trimmed;
      }
    }
    return _ParsedBody(
      message,
      fieldErrors: fieldErrors,
      correlationId: correlationId,
    );
  }

  static String? _extractMessage(Map<String, dynamic> m) {
    for (final key in const ['message', 'error', 'detail', 'title', 'reason']) {
      final v = m[key];
      if (v is String && v.isNotEmpty) return v;
      if (v != null) return v.toString();
    }
    return null;
  }

  static Map<String, List<String>>? _extractFieldErrors(
    Map<String, dynamic> m,
  ) {
    final raw = m['errors'] ?? m['details'] ?? m['fieldErrors'];
    if (raw is! Map) return null;
    final out = <String, List<String>>{};
    raw.forEach((k, v) {
      if (v is List) {
        out[k.toString()] = v.map((e) => e.toString()).toList();
      } else if (v != null) {
        out[k.toString()] = [v.toString()];
      }
    });
    return out.isEmpty ? null : out;
  }
}

class _ParsedBody {
  final String message;
  final Map<String, List<String>>? fieldErrors;
  final String? correlationId;
  const _ParsedBody(this.message, {this.fieldErrors, this.correlationId});
}
