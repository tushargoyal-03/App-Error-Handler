import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../handler/error_handler.dart';

/// Shown when app bootstrap fails — instead of crashing on the first frame.
class InitializationErrorApp extends StatelessWidget {
  final Object error;
  final StackTrace stackTrace;
  final VoidCallback? onRetry;
  final String title;
  final String closeLabel;
  final String retryLabel;

  /// Show the raw error text + "Copy details" button. Defaults to debug and
  /// profile builds only — in release users must not see internals.
  final bool showDetails;

  const InitializationErrorApp({
    super.key,
    required this.error,
    required this.stackTrace,
    this.onRetry,
    this.title = 'The app could not start.',
    this.closeLabel = 'Close app',
    this.retryLabel = 'Retry',
    this.showDetails = !kReleaseMode,
  });

  // iOS has no programmatic "exit app"; SystemNavigator.pop() is a no-op there.
  bool get _canClose => defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Builder → the context below MaterialApp has a ScaffoldMessenger.
      // (Using the outer `context` for SnackBars throws.)
      home: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 56, color: scheme.error),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (showDetails)
                        SelectableText(
                          ErrorHandler.format(error),
                          textAlign: TextAlign.center,
                        )
                      else
                        const Text(
                          'Please try again. If the problem continues, '
                          'restart the app.',
                          textAlign: TextAlign.center,
                        ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          if (showDetails)
                            OutlinedButton.icon(
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('Copy details'),
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text:
                                        '${ErrorHandler.format(error)}\n\n'
                                        '$stackTrace',
                                  ),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Error details copied'),
                                  ),
                                );
                              },
                            ),
                          if (onRetry != null)
                            ElevatedButton.icon(
                              icon: const Icon(Icons.refresh, size: 18),
                              label: Text(retryLabel),
                              onPressed: onRetry,
                            ),
                          if (onRetry == null && _canClose)
                            ElevatedButton(
                              onPressed: SystemNavigator.pop,
                              child: Text(closeLabel),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
