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

  const InitializationErrorApp({
    super.key,
    required this.error,
    required this.stackTrace,
    this.onRetry,
    this.title = 'The app could not start.',
    this.closeLabel = 'Close app',
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(ErrorHandler.format(error), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy details'),
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(
                            text:
                                '${ErrorHandler.format(error)}\n\n$stackTrace',
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Error details copied')),
                        );
                      },
                    ),
                    if (onRetry != null)
                      ElevatedButton.icon(
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Retry'),
                        onPressed: onRetry,
                      ),
                    if (onRetry == null)
                      ElevatedButton(
                        onPressed: () => SystemNavigator.pop(),
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
  }
}
