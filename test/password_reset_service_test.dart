import 'package:flutter_test/flutter_test.dart';
import 'package:ivy_messenger/password_reset_service.dart';

void main() {
  group('PasswordResetService – input validation (no network required)', () {
    // ── requestPasswordReset ───────────────────────────────────────────────

    test('returns failure immediately for blank email', () async {
      final result = await PasswordResetService.requestPasswordReset('   ');
      expect(result, PasswordResetRequestResult.failure);
    });

    test('returns failure immediately for empty email', () async {
      final result = await PasswordResetService.requestPasswordReset('');
      expect(result, PasswordResetRequestResult.failure);
    });

    // ── confirmPasswordReset ──────────────────────────────────────────────

    test('returns failure immediately when email is empty', () async {
      final result = await PasswordResetService.confirmPasswordReset(
        email: '',
        code: '123456',
        newPassword: 'newPass123',
      );
      expect(result, PasswordResetConfirmResult.failure);
    });

    test('returns failure immediately when code is blank', () async {
      final result = await PasswordResetService.confirmPasswordReset(
        email: 'user@example.org',
        code: '   ',
        newPassword: 'newPass123',
      );
      expect(result, PasswordResetConfirmResult.failure);
    });

    test('returns failure immediately when newPassword is empty', () async {
      final result = await PasswordResetService.confirmPasswordReset(
        email: 'user@example.org',
        code: '123456',
        newPassword: '',
      );
      expect(result, PasswordResetConfirmResult.failure);
    });
  });
}
