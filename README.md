# error_handling

Global, project-independent error handling for Flutter. Add it once, never
re-create the same 10 files again.

* **Typed failures** – sealed `AppFailure` → exhaustive `switch` in UI/Bloc.
* **`Result<T>`** – `Success` / `Failure`, `fold`, `map`, `flatMap`, `Result.guard`.
* **`ErrorMapper`** – Dio, `dart:io`, HTTP bodies (incl. NestJS) → `AppFailure`. Never throws.
* **`DioFactory` + `ApiClient`** – timeouts, correlation IDs, bearer token, safe retry; every call returns `Result<T>`.
* **`ErrorKit.bootstrap`** – global crash hooks, init steps with timeout, init-error screen with Retry.

## Install

```yaml
dependencies:
  error_handling:
    path: ../error_handling      # or git: url
```

## main.dart

```dart
Future<void> main() => ErrorKit.bootstrap(
  config: ErrorKitConfig(
    initSteps: [StorageService.instance.init],
    logger: (f) async => FirebaseCrashlytics.instance.recordError(
      f.cause ?? f, f.stackTrace, reason: f.message,
      information: ['corr=${f.correlationId}'],
    ),
    onFailure: (f, msg) => scaffoldMessengerKey.currentState
        ?.showSnackBar(SnackBar(content: Text(msg))),
  ),
  appBuilder: () => const App(),
);
```

## Repository

```dart
final dio = DioFactory.create(
  baseUrl: Env.apiUrl,
  getToken: () => secureStorage.read(key: 'access_token'),
);
final api = ApiClient(dio, onFailure: (f) {
  if (f is UnauthorizedFailure) authCubit.logout();
});

Future<Result<User>> me() =>
    api.get('/users/me', parser: (j) => User.fromJson(j as Map<String, dynamic>));

// Non-HTTP work (storage, platform channels):
Future<Result<String?>> token() => Result.guard(() => storage.read('token'));
```

## Cubit

```dart
final result = await repo.me();
result.fold(
  onSuccess: (u) => emit(Loaded(u)),
  onFailure: (f) => emit(Error(f.userMessage, retryable: f.isRetryable)),
);
```

Failures have value equality, so `Error(failure)` works in Bloc states.

## Localisation

```dart
FailureMessageConfig.resolver = (f) => switch (f) {
  NetworkFailure() => l10n.noInternet,
  _ => null, // fall back to built-in English
};
```

## NestJS notes

* `message: string | string[]` (class-validator) is understood; a 400 with a
  message list becomes `ValidationFailure`.
* Echo the `x-correlation-id` request header in your exception filter and
  include `correlationId` in the error body for end-to-end tracing.

## Behaviour you should know

* Retry: only GET/HEAD/OPTIONS, only timeouts / connection errors /
  408-502-503-504, 1 retry with backoff (`maxRetries`, `retryMethods`).
* Init steps time out after 30 s (`initStepTimeout`, `null` disables).
* Raw error text on the init-error screen is hidden in release builds.
* Web: the package imports `dart:io` for exception types; Dio on web reports
  network problems as `DioException`, which is fully handled.

## Tests

```
flutter test
```
