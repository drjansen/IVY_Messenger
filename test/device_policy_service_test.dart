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
        for (var _ in List.filled(20, 0)) DevicePolicyService.generateUuidV4ForTesting()
      };
      // All 20 generated IDs should be unique.
      expect(ids.length, 20);
    });
  });
}
