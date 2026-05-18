import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ics_messenger_app/device_policy_service.dart';

void main() {
  group('DevicePolicyService UUID generation', () {
    test('generateUuidV4ForTesting returns a well-formed UUID v4', () {
      final uuid = DevicePolicyService.generateUuidV4ForTesting();

      // Basic format: 8-4-4-4-12 hex chars separated by hyphens.
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidRegex.hasMatch(uuid), isTrue,
          reason: 'UUID "$uuid" does not match UUID v4 format');
    });

    test('generateUuidV4ForTesting produces unique values', () {
      final ids = {
        for (var i = 0; i < 20; i++) DevicePolicyService.generateUuidV4ForTesting()
      };
      // All 20 generated IDs should be unique.
      expect(ids.length, 20);
    });
  });

  group('DevicePolicyService session registration', () {
    test(
      'checkDevicePolicy sends Rocket.Chat session headers and only device metadata',
      () async {
        final client = MockClient((request) async {
          expect(
            request.url.toString(),
            'https://apppolicy.icsportals.org/session/register',
          );
          expect(request.method, 'POST');
          expect(request.headers['Content-Type'], 'application/json');
          expect(request.headers['X-App-Policy-Key'], isNotEmpty);
          expect(request.headers['X-Auth-Token'], 'auth-token');
          expect(request.headers['X-User-Id'], 'user-id');

          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['device_id'], 'device-123');
          expect(body['device_name'], 'Pixel 9');
          expect(body['platform'], 'android');
          expect(body['app_version'], '1.0.1');
          expect(body.containsKey('user_id'), isFalse);
          expect(body.containsKey('username'), isFalse);

          return http.Response('{}', 200);
        });

        final result = await DevicePolicyService.checkDevicePolicy(
          client: client,
          authToken: 'auth-token',
          sessionUserId: 'user-id',
          deviceId: 'device-123',
          deviceName: 'Pixel 9',
          platform: 'android',
        );

        expect(result, DevicePolicyResult.allowed);
      },
    );

    test('checkDevicePolicy fails closed when session headers are missing', () async {
      final client = MockClient((request) async {
        fail('HTTP client should not be called when session headers are missing');
      });

      final result = await DevicePolicyService.checkDevicePolicy(
        client: client,
        authToken: '',
        sessionUserId: 'user-id',
        deviceId: 'device-123',
        deviceName: 'Pixel 9',
        platform: 'android',
      );

      expect(result, DevicePolicyResult.error);
    });
  });
}
