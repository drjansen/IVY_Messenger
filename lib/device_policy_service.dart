import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'matrix_service.dart';

/// Result of a device-policy check call to the policy backend.
enum DevicePolicyResult {
  /// The backend registered or recognised this device and/or recorded a
  /// multi-device event for internal monitoring.  Login may proceed normally.
  allowed,

  /// The policy check could not be completed (network error, server error, …).
  /// Callers may choose to block or allow depending on their fail-open/fail-closed
  /// preference; the UI layer is responsible for presenting an appropriate message.
  error,

  /// The backend indicates this session was revoked/superseded by another login.
  revoked,
}

/// Integrates with the ICS messenger-app policy backend.
///
/// The backend tracks single-device session ownership and signals explicit
/// revocation responses when a newer login supersedes this session. This class
/// submits device information and interprets those revocation responses so the
/// UI can force local logout.
///
/// ## What data is collected
/// Only the minimum set required by the policy backend:
/// - `device_id` – a random, app-installation-specific UUID generated locally on
///                  first launch and persisted in the platform secure keystore.
///                  It is **not** a hardware identifier and carries no PII.
/// - `device_name` – human-readable model string from [device_info_plus]
///                  (e.g. "Pixel 7 Pro").  Used only for audit display.
/// - `platform`  – the OS name string (android / ios / web / …)
/// - `app_version` – the semver string declared in pubspec.yaml
///
/// No advertising IDs, IMEI, MAC addresses, or other sensitive hardware
/// identifiers are collected.  All collected fields are logged by the backend
/// only in the `device_events` audit table for PIPA-compliance review.
class DevicePolicyService {
  // ── Backend configuration ────────────────────────────────────────────────

  /// Base URL of the ICS messenger-app policy backend.
  ///
  /// Override this constant when deploying to a different environment.
  static const _policyBaseUrl = 'https://apppolicy.icsportals.org';

  /// The path of the device-policy check endpoint.
  static const _checkPath = '/session/register';

  /// Pre-shared API key sent in the `X-App-Policy-Key` request header.
  ///
  /// The Nginx reverse-proxy in front of the policy backend requires this
  /// header before forwarding any request.  Because this is an internal,
  /// closed-distribution app the key is embedded here; treat it as you would
  /// any low-privilege service credential (rotate on compromise).
  static const _policyApiKey = 'cd1fb10a79134e4d50f1da91f0bf1eb7e49deb6403b1be59116aca0e28fe3e15';

  // ── App metadata ─────────────────────────────────────────────────────────

  /// Semver app version string – keep in sync with pubspec.yaml `version`.
  static const _appVersion = '1.0.1';

  // ── Secure storage ───────────────────────────────────────────────────────

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Secure-storage key under which the stable installation ID is persisted.
  static const _keyDeviceId = 'device_policy_device_id';

  // ── Public API ───────────────────────────────────────────────────────────

