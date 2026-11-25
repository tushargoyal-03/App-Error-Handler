import 'dart:ui' as ui;

import 'package:error_handling/error_handling.dart';
import 'package:flutter/material.dart';

/// Signature for a one-time async init step (storage, config, etc.).
typedef InitStep = Future<void> Function();

/// Signature for a log sink (Crashlytics, Sentry, custom logger).
typedef FailureLogger = Future<void> Function(AppFailure failure);

/// Signature for a global onFailure callback (e.g. show a SnackBar).
typedef FailureListener = void Function(AppFailure failure, String userMessage);

/// Configuration bundle.
class ErrorKitConfig {
  /// Ordered list of init steps. If any throws, the error screen is shown.
  final List<InitStep> initSteps;

  /// Where to send structured failures (Crashlytics, Sentry, your logger).
  final FailureLogger? logger;

  /// Global listener — ideal for a SnackBar via a navigator key.
  final FailureListener? onFailure;

  /// Override the init-error screen title.
  final String initErrorTitle;

  /// Called once bindings are initialized but *before* init steps run.
  /// Use it for `FlutterNativeSplash.preserve`, `Bloc.observer = ...`, etc.
  final Future<void> Function()? onBeforeInit;

  /// Called after init steps succeed, before `runApp`.
  final Future<void> Function()? onAfterInit;

  const ErrorKitConfig({
    this.initSteps = const [],
    this.logger,
    this.onFailure,
    this.initErrorTitle = 'The app could not start.',
    this.onBeforeInit,
    this.onAfterInit,
  });
}

/// The heart of the package: installs global handlers, runs init steps,
/// and boots the app. Turns ~80 lines of main.dart into one call.
class ErrorKit {
  static ErrorHandler? _handler;

  /// Access the global handler (e.g. for reporting non-fatal errors).
  static ErrorHandler get handler {
    final h = _handler;
    if (h == null) {
      throw StateError(
        'ErrorKit.bootstrap() must be called before accessing handler.',
      );
    }
    return h;
  }

  /// One-line bootstrap. Call from main().
  ///
  /// ```dart
  /// Future<void> main() => ErrorKit.bootstrap(
  ///   config: ErrorKitConfig(initSteps: [StorageService.instance.init]),
  ///   appBuilder: () => const App(),
  /// );
  /// ```
  static Future<void> bootstrap({
    required Widget Function() appBuilder,
    ErrorKitConfig config = const ErrorKitConfig(),
  }) async {
    WidgetsFlutterBinding.ensureInitialized();

    // Build the global handler once.
    _handler = ErrorHandler(logger: config.logger, onFailure: config.onFailure);

    // Install global hooks — the *correct* modern way.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _handler!.handle(details.exception, details.stack ?? StackTrace.current);
    };

    ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
      _handler!.handle(error, stackTrace);
      return true; // ← critical: prevents a crash
    };

    await config.onBeforeInit?.call();

    // Run init steps. If any fails, show the init-error screen — never boot
    // into a half-initialized app.
    try {
      for (final step in config.initSteps) {
        await step();
      }
    } catch (error, stackTrace) {
      await _handler!.handle(error, stackTrace);
      runApp(
        InitializationErrorApp(
          error: error,
          stackTrace: stackTrace,
          title: config.initErrorTitle,
        ),
      );
      return;
    }

    await config.onAfterInit?.call();

    runApp(appBuilder());
  }
}
