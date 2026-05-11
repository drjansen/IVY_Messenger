# Security Notes – ICS Messenger App

This document summarises the security findings from the initial review
(May 2026) and tracks the status of each item.

---

## ✅ Fixed in PR #1 (initial hardening)

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 1 | **Critical** | Firebase Admin SDK service-account private key committed to git (`google-services_Broken.json`) | File deleted from repo; patterns added to `.gitignore`. **Action required: immediately revoke key `8ab959a5...` in the Firebase / Google Cloud Console.** |
| 2 | **Critical** | Redundant Firebase config backup (`google-services_OLD.json`) committed to repo | File deleted from repo. |
| 3 | **High** | Plaintext user password stored in `SharedPreferences` ("Remember Me" feature) | Password storage removed entirely. Only the username (non-secret) is retained as a UI convenience. |
| 4 | **High** | Session auth tokens (`matrix_auth_token`, `rocketchat_auth_token`, `rocketchat_user_id`) stored unencrypted in `SharedPreferences` | Migrated to `flutter_secure_storage` (Android Keystore / iOS Keychain). A one-time migration transparently moves existing tokens on first launch. |
| 5 | **High** | Auth token and FCM push token printed to debug log (`print('🔒 [AUTH TOKEN] ...')`) | Log statements removed. |

---

## ✅ Fixed in PR #2 (follow-up hardening)

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 6 | **High** | Logout did not call `SessionManager.clearSession()` or clear `MatrixService` in-memory state | `_onLogout()` now `await`s `MatrixService.logout()` (server-side `/api/v1/logout` + in-memory + secure-storage clear) and `SessionManager.clearSession()`. |
| 7 | **Medium** | No server-side session invalidation on logout (OPN-2) | `MatrixService.logout()` now calls `POST /api/v1/logout` (with auth headers) before clearing local state. Network failure is best-effort and does not block local cleanup. |
| 8 | **Medium** | Verbose subscription data (room IDs, names, unread counts, timestamps) logged unconditionally (OPN-5) | Wrapped in `assert((){}())` so the logs are compiled out of release builds. |
| 9 | **Medium** | Auth-token-bearing URLs (`rc_uid`, `rc_token` query params) appeared in error log messages (`fetchAuthedBytes`, `probeUrl`) | Added `_safeUri()` helper that strips `rc_uid`/`rc_token` from log-bound URI strings; all URL-containing error messages updated. |
| 10 | **Low** | Upload endpoint debug prints leaked file paths, room IDs, and full response bodies (which may contain authed URLs) | Removed `print('Uploading file: …')`, `print('Full URI: …')` lines; response-body prints (`rooms.media ←`, `setAvatar ←`, `chat.postMessage(file) ←`) replaced with status-code-only debug-guarded prints. |
| 11 | **Low** | Avatar URL (auth-token-bearing) logged unconditionally in `_loadUserProfile` | Print statement removed. |
| 12 | **Low** | Missing `shared_preferences` import in `report_screen.dart` (compile-time bug) | Import added. |
| 13 | **Low** | No explicit Android network security policy; cleartext HTTP not explicitly prohibited | Added `android/app/src/main/res/xml/network_security_config.xml` disabling cleartext traffic app-wide and scoping the backend domains. Wired into `AndroidManifest.xml` via `android:networkSecurityConfig`. |

---

## ✅ Fixed in PR #3 (security review hardening)

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| 14 | **Medium** | Android release build was signed with the debug signing config | Removed `signingConfig = signingConfigs.getByName("debug")` from the release build type. Release signing now reads from `android/key.properties` (gitignored). Without `key.properties` the release APK is unsigned (Google Play will reject unsigned builds — this is the intended safe default). See **Release Signing Setup** below. |
| 15 | **Medium** | FCM notification payloads (room ID, message ID) logged unconditionally via `print()` in `lib/main.dart` | All FCM-related `print()` calls gated behind `kDebugMode`. In release builds, no notification metadata appears in device logs. |
| 16 | **Medium** | FCM message data and notification body (title, body text) logged via `debugPrint()` in `lib/chat_rooms_tab.dart` | `debugPrint()` was not suppressed in release builds. All FCM payload/body `debugPrint` calls wrapped in `kDebugMode` guards. |
| 17 | **Medium** | ~50 naked `print()` calls in `lib/matrix_service.dart` printed response bodies, rate-limit details, and error context in release builds | All remaining naked `print()` calls in `matrix_service.dart` wrapped in `assert(() { … }())` blocks (stripped from release builds). Response bodies are no longer printed at all — only HTTP status codes are included in assert-guarded messages. |
| 18 | **Medium** | Chat message attachments cached locally for 30 days (up to 500 objects) | Reduced to 7-day retention and 100-object limit in `lib/chat_screen.dart`. |
| 19 | **Medium** | Sensitive PII caches (`cached_announcements`, `cached_children`, `cached_lunch_menu`, `cached_chat_rooms`, `calendar_events`) in `SharedPreferences` persisted across logouts | `SessionManager.clearSession()` now removes all five cache keys on logout/session expiry. |
| 20 | **Low** | Android push notifications displayed full message content on lock screen | `NotificationCompat.Builder` in `MyFirebaseMessagingService.kt` now sets `VISIBILITY_PRIVATE` and provides a generic public version ("New message") that is shown on the lock screen instead of the actual content. |

