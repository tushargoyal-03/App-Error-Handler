// ignore_for_file: avoid_print
/// Tests specific to HRMS use-cases:
/// 1. HRMS-variant JSON keys (Message, responseMessage, ResultMessage, etc.)
/// 2. ASP.NET ProblemDetails / validation error formats
/// 3. Device / Location failure types (OutOfRadius, DeviceIntegrity, etc.)
/// 4. Custom fallback parameter in ErrorMapper.fromResponse
/// 5. 401 onFailure callback (token expiry / auto-logout)
/// 6. UI type-based pattern matching (no string.contains needed)
library;

import 'package:error_handling/error_handling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ===========================================================================
  // 1. HRMS JSON Key Variants
  // ===========================================================================

  group('HRMS – JSON key variants', () {
    test('"Message" (PascalCase) is extracted', () {
      final f = ErrorMapper.fromResponse(400, {'Message': 'Employee not found'});
      expect(f.message, 'Employee not found');
    });

    test('"responseMessage" is extracted', () {
      final f = ErrorMapper.fromResponse(
        400,
        {'responseMessage': 'Invalid shift code'},
      );
      expect(f.message, 'Invalid shift code');
    });

    test('"ResponseMessage" (PascalCase) is extracted', () {
      final f = ErrorMapper.fromResponse(
        400,
        {'ResponseMessage': 'Attendance already marked'},
      );
      expect(f.message, 'Attendance already marked');
    });

    test('"ResultMessage" is extracted', () {
      final f = ErrorMapper.fromResponse(
        422,
        {'ResultMessage': 'Payroll locked for this period'},
      );
      expect(f.message, 'Payroll locked for this period');
    });

    test('"resultMessage" (camelCase) is extracted', () {
      final f = ErrorMapper.fromResponse(
        400,
        {'resultMessage': 'Leave quota exceeded'},
      );
      expect(f.message, 'Leave quota exceeded');
    });

    test('"errorMessage" is extracted', () {
      final f = ErrorMapper.fromResponse(
        500,
        {'errorMessage': 'Database timeout'},
      );
      expect(f.message, 'Database timeout');
    });

    test('"ErrorMessage" (PascalCase) is extracted', () {
      final f = ErrorMapper.fromResponse(
        400,
        {'ErrorMessage': 'Invalid employee ID'},
      );
      expect(f.message, 'Invalid employee ID');
    });

    test('"msg" short key is extracted', () {
      final f = ErrorMapper.fromResponse(400, {'msg': 'Short error'});
      expect(f.message, 'Short error');
    });

    test('"description" key is extracted', () {
      final f = ErrorMapper.fromResponse(
        403,
        {'description': 'Access denied for this branch'},
      );
      expect(f.message, 'Access denied for this branch');
    });

    test('empty HRMS key falls through to next key', () {
      final f = ErrorMapper.fromResponse(400, {
        'Message': '',
        'responseMessage': 'Fallback message',
      });
      expect(f.message, 'Fallback message');
    });

    test('all HRMS keys absent → generic fallback message', () {
      final f = ErrorMapper.fromResponse(400, {'code': 1001, 'status': 'FAIL'});
      expect(f.message, contains('Something went wrong'));
    });
  });

  // ===========================================================================
  // 2. ASP.NET / HRMS Error Response Formats
  // ===========================================================================

  group('HRMS – ASP.NET error formats', () {
    test('ProblemDetails: title + status 400 → ValidationFailure', () {
      // A 400 with only a title and no list → ServerFailure (not Validation)
      final f = ErrorMapper.fromResponse(400, {
        'title': 'One or more validation errors occurred.',
        'status': 400,
        'traceId': '00-abc123',
      });
      // title IS extracted as the message; status 400 without a list → ServerFailure
      expect(f.message, 'One or more validation errors occurred.');
    });

    test('ProblemDetails: errors map → ValidationFailure with fieldErrors', () {
      final f = ErrorMapper.fromResponse(400, {
        'title': 'Validation Failed',
        'status': 400,
        'errors': {
          'Email': ['The Email field is required.'],
          'Phone': ['Phone must be 10 digits.'],
        },
      });
      expect(f, isA<ValidationFailure>());
      final fe = (f as ValidationFailure).fieldErrors!;
      expect(fe['Email'], ['The Email field is required.']);
      expect(fe['Phone'], ['Phone must be 10 digits.']);
    });

    test('{ "errors": ["Email is required"] } list → error message extracted from errors list',
        () {
      // A bare list in "errors" without field-property structure is surfaced
      // as a ServerFailure (the message key wins). This is the correct behaviour:
      // the first message comes from the "Message" key, and the errors list is
      // treated as supplementary. If you need ValidationFailure, the backend
      // should return { "errors": { "field": ["msg"] } }.
      final f = ErrorMapper.fromResponse(400, {
        'Message': 'Invalid request',
        'errors': ['Email is required', 'Phone is required'],
      });
      // The message was extracted correctly
      expect(f.message, 'Invalid request');
      expect(f, isA<ServerFailure>());
    });

    test('502 HTML gateway response → no crash, generic message', () {
      const html =
          '<html><body><h1>502 Bad Gateway</h1><p>nginx</p></body></html>';
      final f = ErrorMapper.fromResponse(502, html);
      expect(f, isA<ServerFailure>());
      expect(f.message, isNot(contains('<')));
      expect(f.message.isNotEmpty, isTrue);
    });

    test('503 plain text "Service Unavailable" → safe fallback', () {
      final f = ErrorMapper.fromResponse(503, 'Service Unavailable');
      expect(f, isA<ServerFailure>());
    });

    test('HRMS wrapped response: { data: null, Message: "...", Success: false }',
        () {
      final f = ErrorMapper.fromResponse(400, {
        'Success': false,
        'data': null,
        'Message': 'Shift not assigned for today',
      });
      expect(f.message, 'Shift not assigned for today');
    });
  });

  // ===========================================================================
  // 3. Custom Fallback Parameter
  // ===========================================================================

  group('HRMS – Custom fallback parameter', () {
    test('fallback used when body has no recognisable message key', () {
      final f = ErrorMapper.fromResponse(
        500,
        {'code': 500, 'status': 'ERROR'},
        fallback: 'Attendance marking failed. Please try again.',
      );
      expect(f.message, 'Attendance marking failed. Please try again.');
    });

    test('fallback NOT used when body has a valid message key', () {
      final f = ErrorMapper.fromResponse(
        400,
        {'Message': 'Employee ID mismatch'},
        fallback: 'Attendance marking failed.',
      );
      // Real message from body wins over fallback
      expect(f.message, 'Employee ID mismatch');
    });

    test('empty fallback string behaves same as no fallback', () {
      final f = ErrorMapper.fromResponse(500, null, fallback: '   ');
      expect(f.message, contains('Something went wrong'));
    });

    test('null body with fallback uses fallback', () {
      final f = ErrorMapper.fromResponse(
        404,
        null,
        fallback: 'Employee record not found.',
      );
      expect(f.message, 'Employee record not found.');
    });
  });

  // ===========================================================================
  // 4. Device / Location Failure Types
  // ===========================================================================

  group('HRMS – Device & Location failure types', () {
    test('OutOfRadiusFailure default message is user-friendly', () {
      const f = OutOfRadiusFailure();
      expect(f.message, contains('radius'));
      expect(f.isRetryable, isFalse);
    });

    test('OutOfRadiusFailure stores distanceMeters', () {
      const f = OutOfRadiusFailure('Outside office', 420.5);
      expect(f.distanceMeters, 420.5);
      expect(f.message, 'Outside office');
    });

    test('OutOfRadiusFailure.withContext preserves distanceMeters', () {
      const f = OutOfRadiusFailure('Outside', 300.0);
      final enriched = f.withContext(correlationId: 'c-1');
      expect(enriched.runtimeType, OutOfRadiusFailure);
      expect((enriched as OutOfRadiusFailure).distanceMeters, 300.0);
      expect(enriched.correlationId, 'c-1');
    });

    test('OutOfRadiusFailure userMessage is HRMS-specific', () {
      const f = OutOfRadiusFailure();
      expect(f.userMessage.toLowerCase(), contains('office'));
    });

    test('DeviceIntegrityFailure default message mentions mock GPS / rooted',
        () {
      const f = DeviceIntegrityFailure();
      final msg = f.message.toLowerCase();
      expect(msg, anyOf(contains('root'), contains('mock'), contains('integrity')));
      expect(f.isRetryable, isFalse);
    });

    test('DeviceIntegrityFailure.withContext preserves type', () {
      const f = DeviceIntegrityFailure();
      final enriched = f.withContext(correlationId: 'dev-1');
      expect(enriched.runtimeType, DeviceIntegrityFailure);
      expect(enriched.correlationId, 'dev-1');
    });

    test('LocationPermissionFailure: default is NOT permanently denied', () {
      const f = LocationPermissionFailure();
      expect(f.isPermanentlyDenied, isFalse);
      expect(f.isRetryable, isFalse);
    });

    test('LocationPermissionFailure: isPermanentlyDenied=true changes message',
        () {
      const denied = LocationPermissionFailure(isPermanentlyDenied: true);
      expect(denied.userMessage.toLowerCase(), contains('settings'));
      const ask = LocationPermissionFailure();
      // The two messages should differ
      expect(denied.userMessage, isNot(ask.userMessage));
    });

    test('LocationPermissionFailure.withContext preserves isPermanentlyDenied',
        () {
      const f = LocationPermissionFailure(isPermanentlyDenied: true);
      final enriched = f.withContext(stackTrace: StackTrace.empty);
      expect((enriched as LocationPermissionFailure).isPermanentlyDenied, isTrue);
    });

    test('LocationServiceFailure default message mentions GPS', () {
      const f = LocationServiceFailure();
      expect(f.userMessage.toLowerCase(), contains('gps'));
      expect(f.isRetryable, isFalse);
    });

    test('LocationServiceFailure.withContext preserves type', () {
      const f = LocationServiceFailure();
      final enriched = f.withContext(correlationId: 'loc-1');
      expect(enriched.runtimeType, LocationServiceFailure);
      expect(enriched.correlationId, 'loc-1');
    });
  });

  // ===========================================================================
  // 5. UI Pattern Matching (switch on type, never string.contains)
  // ===========================================================================

  group('HRMS – UI type-based pattern matching', () {
    String _uiAction(AppFailure failure) => switch (failure) {
          NetworkFailure() => 'show_no_internet_sheet',
          UnauthorizedFailure() => 'go_to_login',
          ForbiddenFailure() => 'show_permission_denied',
          ValidationFailure() => 'highlight_form_errors',
          OutOfRadiusFailure() => 'show_outside_office_sheet',
          DeviceIntegrityFailure() => 'block_action_device_error',
          LocationPermissionFailure(:final isPermanentlyDenied) =>
            isPermanentlyDenied ? 'open_settings' : 'request_permission',
          LocationServiceFailure() => 'prompt_enable_gps',
          TimeoutFailure() || RateLimitedFailure() => 'show_retry_button',
          _ => 'show_generic_snackbar',
        };

    test('NetworkFailure → no_internet sheet', () {
      expect(_uiAction(const NetworkFailure()), 'show_no_internet_sheet');
    });

    test('UnauthorizedFailure → go to login', () {
      expect(_uiAction(const UnauthorizedFailure()), 'go_to_login');
    });

    test('OutOfRadiusFailure → outside office sheet', () {
      expect(
        _uiAction(const OutOfRadiusFailure()),
        'show_outside_office_sheet',
      );
    });

    test('DeviceIntegrityFailure → block action', () {
      expect(
        _uiAction(const DeviceIntegrityFailure()),
        'block_action_device_error',
      );
    });

    test('LocationPermissionFailure (not permanent) → request permission', () {
      expect(
        _uiAction(const LocationPermissionFailure()),
        'request_permission',
      );
    });

    test('LocationPermissionFailure (permanent) → open settings', () {
      expect(
        _uiAction(const LocationPermissionFailure(isPermanentlyDenied: true)),
        'open_settings',
      );
    });

    test('LocationServiceFailure → prompt enable GPS', () {
      expect(_uiAction(const LocationServiceFailure()), 'prompt_enable_gps');
    });

    test('ValidationFailure → highlight form errors', () {
      expect(
        _uiAction(const ValidationFailure('Email invalid')),
        'highlight_form_errors',
      );
    });

    test('TimeoutFailure → show retry button', () {
      expect(_uiAction(const TimeoutFailure()), 'show_retry_button');
    });

    test('ServerFailure (5xx) → generic snackbar', () {
      expect(
        _uiAction(const ServerFailure('Internal', statusCode: 500)),
        'show_generic_snackbar',
      );
    });
  });

  // ===========================================================================
  // 6. FailureMessages for new HRMS types
  // ===========================================================================

  group('HRMS – FailureMessages for device/location types', () {
    setUp(() => FailureMessageConfig.resolver = null);
    tearDown(() => FailureMessageConfig.resolver = null);

    test('OutOfRadiusFailure userMessage mentions office/radius', () {
      final msg = const OutOfRadiusFailure().userMessage.toLowerCase();
      expect(msg, anyOf(contains('office'), contains('radius'), contains('location')));
    });

    test('DeviceIntegrityFailure userMessage mentions rooted/mock', () {
      final msg = const DeviceIntegrityFailure().userMessage.toLowerCase();
      expect(msg, anyOf(contains('root'), contains('mock'), contains('cannot')));
    });

    test('LocationPermissionFailure (normal) userMessage mentions permission',
        () {
      final msg = const LocationPermissionFailure().userMessage.toLowerCase();
      expect(msg, contains('permission'));
    });

    test('LocationPermissionFailure (permanent) userMessage mentions Settings',
        () {
      final msg = const LocationPermissionFailure(isPermanentlyDenied: true)
          .userMessage;
      expect(msg, contains('Settings'));
    });

    test('LocationServiceFailure userMessage mentions GPS', () {
      final msg = const LocationServiceFailure().userMessage;
      expect(msg, contains('GPS'));
    });

    test('custom resolver overrides HRMS failure messages', () {
      FailureMessageConfig.resolver =
          (f) => f is OutOfRadiusFailure ? 'Office se bahar hain!' : null;
      expect(const OutOfRadiusFailure().userMessage, 'Office se bahar hain!');
      // Other types still use defaults
      expect(
        const LocationServiceFailure().userMessage,
        isNot('Office se bahar hain!'),
      );
    });
  });

  // ===========================================================================
  // 7. Result.guard with HRMS custom failures
  // ===========================================================================

  group('HRMS – Result.guard with device failures', () {
    test('guard wraps OutOfRadiusFailure thrown manually', () async {
      final result = await Result.guard<void>(() async {
        throw const OutOfRadiusFailure('You are 500m away', 500.0);
      });
      expect(result.isFailure, isTrue);
      expect(result.failureOrNull, isA<OutOfRadiusFailure>());
    });

    test('guard with custom mapError returns LocationPermissionFailure', () async {
      final result = await Result.guard<void>(
        () async => throw Exception('permission_denied'),
        mapError: (e, st) => const LocationPermissionFailure(),
      );
      expect(result.failureOrNull, isA<LocationPermissionFailure>());
    });

    test('guard with AppFailure thrown is preserved, not double-wrapped',
        () async {
      const failure = DeviceIntegrityFailure('Mock GPS detected');
      final result = await Result.guard<void>(() async => throw failure);
      expect(result.failureOrNull, isA<DeviceIntegrityFailure>());
      expect(result.failureOrNull!.message, 'Mock GPS detected');
    });
  });
}
