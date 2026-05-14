class PasswordPolicyValidator {
  static final RegExp _hasLowercase = RegExp(r'[a-z]');
  static final RegExp _hasUppercase = RegExp(r'[A-Z]');
  static final RegExp _hasNumber = RegExp(r'[0-9]');
  static final RegExp _hasSymbol = RegExp(r'[^A-Za-z0-9]');
  static final RegExp _hasFourOrMoreConsecutive = RegExp(r'(.)\1{3,}');

  static String? validateResetPassword(String value) {
    if (value.isEmpty) {
      return 'forgot_password_new_password_required';
    }
    if (value.length < 8) {
      return 'forgot_password_password_rule_min_length';
    }
    if (!_hasLowercase.hasMatch(value)) {
      return 'forgot_password_password_rule_lowercase';
    }
    if (!_hasUppercase.hasMatch(value)) {
      return 'forgot_password_password_rule_uppercase';
    }
    if (!_hasNumber.hasMatch(value)) {
      return 'forgot_password_password_rule_number';
    }
    if (!_hasSymbol.hasMatch(value)) {
      return 'forgot_password_password_rule_symbol';
    }
    if (_hasFourOrMoreConsecutive.hasMatch(value)) {
      return 'forgot_password_password_rule_repeating';
    }
    return null;
  }
}
