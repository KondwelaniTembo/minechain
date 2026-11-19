# Security review of the mobile app (OWASP MASVS v2)

Hardening T1, 19 Nov 2026, on `chore/hardening` from `main` at `58b4c81`. Plan:
`docs/plans/hardening-plan.md`.

## 1. Scope and method

- **What:** the Android app as merged on `main` after PR #11: the mobile foundation (login,
  account request and activation, homes, account, pinned TLS, secure storage), the miner
  module (device key, encrypted local database, registration, sync, "My consignments"), the
  administrator's account requests screen, and Mapalo's design. The backend is reviewed with
  the server work and is out of scope here, except where the app relies on it.
- **Standard:** OWASP MASVS v2, the eight control groups. The MASVS-L1 baseline is the target,
  with the L2 controls NFR-01 and NFR-02 ask for (encryption at rest, pinning, keys in
  hardware). MASVS-R (resilience) is not a goal for a prototype, and is reported for
  completeness.
- **How:** the MASTG tests, named in each row. They were done by reading the source, the
  merged manifest of the latest build (the debug build of 19 Nov; a release build was started
  but stopped after 15 minutes without progress, and is run in T4 instead) and the lock file,
  plus advisory lookups. Plugins add the same entries to a debug and a release manifest; the
  only differences are `android:debuggable` and the debug-only INTERNET line. The tests that need a phone are T4 (§5). Unit and widget tests
  that already prove a control are named as evidence.
- **Not done:** no dynamic testing with Frida, no traffic interception with a proxy, and no
  decompiling of the APK. These are listed as limits of the review (§6).

## 2. Rating scale

OWASP Risk Rating, simplified to likelihood × impact for this app's setting (a prototype,
phones carried at mine sites, no app store):

| Rating | Meaning |
|---|---|
| **Critical** | Remote, needs no special access, and exposes keys or tokens, or lets someone sign as another user |
| **High** | Needs the phone briefly or a common tool (adb on an unlocked phone, a backup), and exposes the token, the database or signed work, or lets someone sign as its owner |
| **Medium** | Leaks personal data or work details without giving control (a screenshot, the recent-apps picture), or needs a rooted phone to do worse |
| **Low** | Defence in depth, or only on old Android versions |
| **Info** | A prototype limit with no direct attack |

## 3. Findings

| ID | Rating | MASVS | Finding | Proposed |
|---|---|---|---|---|
| H1 | **High** | AUTH-2, CRYPTO-2 | **The signing key works on a phone with no screen lock.** The key is made with `setUserAuthenticationRequired(false)` (`DeviceKeyPlugin.kt`, `createKey`) and nothing checks that the phone has a PIN, pattern or password. Anyone who picks up such a phone can open the app and register consignments signed as its owner, even after the token has expired (Mobile (11): offline work stays open). Mobile (11) recorded the unlocked-phone case as a known limit; the no-screen-lock case is the same gap, and it is the one an attacker meets most | Fix in T2, after the developer chooses (Q6 in the T1 report) |
| M1 | Medium | PLATFORM-3, STORAGE-2 | **No `FLAG_SECURE`.** The recent-apps screen keeps a picture of the last screen (an administrator's account requests with names and licence numbers, a miner's consignments), and screenshots and screen recording are allowed | Fix in T2: release builds only (Q1, approved) |
| M2 | Medium | STORAGE-1 | **On a rooted phone the database key can be read from secure storage**, so the database can be opened. The Keystore keeps the wrapping key, but root can ask the Keystore to unwrap | Accepted limit (already in the miner plan §7) |
| L1 | Low | PLATFORM-3 | **No tapjacking guard.** Android 12+ blocks touches that pass through another app's overlay; Android 8–11, inside NFR-09's range, does not | Fix in T2 (Q2, approved) |
| L2 | Low | CODE-4, RESILIENCE-3 | **No release build has been run on a phone.** Flutter turns on R8 shrinking for release builds, but nobody has built one yet or checked that the Keystore channel, sqlite3mc and ML Kit work after shrinking. Dart code is not obfuscated | T4 check 1, with `--obfuscate --split-debug-info` |
| L3 | Low | STORAGE-2 | **The demo has so far been run from debug builds**, which are debuggable: a debugger can attach and read memory (the token, the database key while open) | T4 check 1; the thesis demo uses a release build |
| L4 | Low | NETWORK-2 | **Pinning is to root CAs, not to the server's own key.** A wrongly issued certificate from one of the three pinned roots would be trusted | Accepted (Deployment (11): Render renews its certificates, so a leaf pin would break the app) |
| L5 | Low | PRIVACY-2, PRIVACY-3 | **ML Kit brings Google's data transport library** (`com.google.android.datatransport`, its CCT backend and a job scheduler in the merged manifest), which ML Kit uses to send usage and performance statistics to Google. The app itself sends nothing to Google, and no consignment data goes through it, but a user is not told | Accepted limit, named in the thesis; removing the library from the manifest could break the scanner, so not done |
| I1 | Info | AUTH-2 | Someone holding the owner's unlocked phone can sign as the owner. After H1 this is the remaining part of Mobile (11) | Accepted limit (NFR-06) |
| I2 | Info | CRYPTO-2 | No key attestation, so the server cannot tell a hardware key from a software one | Accepted limit (signing spec, known limits) |
| I3 | Info | RESILIENCE-1, 2, 4 | No root, emulator, tamper or debugger detection | Out of scope (MASVS-R is not a goal) |
| I4 | Info | RESILIENCE-2 | The release build is signed with Flutter's debug key | Prototype limit; a release key is for a real release |
| I5 | Info | CODE-2 | No forced-update mechanism | Prototype limit; the app is installed by hand |
| I6 | Info | STORAGE-1 | After a logout the previous user's signed steps stay in the database (on purpose, so unsynced work is not lost, NFR-04). "My consignments" shows only the signed-in user's rows | Accepted, by design (Mobile (34)) |

