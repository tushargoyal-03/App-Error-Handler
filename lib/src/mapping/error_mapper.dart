import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../failures/app_failure.dart';

/// Transport-agnostic mapper. Nothing here depends on a specific HTTP client
/// except the small Dio adapter ([fromDio]) — everything else works with raw
/// status codes + bodies so you can swap clients freely.
///
/// **Contract: no method in this class ever throws.**
class ErrorMapper {
  const ErrorMapper._();

  /// Header carrying the correlation id (request and response).
  static const String correlationHeader = 'x-correlation-id';

  // ---------- Universal entry point ----------

  /// Converts *anything* thrown into an [AppFailure].
  static AppFailure from(Object error, [StackTrace? stackTrace]) {
    try {
      if (error is AppFailure) return _attach(error, stackTrace);
      if (error is DioException) return fromDio(error);
      return fromException(error, stackTrace);
    } catch (_) {
      return UnknownFailure('An unexpected error occurred.', stackTrace);
    }
  }

  // ---------- Exceptions ----------

  static AppFailure fromException(Object error, [StackTrace? stackTrace]) {
    // Never double-wrap — preserves original context (stack, correlationId).
    if (error is AppFailure) return _attach(error, stackTrace);
    if (error is DioException) return fromDio(error);

    final AppFailure failure;
    if (error is TlsException) {
      // HandshakeException is a TlsException.
      failure = SecureConnectionFailure('Secure connection failed.', stackTrace);
    } else if (error is SocketException) {
      failure = NetworkFailure(
        _orDefault(error.message, 'Network error.'),
        stackTrace,
      );
    } else if (error is HttpException || error is WebSocketException) {
      failure = NetworkFailure(safeToString(error), stackTrace);
    } else if (error is TimeoutException) {
      final d = error.duration;
      failure = TimeoutFailure(
        d == null
            ? 'The request timed out.'
            : 'The request timed out after ${d.inSeconds}s.',
        stackTrace,
      );
    } else if (error is FormatException) {
      failure = ParsingFailure(
        'Received invalid data: ${error.message}',
        stackTrace,
      );
    } else if (error is FileSystemException) {
      // Includes PathNotFoundException.
      failure = LocalStorageFailure(safeToString(error), stackTrace);
    } else {
      // NOTE: TypeError is deliberately *not* mapped to ParsingFailure — a
      // TypeError is a programmer bug and must not tell the user "the server
      // sent bad data". ApiClient converts parser errors itself.
      failure = UnknownFailure(
        _orDefault(safeToString(error), 'An unexpected error occurred.'),
        stackTrace,
      );
    }
    return failure.withContext(cause: error);
  }

  // ---------- HTTP responses (any transport) ----------

  /// [body] may be the raw `String`, an already-decoded `Map`/`List`, or null.
  static AppFailure fromResponse(
    int statusCode,
    Object? body, {
    String? correlationId,
    StackTrace? stackTrace,
    Duration? retryAfter,
  }) {
    try {
      final parsed = _parseBody(statusCode, body);
      final message = parsed.message;
      final correlation = correlationId ?? parsed.correlationId;

      final AppFailure failure = switch (statusCode) {
        400 when parsed.messageWasList || parsed.fieldErrors != null =>
          ValidationFailure(
            message,
            statusCode: 400,
            fieldErrors: parsed.fieldErrors,
            stackTrace: stackTrace,
          ),
        401 => UnauthorizedFailure(message, stackTrace),
        403 => ForbiddenFailure(message, stackTrace),
        404 => NotFoundFailure(message, stackTrace),
        409 => ConflictFailure(message, stackTrace),
        422 => ValidationFailure(
          message,
          fieldErrors: parsed.fieldErrors,
          stackTrace: stackTrace,
        ),
        429 => RateLimitedFailure(message, stackTrace, retryAfter),
        >= 400 && < 600 => ServerFailure(
          message,
          statusCode: statusCode,
          fieldErrors: parsed.fieldErrors,
          stackTrace: stackTrace,
        ),
        _ => UnknownFailure(message, stackTrace),
      };

      return correlation == null
          ? failure
          : failure.withContext(correlationId: correlation);
    } catch (_) {
      return ServerFailure(
        'Something went wrong (Code: $statusCode)',
        statusCode: statusCode,
        stackTrace: stackTrace,
        correlationId: correlationId,
      );
    }
  }

  // ---------- Dio adapter ----------

  static AppFailure fromDio(DioException e) {
    try {
      var failure = _fromDioType(e);
      // Even client-side failures (timeouts, no network) get the id we sent,
      // so they can be matched against server logs.
      if (failure.correlationId == null) {
        final sent = e.requestOptions.headers[correlationHeader]?.toString();
        if (sent != null && sent.isNotEmpty) {
          failure = failure.withContext(correlationId: sent);
        }
      }
      return failure.cause == null ? failure.withContext(cause: e) : failure;
    } catch (_) {
      return UnknownFailure('Unknown network error', e.stackTrace);
    }
  }

