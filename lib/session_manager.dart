import 'package:shared_preferences/shared_preferences.dart';

class SessionManager {
  static String? username;
  static String? rocketchatAuthToken;
  static String? rocketchatUserId;

  // Save session info to SharedPreferences
  static Future<void> saveSession({
    required String username,
    required String rocketchatAuthToken,
    required String rocketchatUserId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_username', username);
    await prefs.setString('rocketchat_auth_token', rocketchatAuthToken);
    await prefs.setString('rocketchat_user_id', rocketchatUserId);
    // update static variables
    SessionManager.username = username;
    SessionManager.rocketchatAuthToken = rocketchatAuthToken;
    SessionManager.rocketchatUserId = rocketchatUserId;
  }

  // Restore session info from SharedPreferences
  static Future<bool> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    username = prefs.getString('saved_username');
    rocketchatAuthToken = prefs.getString('rocketchat_auth_token');
    rocketchatUserId = prefs.getString('rocketchat_user_id');
    // return true if all fields are available
    return username != null && rocketchatAuthToken != null && rocketchatUserId != null;
  }

  // Clear session info
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_username');
    await prefs.remove('rocketchat_auth_token');
    await prefs.remove('rocketchat_user_id');
    username = null;
    rocketchatAuthToken = null;
    rocketchatUserId = null;
  }
}