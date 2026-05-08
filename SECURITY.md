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

## ✅ Fixed in PR #2 (this PR – follow-up hardening)

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

## ⚠️ Open Findings (require product or infrastructure decisions)

### OPN-1 – Auth tokens exposed as URL query parameters (Medium)
**Location:** `lib/matrix_service.dart` → `withAuthQuery()`

**Detail:** `rc_uid` and `rc_token` are appended to image/media URLs as query
parameters. This means auth credentials appear in:
- Server access logs
- HTTP Referer headers sent to third-party CDNs
- Device browser history (web build)

**What was improved:** Log messages no longer expose these URLs (see fix #9
above). However, the tokens are still embedded in the URLs used by
`CachedNetworkImage` and passed across widget trees. Eliminating them
entirely requires a backend change.

**Remaining fix:** Upgrade the backend (Rocket.Chat) to use signed, expiring
media tokens, or proxy media downloads through a short-lived signed URL
endpoint so the main auth token is never embedded in a URL.

---

### OPN-3 – No TLS certificate pinning (Medium)
**Location:** all `http.get` / `http.post` calls in `matrix_service.dart` and
`reports/report_screen.dart`.

**Detail:** The app trusts the device's system CA store. On a device with a
custom CA installed (e.g. corporate MDM, or a compromised device) traffic to
`app.icsportals.org` and `reports.icsportals.org` could be intercepted.

**What was improved:** The Android network security config added in fix #13
above excludes user-installed CA certificates from the trust store in release
builds, which materially reduces the MITM risk without requiring certificate
pinning.

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
signing certificate SHA-1.

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
