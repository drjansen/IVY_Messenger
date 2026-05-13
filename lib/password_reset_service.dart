import 'dart:convert';

import 'package:http/http.dart' as http;

enum PasswordResetRequestResult {
  success,
  failure,
}

class PasswordResetService {
  static const _endpoint = 'https://app.icsportals.org/api/v1/users.forgotPassword';

  static Future<PasswordResetRequestResult> requestPasswordReset(
    String email,
  ) async {
    try {
      final resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: const {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        return PasswordResetRequestResult.success;
      }

      assert(() {
        // ignore: avoid_print
        print('⚠️ PasswordResetService: unexpected status ${resp.statusCode}');
        return true;
      }());
      return PasswordResetRequestResult.failure;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('⚠️ PasswordResetService: request failed: $e');
        return true;
      }());
      return PasswordResetRequestResult.failure;
    }
  }
}
