import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../failures/app_failure.dart';
import '../handler/error_handler.dart';
import '../widget/initialization_error_app.dart';

/// Signature for a one-time async init step (storage, config, etc.).
typedef InitStep = Future<void> Function();

/// Configuration bundle.
class ErrorKitConfig {
  /// Ordered list of init steps. If any throws (or times out), the error
  /// screen is shown — with a Retry button that re-runs the whole sequence.
  final List<InitStep> initSteps;

  /// Where to send structured failures (Crashlytics, Sentry, your logger).
  final FailureLogger? logger;

  /// Global listener — ideal for a SnackBar via a navigator key.
  final FailureListener? onFailure;

  /// Failures for which this returns `true` are dropped (default: cancelled).
  final bool Function(AppFailure failure)? shouldIgnore;

  /// Override the init-error screen title.
  final String initErrorTitle;

  /// Called once bindings are initialized but *before* init steps run.
  /// Use it for `FlutterNativeSplash.preserve`, `Bloc.observer = ...`, etc.
  final Future<void> Function()? onBeforeInit;

  /// Called after init steps succeed, before `runApp`.
  final Future<void> Function()? onAfterInit;

  /// Max time for a single init step. A step that hangs would otherwise leave
  /// the user on the splash screen forever. `null` disables the timeout.
  final Duration? initStepTimeout;

  /// Show raw error text on the init-error screen. Default: not in release.
  final bool showInitErrorDetails;

  const ErrorKitConfig({
    this.initSteps = const [],
    this.logger,
    this.onFailure,
    this.shouldIgnore,
    this.initErrorTitle = 'The app could not start.',
    this.onBeforeInit,
    this.onAfterInit,
    this.initStepTimeout = const Duration(seconds: 30),
    this.showInitErrorDetails = !kReleaseMode,
  });
}

/// The heart of the package: installs global handlers, runs init steps,
/// and boots the app. Turns ~80 lines of main.dart into one call.
class ErrorKit {
  const ErrorKit._();

  static ErrorHandler? _handler;
  static bool _hooksInstalled = false;
  static bool _starting = false;

  /// Access the global handler.
  static ErrorHandler get handler {
    final h = _handler;
    if (h == null) {
      throw StateError(
        'ErrorKit.bootstrap() must be called before accessing handler.',
      );
    }
    return h;
  }

  /// Report a non-fatal error you caught yourself. Safe to call even before
  /// [bootstrap] (it then only prints in debug mode).
  static Future<AppFailure> report(Object error, [StackTrace? stackTrace]) =>
      (_handler ?? const ErrorHandler()).handle(error, stackTrace);

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

    final handler = ErrorHandler(
      logger: config.logger,
      onFailure: config.onFailure,
      shouldIgnore: config.shouldIgnore,
    );
    _handler = handler;
    _installHooksOnce();

    await _start(appBuilder, config, handler);
  }

  // ---------------------------------------------------------------------------

  /// Hooks read [_handler] lazily, so calling bootstrap twice (tests, hot
  /// restart) swaps the handler without stacking hooks on top of each other.
  /// Hooks that were registered before us (e.g. Crashlytics) are preserved.
  static void _installHooksOnce() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;

    final previousFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (previousFlutterOnError != null &&
          previousFlutterOnError != FlutterError.presentError) {
        try {
          previousFlutterOnError(details);
        } catch (_) {}
      }
      unawaited(
        _handler?.handle(details.exception, details.stack ?? StackTrace.current),
      );
    };

    final previousDispatcherOnError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
      if (previousDispatcherOnError != null) {
        try {
          previousDispatcherOnError(error, stackTrace);
        } catch (_) {}
      }
      unawaited(_handler?.handle(error, stackTrace));
      return true; // ← critical: marks the error as handled, prevents a crash
    };
  }

  /// Runs hooks + init steps + `runApp`. Any failure shows the init-error
  /// screen — never boots into a half-initialized app.
  static Future<void> _start(
    Widget Function() appBuilder,
    ErrorKitConfig config,
    ErrorHandler handler,
  ) async {
    try {
      await config.onBeforeInit?.call();
      for (final step in config.initSteps) {
        await _runStep(step, config.initStepTimeout);
      }
      await config.onAfterInit?.call();
      runApp(appBuilder());
    } catch (error, stackTrace) {
      await handler.handle(error, stackTrace);
      runApp(
        InitializationErrorApp(
          error: error,
          stackTrace: stackTrace,
          title: config.initErrorTitle,
          showDetails: config.showInitErrorDetails,
          onRetry: () {
            if (_starting) return; // ignore double taps
            _starting = true;
            unawaited(
              _start(
                appBuilder,
                config,
                handler,
              ).whenComplete(() => _starting = false),
            );
          },
        ),
      );
    }
  }

  static Future<void> _runStep(InitStep step, Duration? timeout) {
    final future = step();
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'An initialization step did not finish within ${timeout.inSeconds}s.',
        timeout,
      ),
    );
  }
}
