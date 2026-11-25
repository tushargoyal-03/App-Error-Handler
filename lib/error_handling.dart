/// Global, project-independent error handling for Flutter.
///
/// * [AppFailure] — sealed, typed failures (exhaustive `switch`).
/// * [Result] — `Success` / `Failure` with `fold`, `map`, `guard`, ...
/// * [ErrorMapper] — Dio / dart:io / HTTP body → [AppFailure].
/// * [DioFactory] + [ApiClient] — ready-made networking that never throws.
/// * [ErrorKit] — one-call bootstrap with global crash hooks.
// ignore_for_file: unnecessary_library_name
library error_handling;

// Failures
export 'src/failures/app_failure.dart';
export 'src/failures/failure_messages.dart';

// Result
export 'src/result/result.dart';

// Mapping
export 'src/mapping/error_mapper.dart';

// Network
export 'src/network/dio_factory.dart';
export 'src/network/api_client.dart';

// Handler
export 'src/handler/error_handler.dart';

// Widgets
export 'src/widget/initialization_error_app.dart';

// Bootstrap
export 'src/bootstrap/error_kit_bootstrap.dart';
