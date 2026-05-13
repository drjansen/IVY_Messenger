import 'package:flutter_test/flutter_test.dart';
import 'package:ics_messenger_app/password_reset_service.dart';

void main() {
  group('PasswordResetService', () {
    test('returns unavailable for non-empty email in placeholder flow', () async {
      final result = await PasswordResetService.requestPasswordReset(
        'user@example.org',
      );

      expect(result, PasswordResetRequestResult.unavailable);
    });

    test('returns failure for empty email', () async {
      final result = await PasswordResetService.requestPasswordReset('   ');

      expect(result, PasswordResetRequestResult.failure);
    });
  });
}
