import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' show basename;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'session_manager.dart';
import 'app_config.dart';
import 'firebase_bootstrap.dart';

enum MatrixLoginStatus {
  success,
  twoFactorRequired,
  twoFactorInvalid,
  failure,
}

class MatrixLoginResult {
  final MatrixLoginStatus status;
  final String? twoFactorMethod;
  final String? emailOrUsername;
  final String? message;

  const MatrixLoginResult({
    required this.status,
    this.twoFactorMethod,
    this.emailOrUsername,
    this.message,
  });

  bool get isSuccess => status == MatrixLoginStatus.success;
}

class MatrixService {
  static const _baseUrl = AppConfig.chatBaseUrl;
  static late String _authToken;
  static late String _userId;

  static String get rocketchatAuthToken => _authToken;
  static String get rocketchatUserId => _userId;
  static String get authToken => _authToken;
  static String get userId => _userId;

  static final Map<String, String?> _avatarCache = {};
  static DateTime? _lastAvatarFetch;
  static const _avatarFetchCooldown = Duration(milliseconds: 500);
  static Map<String, dynamic>? _cachedMe;
  static DateTime? _lastMeFetch;
  static const _meCacheDuration = Duration(seconds: 30);

  // --- Rate limit state (messages) ---
  static DateTime? _messagesRateLimitedUntil;
  static bool _revokedSessionHandled = false;
  static Future<void>? _revokedSessionLogoutFuture;
  static final ValueNotifier<String?> authEventNoticeKey =
      ValueNotifier<String?>(null);

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _keyAuthToken = 'matrix_auth_token';
  static const _keyUserId = 'matrix_user_id';

  static Future<void> persistSession() async {
    await _secure.write(key: _keyAuthToken, value: _authToken);
    await _secure.write(key: _keyUserId, value: _userId);
    // Migrate: remove any tokens previously written to plain SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('matrix_auth_token');
    await prefs.remove('matrix_user_id');
  }

  /// Clears all in-memory auth state and removes tokens from secure storage.
  /// Does NOT contact the server – call [logout] for a full server+client
  /// invalidation (e.g. when the user explicitly logs out).
  static Future<void> clearSession() async {
    _authToken = '';
    _userId = '';
    _avatarCache.clear();
    _cachedMe = null;
    _lastMeFetch = null;
    _lastAvatarFetch = null;
    _messagesRateLimitedUntil = null;
    await _secure.delete(key: _keyAuthToken);
    await _secure.delete(key: _keyUserId);
    // Belt-and-suspenders: remove any legacy plain-prefs copies.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('matrix_auth_token');
    await prefs.remove('matrix_user_id');
  }

  static void clearAuthEventNotice() {
    authEventNoticeKey.value = null;
  }

  static bool _matchesRevokedCode(String? value) {
    if (value == null || value.trim().isEmpty) return false;
    final normalized = value.trim().toUpperCase().replaceAll('-', '_');
    const revokedCodes = <String>{
      'SESSION_REVOKED',
      'LOGGED_IN_ON_ANOTHER_DEVICE',
      'SESSION_SUPERSEDED',
    };
    for (final code in revokedCodes) {
      if (normalized == code ||
          normalized.startsWith('$code:') ||
          normalized.startsWith('$code ') ||
          normalized.startsWith('${code}_') ||
          normalized.startsWith('$code-')) {
        return true;
      }
    }
    return false;
  }