**Result: no Critical, one High (H1).** NFR-02 is met once H1 is fixed.

## 4. Control by control

### MASVS-STORAGE

| Control | What the app does | Evidence | MASTG test | Result |
|---|---|---|---|---|
| STORAGE-1 Sensitive data stored securely | Token, expiry, user and the database key in flutter_secure_storage 11.2.0: an RSA-OAEP key in the Keystore wraps an AES key, values AES-256-GCM, `resetOnError: false` | `lib/core/storage/secure_store.dart` (`_android`), Mobile (10), (19) | Testing Local Storage for Sensitive Data | Pass (M2 on root) |
| | Signed steps in a SQLCipher v4 database (SQLite3MultipleCiphers), WAL included, key of 32 bytes from `Random.secure()`, in the app's private support directory | `lib/core/database/open_encrypted.dart`, `database_key.dart:75`, `local_database.dart:145`, Mobile (1), (28) | Testing Local Storage for Sensitive Data | Pass (on-disk check in T4) |
| | No shared preferences, no external storage, no files outside the app's own directory | grep of `lib/` | Testing Local Storage for Sensitive Data | Pass |
| STORAGE-2 No leaks | Backup and device transfer off: `allowBackup="false"`, `data_extraction_rules.xml`, `backup_rules.xml`, every domain excluded | `AndroidManifest.xml`, `res/xml/`, Mobile (14) | Testing Backups for Sensitive Data | Pass (T4 check 3) |
| | Logs: release builds print only the name of a broken config rule; the sync debug line and the timing lines are behind `kDebugMode`, so not compiled into release; every failure's `toString()` prints codes and counts only; the Kotlin channel never logs and sends fixed codes only | `main.dart:85`, `sync_service.dart:428`, `core/errors/app_failure.dart`, `DeviceKeyPlugin.kt` | Testing Logs for Sensitive Data | Pass (T4 check 2) |
| | Keyboards: password, username, licence, activation code and weight fields have `autocorrect: false`, `enableSuggestions: false`; passwords are obscured, so they cannot be copied | `password_field.dart:63`, `login_screen.dart:181`, `register_screen.dart:227`, `activate_screen.dart:168`, `register_consignment_screen.dart:683` | Determining Whether the Keyboard Cache Is Disabled for Text Input Fields | Pass |
| | No clipboard use in the app's own code | grep of `lib/` | Determining Whether Sensitive Data Is Exposed via the Clipboard | Pass |
| | The recent-apps picture and screenshots | none | Finding Sensitive Information in Auto-Generated Screenshots | **M1** |

