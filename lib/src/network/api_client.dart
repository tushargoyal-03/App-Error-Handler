import 'package:dio/dio.dart';

import '../failures/app_failure.dart';
import '../mapping/error_mapper.dart';
import '../result/result.dart';

/// Thin repository-facing wrapper over [Dio].
///
/// Every call returns `Result<T>` — repositories never need `try/catch`.
/// Errors are converted to typed [AppFailure]s via [ErrorMapper], so the UI
/// can `switch` exhaustively. **No method here ever throws.**
///
/// ```dart
/// final result = await api.get<User>(
///   '/users/me',
///   parser: (json) => User.fromJson(json as Map<String, dynamic>),
/// );
/// result.fold(
///   onSuccess: (user) => print(user.name),
///   onFailure: (failure) => print(failure.userMessage),
/// );
/// ```
class ApiClient {
  final Dio _dio;

  /// Optional hook fired for every failure (except cancellations) — handy
  /// for global logging, analytics or forcing logout on
  /// [UnauthorizedFailure]. Will *not* replace the `Failure` returned to the
  /// caller. Exceptions thrown by the hook are swallowed.
  final void Function(AppFailure failure)? onFailure;

  ApiClient(this._dio, {this.onFailure});

  /// Underlying Dio instance, for the rare cases where you need raw access.
  Dio get dio => _dio;

  // ---------------------------------------------------------------------------
  // Core request
  // ---------------------------------------------------------------------------

  Future<Result<T>> request<T>({
    required String path,
    required String method,
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    Options? options,
  }) => _execute<T>(
    () => _dio.request<dynamic>(
      path,
      data: body,
      queryParameters: query,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      options: (options ?? Options()).copyWith(
        method: method,
        headers: {...?options?.headers, ...?headers},
      ),
    ),
    parser,
  );

  // ---------------------------------------------------------------------------
  // Convenience methods
  // ---------------------------------------------------------------------------

  Future<Result<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    Options? options,
  }) => request<T>(
    path: path,
    method: 'GET',
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<Result<T>> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    Options? options,
  }) => request<T>(
    path: path,
    method: 'POST',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<Result<T>> put<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    Options? options,
  }) => request<T>(
    path: path,
    method: 'PUT',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<Result<T>> patch<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    Options? options,
  }) => request<T>(
    path: path,
    method: 'PATCH',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<Result<T>> delete<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    Options? options,
  }) => request<T>(
    path: path,
    method: 'DELETE',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    options: options,
  );

  /// Multipart upload helper.
  Future<Result<T>> upload<T>(
    String path, {
    required FormData formData,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? headers,
    Options? options,
  }) => _execute<T>(
    () => _dio.post<dynamic>(
      path,
      data: formData,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      options: (options ?? Options()).copyWith(
        headers: {...?options?.headers, ...?headers},
      ),
    ),
    parser,
  );

  // ---------------------------------------------------------------------------
  // Shared pipeline
  // ---------------------------------------------------------------------------

  Future<Result<T>> _execute<T>(
    Future<Response<dynamic>> Function() send,
    T Function(dynamic json)? parser,
  ) async {
    try {
      final response = await send();

      // Dio is configured to throw on non-2xx, but if a caller overrode
      // validateStatus, guard here anyway.
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        return _fail<T>(
          ErrorMapper.fromResponse(
            status,
            response.data,
            correlationId: _correlationId(response),
          ),
        );
      }

      final data = response.data;

      // No parser → hand back the raw JSON, type-checked.
      if (parser == null) {
        if (data is T) return Success<T>(data);
        return _fail<T>(
          ParsingFailure(
            'Unexpected response type: expected $T, got ${data.runtimeType}',
          ).withContext(correlationId: _correlationId(response)),
        );
      }

      // ANY parser error (bad shape, null cast, custom exception) is a
      // ParsingFailure — not "Unknown".
      try {
        return Success<T>(parser(data));
      } catch (e, st) {
        return _fail<T>(
          ParsingFailure(
            'Failed to parse response: ${_brief(e)}',
            st,
          ).withContext(cause: e, correlationId: _correlationId(response)),
        );
      }
    } on DioException catch (e) {
      return _fail<T>(ErrorMapper.fromDio(e));
    } catch (e, st) {
      return _fail<T>(ErrorMapper.fromException(e, st));
    }
  }

  Result<T> _fail<T>(AppFailure failure) {
    if (failure is! CancelledFailure) {
      try {
        onFailure?.call(failure);
      } catch (_) {
        // A broken hook must never break the Result contract.
      }
    }
    return Failure<T>(failure);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _brief(Object e) {
    final s = ErrorMapper.safeToString(e);
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  String? _correlationId(Response<dynamic> response) {
    try {
      return response.headers.value(ErrorMapper.correlationHeader) ??
          response.requestOptions.headers[ErrorMapper.correlationHeader]
              ?.toString();
    } catch (_) {
      return null;
    }
  }
}
