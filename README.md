# error_handling

Global, project-independent error handling for Flutter. Add it once, never
re-create the same 10 files again.

* **Typed failures** – sealed `AppFailure` → exhaustive `switch` in UI/Bloc.
* **`Result<T>`** – `Success` / `Failure`, `fold`, `map`, `flatMap`, `Result.guard`.
* **`ErrorMapper`** – Dio, `dart:io`, HTTP bodies (NestJS / ASP.NET / HRMS variants) → `AppFailure`. Never throws.
* **`DioFactory` + `ApiClient`** – timeouts, correlation IDs, bearer token, safe retry; every call returns `Result<T>`.
* **`ErrorKit.bootstrap`** – global crash hooks, init steps with timeout, init-error screen with Retry.
* **HRMS-ready** – device/location failures, 15+ JSON key variants, custom fallback messages.

## Install

```yaml
dependencies:
  error_handling:
    git:
      url: https://github.com/tushargoyal-03/App-Error-Handler.git
      ref: main
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

## Repository / ApiClient

```dart
final dio = DioFactory.create(
  baseUrl: Env.apiUrl,
  getToken: () => secureStorage.read(key: 'access_token'),
);

// 401 auto-logout callback
final api = ApiClient(dio, onFailure: (f) {
  if (f is UnauthorizedFailure) authCubit.logout();
});

Future<Result<User>> me() =>
    api.get('/users/me', parser: (j) => User.fromJson(j as Map<String, dynamic>));

// Non-HTTP work (storage, platform channels):
Future<Result<String?>> token() => Result.guard(() => storage.read('token'));
```

## Cubit / BLoC

```dart
final result = await repo.me();
result.fold(
  onSuccess: (u) => emit(Loaded(u)),
  onFailure: (f) => emit(Error(f.userMessage, retryable: f.isRetryable)),
);
```

## UI Pattern Matching (Type-safe, no string.contains)

```dart
switch (failure) {
  case NetworkFailure():
    showNoInternetSheet();
  case UnauthorizedFailure():
    goToLogin();
  case OutOfRadiusFailure():
    showOutsideOfficeSheet();
  case DeviceIntegrityFailure():
    showMockGpsBlockedDialog();
  case LocationPermissionFailure(:final isPermanentlyDenied):
    isPermanentlyDenied ? openAppSettings() : requestPermission();
  case LocationServiceFailure():
    promptEnableGps();
  case ValidationFailure(:final fieldErrors):
    highlightFormErrors(fieldErrors);
  case TimeoutFailure() || RateLimitedFailure():
    showRetryButton();
  default:
    showGenericSnackbar(failure.userMessage);
}
```

## HRMS Device / Location Failures

```dart
// Out of office radius
throw const OutOfRadiusFailure('You are 500m from office.', 500.0);
// or
OutOfRadiusFailure('Outside radius', distanceMeters: 320.5);

// Mock GPS / rooted device
throw const DeviceIntegrityFailure();

// Location permission
throw const LocationPermissionFailure(isPermanentlyDenied: true);

// GPS disabled
throw const LocationServiceFailure();

// Use with Result.guard in your location service:
Future<Result<LatLng>> getCurrentLocation() => Result.guard(
  () async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.deniedForever) {
      throw const LocationPermissionFailure(isPermanentlyDenied: true);
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationServiceFailure();
    }
    return await Geolocator.getCurrentPosition();
  },
);
```

## Custom Fallback Message

```dart
// When backend body has no recognisable message key, use feature-specific text:
final failure = ErrorMapper.fromResponse(
  response.statusCode,
  response.data,
  fallback: 'Attendance marking failed. Please try again.',
);
```

## Supported JSON Keys (Auto-detected)

The parser scans these keys in priority order — no configuration needed:

| Category | Keys |
|----------|------|
| Standard REST | `message`, `error`, `detail`, `title`, `reason`, `error_description` |
| ASP.NET / HRMS | `Message`, `responseMessage`, `ResponseMessage`, `ResultMessage`, `resultMessage`, `errorMessage`, `ErrorMessage` |
| Others | `msg`, `description`, `errMsg` |
| Field errors | `errors` (Map or List), `details`, `fieldErrors` |
| Correlation ID | `correlationId`, `correlation_id` |

HTML bodies (nginx 502 pages) are automatically discarded — app never crashes.

## All Failure Types

| Type | Trigger |
|------|---------|
| `NetworkFailure` | No internet, `SocketException`, `connectionError` |
| `TimeoutFailure` | `connectionTimeout`, `sendTimeout`, `receiveTimeout` |
| `UnauthorizedFailure` | HTTP 401 |
| `ForbiddenFailure` | HTTP 403 |
| `NotFoundFailure` | HTTP 404 |
| `ValidationFailure` | HTTP 422, or 400 with field errors / message list |
| `ConflictFailure` | HTTP 409 |
| `RateLimitedFailure` | HTTP 429 (with optional `retryAfter`) |
| `ServerFailure` | HTTP 5xx / other 4xx |
| `SecureConnectionFailure` | TLS / certificate errors |
| `CancelledFailure` | Request cancelled |
| `ParsingFailure` | JSON decode / type cast failure |
| `LocalStorageFailure` | `FileSystemException` |
| `UnknownFailure` | Anything else |
| `OutOfRadiusFailure` | User outside office geofence |
| `DeviceIntegrityFailure` | Rooted device / mock GPS |
| `LocationPermissionFailure` | Location permission denied |
| `LocationServiceFailure` | GPS/location service disabled |

## Localisation

```dart
FailureMessageConfig.resolver = (f) => switch (f) {
  NetworkFailure() => l10n.noInternet,
  OutOfRadiusFailure() => l10n.outsideOfficeRadius,
  LocationPermissionFailure(:final isPermanentlyDenied) =>
    isPermanentlyDenied ? l10n.permissionPermanentlyDenied : l10n.permissionDenied,
  _ => null, // fall back to built-in English
};
```

## ASP.NET / HRMS Notes

* All PascalCase and camelCase key variants are auto-detected (`Message`, `responseMessage`, etc.).
* `{ "errors": { "field": ["msg"] } }` → `ValidationFailure` with `fieldErrors` map.
* `{ "title": "Validation Failed", "status": 400 }` (RFC 7807 ProblemDetails) → `title` extracted.
* Echo the `x-correlation-id` request header in your ASP.NET exception middleware for end-to-end tracing.

## Behaviour you should know

* Retry: only GET/HEAD/OPTIONS, only timeouts / connection errors / 408-502-503-504, 1 retry with backoff (`maxRetries`, `retryMethods`).
* `isRetryable`: `NetworkFailure`, `TimeoutFailure`, `RateLimitedFailure`, `ServerFailure` (5xx) are retryable. Device/location failures are never retryable.
* Init steps time out after 30 s (`initStepTimeout`, `null` disables).
* Raw error text on the init-error screen is hidden in release builds.
* Web: the package imports `dart:io` for exception types; Dio on web reports network problems as `DioException`, which is fully handled.

## Tests

```bash
flutter test
```

293 tests — covering all HTTP status codes, JSON key variants, device/location failures, UI pattern matching, and edge cases.
