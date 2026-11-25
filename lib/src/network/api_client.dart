import 'package:dio/dio.dart';

import '../failures/app_failure.dart';
import '../mapping/error_mapper.dart';
import '../result/result.dart';

/// Thin repository-facing wrapper over [Dio].
///
/// Every call returns `Result<T>` — repositories never need `try/catch`.
/// Errors are converted to typed [AppFailure]s via [ErrorMapper], so the UI
/// can `switch` exhaustively.
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

  /// Optional hook fired for every failure — handy for global logging or
  /// analytics. Will *not* replace the `Failure` returned to the caller.
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
  }) async {
    try {
      final response = await _dio.request<dynamic>(
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
      );

      // Dio was configured to throw on non-2xx, but if a caller overrode
      // validateStatus, guard here anyway.
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final failure = ErrorMapper.fromResponse(
          status,
          _stringifyBody(response.data),
          correlationId: _correlationId(response),
        );
        onFailure?.call(failure);
        return Failure(failure);
      }

      // No parser → cast the raw JSON to T.
      if (parser == null) {
        return Success(response.data as T);
      }

      // Parser errors (bad JSON shape, type mismatch) become ParsingFailure.
      try {
        return Success(parser(response.data));
      } catch (e, st) {
        final failure = ErrorMapper.fromException(e, st);
        onFailure?.call(failure);
        return Failure(failure);
      }
    } on DioException catch (e) {
      final failure = ErrorMapper.fromDio(e);
      onFailure?.call(failure);
      return Failure(failure);
    } catch (e, st) {
      final failure = ErrorMapper.fromException(e, st);
      onFailure?.call(failure);
      return Failure(failure);
    }
  }

  // ---------------------------------------------------------------------------
  // Convenience methods
  // ---------------------------------------------------------------------------

  Future<Result<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? parser,
    CancelToken? cancelToken,
    Options? options,
  }) => request(
    path: path,
    method: 'GET',
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
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
    Options? options,
  }) => request(
    path: path,
    method: 'POST',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
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
    Options? options,
  }) => request(
    path: path,
    method: 'PUT',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
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
    Options? options,
  }) => request(
    path: path,
    method: 'PATCH',
    body: body,
    query: query,
    headers: headers,
    parser: parser,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
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
  }) => request(
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
    Map<String, dynamic>? headers,
    Options? options,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: formData,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        options: (options ?? Options()).copyWith(
          headers: {...?options?.headers, ...?headers},
        ),
      );

      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final failure = ErrorMapper.fromResponse(
          status,
          _stringifyBody(response.data),
          correlationId: _correlationId(response),
        );
        onFailure?.call(failure);
        return Failure(failure);
      }

      if (parser == null) return Success(response.data as T);
      try {
        return Success(parser(response.data));
      } catch (e, st) {
        final failure = ErrorMapper.fromException(e, st);
        onFailure?.call(failure);
        return Failure(failure);
      }
    } on DioException catch (e) {
      final failure = ErrorMapper.fromDio(e);
      onFailure?.call(failure);
      return Failure(failure);
    } catch (e, st) {
      final failure = ErrorMapper.fromException(e, st);
      onFailure?.call(failure);
      return Failure(failure);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _stringifyBody(dynamic body) {
    if (body == null) return '';
    if (body is String) return body;
    try {
      return body.toString();
    } catch (_) {
      return '';
    }
  }

  String? _correlationId(Response<dynamic> response) {
    try {
      return response.headers.value('x-correlation-id');
    } catch (_) {
      return null;
    }
  }
}
