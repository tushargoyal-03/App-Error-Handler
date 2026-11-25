# app_error_kit

Production-ready error handling for Flutter: typed failures, `Result<T>`, Dio integration, global handlers, and UX-safe messaging.

## Install

```yaml
dependencies:
  app_error_kit:
    git:
      url: https://github.com/tushargoyal-03/App-Error-Handler
      ref: v1.0.0
```

## Quick start

```dart
Future<void> main() => ErrorKit.bootstrap(
      appBuilder: () => const App(),
      config: ErrorKitConfig(
        initSteps: [StorageService.instance.init],
        logger: (failure) async {
          // Crashlytics / Sentry / your logger
        },
      ),
    );
```

## API calls

```dart
final api = ApiClient(DioFactory.create(baseUrl: 'https://api.example.com'));
final result = await api.get<User>('/users/me', parser: User.fromJson);

result.fold(
  onSuccess: (user) { /* ... */ },
  onFailure: (failure) => print(failure.userMessage),
);
```

## Report non-fatal errors

```dart
ErrorKit.handler.handle(someError, someStack);
```