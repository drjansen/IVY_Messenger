# IVY Messenger

A private school communication app built with Flutter, designed for parents and teachers to communicate securely. The backend is powered by [Rocket.Chat](https://rocket.chat/).

## Features

- **Parent–Teacher Messaging** — Direct, private messaging between parents and teachers via a Rocket.Chat backend.
- **Dashboard** — Announcements, upcoming school events, attendance summary, and today's lunch menu at a glance.
- **Calendar** — School calendar with elementary and middle/high-school views.
- **PTC Scheduling** — Parent-Teacher Conference booking and management.
- **Incident Reports** — Structured incident/misconduct reporting with evidence upload.
- **Push Notifications** — Firebase Cloud Messaging (FCM) integration for real-time message alerts.
- **Two-Factor Authentication** — TOTP and email-based 2FA support.

## Getting Started

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install).
2. Replace the placeholder configuration values in `lib/app_config.dart` with your own environment settings:
   - `chatBaseUrl` — your Rocket.Chat server URL
   - `policyBaseUrl`, `reportsBaseUrl`, `ptcBaseUrl` — your school's backend service URLs
   - `privacyPolicyUri` — link to your privacy policy
   - `appPolicyKey` — your shared policy key
3. Add your Firebase configuration:
   - `android/app/google-services.json` — Android Firebase config
   - `ios/Runner/GoogleService-Info.plist` — iOS Firebase config (if targeting iOS)
4. Update the Android/iOS bundle/application identifiers if you plan to publish the app.
5. Run `flutter pub get`.
6. Run `flutter analyze` and `flutter test`.
7. Run `flutter run` on a connected device or emulator.

For Flutter help, see the [official documentation](https://docs.flutter.dev/).

## Configuration Placeholders

This repository has been sanitized for public visibility. The following files contain placeholder values that must be replaced before deploying:

| File | What to replace |
|------|----------------|
| `lib/app_config.dart` | Backend URLs, privacy-policy URL, shared policy key |
| `android/app/google-services.json` | Firebase Android configuration |
| Platform bundle/app identifiers | If you plan to publish the app to an app store |

## Backend

IVY Messenger uses [Rocket.Chat](https://rocket.chat/) as its messaging backend. The Flutter client communicates with the Rocket.Chat REST API for authentication, messaging, and user management.

## Security

See [SECURITY.md](SECURITY.md) for a full list of security findings addressed during the initial hardening passes and known open items.

---

## License

This project is released under the [MIT No Attribution License (MIT-0)](LICENSE).

> **Provided as-is, without warranty of any kind.** The authors and contributors accept no liability for any damages arising from the use of this software. See the [LICENSE](LICENSE) file for the full terms.

If you find this project useful, a ⭐ star on GitHub is always appreciated — it helps others discover it too.
If you adapt IVY Messenger for your own school or organisation, consider forking the repo and sharing your improvements with the community.
