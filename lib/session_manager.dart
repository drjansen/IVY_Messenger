import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages Rocket.Chat user session state.
///
/// Security model:
/// - Auth tokens (rocketchatAuthToken, rocketchatUserId) are stored in the
///   platform secure keystore (Android Keystore / iOS Keychain) via
///   flutter_secure_storage.  They are never written to SharedPreferences.
///   (MatrixService manages its own matrix_auth_token / matrix_user_id tokens
///   identically, using its own FlutterSecureStorage instance.)
/// - The username is stored only in SharedPreferences as a non-sensitive UI
///   convenience (pre-fills the login field when "Remember Me" is on).
class SessionManager {
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyAuthToken = 'rocketchat_auth_token';
  static const _keyUserId = 'rocketchat_user_id';

  static String? username;
  static String? rocketchatAuthToken;
  static String? rocketchatUserId;

  // Save session info.
  static Future<void> saveSession({
    required String username,
    required String rocketchatAuthToken,
    required String rocketchatUserId,
  }) async {
    // Tokens go into the secure keystore.
    await _secure.write(key: _keyAuthToken, value: rocketchatAuthToken);
    await _secure.write(key: _keyUserId, value: rocketchatUserId);

    // Username is non-sensitive; keep in SharedPreferences for UI use only.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_username', username);

    // Migrate: remove any tokens that may have been stored in plain prefs.
    await prefs.remove('rocketchat_auth_token');
    await prefs.remove('rocketchat_user_id');

    SessionManager.username = username;
    SessionManager.rocketchatAuthToken = rocketchatAuthToken;
    SessionManager.rocketchatUserId = rocketchatUserId;
  }

  // Restore session info.
  static Future<bool> restoreSession() async {
    rocketchatAuthToken = await _secure.read(key: _keyAuthToken);
    rocketchatUserId = await _secure.read(key: _keyUserId);

    final prefs = await SharedPreferences.getInstance();
    username = prefs.getString('saved_username');

    // Migrate: if tokens were previously stored in plain prefs, move them to
    // secure storage and remove them from plain prefs.
    if (rocketchatAuthToken == null || rocketchatUserId == null) {
      final legacyToken = prefs.getString('rocketchat_auth_token');
      final legacyUserId = prefs.getString('rocketchat_user_id');
      if (legacyToken != null && legacyUserId != null) {
        await _secure.write(key: _keyAuthToken, value: legacyToken);
        await _secure.write(key: _keyUserId, value: legacyUserId);
        await prefs.remove('rocketchat_auth_token');
        await prefs.remove('rocketchat_user_id');
        rocketchatAuthToken = legacyToken;
        rocketchatUserId = legacyUserId;
      }
    }

    return username != null &&
        rocketchatAuthToken != null &&
        rocketchatUserId != null;
  }

  // Clear session info.
  static Future<void> clearSession() async {
    await _secure.delete(key: _keyAuthToken);
    await _secure.delete(key: _keyUserId);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_username');
    // Belt-and-suspenders: remove legacy plain-prefs copies if present.
    await prefs.remove('rocketchat_auth_token');
    await prefs.remove('rocketchat_user_id');

    username = null;
    rocketchatAuthToken = null;
    rocketchatUserId = null;
  }
}