### MASVS-CRYPTO

| Control | What the app does | Evidence | MASTG test | Result |
|---|---|---|---|---|
| CRYPTO-1 Strong, current crypto | ECDSA P-256 with SHA-256 (`SHA256withECDSA`), DER; AES-256 for the database (SQLCipher v4 scheme) and secure storage; SHA-256 for the key fingerprint. No hand-written crypto | `DeviceKeyPlugin.kt`, `docs/signing-spec.md`, `key_fingerprint.dart` | Testing for Weak Cryptographic Algorithms | Pass |
| | Randomness: `Random.secure()` for the database key and step ids | `database_key.dart:33`, `payload_format.dart:53` | Testing Random Number Generation | Pass |
| | The signature is checked against fixed vectors, byte for byte | `docs/signing-vectors.json`, `registration_payload_test.dart`, `integration_test/device_key_test.dart` | Testing the Configuration of Cryptographic Standard Algorithms | Pass |
| CRYPTO-2 Key management | The private key is made inside the Keystore (TEE) and has no export or delete path; the alias is checked in Kotlin against one pattern, so no other Keystore entry can be reached; never overwritten (`KEY_EXISTS`) | `DeviceKeyPlugin.kt` (`ALIAS`, `createKey`), Mobile (4), (17) | Testing Key Management | Pass, except **H1** |

### MASVS-AUTH

| Control | What the app does | Evidence | MASTG test | Result |
|---|---|---|---|---|
| AUTH-1 Secure authentication | JWT from the server, 60 minutes at most, sent only in the `Authorization` header; the phone also checks its own expiry and on every return to the foreground; a 401 `TOKEN_EXPIRED` forgets the token; logout removes exactly the three session keys | `api_client.dart:147`, `auth_controller.dart:276`, `session_expiry_watcher.dart`, `session_store.dart:96–104`, Mobile (11) | Testing Stateful Session Management | Pass |
| AUTH-2 Local authentication | The signing key needs no screen lock and no PIN | `DeviceKeyPlugin.kt` (`setUserAuthenticationRequired(false)`) | Testing Confirm Credentials | **H1**, I1 |
| AUTH-3 Extra check for sensitive actions | A password change asks for the current password; account approval is an admin's, checked by the server | `api.md`, `/auth/me/password` | — | Pass |

### MASVS-NETWORK

| Control | What the app does | Evidence | MASTG test | Result |
|---|---|---|---|---|
| NETWORK-1 Secure traffic | `https://` only, refused at start-up otherwise; `usesCleartextTraffic="false"`; TLS 1.3 minimum; no redirects followed; no `badCertificateCallback` | `app_config.dart:61`, `AndroidManifest.xml`, `pinned_http_client.dart:85, 94`, `api_client.dart:145`, Mobile (12), (21); `tool/check_tls.dart` | Testing Data Encryption on the Network; Testing the TLS Settings | Pass |
| NETWORK-2 Identity pinning | Trust store starts empty (`withTrustedRoots: false`), then only GTS Root R4, GlobalSign ECC Root CA R4 and ISRG Root X1 | `pinned_http_client.dart:61`, `pinned_roots.dart`, Mobile (2), Deployment (11) | Testing Custom Certificate Stores and Certificate Pinning | Pass (L4) |

### MASVS-PLATFORM

| Control | What the app does | Evidence | MASTG test | Result |
|---|---|---|---|---|
| PLATFORM-1 IPC | One exported activity (the launcher, which must be), plus a DUMP-guarded AndroidX receiver. `taskAffinity=""` stops task hijacking. No deep links, no content providers, receivers or services of the app's own. The method channel is reachable only from the app's own Dart code and checks every argument | `AndroidManifest.xml`, merged manifest (below), `DeviceKeyPlugin.kt` | Testing for Sensitive Functionality Exposure Through IPC; Testing App Links | Pass |
| PLATFORM-2 WebViews | None | `pubspec.yaml`, grep of `lib/` | Testing WebView Configuration | Pass (not used) |
| PLATFORM-3 UI | Server text is shown as plain `Text`, never as HTML; no FLAG_SECURE; no tapjacking guard | — | Testing for Overlay Attacks; Finding Sensitive Information in Auto-Generated Screenshots | **M1**, **L1** |

