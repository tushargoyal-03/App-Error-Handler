import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Builds a pre-configured [Dio] instance with:
///
/// * **Correlation IDs** — every request carries `x-correlation-id`, matching
///   the header the backend should echo on errors (so client and server logs
///   line up).
/// * **Split timeouts** — connect / send / receive are independent, so a slow
///   server doesn't look like a dead network.
/// * **Bearer auth** — injectable token provider; called per request so it
///   always sees the latest token.
/// * **Automatic retry** — one retry with backoff for idempotent (GET/HEAD)
///   requests that fail with a transient error (timeout, connection error,
///   5xx).
/// * **Typed exceptions preserved** — errors are surfaced as [DioException]
///   unchanged; use `ErrorMapper.fromDio` to convert to `AppFailure`.
class DioFactory {
  const DioFactory._();

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

    /// How long to wait for the first byte of the response.
    Duration receiveTimeout = const Duration(seconds: 20),

    /// How long the socket can stall while uploading the request body.
    Duration sendTimeout = const Duration(seconds: 20),

    /// Header name used for correlation IDs. Must match the backend.
    String correlationHeader = 'x-correlation-id',

    /// Whether to auto-retry idempotent requests once on transient failures.
    bool enableRetry = true,

    /// Base delay before the single retry. Doubled per attempt (only one
    /// attempt by default, so effectively `retryDelay`).
    Duration retryDelay = const Duration(milliseconds: 500),

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
          // Attach correlation ID (fresh per request).
          if (!options.headers.containsKey(correlationHeader)) {
            options.headers[correlationHeader] = const Uuid().v4();
          }

          // Attach bearer token if a provider is supplied.
          if (getToken != null) {
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

          // Only retry idempotent methods.
          final isIdempotent =
              request.method == 'GET' || request.method == 'HEAD';
          if (!isIdempotent) return handler.next(error);

          // Never retry an already-retried request.
          if (request.extra['__retried__'] == true) {
            return handler.next(error);
          }

          // Retry only on transient failures.
          final isTransient = switch (error.type) {
            DioExceptionType.connectionTimeout ||
            DioExceptionType.receiveTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.connectionError => true,
            DioExceptionType.badResponse =>
              (error.response?.statusCode ?? 0) >= 500 &&
                  (error.response?.statusCode ?? 0) < 600,
            _ => false,
          };
          if (!isTransient) return handler.next(error);

          onRetry?.call(request);

          // Backoff before the single retry.
          await Future<void>.delayed(retryDelay);

          try {
            final response = await dio.fetch<dynamic>(
              request.copyWith(extra: {...request.extra, '__retried__': true}),
            );
            return handler.resolve(response);
          } catch (_) {
            // Retry also failed — surface the *original* error for context.
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
}