  static bool _isRevokedSessionResponse(int statusCode, String? body) {
    if (statusCode != 401 && statusCode != 403) return false;
    if (body == null || body.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return false;
      final candidates = <String?>[
        decoded['code']?.toString(),
        decoded['errorCode']?.toString(),
        decoded['error_type']?.toString(),
        decoded['errorType']?.toString(),
        decoded['detail']?.toString(),
        decoded['error']?.toString(),
        decoded['message']?.toString(),
      ];
      return candidates.any(_matchesRevokedCode);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _runRevokedSessionLogout() async {
    _revokedSessionHandled = true;
    await clearSession();
    await SessionManager.clearSession();
    authEventNoticeKey.value = 'session_revoked_notice';
  }

  static Future<void> forceLogoutForRevokedSession() async {
    await _enforceRevokedSessionLogout();
  }

  static Future<void> _enforceRevokedSessionLogout() async {
    if (_revokedSessionHandled) return;
    if (_revokedSessionLogoutFuture != null) {
      await _revokedSessionLogoutFuture;
      return;
    }
    final pending = _runRevokedSessionLogout();
    _revokedSessionLogoutFuture = pending;
    try {
      await pending;
    } finally {
      // Only clear the same in-flight future instance created above.
      if (identical(_revokedSessionLogoutFuture, pending)) {
        _revokedSessionLogoutFuture = null;
      }
    }
  }

  static Future<void> handlePotentialRevokedSessionResponse(
    http.Response resp,
  ) async {
    if (_isRevokedSessionResponse(resp.statusCode, resp.body)) {
      await _enforceRevokedSessionLogout();
    }
  }

  static Future<void> handlePotentialRevokedSessionStatus(
    int statusCode, {
    String? responseBody,
  }) async {
    if (_isRevokedSessionResponse(statusCode, responseBody)) {
      await _enforceRevokedSessionLogout();
    }
  }

  static bool looksLikeRevokedSessionStatus(
    int statusCode, {
    String? responseBody,
  }) =>
      _isRevokedSessionResponse(statusCode, responseBody);

  /// Exposed for unit testing only.
  static bool isRevokedSessionResponseForTesting({
    required int statusCode,
    required String body,
  }) =>
      _isRevokedSessionResponse(statusCode, body);

  /// Calls the Rocket.Chat server-side logout endpoint, then clears all local
  /// auth state.  Best-effort: a network failure does not prevent local cleanup.
  static Future<void> logout() async {
    // Attempt server-side session invalidation first so the token cannot be
    // replayed even if it was captured from a log or network trace.
    if (_authToken.isNotEmpty && _userId.isNotEmpty) {
      try {
        await http
            .post(
              Uri.parse('$_baseUrl/api/v1/logout'),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        // Network failure is non-fatal; local cleanup still proceeds below.
        // Log at debug level so developers can see transient connectivity issues.
        assert(() {
          // ignore: avoid_print
          print('⚠️ MatrixService.logout: server-side invalidation failed: $e');
          return true;
        }());
      }
    }
    await clearSession();
  }

  static Future<bool> restoreSession() async {
    var token = await _secure.read(key: _keyAuthToken);
    var userId = await _secure.read(key: _keyUserId);

    // Migrate: move tokens from plain SharedPreferences to secure storage.
    if (token == null || userId == null) {
      final prefs = await SharedPreferences.getInstance();
      final legacyToken = prefs.getString('matrix_auth_token');
      final legacyUserId = prefs.getString('matrix_user_id');
      if (legacyToken != null && legacyUserId != null) {
        await _secure.write(key: _keyAuthToken, value: legacyToken);
        await _secure.write(key: _keyUserId, value: legacyUserId);
        await prefs.remove('matrix_auth_token');
        await prefs.remove('matrix_user_id');
        token = legacyToken;
        userId = legacyUserId;
      }
    }

    if (token != null && userId != null) {
      _authToken = token;
      _userId = userId;
      return true;
    }
    return false;
  }

  static Uri _abs(String url) {
    return Uri.parse(url.startsWith('http') ? url : '$_baseUrl$url');
  }

  /// Returns a copy of [uri] with auth-bearing query parameters removed,
  /// safe to include in log messages.
  static Uri _safeUri(Uri uri) {
    const sensitiveParams = {'rc_uid', 'rc_token'};
    if (!uri.queryParameters.keys.any(sensitiveParams.contains)) return uri;
    final sanitized = Map<String, String>.from(uri.queryParameters)
      ..removeWhere((k, _) => sensitiveParams.contains(k));
    if (sanitized.isEmpty) {
      // Rebuild URI without any query string.
      return Uri(
        scheme: uri.scheme,
        userInfo: uri.userInfo,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      );
    }
    return uri.replace(queryParameters: sanitized);
  }

  static Map<String, String> get _headers => {
    'X-Auth-Token': _authToken,
    'X-User-Id': _userId,
    'Content-Type': 'application/json',
  };

  static Map<String, String> get _authHeaders => {
    'X-Auth-Token': _authToken,
    'X-User-Id': _userId,
  };

  static Future<http.Response> _authedGet(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final resp = await http.get(uri, headers: headers ?? _headers);
    await handlePotentialRevokedSessionResponse(resp);
    return resp;
  }

  static Future<http.Response> _authedPost(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final resp = await http.post(
      uri,
      headers: headers ?? _headers,
      body: body,
    );
    await handlePotentialRevokedSessionResponse(resp);
    return resp;
  }

  /// Adds rc_uid/rc_token query parameters to a URL (relative or absolute),
  /// preserving any existing query parameters.
  static Uri withAuthQuery(String url) {
    final uri = _abs(url);

    // If already tokenized, do not override.
    if (uri.queryParameters.containsKey('rc_uid') ||
        uri.queryParameters.containsKey('rc_token')) {
      return uri;
    }

    final qp = Map<String, String>.from(uri.queryParameters);
    qp['rc_uid'] = _userId;
    qp['rc_token'] = _authToken;
    return uri.replace(queryParameters: qp);
  }

  static Future<Uint8List?> fetchAuthedBytes(
      String url, {
        int maxRedirects = 5,
        Duration timeout = const Duration(seconds: 30),
      }) async {
    Uri current = _abs(url);

    for (int i = 0; i <= maxRedirects; i++) {
      http.Response resp;
      try {
        resp = await _authedGet(current, headers: _authHeaders).timeout(timeout);
      } catch (e) {
        assert(() {
          // ignore: avoid_print
          print('❌ fetchAuthedBytes error for ${_safeUri(current)}: $e');
          return true;
        }());
        return null;
      }

      final status = resp.statusCode;

      if (status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308) {
        final loc = resp.headers['location'];
        if (loc == null || loc.isEmpty) {
          assert(() {
            // ignore: avoid_print
            print('❌ fetchAuthedBytes redirect without location for ${_safeUri(current)}');
            return true;
          }());
          return null;
        }
        current = Uri.parse(loc.startsWith('http') ? loc : '$_baseUrl$loc');
        continue;
      }

      if (status != 200) {
        assert(() {
          final ct = resp.headers['content-type'];
          // ignore: avoid_print
          print(
              '❌ fetchAuthedBytes non-200=$status ct=$ct url=${_safeUri(current)} bytes=${resp.bodyBytes.length}');
          final preview = resp.bodyBytes.isNotEmpty
              ? utf8.decode(resp.bodyBytes.take(250).toList(),
              allowMalformed: true)
              : '';
          if (preview.isNotEmpty) {
            // ignore: avoid_print
            print('❌ fetchAuthedBytes body preview: $preview');
          }
          return true;
        }());
        return null;
      }

      if (resp.bodyBytes.isEmpty) {
        assert(() {
          // ignore: avoid_print
          print('❌ fetchAuthedBytes empty body for ${_safeUri(current)}');
          return true;
        }());
        return null;
      }

      return resp.bodyBytes;
    }

    assert(() {
      // ignore: avoid_print
      print('❌ fetchAuthedBytes exceeded maxRedirects=$maxRedirects for ${_safeUri(_abs(url))}');
      return true;
    }());
    return null;
  }

  static Future<void> probeUrl(String url) async {
    assert(() {
      // probeUrl is a debug-only diagnostic helper; compile out of release.
      _abs(url); // validate the URL parses.
      return true;
    }());
    // Only run the actual network probe in debug mode.
    assert(() {
      final uri = _abs(url);
      http.get(uri, headers: _authHeaders).then((resp) {
        // ignore: avoid_print
        print(
            '🔎 probeUrl ${_safeUri(uri)} -> ${resp.statusCode} ct=${resp.headers['content-type']} bytes=${resp.bodyBytes.length}');
      }).catchError((Object e) {
        // ignore: avoid_print
        print('❌ probeUrl error for ${_safeUri(_abs(url))}: $e');
      });
      return true;
    }());
  }

  static String getMimeType(String filePathOrName) {
    final ext = filePathOrName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'jfif':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  static bool _isLikelyImageByName(String filename) {
    final name = filename.toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp') ||
        name.endsWith('.jfif');
  }

  static int? _parseRetryAfterSecondsFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error']?.toString() ?? '';
        final m = RegExp(r'wait\s+(\d+)\s+seconds', caseSensitive: false)
            .firstMatch(err);
        if (m != null) return int.tryParse(m.group(1) ?? '');
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _getUserAvatar(String userId) async {
    if (_avatarCache.containsKey(userId)) return _avatarCache[userId];

    if (_lastAvatarFetch != null &&
        DateTime.now().difference(_lastAvatarFetch!) < _avatarFetchCooldown) {
      final defaultAvatar = withAuthQuery('/avatar/$userId').toString();
      _avatarCache[userId] = defaultAvatar;
      return defaultAvatar;
    }
    _lastAvatarFetch = DateTime.now();

    if (userId == _userId) {
      final me = await getMe();
      _avatarCache[userId] = me['avatarUrl'] as String?;
      return _avatarCache[userId];
    }

    try {
      final resp = await _authedGet(
        Uri.parse('$_baseUrl/api/v1/users.info?userId=$userId'),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ _getUserAvatar rate limited for $userId');
          return true;
        }());
        final defaultAvatar = withAuthQuery('/avatar/$userId').toString();
        _avatarCache[userId] = defaultAvatar;
        return defaultAvatar;
      }

      if (resp.statusCode != 200) {
        _avatarCache[userId] = null;
        return null;
      }

      final dec = jsonDecode(resp.body) as Map<String, dynamic>;
      final rawUser =
      (dec['user'] ?? (dec['data'] as Map?)?['user']) as Map<String, dynamic>?;
      if (rawUser == null) {
        _avatarCache[userId] = null;
        return null;
      }

      final username = rawUser['username'] as String? ?? userId;
      var avatar = rawUser['avatarUrl'] as String? ??
          rawUser['avatar'] as String? ??
          '/avatar/$username';
      if (!avatar.startsWith('http')) avatar = '$_baseUrl$avatar';

      final etag = rawUser['avatarETag'] as String?;
      if (etag != null && etag.isNotEmpty) {
        avatar = avatar.contains('?') ? '$avatar&etag=$etag' : '$avatar?etag=$etag';
      }

      final authed = withAuthQuery(avatar).toString();
      _avatarCache[userId] = authed;
      return authed;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ _getUserAvatar error for $userId: $e');
        return true;
      }());
      final defaultAvatar = withAuthQuery('/avatar/$userId').toString();
      _avatarCache[userId] = defaultAvatar;
      return defaultAvatar;
    }
  }

