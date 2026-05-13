enum PasswordResetRequestResult {
  unavailable,
  failure,
}

class PasswordResetService {
  static PasswordResetRequestBackend _backend =
      const PasswordResetUnavailableBackend();

  static void configureBackendForTesting(PasswordResetRequestBackend backend) {
    _backend = backend;
  }

  static Future<PasswordResetRequestResult> requestPasswordReset(
    String email,
  ) async {
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      return PasswordResetRequestResult.failure;
    }

    return _backend.requestPasswordReset(normalizedEmail);
  }
}

abstract class PasswordResetRequestBackend {
  const PasswordResetRequestBackend();

  Future<PasswordResetRequestResult> requestPasswordReset(String email);
}

class PasswordResetUnavailableBackend extends PasswordResetRequestBackend {
  const PasswordResetUnavailableBackend();

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    try {
      // Placeholder backend for upcoming in-app reset code integration.
      // Intentionally avoids any direct Rocket.Chat forgot-password API call.
      return PasswordResetRequestResult.unavailable;
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
