import 'package:flutter_test/flutter_test.dart';
import 'package:ivy_messenger/app_config.dart';

void main() {
  test('default public-release config uses obvious placeholder values', () {
    expect(AppConfig.appDisplayName, 'IVY Messenger');
    expect(Uri.parse(AppConfig.chatBaseUrl).host, 'chat.example.com');
    expect(Uri.parse(AppConfig.policyBaseUrl).host, 'policy.example.com');
    expect(Uri.parse(AppConfig.reportsBaseUrl).host, 'reports.example.com');
    expect(Uri.parse(AppConfig.ptcBaseUrl).host, 'ptc.example.com');
    expect(AppConfig.privacyPolicyUri.toString(), 'https://example.com/privacy');
    expect(AppConfig.appPolicyKey, 'YOUR_APP_POLICY_KEY_HERE');
  });
}