---

## 🔐 Release Signing Setup

After removing the debug signing config, release builds require a keystore file.

### Steps to configure release signing:

1. **Generate a release keystore** (if you don't already have one):
   ```sh
   keytool -genkeypair -v \
     -keystore android/release.keystore \
     -alias release \
     -keyalg RSA -keysize 2048 \
     -validity 10000
   ```

2. **Create `android/key.properties`** (this file is gitignored):
   ```
   storeFile=release.keystore
   storePassword=<keystore-password>
   keyAlias=release
   keyPassword=<key-password>
   ```

3. **Store signing credentials securely in CI** (e.g. GitHub Actions secrets) and
   write `key.properties` as part of the CI job before building.

4. **Never commit** `key.properties`, `*.keystore`, or `*.jks` to version control —
   these patterns are already listed in `android/.gitignore`.

---

## ⚠️ Open Findings (require product or infrastructure decisions)

### OPN-1 – Auth tokens exposed as URL query parameters (Medium)
**Location:** `lib/matrix_service.dart` → `withAuthQuery()`

**Detail:** `rc_uid` and `rc_token` are appended to image/media URLs as query
parameters. This means auth credentials appear in:
- Server access logs
- HTTP Referer headers sent to third-party CDNs
- Device browser history (web build)

**What was improved (PR #2):** Log messages no longer expose these URLs (see fix #9
above). However, the tokens are still embedded in the URLs used by
`CachedNetworkImage` and passed across widget trees. Eliminating them
entirely requires a backend change.

**Remaining fix:** Upgrade the backend (Rocket.Chat) to use signed, expiring
media tokens, or proxy media downloads through a short-lived signed URL
endpoint so the main auth token is never embedded in a URL.

---

### OPN-2 – Same Rocket.Chat token forwarded to multiple backend domains (High)
**Location:** `lib/dashboard_screen.dart`, `lib/calendar_screen.dart`,
`lib/ptc_screen.dart`, `lib/reports/report_screen.dart`

**Detail:** The Rocket.Chat session token (`X-Auth-Token` / `X-User-Id`) is
forwarded directly to `reports.icsportals.org` and `ptc.icsportals.org`. This
expands the trust boundary: compromise of any one service can expose a token
that is valid across all services.

**What was assessed:** No low-risk client-side fix is available without backend
changes. Introducing fake service-specific tokens in the client would provide
no real security benefit.

**Remaining fix:** Implement audience-scoped, short-lived tokens per service on
the backend. The Rocket.Chat token should never leave the `app.icsportals.org`
domain. Consider a backend token-exchange endpoint that issues service-scoped
JWT tokens in response to a valid Rocket.Chat session proof.

---

### OPN-3 – No TLS certificate pinning (Medium)
**Location:** all `http.get` / `http.post` calls in `matrix_service.dart` and
`reports/report_screen.dart`.

**Detail:** The app trusts the device's system CA store. On a device with a
custom CA installed (e.g. corporate MDM, or a compromised device) traffic to
`app.icsportals.org` and `reports.icsportals.org` could be intercepted.

**What was improved (PR #2):** The Android network security config excludes
user-installed CA certificates from the trust store in release builds, which
materially reduces the MITM risk without requiring certificate pinning.

**Remaining fix:** For a stronger guarantee, implement certificate pinning via
`dart:io SecurityContext` or `ssl_pinning_plugin`, pinning the server's leaf
or intermediate certificate public-key hash.  This requires:
1. Obtaining the current public-key hash(es) from the server team.
2. Establishing a pin-rotation plan so the app can be updated before certs
   expire without locking users out.

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
signing certificate SHA-1. Note: the SHA-1 of the production signing cert will
change once you migrate away from the debug signing config (fix #14 above).
Update the Firebase key restriction after deploying the new release keystore.

---

### OPN-5 – Sensitive PII still stored in SharedPreferences (Medium)
**Location:** `lib/dashboard_screen.dart`, `lib/calendar_screen.dart`

**Detail:** Attendance, children, announcements, lunch menu, and calendar data
are cached in `SharedPreferences` as plaintext JSON. While these caches are now
cleared on logout (fix #19 above), they remain unencrypted while a user session
is active. On a rooted device or via a local backup, this data could be extracted.

**Remaining fix:** For higher assurance, migrate the most sensitive caches
(children, attendance) to `flutter_secure_storage` or an encrypted SQLite
database. This is not done in this PR because it requires a larger refactor of
the caching layer.

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
