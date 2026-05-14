import 'package:flutter_test/flutter_test.dart';
import 'package:ics_messenger_app/password_policy_validator.dart';

void main() {
  group('PasswordPolicyValidator.validateResetPassword', () {
    test('requires at least 8 characters', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('Aa1!abc'),
        'forgot_password_password_rule_min_length',
      );
    });

    test('requires lowercase', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('AA1!AAAA'),
        'forgot_password_password_rule_lowercase',
      );
    });

    test('requires uppercase', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('aa1!aaaa'),
        'forgot_password_password_rule_uppercase',
      );
    });

    test('requires number', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('Aa!aaaaa'),
        'forgot_password_password_rule_number',
      );
    });

    test('requires symbol', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('Aa1aaaaa'),
        'forgot_password_password_rule_symbol',
      );
    });

    test('rejects 4+ identical consecutive characters', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('Aa1!aaaa'),
        'forgot_password_password_rule_repeating',
      );
    });

    test('accepts a valid password', () {
      expect(
        PasswordPolicyValidator.validateResetPassword('Aa1!bcdE'),
        isNull,
      );
    });
  });
}