  static AppFailure _fromDioType(DioException e) {
    final stack = e.stackTrace;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return TimeoutFailure('The request timed out. Please try again.', stack);
      case DioExceptionType.connectionError:
        return NetworkFailure(
          'No internet connection. Please check your network.',
          stack,
        );
      case DioExceptionType.cancel:
        return CancelledFailure('Request was cancelled.', stack);
      case DioExceptionType.badCertificate:
        return SecureConnectionFailure('Secure connection failed.', stack);
      case DioExceptionType.badResponse:
        final res = e.response;
        if (res == null) {
          return UnknownFailure(e.message ?? 'Bad response', stack);
        }
        return fromResponse(
          res.statusCode ?? 0,
          res.data,
          correlationId: _header(res.headers, correlationHeader),
          retryAfter: _parseRetryAfter(_header(res.headers, 'retry-after')),
          stackTrace: stack,
        );
      case DioExceptionType.unknown:
      default:
        // `default` also covers enum values added by newer Dio versions.
        final inner = e.error;
        // An interceptor may have thrown an AppFailure — keep it.
        if (inner is AppFailure) return inner;
        if (inner != null && inner is! DioException) {
          return fromException(inner, stack);
        }
        return UnknownFailure(e.message ?? 'Unknown network error', stack);
    }
  }

  // ---------- Helpers ----------

  /// `toString()` that can never throw.
  static String safeToString(Object? o) {
    try {
      return o.toString();
    } catch (_) {
      return o.runtimeType.toString();
    }
  }

  static AppFailure _attach(AppFailure f, StackTrace? st) =>
      (st != null && f.stackTrace == null) ? f.withContext(stackTrace: st) : f;

  static String _orDefault(String s, String fallback) =>
      s.trim().isEmpty ? fallback : s;

  static String? _header(Headers headers, String name) {
    try {
      return headers.value(name);
    } catch (_) {
      final all = headers[name];
      return (all == null || all.isEmpty) ? null : all.first;
    }
  }

  /// Only the "delay-seconds" form is supported (HTTP-date is ignored).
  static Duration? _parseRetryAfter(String? v) {
    final seconds = int.tryParse(v?.trim() ?? '');
    return (seconds == null || seconds < 0) ? null : Duration(seconds: seconds);
  }

  // ---------- Body parsing ----------

  static _ParsedBody _parseBody(int status, Object? body) {
    final fallback = 'Something went wrong (Code: $status)';
    Object? decoded = body;
    String? text;

    if (body is String) {
      final trimmed = body.trim();
      if (trimmed.isEmpty) return _ParsedBody(fallback);
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        decoded = null;
        text = trimmed;
      }
      if (decoded is String) {
        text = decoded;
        decoded = null;
      }
    }

    if (decoded is Map) {
      final map = _stringKeyed(decoded);
      final extracted = _extractMessage(map);
      return _ParsedBody(
        extracted?.text ?? fallback,
        fieldErrors: _extractFieldErrors(map),
        correlationId: (map['correlationId'] ?? map['correlation_id'])
            ?.toString(),
        messageWasList: extracted?.isList ?? false,
      );
    }

    // Plain-text body. For 4xx short text is often useful; never show HTML
    // error pages (nginx/CDN) or 5xx internals.
    if (text != null &&
        status >= 400 &&
        status < 500 &&
        text.length < 200 &&
        !text.startsWith('<')) {
      return _ParsedBody(text);
    }
    return _ParsedBody(fallback);
  }

  static Map<String, dynamic> _stringKeyed(Map<dynamic, dynamic> m) =>
      m.map<String, dynamic>((k, v) => MapEntry(k.toString(), v));

  /// Understands `{message: "x"}`, `{message: ["a","b"]}` (NestJS validation),
  /// `{error: {message: "x"}}` and skips empty values.
  static ({String text, bool isList})? _extractMessage(
    Map<String, dynamic> m,
  ) {
    for (final key in const [
      'message',
      'error',
      'detail',
      'title',
      'reason',
      'error_description',
    ]) {
      final r = _stringify(m[key]);
      if (r != null) return r;
    }
    return null;
  }

  static ({String text, bool isList})? _stringify(Object? v) {
    if (v is String) {
      final t = v.trim();
      return t.isEmpty ? null : (text: t, isList: false);
    }
    if (v is List) {
      final parts = <String>[];
      for (final e in v) {
        final String? s = e is Map
            ? _extractMessage(_stringKeyed(e))?.text
            : e?.toString();
        if (s != null && s.trim().isNotEmpty) parts.add(s.trim());
      }
      return parts.isEmpty ? null : (text: parts.join('\n'), isList: true);
    }
    if (v is Map) return _extractMessage(_stringKeyed(v));
    return null; // numbers / bools / null are not messages
  }

  /// Understands `{errors: {field: [..]}}` and class-validator style
  /// `{errors: [{property, constraints: {..}}]}`.
  static Map<String, List<String>>? _extractFieldErrors(
    Map<String, dynamic> m,
  ) {
    final raw = m['errors'] ?? m['details'] ?? m['fieldErrors'];
    final out = <String, List<String>>{};

    if (raw is Map) {
      raw.forEach((k, v) {
        final msgs = _toStringList(v);
        if (msgs.isNotEmpty) out[k.toString()] = msgs;
      });
    } else if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final it = _stringKeyed(item);
        final field = (it['property'] ?? it['field'] ?? it['path'])?.toString();
        if (field == null || field.isEmpty) continue;
        final msgs = <String>[
          ..._toStringList(it['constraints']),
          ..._toStringList(it['messages']),
          ..._toStringList(it['message']),
        ];
        if (msgs.isNotEmpty) (out[field] ??= <String>[]).addAll(msgs);
      }
    }
    return out.isEmpty ? null : out;
  }

  static List<String> _toStringList(Object? v) {
    if (v == null) return const <String>[];
    final Iterable<Object?> items = v is Map
        ? v.values
        : v is List
        ? v
        : [v];
    return items
        .where((e) => e != null)
        .map((e) => e.toString())
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }
}

class _ParsedBody {
  final String message;
  final Map<String, List<String>>? fieldErrors;
  final String? correlationId;
  final bool messageWasList;
  const _ParsedBody(
    this.message, {
    this.fieldErrors,
    this.correlationId,
    this.messageWasList = false,
  });
}
