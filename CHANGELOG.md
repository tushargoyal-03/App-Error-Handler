# 1.0.0

Production hardening of the initial package. See the chat review for the full
bug list. Breaking changes vs. the draft:

* `AppFailure.withContext` gained `cause`; subclasses' `withContext` return `AppFailure`.
* New sealed subclasses `RateLimitedFailure` (429) and `SecureConnectionFailure`
  — add them to your own exhaustive `switch`es.
* `ErrorMapper.fromResponse` takes `Object? body` (String still works).
* `ErrorHandler.handle` returns `Future<AppFailure>`.
* `FailureLogger` / `FailureListener` typedefs now live in `error_handler.dart` (same public export).
* `TypeError` is no longer mapped to `ParsingFailure`.
* `ServerFailure` message for 5xx no longer has a `Server error:` prefix.
* `DioFactory`: retry also needs `maxRetries`/`retryMethods`/`retryStatusCodes` (defaults keep old behaviour, except plain 500 is no longer retried).