  /// Parses a non-200 login response body and returns the appropriate
  /// [MatrixLoginResult].  Exposed for testing via
  /// [parseFailedLoginResponseForTesting].
  static MatrixLoginResult _parseFailedLoginResponse(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>?;
      final errorType =
          (decoded?['errorType'] ?? decoded?['error'])?.toString();
      if (errorType == 'totp-required') {
        final details = decoded?['details'] as Map<String, dynamic>?;
        return MatrixLoginResult(
          status: MatrixLoginStatus.twoFactorRequired,
          twoFactorMethod: details?['method']?.toString(),
          emailOrUsername: details?['emailOrUsername']?.toString(),
        );
      }
      if (errorType == 'totp-invalid') {
        final details = decoded?['details'] as Map<String, dynamic>?;
        return MatrixLoginResult(
          status: MatrixLoginStatus.twoFactorInvalid,
          twoFactorMethod: details?['method']?.toString(),
        );
      }
    } catch (_) {}
    return const MatrixLoginResult(status: MatrixLoginStatus.failure);
  }

  /// Exposed for unit testing only.
  static MatrixLoginResult parseFailedLoginResponseForTesting(String body) =>
      _parseFailedLoginResponse(body);

  static Future<MatrixLoginResult> login(
    String username,
    String password, {
    String? twoFactorCode,
    String? twoFactorMethod,
  }) async {
    try {
      final has2fa = twoFactorCode != null && twoFactorCode.isNotEmpty;
      final headers = {'Content-Type': 'application/json'};
      if (has2fa) {
        headers['x-2fa-code'] = twoFactorCode;
        headers['x-2fa-method'] =
            (twoFactorMethod != null && twoFactorMethod.isNotEmpty)
                ? twoFactorMethod
                : 'totp';
      }

      final body = <String, dynamic>{
        'user': username,
        'password': password,
      };
      if (has2fa) {
        body['code'] = twoFactorCode;
      }

      final resp = await http.post(
        Uri.parse('$_baseUrl/api/v1/login'),
        headers: headers,
        body: jsonEncode(body),
      );

      if (resp.statusCode != 200) {
        assert(() {
          // ignore: avoid_print
          print('❌ Login failed: ${resp.statusCode}');
          return true;
        }());
        // Note: _parseFailedLoginResponse reads the body only to distinguish
        // 2FA challenges (totp-required/totp-invalid) from generic failures.
        // It does not log any part of the response body.
        return _parseFailedLoginResponse(resp.body);
      }

      final data =
          (jsonDecode(resp.body)['data']) as Map<String, dynamic>;
      final authToken = data['authToken'] as String?;
      final userId = data['userId'] as String?;
      if (authToken == null || userId == null) {
        return const MatrixLoginResult(status: MatrixLoginStatus.failure);
      }

      _authToken = authToken;
      _userId = userId;
      _revokedSessionHandled = false;
      _revokedSessionLogoutFuture = null;
      authEventNoticeKey.value = null;

      _avatarCache.clear();
      _cachedMe = null;
      _lastMeFetch = null;
      _messagesRateLimitedUntil = null;

      await persistSession();
      return const MatrixLoginResult(status: MatrixLoginStatus.success);
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ Login exception: $e');
        return true;
      }());
      return const MatrixLoginResult(status: MatrixLoginStatus.failure);
    }
  }

  static Future<List<Map<String, dynamic>>> fetchJoinedRoomIds(String _) async {
    try {
      final resp = await _authedGet(
        Uri.parse('$_baseUrl/api/v1/subscriptions.get'),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ fetchJoinedRoomIds rate limited');
          return true;
        }());
        return [];
      }

      if (resp.statusCode != 200) {
        assert(() {
          // ignore: avoid_print
          print('❌ fetchRooms failed: ${resp.statusCode}');
          return true;
        }());
        return [];
      }

      final subs = (jsonDecode(resp.body)['update']) as List<dynamic>;

      // Debug-only: subscription payload inspection (room type + unread counters).
      // Guarded so it is compiled out of release builds.
      assert(() {
        for (final s in subs) {
          // ignore: avoid_print
          print(
            'SUB rid=${s['rid']} t=${s['t']} fname=${s['fname']} '
                'unread=${s['unread']} alert=${s['alert']} open=${s['open']} '
                'ls=${s['ls']}',
          );
        }
        return true;
      }());

      return subs.map((s) {
        final rawUnread = s['unread'];
        final int unreadCount =
        rawUnread != null ? int.tryParse(rawUnread.toString()) ?? 0 : 0;

        String? avatarUrl;
        final avatarPath = s['avatar'] as String?;
        final avatarETag = s['avatarETag'] as String?;
        if (avatarPath != null && avatarPath.isNotEmpty) {
          avatarUrl = avatarPath.startsWith('http')
              ? avatarPath
              : '$_baseUrl$avatarPath';
          if (avatarETag != null && avatarETag.isNotEmpty) {
            avatarUrl = avatarUrl.contains('?')
                ? '$avatarUrl&etag=$avatarETag'
                : '$avatarUrl?etag=$avatarETag';
          }
          avatarUrl = withAuthQuery(avatarUrl).toString();
        }

        return {
          'id': s['rid'] as String,
          'name': s['fname'] as String? ?? '',
          'unread': unreadCount,
          'type': s['t'] as String,
          'muted': s['muted'] as bool? ?? false,
          'alert': s['alert'] as bool? ?? false, // ✅ ADDED: per-room activity indicator
          'avatarUrl': avatarUrl,
        };
      }).toList();
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ fetchJoinedRoomIds error: $e');
        return true;
      }());
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> fetchMessages(
      String roomId, String roomType) async {
    if (_messagesRateLimitedUntil != null &&
        DateTime.now().isBefore(_messagesRateLimitedUntil!)) {
      assert(() {
        // ignore: avoid_print
        print(
            '⏳ fetchMessages skipped until $_messagesRateLimitedUntil (rate limited)');
        return true;
      }());
      return [];
    }

    final endpoint = roomType == 'd'
        ? 'im.history'
        : roomType == 'c'
        ? 'channels.messages'
        : 'groups.messages';

    try {
      final resp = await _authedGet(
        Uri.parse('$_baseUrl/api/v1/$endpoint?roomId=$roomId&count=50'),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ fetchMessages rate limited');
          return true;
        }());
        final waitSeconds = _parseRetryAfterSecondsFromBody(resp.body);
        final backoff = Duration(seconds: (waitSeconds ?? 30) + 1);
        _messagesRateLimitedUntil = DateTime.now().add(backoff);
        assert(() {
          // ignore: avoid_print
          print(
              '⏳ fetchMessages cooldown set for ${backoff.inSeconds}s (until $_messagesRateLimitedUntil)');
          return true;
        }());
        return [];
      }

      _messagesRateLimitedUntil = null;

      if (resp.statusCode != 200) {
        assert(() {
          // ignore: avoid_print
          print('❌ fetchMessages failed: ${resp.statusCode}');
          return true;
        }());
        return [];
      }

      final list = (jsonDecode(resp.body)['messages']) as List<dynamic>;
      final results = <Map<String, dynamic>>[];

      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        final entry = <String, dynamic>{
          'senderId': m['u']?['_id']?.toString() ?? '',
          'event_id': m['_id']?.toString() ?? '',
          'sender': m['u']?['username']?.toString().toLowerCase() ?? '',
          'body': m['msg']?.toString() ?? '',
          'timestamp': m['ts'] != null
              ? DateTime.parse(m['ts'].toString()).millisecondsSinceEpoch
              : 0,
        };

        if (m['animatedEmoji'] != null &&
            m['animatedEmoji'].toString().isNotEmpty) {
          entry['animatedEmoji'] = m['animatedEmoji'].toString();
        } else if (m['attachments'] is List) {
          final atts = m['attachments'] as List<dynamic>;
          if (atts.isNotEmpty && atts[0]['animatedEmoji'] != null) {
            entry['animatedEmoji'] = atts[0]['animatedEmoji'].toString();
          }
        }

        final file = m['file'] as Map<String, dynamic>?;
        if (file != null && file['url'] != null) {
          entry['imageUrl'] = withAuthQuery(file['url'].toString()).toString();
        } else if (m['attachments'] is List) {
          final atts = m['attachments'] as List<dynamic>;
          if (atts.isNotEmpty) {
            final img = atts[0]['image_url'] as String? ??
                atts[0]['title_link'] as String?;
            if (img != null) {
              entry['imageUrl'] = withAuthQuery(img).toString();
            }
          }
        }

        if (m['tmid'] != null) {
          entry['replyToEventId'] = m['tmid'] as String;
        }

        final uid = entry['senderId'] as String;
        entry['avatarUrl'] = await _getUserAvatar(uid);

        results.add(entry);
      }

      return results.reversed.toList();
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ fetchMessages error: $e');
        return true;
      }());
      return [];
    }
  }

  static Future<bool> sendMessage(
      String roomId,
      String text, {
        String? threadId,
        String? animatedEmoji,
      }) async {
    final payload = <String, dynamic>{
      'roomId': roomId,
      'text': text,
      if (threadId != null) 'tmid': threadId,
      if (animatedEmoji != null && animatedEmoji.isNotEmpty)
        'animatedEmoji': animatedEmoji,
    };

    try {
      final resp = await _authedPost(
        Uri.parse('$_baseUrl/api/v1/chat.postMessage'),
        body: jsonEncode(payload),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ sendMessage rate limited');
          return true;
        }());
        return false;
      }

      if (resp.statusCode != 200) {
        assert(() {
          // ignore: avoid_print
          print('❌ sendMessage failed: ${resp.statusCode}');
          return true;
        }());
        return false;
      }
      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ sendMessage error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<Map<String, dynamic>?> _uploadToRoomsMedia(
      String roomId,
      String filePath, {
        String? message,
      }) async {
    final uri = Uri.parse('$_baseUrl/api/v1/rooms.media/$roomId');

    final req = http.MultipartRequest('POST', uri)..headers.addAll(_authHeaders);

    req.fields['roomId'] = roomId;

    if (message != null && message.trim().isNotEmpty) {
      req.fields['msg'] = message.trim();
    }

    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        filePath,
        filename: basename(filePath),
        contentType: MediaType.parse(getMimeType(filePath)),
      ),
    );

    try {
      final res = await req.send();
      final body = await res.stream.bytesToString();
      await handlePotentialRevokedSessionStatus(
        res.statusCode,
        responseBody: body,
      );
      assert(() {
        // ignore: avoid_print
        print('⬅️ rooms.media ← ${res.statusCode}');
        return true;
      }());

      if (res.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ rooms.media rate limited');
          return true;
        }());
        return null;
      }

      if (res.statusCode != 200) return null;

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['success'] != true) return null;

      final file = decoded['file'];
      if (file is! Map<String, dynamic>) return null;

      final url = file['url']?.toString();
      if (url == null || url.isEmpty) return null;

      return file;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ rooms.media upload error: $e');
        return true;
      }());
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _uploadToRoomsMediaBytes(
      String roomId,
      Uint8List bytes,
      String filename, {
        String? message,
      }) async {
    final uri = Uri.parse('$_baseUrl/api/v1/rooms.media/$roomId');

    final req = http.MultipartRequest('POST', uri)..headers.addAll(_authHeaders);

    req.fields['roomId'] = roomId;

    if (message != null && message.trim().isNotEmpty) {
      req.fields['msg'] = message.trim();
    }

    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: MediaType.parse(getMimeType(filename)),
      ),
    );

    try {
      final res = await req.send();
      final body = await res.stream.bytesToString();
      await handlePotentialRevokedSessionStatus(
        res.statusCode,
        responseBody: body,
      );
      assert(() {
        // ignore: avoid_print
        print('⬅️ rooms.media(bytes) ← ${res.statusCode}');
        return true;
      }());

      if (res.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ rooms.media(bytes) rate limited');
          return true;
        }());
        return null;
      }

      if (res.statusCode != 200) return null;

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['success'] != true) return null;

      final file = decoded['file'];
      if (file is! Map<String, dynamic>) return null;

      final url = file['url']?.toString();
      if (url == null || url.isEmpty) return null;

      return file;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ rooms.media(bytes) upload error: $e');
        return true;
      }());
      return null;
    }
  }

  /// IMPORTANT for grouping in the app UI:
  /// - When the upload is an image and the user didn't provide a caption,
  ///   we send an empty text (so `msg` is empty).
  static Future<bool> _postFileMessage({
    required String roomId,
    required Map<String, dynamic> file,
    String? message,
  }) async {
    final relativeUrl = file['url']?.toString();
    if (relativeUrl == null || relativeUrl.isEmpty) return false;

    final authedUrl = withAuthQuery(relativeUrl).toString();
    final filename =
        file['name']?.toString() ?? basename(Uri.parse(authedUrl).path);

    final caption = message?.trim();
    final bool hasCaption = caption != null && caption.isNotEmpty;
    final bool isImage = _isLikelyImageByName(filename);

    final String textToSend;
    if (hasCaption) {
      textToSend = caption!;
    } else if (isImage) {
      textToSend = '';
    } else {
      textToSend = filename;
    }

    final payload = <String, dynamic>{
      'roomId': roomId,
      'text': textToSend,
      'attachments': [
        {
          'title': filename,
          'title_link': authedUrl,
          if (isImage) 'image_url': authedUrl,
        }
      ],
    };

    try {
      final resp = await _authedPost(
        Uri.parse('$_baseUrl/api/v1/chat.postMessage'),
        body: jsonEncode(payload),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ chat.postMessage(file) rate limited');
          return true;
        }());
        return false;
      }

      assert(() {
        // ignore: avoid_print
        print('⬅️ chat.postMessage(file) ← ${resp.statusCode}');
        return true;
      }());
      if (resp.statusCode != 200) return false;

      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ chat.postMessage(file) error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<bool> uploadFile(
      String roomId,
      String filePath, {
        String? message,
      }) async {
    try {
      final file = await _uploadToRoomsMedia(roomId, filePath, message: message);
      if (file == null) return false;

      final ok =
      await _postFileMessage(roomId: roomId, file: file, message: message);
      assert(() {
        if (!ok) {
          // ignore: avoid_print
          print('❌ uploadFile: upload succeeded but posting message failed.');
        }
        return true;
      }());
      return ok;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ uploadFile error: $e');
        return true;
      }());
      return false;
    }
  }

  /// New: upload when you only have bytes (reliable for MediaStore/camera images).
  static Future<bool> uploadBytes(
      String roomId,
      Uint8List bytes,
      String filename, {
        String? message,
      }) async {
    try {
      final file = await _uploadToRoomsMediaBytes(
        roomId,
        bytes,
        filename,
        message: message,
      );
      if (file == null) return false;

      final ok =
      await _postFileMessage(roomId: roomId, file: file, message: message);
      assert(() {
        if (!ok) {
          // ignore: avoid_print
          print('❌ uploadBytes: upload succeeded but posting message failed.');
        }
        return true;
      }());
      return ok;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ uploadBytes error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<void> registerPushToken(String _) async {
    if (kIsWeb || !FirebaseBootstrap.isAvailable) return;
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;

    try {
      await _authedPost(
        Uri.parse('$_baseUrl/api/v1/push.token'),
        body: jsonEncode({
          'type': 'gcm',
          'value': token,
          'appName': AppConfig.pushAppName,
        }),
      );
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ registerPushToken error: $e');
        return true;
      }());
    }
  }

  static Future<bool> markRoomAsRead(String roomId) async {
    try {
      final resp = await _authedPost(
        Uri.parse('$_baseUrl/api/v1/subscriptions.read'),
        body: jsonEncode({'rid': roomId}),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ markRoomAsRead rate limited');
          return true;
        }());
        return false;
      }

      if (resp.statusCode != 200) {
        assert(() {
          // ignore: avoid_print
          print('❌ markRoomAsRead failed: ${resp.statusCode}');
          return true;
        }());
        return false;
      }
      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ markRoomAsRead error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<Map<String, dynamic>> getMe() async {
    if (_cachedMe != null &&
        _lastMeFetch != null &&
        DateTime.now().difference(_lastMeFetch!) < _meCacheDuration) {
      return _cachedMe!;
    }

    Map<String, dynamic>? userMap;

    try {
      final resp = await _authedGet(
        Uri.parse('$_baseUrl/api/v1/me'),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ getMe rate limited');
          return true;
        }());
        if (_cachedMe != null) return _cachedMe!;
        return {
          'username': _userId,
          'name': '',
          'avatarUrl': withAuthQuery('/avatar/$_userId').toString(),
        };
      }

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          if (decoded.containsKey('username') || decoded.containsKey('_id')) {
            userMap = decoded;
          } else {
            final data = decoded['data'] as Map<String, dynamic>?;
            if (data != null) {
              final u = data['user'] ?? data['me'];
              if (u is Map<String, dynamic>) userMap = Map.from(u);
            }
            if (userMap == null) {
              final u = decoded['user'] ?? decoded['me'];
              if (u is Map<String, dynamic>) userMap = Map.from(u);
            }
          }
        }
      }
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ getMe /me endpoint error: $e');
        return true;
      }());
    }

    if (userMap == null) {
      try {
        final info = await _authedGet(
          Uri.parse('$_baseUrl/api/v1/users.info?userId=$_userId'),
        );

        if (info.statusCode == 429) {
          assert(() {
            // ignore: avoid_print
            print('⚠️ getMe users.info rate limited');
            return true;
          }());
          if (_cachedMe != null) return _cachedMe!;
          return {
            'username': _userId,
            'name': '',
            'avatarUrl': withAuthQuery('/avatar/$_userId').toString(),
          };
        }

        if (info.statusCode == 200) {
          final dec = jsonDecode(info.body);
          final direct = dec['user'];
          final nested = (dec['data'] as Map?)?['user'];
          final raw = direct is Map<String, dynamic> ? direct : nested;
          if (raw is Map<String, dynamic>) userMap = Map.from(raw);
        }
      } catch (e) {
        assert(() {
          // ignore: avoid_print
          print('❌ getMe users.info fallback error: $e');
          return true;
        }());
      }
    }

    if (userMap == null) {
      assert(() {
        // ignore: avoid_print
        print('❌ getMe: could not retrieve user');
        return true;
      }());
      return {
        'username': _userId,
        'name': '',
        'avatarUrl': withAuthQuery('/avatar/$_userId').toString(),
      };
    }

    final username = userMap['username'] as String? ?? '';
    final name = userMap['name'] as String? ?? username;
    var avatar = userMap['avatarUrl'] as String? ??
        (userMap['avatar'] as String?) ??
        '/avatar/$username';
    if (!avatar.startsWith('http')) avatar = '$_baseUrl$avatar';
    final etag = userMap['avatarETag'] as String?;
    if (etag != null && etag.isNotEmpty) {
      avatar = avatar.contains('?') ? '$avatar&etag=$etag' : '$avatar?etag=$etag';
    }

    final result = {
      'username': username,
      'name': name,
      'avatarUrl': withAuthQuery(avatar).toString(),
    };

    _cachedMe = result;
    _lastMeFetch = DateTime.now();

    return result;
  }

  static Future<bool> setAvatar(File file) async {
    final uri = Uri.parse('$_baseUrl/api/v1/users.setAvatar');
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(_authHeaders)
      ..files.add(
        await http.MultipartFile.fromPath(
          'image',
          file.path,
          filename: basename(file.path),
          contentType: MediaType.parse(getMimeType(file.path)),
        ),
      );

    try {
      final res = await req.send();
      final body = await res.stream.bytesToString();
      await handlePotentialRevokedSessionStatus(
        res.statusCode,
        responseBody: body,
      );
      assert(() {
        // ignore: avoid_print
        print('⬅️ setAvatar ← ${res.statusCode}');
        return true;
      }());

      if (res.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ setAvatar rate limited');
          return true;
        }());
        return false;
      }

      if (res.statusCode != 200) return false;

      _cachedMe = null;
      _avatarCache.remove(_userId);

      final d = jsonDecode(body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ setAvatar error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<bool> setRoomMute(String roomId, bool mute) async {
    final uri = Uri.parse('$_baseUrl/api/v1/rooms.saveNotification');
    final body = jsonEncode({
      'roomId': roomId,
      'notifications': {
        'mobilePushNotifications': mute ? 'nothing' : 'all',
      }
    });

    try {
      final resp = await _authedPost(uri, body: body);

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ setRoomMute rate limited');
          return true;
        }());
        return false;
      }

      if (resp.statusCode != 200) {
        assert(() {
          // ignore: avoid_print
          print('❌ setRoomMute failed: ${resp.statusCode}');
          return true;
        }());
        return false;
      }
      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ setRoomMute error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<bool> reactToMessage(String messageId, String emoji) async {
    try {
      final resp = await _authedPost(
        Uri.parse('$_baseUrl/api/v1/chat.react'),
        body: jsonEncode({'messageId': messageId, 'emoji': emoji}),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ reactToMessage rate limited');
          return true;
        }());
        return false;
      }

      if (resp.statusCode != 200) return false;
      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ reactToMessage error: $e');
        return true;
      }());
      return false;
    }
  }

  static Future<bool> deleteMessage(String roomId, String messageId) async {
    try {
      final resp = await _authedPost(
        Uri.parse('$_baseUrl/api/v1/chat.delete'),
        body: jsonEncode({'roomId': roomId, 'msgId': messageId}),
      );

      if (resp.statusCode == 429) {
        assert(() {
          // ignore: avoid_print
          print('⚠️ deleteMessage rate limited');
          return true;
        }());
        return false;
      }

      if (resp.statusCode != 200) return false;
      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      return d['success'] == true;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('❌ deleteMessage error: $e');
        return true;
      }());
      return false;
    }
  }

  static void clearCaches() {
    _avatarCache.clear();
    _cachedMe = null;
    _lastMeFetch = null;
    _lastAvatarFetch = null;

    _messagesRateLimitedUntil = null;
  }

  /// Validates a restored session at startup to avoid entering a broken
  /// authenticated state with stale local tokens.
  static Future<bool> validateRestoredSession() async {
    try {
      if (_authToken.isEmpty || _userId.isEmpty) return false;
    } catch (_) {
      return false;
    }
    try {
      final resp = await _authedGet(Uri.parse('$_baseUrl/api/v1/me'));
      if (resp.statusCode == 200) return true;
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        await clearSession();
        await SessionManager.clearSession();
        return false;
      }
      return true;
    } catch (_) {
      // Connectivity issues should not force a logout.
      assert(() {
        // ignore: avoid_print
        print('⚠️ validateRestoredSession: unable to verify session online');
        return true;
      }());
      return true;
    }
  }
}
