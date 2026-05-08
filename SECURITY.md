# Security Notes – ICS Messenger App

This document summarises the security findings from the initial review
(May 2026) and tracks the status of each item.

---

## ✅ Fixed in this PR

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 1 | **Critical** | Firebase Admin SDK service-account private key committed to git (`google-services_Broken.json`) | File deleted from repo; patterns added to `.gitignore`. **Action required: immediately revoke key `8ab959a5...` in the Firebase / Google Cloud Console.** |
| 2 | **Critical** | Redundant Firebase config backup (`google-services_OLD.json`) committed to repo | File deleted from repo. |
| 3 | **High** | Plaintext user password stored in `SharedPreferences` ("Remember Me" feature) | Password storage removed entirely. Only the username (non-secret) is retained as a UI convenience. |
| 4 | **High** | Session auth tokens (`matrix_auth_token`, `rocketchat_auth_token`, `rocketchat_user_id`) stored unencrypted in `SharedPreferences` | Migrated to `flutter_secure_storage` (Android Keystore / iOS Keychain). A one-time migration transparently moves existing tokens on first launch. |
| 5 | **High** | Auth token and FCM push token printed to debug log (`print('🔒 [AUTH TOKEN] ...')`) | Log statements removed. |

---

## ⚠️ Open Findings (require product or infrastructure decisions)

### OPN-1 – Auth tokens exposed as URL query parameters (Medium)
**Location:** `lib/matrix_service.dart` → `withAuthQuery()`

**Detail:** `rc_uid` and `rc_token` are appended to image/media URLs as query
parameters. This means auth credentials appear in:
- Server access logs
- HTTP Referer headers sent to third-party CDNs
- Device browser history (web build)

**Recommended fix:** Upgrade the backend (Rocket.Chat) to use signed, expiring
media tokens, or proxy media downloads through a short-lived signed URL
endpoint so the main auth token is never embedded in a URL.

---

### OPN-2 – Session tokens not invalidated on server at logout (Medium)
**Location:** `lib/session_manager.dart` → `clearSession()`

**Detail:** Clearing local storage does not call the Rocket.Chat
`/api/v1/logout` endpoint. A stolen token snapshot remains valid until it
naturally expires on the server.

**Recommended fix:** Call `POST /api/v1/logout` (with auth headers) before
clearing local storage during explicit logout.

---

### OPN-3 – No TLS certificate pinning (Medium)
**Location:** all `http.get` / `http.post` calls in `matrix_service.dart` and
`reports/report_screen.dart`.

**Detail:** The app trusts the device's CA store. On a device with a custom CA
installed (e.g. corporate MDM, or a compromised device) traffic to
`app.icsportals.org` and `reports.icsportals.org` could be intercepted.

**Recommended fix:** Implement certificate pinning via `dart:io`
`SecurityContext` or the `ssl_pinning_plugin` package, pinning the server's
leaf or intermediate certificate public key.

---

### OPN-4 – Firebase API key not restricted (Low–Medium)
**Location:** `android/app/google-services.json` (`AIzaSyDj54Sk...`)

**Detail:** The client-side Firebase API key is present in the repository and
in the compiled app. By itself this is expected and not a secret; however, if
the key is not restricted in the Firebase / Google Cloud Console to:
- Specific Android package name & SHA-1
- Specific iOS bundle ID (if applicable)
- Only the Firebase services actually used (FCM, etc.)

…then it can be misused by anyone who reads the APK.

**Recommended fix:** In the Google Cloud Console → Credentials, restrict the
key to the package name `app.icsportals.ics_messenger_app` and the production
signing certificate SHA-1.

---

### OPN-5 – Verbose subscription data logged in debug mode (Low)
**Location:** `lib/matrix_service.dart` → `fetchJoinedRoomIds()` (lines ~303–311)

**Detail:** Every subscription record (room id, name, unread count, last-seen
timestamp) is printed via `print()`. This data is visible in ADB logcat and
may be captured by third-party crash-reporting SDKs.

**Recommended fix:** Wrap these `print` calls in a debug-only guard:
```dart
assert(() {
  print('SUB rid=...');
  return true;
}());
```
or remove them entirely before production release.

---

### OPN-6 – IP address logging and data retention (Regulatory – PIPA)
**Location:** server-side (Rocket.Chat / reports backend)

**Detail:** Per earlier legal analysis, logging IP addresses for security
purposes is likely lawful under South Korea's Personal Information Protection
Act (PIPA) if:
- The purpose is stated in the privacy policy
- Retention period is defined (recommended: 30–90 days)
- Access is restricted to authorised admins
- Data is not repurposed beyond stated security use

**Action required:**
1. Confirm IP logging is enabled and appropriately scoped on the server.
2. Update the app's Privacy Policy with explicit IP logging disclosure.
3. Set a server-side retention/purge policy.

---

## Responsible Disclosure

If you discover a security issue, please report it privately to the
institution's IT security contact rather than opening a public GitHub issue.
