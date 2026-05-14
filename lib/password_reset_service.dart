import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of a password-reset *request* call.
enum PasswordResetRequestResult {
  /// The request was accepted.  A reset code has been dispatched to the
  /// address if an account for it exists.  Use this neutral wording to
  /// avoid leaking whether a given email is registered.
  sent,

  /// A network or server error prevented the request from being processed.
  failure,
}

/// Result of a password-reset *confirm* call.
enum PasswordResetConfirmResult {
  /// The reset code was valid and the password has been updated.
  success,

  /// The code was wrong, expired, or a server/network error occurred.
  failure,
}

/// Service that integrates with the ICS policy-backend password-reset API.
///
/// Endpoint base URL and API-key follow the same pattern used by
/// [DevicePolicyService].  All HTTP calls are intentionally kept here so
/// that widget code contains no direct networking logic.
class PasswordResetService {
  // ── Backend configuration ─────────────────────────────────────────────────

  /// Base URL shared with the device-policy backend.
  static const _policyBaseUrl = 'https://apppolicy.icsportals.org';

  /// Pre-shared API key required by the Nginx reverse-proxy layer.
  static const _policyApiKey =
      'cd1fb10a79134e4d50f1da91f0bf1eb7e49deb6403b1be59116aca0e28fe3e15';

  static const _requestPath = '/password-reset/request';
  static const _confirmPath = '/password-reset/confirm';

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'X-App-Policy-Key': _policyApiKey,
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Requests a password-reset code for [email].
  ///
  /// Returns [PasswordResetRequestResult.sent] whether or not the account
  /// exists so that account enumeration is not possible.
  /// Returns [PasswordResetRequestResult.failure] on network or server error.
  static Future<PasswordResetRequestResult> requestPasswordReset(
    String email,
  ) async {
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      return PasswordResetRequestResult.failure;
    }

    try {
      final resp = await http
          .post(
            Uri.parse('$_policyBaseUrl$_requestPath'),
            headers: _headers,
            body: jsonEncode({'email': normalizedEmail}),
          )
          .timeout(const Duration(seconds: 15));

      // Any 2xx response (account found/accepted) and 404 (no account) are
      // treated as "sent" to prevent account-enumeration attacks.
      // The backend may return 202 Accepted when the reset email is queued
      // asynchronously, so all 2xx codes are valid success responses here.
      if ((resp.statusCode >= 200 && resp.statusCode < 300) ||
          resp.statusCode == 404) {
        return PasswordResetRequestResult.sent;
      }

      assert(() {
        // ignore: avoid_print
        print(
          '⚠️ PasswordResetService.request: unexpected status ${resp.statusCode}',
        );
        return true;
      }());
      return PasswordResetRequestResult.failure;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('⚠️ PasswordResetService.request: request failed: $e');
        return true;
      }());
      return PasswordResetRequestResult.failure;
    }
  }

  /// Confirms a password reset using the code sent to [email].
  ///
  /// Returns [PasswordResetConfirmResult.success] if the backend accepted the
  /// reset, or [PasswordResetConfirmResult.failure] on any error.
  static Future<PasswordResetConfirmResult> confirmPasswordReset({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final normalizedEmail = email.trim();
    final trimmedCode = code.trim();
    if (normalizedEmail.isEmpty ||
        trimmedCode.isEmpty ||
        newPassword.isEmpty) {
      return PasswordResetConfirmResult.failure;
    }

    try {
      final resp = await http
          .post(
            Uri.parse('$_policyBaseUrl$_confirmPath'),
            headers: _headers,
            body: jsonEncode({
              'email': normalizedEmail,
              'reset_code': trimmedCode,
              'new_password': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));

      // Accept any 2xx response as success; the backend may return 200, 201,
      // or 202 depending on whether the operation completed synchronously.
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return PasswordResetConfirmResult.success;
      }

      assert(() {
        // ignore: avoid_print
        print(
          '⚠️ PasswordResetService.confirm: unexpected status ${resp.statusCode}',
        );
        return true;
      }());
      return PasswordResetConfirmResult.failure;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('⚠️ PasswordResetService.confirm: request failed: $e');
        return true;
      }());
      return PasswordResetConfirmResult.failure;
    }
  }
}
