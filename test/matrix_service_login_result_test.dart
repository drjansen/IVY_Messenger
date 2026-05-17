import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ics_messenger_app/matrix_service.dart';

void main() {
  group('parseFailedLoginResponseForTesting', () {
    test('detects 2FA required and captures email method details', () {
      final body = jsonEncode({
        'status': 'error',
        'errorType': 'totp-required',
        'message': 'TOTP Required',
        'details': {
          'method': 'email',
          'emailOrUsername': 'user@example.org',
          'codeGenerated': true,
        },
      });

      final result = MatrixService.parseFailedLoginResponseForTesting(body);

      expect(result.status, MatrixLoginStatus.twoFactorRequired);
      expect(result.twoFactorMethod, 'email');
      expect(result.emailOrUsername, 'user@example.org');
    });

    test(
        'detects 2FA required from top-level error field and totp method',
        () {
      final body = jsonEncode({
        'status': 'error',
        'error': 'totp-required',
        'details': {
          'method': 'totp',
        },
      });

      final result = MatrixService.parseFailedLoginResponseForTesting(body);

      expect(result.status, MatrixLoginStatus.twoFactorRequired);
      expect(result.twoFactorMethod, 'totp');
      expect(result.emailOrUsername, isNull);
    });

    test('detects invalid 2FA code', () {
      final body = jsonEncode({
        'status': 'error',
        'errorType': 'totp-invalid',
        'details': {
          'method': 'email',
        },
      });

      final result = MatrixService.parseFailedLoginResponseForTesting(body);

      expect(result.status, MatrixLoginStatus.twoFactorInvalid);
      expect(result.twoFactorMethod, 'email');
    });

    test('treats unknown error shape as generic failure', () {
      final body = jsonEncode({
        'status': 'error',
        'error': 'Unauthorized',
      });

      final result = MatrixService.parseFailedLoginResponseForTesting(body);

      expect(result.status, MatrixLoginStatus.failure);
    });

    test('handles malformed response body as generic failure', () {
      const body = 'not-json';

      final result = MatrixService.parseFailedLoginResponseForTesting(body);

      expect(result.status, MatrixLoginStatus.failure);
    });
  });

  group('isRevokedSessionResponseForTesting', () {
    test('detects SESSION_REVOKED code on auth failure status', () {
      final body = jsonEncode({
        'code': 'SESSION_REVOKED',
        'detail': 'Session invalidated by newer login.',
      });

      final detected = MatrixService.isRevokedSessionResponseForTesting(
        statusCode: 403,
        body: body,
      );

      expect(detected, isTrue);
    });

    test('does not treat generic unauthorized as revoked session', () {
      final body = jsonEncode({'error': 'Unauthorized'});

      final detected = MatrixService.isRevokedSessionResponseForTesting(
        statusCode: 401,
        body: body,
      );

      expect(detected, isFalse);
    });
  });

  test('clearAuthEventNotice clears any pending auth event notice', () {
    MatrixService.authEventNoticeKey.value = 'session_revoked_notice';
    MatrixService.clearAuthEventNotice();
    expect(MatrixService.authEventNoticeKey.value, isNull);
  });
}