  /// Checks the device-policy endpoint for the authenticated user.
  ///
  /// Must be called **after** a successful Rocket.Chat login so that the
  /// current Rocket.Chat session headers are available.
  ///
  /// Returns:
  /// - [DevicePolicyResult.allowed]  → backend accepted the current session
  /// - [DevicePolicyResult.revoked]  → backend reports this session is superseded
  /// - [DevicePolicyResult.error]    → transport/server error; caller decides
  static Future<DevicePolicyResult> checkDevicePolicy({
    http.Client? client,
    String? authToken,
    String? sessionUserId,
    String? deviceId,
    String? deviceName,
    String? platform,
  }) async {
    final resolvedAuthToken = authToken ?? MatrixService.authToken;
    final resolvedUserId = sessionUserId ?? MatrixService.userId;
    if (resolvedAuthToken.isEmpty || resolvedUserId.isEmpty) {
      assert(() {
        // ignore: avoid_print
        print('⚠️ DevicePolicyService: missing Rocket.Chat session headers');
        return true;
      }());
      return DevicePolicyResult.error;
    }
    if ((deviceName == null) != (platform == null)) {
      assert(() {
        // ignore: avoid_print
        print('⚠️ DevicePolicyService: deviceName/platform overrides must be provided together');
        return true;
      }());
      return DevicePolicyResult.error;
    }

    final requestClient = client ?? http.Client();
    try {
      final resolvedDeviceId = deviceId ?? await getOrCreateDeviceId();
      final resolvedDeviceInfo = deviceName != null
          ? _DeviceInfo(deviceName: deviceName, platform: platform!)
          : await getDeviceInfo();

      final payload = <String, String>{
        'device_id': resolvedDeviceId,
        'device_name': resolvedDeviceInfo.deviceName,
        'platform': resolvedDeviceInfo.platform,
        'app_version': _appVersion,
      };

      final resp = await requestClient
          .post(
            Uri.parse('$_policyBaseUrl$_checkPath'),
            headers: {
              'Content-Type': 'application/json',
              'X-App-Policy-Key': _policyApiKey,
              'X-Auth-Token': resolvedAuthToken,
              'X-User-Id': resolvedUserId,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        return DevicePolicyResult.allowed;
      }

      if ((resp.statusCode == 401 || resp.statusCode == 403) &&
          MatrixService.looksLikeRevokedSessionStatus(
            resp.statusCode,
            responseBody: resp.body,
          )) {
        return DevicePolicyResult.revoked;
      }

      // Any non-200 status indicates an unexpected server or configuration error.
      assert(() {
        // ignore: avoid_print
        print('⚠️ DevicePolicyService: unexpected status ${resp.statusCode}');
        return true;
      }());
      return DevicePolicyResult.error;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('⚠️ DevicePolicyService: request failed: $e');
        return true;
      }());
      return DevicePolicyResult.error;
    } finally {
      if (client == null) {
        requestClient.close();
      }
    }
  }

  // ── Device-ID helpers ────────────────────────────────────────────────────

  /// Returns the stable installation-specific device ID, creating and
  /// persisting a new one if this is the first launch.
  ///
  /// The ID is a randomly generated UUID v4 stored in the platform secure
  /// keystore.  It is not tied to any hardware identifier.
  static Future<String> getOrCreateDeviceId() async {
    var id = await _secure.read(key: _keyDeviceId);
    if (id == null || id.isEmpty) {
      id = _generateUuidV4();
      await _secure.write(key: _keyDeviceId, value: id);
    }
    return id;
  }

  // ── Device-info helpers ──────────────────────────────────────────────────

  /// Collects non-identifying device metadata for the policy request.
  static Future<_DeviceInfo> getDeviceInfo() async {
    if (kIsWeb) {
      return const _DeviceInfo(deviceName: 'Web Browser', platform: 'web');
    }
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return _DeviceInfo(
          deviceName: '${info.manufacturer} ${info.model}',
          platform: 'android',
        );
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        return _DeviceInfo(
          deviceName: info.model,
          platform: 'ios',
        );
      }
      if (Platform.isLinux) {
        return const _DeviceInfo(deviceName: 'Linux Device', platform: 'linux');
      }
      if (Platform.isMacOS) {
        final info = await plugin.macOsInfo;
        return _DeviceInfo(
          deviceName: info.model,
          platform: 'macos',
        );
      }
      if (Platform.isWindows) {
        return const _DeviceInfo(
          deviceName: 'Windows Device',
          platform: 'windows',
        );
      }
    } catch (_) {
      // Fall through to unknown.
    }
    return const _DeviceInfo(deviceName: 'Unknown Device', platform: 'unknown');
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  /// Exposed for unit testing only.
  static String generateUuidV4ForTesting() => _generateUuidV4();

  /// Generates a UUID v4 using a cryptographically secure random source.
  static String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));

    // Set version bits (version 4)
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant bits (variant 1)
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

/// Minimal device metadata collected for the policy-check request.
class _DeviceInfo {
  final String deviceName;
  final String platform;

  const _DeviceInfo({required this.deviceName, required this.platform});
}