**Merged manifest (19 Nov):** `minSdkVersion` 26, `targetSdkVersion` 36. Permissions: INTERNET,
CAMERA, the two location permissions, ACCESS_NETWORK_STATE (from a plugin) and AndroidX's
signature-level `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. Exported: `MainActivity` (the
launcher) and AndroidX's `ProfileInstallReceiver`, which is guarded by
`android.permission.DUMP`, so only the system and adb can send to it. Not exported: the
geolocator location service, the CameraX metadata holder (also disabled), ML Kit's
discovery service and init provider, `GoogleApiActivity`, the AndroidX startup provider, and
the data transport services and receiver (L5). Pass.

### MASVS-CODE

| Control | What the app does | Evidence | MASTG test | Result |
|---|---|---|---|---|
| CODE-1 Current platform | minSdk 26 (NFR-09), targetSdk from Flutter 3.47.9 | `build.gradle.kts`, merged manifest | Testing the Target SDK | Pass |
| CODE-2 Updates | None (installed by hand) | — | Testing Enforced Updating | I5 |
| CODE-3 No known-vulnerable parts | Every direct dependency is pinned exactly and is the latest version (`flutter pub outdated`, 19 Nov). The GitHub Advisory Database lists 14 pub advisories (19 Nov); one names a package we use, `http`, fixed in 0.13.3, and we use 1.6.0. None names a transitive package in `pubspec.lock` | `pubspec.yaml`, `pubspec.lock`, Mobile (18), (27) | Checking for Weaknesses in Third Party Libraries | Pass (the database covers Dart packages only, §6) |
| CODE-4 Untrusted input | QR codes must match the custody record ID pattern exactly; weights parsed as text to whole milligrams, never floats; licence numbers shaped as typed; the server validates everything again; the Kotlin channel refuses bad arguments and more than 512 bytes | `custody_record.dart`, `weight.dart`, `DeviceKeyPlugin.kt` (`workFor`), Mobile (23), (25), (31) | Testing Local Storage for Input Validation; Testing for Injection Flaws | Pass |
| | Local SQL is parameterised; the one value that cannot be bound (the database key in `PRAGMA key`) is 64 hex characters the app made itself | `local_steps_repository.dart`, `open_encrypted.dart:97` | Testing for Injection Flaws | Pass |

### MASVS-RESILIENCE

Not a goal (§1). R8 shrinking is on in release builds (Flutter's default); Dart obfuscation is
off (L2); no root, emulator, tamper or debugger detection (I3); debug signing key (I4).

### MASVS-PRIVACY

| Control | What the app does | Evidence | Result |
|---|---|---|---|
| PRIVACY-1 Least access | Camera and fine/coarse location only, each asked for when first needed and only in the foreground; no background location | `AndroidManifest.xml`, `location_source.dart`, Mobile (32) | Pass |
| PRIVACY-2 No identification beyond need | The GPS point is taken once per registration, because FR-01 needs it; no device ids, no analytics of the app's own. On-chain data is hashes and references only | Mobile (32), contract spec | Pass, except **L5** (ML Kit statistics) |
| PRIVACY-3 Transparency | The camera and location requests are explained in plain words before they are asked for | `app_text.dart:205–227` | Pass |
| PRIVACY-4 User control | Account deletion is an administrator's action (Scope (6)) | `api.md` | Pass for a prototype |

## 5. Device checks (T4)

1. A release build, obfuscated, works on the A57: log in as the demo miner, register, send.
2. `adb logcat` during login, registration and sync holds no token (`eyJ`), QR code, payload
   or password.
3. Nothing readable outside the app: blank recent-apps card (after M1's fix); the database
   file from a debug install does not start with `SQLite format 3`; `adb backup` is empty.

## 6. Limits of this review

- No dynamic instrumentation, proxy interception or decompiling was done. Pinning is
  proven by the unit tests and `tool/check_tls.dart` instead.
- The advisory check covers Dart packages only. Native parts (ML Kit, the sqlite3mc build,
  the AndroidX libraries plugins bring) are not covered by the GitHub pub database.
- One reviewer, who also wrote much of the code.
