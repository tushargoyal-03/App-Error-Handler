import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../mapping/error_mapper.dart';

/// Builds a pre-configured [Dio] instance with:
///
/// * **Correlation IDs** — every request carries `x-correlation-id`, matching
///   the header the backend should echo on errors (so client and server logs
///   line up). A retried request keeps the *same* id.
/// * **Split timeouts** — connect / send / receive are independent, so a slow
///   server doesn't look like a dead network.
/// * **Bearer auth** — injectable token provider; called per request so it
///   always sees the latest token. An explicit `Authorization` header on a
///   request is never overwritten (e.g. refresh-token calls).
/// * **Automatic retry** — exponential backoff + jitter for idempotent
///   requests (GET/HEAD/OPTIONS by default) that fail with a transient error
///   (timeout, connection error, 408/502/503/504).
/// * **Typed exceptions preserved** — errors are surfaced as [DioException]
///   unchanged; use `ErrorMapper.fromDio` (or `ApiClient`) to convert them.
class DioFactory {
  const DioFactory._();

  static const _uuid = Uuid();
  static final _random = Random();
  static const _retryKey = '__error_handling_retry_attempt__';

  /// Creates a configured [Dio] client.
  ///
  /// ```dart
  /// final dio = DioFactory.create(
  ///   baseUrl: 'https://api.example.com',
  ///   getToken: () async => SecureStorage.read('access_token'),
  /// );
  /// ```
  static Dio create({
    required String baseUrl,
    Future<String?> Function()? getToken,

    /// Connect-phase timeout (DNS + TCP + TLS).
    Duration connectTimeout = const Duration(seconds: 10),

    /// How long to wait for the response (between chunks).
    Duration receiveTimeout = const Duration(seconds: 20),

    /// How long the socket can stall while uploading the request body.
    Duration sendTimeout = const Duration(seconds: 20),

    /// Header name used for correlation IDs. Must match the backend.
    String correlationHeader = ErrorMapper.correlationHeader,

    /// Whether to auto-retry idempotent requests on transient failures.
    bool enableRetry = true,

    /// How many times a failed request is retried (after the first attempt).
    int maxRetries = 1,

    /// Base delay before the first retry; doubled per attempt (+ up to 25 %
    /// random jitter so clients don't retry in lockstep).
    Duration retryDelay = const Duration(milliseconds: 500),

    /// HTTP methods that may be retried safely. Add 'PUT'/'DELETE' only if
    /// your endpoints are truly idempotent.
    Set<String> retryMethods = const {'GET', 'HEAD', 'OPTIONS'},

    /// HTTP statuses that count as transient.
    Set<int> retryStatusCodes = const {408, 502, 503, 504},

    /// Optional callback invoked whenever a request is retried — useful for
    /// metrics or debugging.
    void Function(RequestOptions request)? onRetry,

    /// Optional additional interceptors appended after the built-in ones.
    List<Interceptor> interceptors = const [],
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        responseType: ResponseType.json,
        // Let non-2xx responses through as DioException.badResponse so the
        // mapper can read the error body.
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // Attach correlation ID (fresh per request, kept across retries).
          if (!options.headers.containsKey(correlationHeader)) {
            options.headers[correlationHeader] = _uuid.v4();
          }

          // Attach bearer token if a provider is supplied and the caller
          // did not set Authorization explicitly.
          if (getToken != null && !options.headers.containsKey('Authorization')) {
            try {
              final token = await getToken();
              if (token != null && token.isNotEmpty) {
                options.headers['Authorization'] = 'Bearer $token';
              }
            } catch (_) {
              // Token provider failed — proceed unauthenticated; the server
              // will return 401 and the mapper will surface UnauthorizedFailure.
            }
          }

          handler.next(options);
        },
        onError: (error, handler) async {
          if (!enableRetry) return handler.next(error);

          final request = error.requestOptions;

          if (!retryMethods.contains(request.method.toUpperCase())) {
            return handler.next(error);
          }

          final attempt = (request.extra[_retryKey] as int?) ?? 0;
          if (attempt >= maxRetries) return handler.next(error);

          if (!_isTransient(error, retryStatusCodes)) {
            return handler.next(error);
          }

          onRetry?.call(request);

          await Future<void>.delayed(_backoff(retryDelay, attempt));

          try {
            final response = await dio.fetch<dynamic>(
              request.copyWith(
                extra: {...request.extra, _retryKey: attempt + 1},
              ),
            );
            return handler.resolve(response);
          } on DioException catch (e) {
            // The nested call already exhausted its own retries; surface the
            // most recent error.
            return handler.next(e);
          } catch (_) {
            return handler.next(error);
          }
        },
      ),
    );

    if (interceptors.isNotEmpty) {
      dio.interceptors.addAll(interceptors);
    }

    return dio;
  }

  static bool _isTransient(DioException error, Set<int> retryStatusCodes) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        return retryStatusCodes.contains(error.response?.statusCode);
      case DioExceptionType.unknown:
        return error.error is SocketException;
      default:
        return false;
    }
  }

  static Duration _backoff(Duration base, int attempt) {
    if (base <= Duration.zero) return Duration.zero;
    final ms = base.inMilliseconds * (1 << attempt);
    return Duration(milliseconds: ms + _random.nextInt((ms ~/ 4) + 1));
  }
}
