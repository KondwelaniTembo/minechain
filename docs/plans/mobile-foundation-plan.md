# Mobile foundation plan (Module 3)

The plan for the first module of the Flutter Android app in `mobile/`: the app's skeleton,
its secure connection to the API, login, role-based navigation and placeholder home screens.
No custody work (registration, scanning, GPS, signing, offline database, sync) is built here;
this module gives those later modules something solid to sit on.

Branch: `feature/mobile-app`. Starting point: the `flutter create` scaffold (`1cece2e`).

Status: **approved 16 Nov 2026, nothing built yet.** Decisions are in section 11.

---

## 0. What was checked for this plan (15 Nov 2026)

| Check | Result |
|---|---|
| `flutter --version` | Flutter 3.47.9 stable, Dart 3.13.7, as Mobile (9) records |
| `flutter doctor` | Android toolchain OK (Android SDK 37.0.0). Visual Studio missing, which only matters for Windows desktop apps, so it can be ignored |
| `flutter emulators` | One emulator: `Medium_Phone_API_36.0`. **No small or Android 8.0 emulator yet** (section 9) |
| Flutter's default `minSdk` | 24 (`FlutterExtension.kt` in the Flutter SDK), so the app must set **26** itself (F1) |
| Flutter's default `compileSdk` / `targetSdk` | 36 |
| `AndroidManifest.xml` (main) | Has **no `INTERNET` permission**. Flutter puts it only in the debug and profile manifests, so a release build would have no network until F1 adds it |
| `SecurityContext` in the local Dart 3.13.7 SDK | `SecurityContext({bool withTrustedRoots = false})`, `setTrustedCertificatesBytes`, and `minimumTlsProtocolVersion` with `TlsProtocolVersion.tls1_2` (the default) and `tls1_3`. Section 5 says what this means |
| pub.dev | Versions and dates in section 2, read from the pub.dev API |

The API's base URL is **not** in `docs/deployment.md`: that page deliberately holds no
hostnames or URLs. That fits this plan, because the URL is given at build time and never
written into the repository (section 5.1).

---

## 1. Folder structure

Feature-first, as CLAUDE.md sets out. Widgets only draw state and forward taps; every decision
(what a code means, where to go after login, when to log out) lives in a controller, a
repository or a pure function that can be tested without a screen.

```
mobile/
  assets/certs/                      the three pinned root certificates, as PEM (section 5.2)
  env/                               git-ignored build settings, one example file committed
    api.example.json                 { "API_BASE_URL": "https://example.invalid" }, fake value
  tool/
    check_tls.dart                   manual check of pinning and the TLS 1.3 minimum (section 9)
  lib/
    main.dart                        reads the build settings, starts ProviderScope and the app
    app.dart                         MaterialApp.router: theme, router, nothing else

    core/
      config/
        app_config.dart              API base URL from --dart-define; refuses a missing or non-https URL
      errors/
        app_failure.dart             sealed AppFailure types; plain Dart, no Flutter imports
        api_codes.dart               the server's error codes as constants, so nothing is typed twice
        failure_text.dart            AppFailure -> plain-language sentence for the screen
      network/
        pinned_http_client.dart      SecurityContext (3 roots, TLS 1.3), HttpClient timeouts, IOClient
        api_client.dart              JSON in and out, Bearer header, error envelope -> AppFailure
        session_events.dart          tells auth that the server refused the session (section 4.3)
        server_status.dart           health check and the "waking the server" state
        network_providers.dart       Riverpod providers for the client, the API and server status
      storage/
        secure_store.dart            small interface over flutter_secure_storage, plus a fake for tests
      router/
        routes.dart                  every path as a constant
        redirect.dart                pure function: (auth state, path) -> where to go
        app_router.dart              GoRouter provider, wired to auth through refreshListenable
      theme/
        app_theme.dart               Material 3 light and dark themes from a copper seed colour, with some pairs set by hand (Mobile (35))
        sizes.dart                   tap targets, spacing, breakpoints
      text/
        app_text.dart                every sentence the user sees, in one file (FR-15 is cut, but
                                     one file keeps the wording plain and consistent)
      widgets/
        action_tile.dart             big icon plus label button used by every home screen
        home_scaffold.dart           shared layout for the five homes: title, tiles, account icon
        message_banner.dart          shows an AppFailure or a notice in plain language
        server_waking_banner.dart    "Waking the server" with a progress indicator

    features/
      auth/
        domain/
          user.dart                  User, Role (5 values), AccountStatus; parsed from the API's user
          auth_state.dart            the states auth can be in (section 6.1)
        data/
          auth_api.dart              POST /auth/login, GET /auth/me (later /register, /activate)
          session_store.dart         token, expiry and user saved in secure storage
          auth_repository.dart       login, restore at start-up, logout; owns the rules in section 6
        presentation/
          auth_controller.dart       Riverpod Notifier holding AuthState
          splash_screen.dart         shown while the saved session is read at start-up
          login_screen.dart          username, password, Log in, links to register and activate
      account/
        presentation/
          account_screen.dart        name, role, username; Log out (change password comes later)
      miner/presentation/miner_home_screen.dart              placeholder home (section 4.2)
      transporter/presentation/transporter_home_screen.dart  placeholder home
      buyer/presentation/buyer_home_screen.dart              placeholder home
      officer/presentation/officer_home_screen.dart          placeholder home
      admin/presentation/admin_home_screen.dart              placeholder home

  test/                              mirrors lib/: core/..., features/auth/...
```

The role folders have only `presentation/` in Module 3. They gain `data/` and `domain/` when
their real screens are built. Later modules add their own features beside these, for
example `device_key/`, `consignments/`, `sync/`, `scan/`, `alerts/`, `reports/`, `users/`,
`zones/` and `anchoring/`.

`cupertino_icons` (an iOS icon font) is removed in F1: the app is Android only and uses
Material icons.

---

## 2. Packages

Read from the pub.dev API on 15 Nov 2026. "Android" and "Dart 3" are pub.dev's own tags
(`platform:android`, `is:dart3-compatible`, `is:null-safe`), which all four have.

| Package | Decision | Latest stable | Published | Needs | Publisher | Module 3 use |
|---|---|---|---|---|---|---|
| flutter_riverpod | Mobile (8) | **3.5.0** | 6 Nov 2026 | Dart ^3.12 | dash-overflow.net | all state |
| go_router | Mobile (7) | **18.1.4** | 9 Nov 2026 | Dart ^3.12, Flutter ≥ 3.44 | flutter.dev | navigation, role redirect |
| http | Mobile (2) | **1.6.0** | 10 Nov 2025 | Dart ^3.4 | dart.dev | `IOClient` over our pinned `HttpClient` |
| flutter_secure_storage | Mobile (3) | **11.2.0** (10.x line: 10.3.4, 13 Sep 2026) | 16 Sep 2026 | Dart ≥ 3.8, minSdk 24 | steenbakker.dev | token and user |

All four work with Flutter 3.47.9 and Dart 3.13.7, so Mobile (9)'s "no Flutter upgrade" holds.

**Honest notes:**

- **flutter_secure_storage: Mobile (3) rests on a premise that is no longer true.** It says
  "the latest stable 10.x, not the 11.0 beta". In fact 11.0.0 became stable on 6 Aug 2026,
  and 11.2.0 is now the latest stable. The 10.x line is still patched (10.3.2–10.3.4 in
  September), but those releases are not in the main changelog, so I could not see what
  they fixed or whether 10.x will keep getting fixes. 11.0.0's breaking changes only remove
  old Android ciphers and options (and need data to be migrated through 10.x first); this
  app has no stored data yet, so nothing needs migrating. Most 11.x fixes since August are in
  biometric and namespace options, which this app does not use. **Decided in Q1 (16 Nov
  2026): 11.2.0.**
- **http 1.6.0 is a year old.** It is published by the Dart team, scores 160/160 and has
  15 million downloads a month, so its age reads as stable rather than abandoned. I did not
  confirm whether it has a way to cancel a request on timeout (I believe `AbortableRequest`
  arrived in 1.5); F4 checks this, and section 5.4 says what happens either way.
- **go_router "feature-complete, bug fixes only"** comes from Mobile (7); I did not re-check
  that wording today, only that 18.1.4 was released this month.
- **Riverpod 3 retries a failed provider automatically** by default. I am confident of the
  behaviour but did not confirm the exact parameter name in 3.5; F2 checks it. Section 3 says
  why it is turned off.

**Not added, and why:**

- `riverpod_annotation`, `riverpod_generator`, `build_runner`, `riverpod_lint`: code
  generation is not in the decisions. Hand-written providers are fewer moving parts and
  easier to read while learning. Not adding them is not a new decision; adding them would be.
- `mocktail` or `mockito`: not needed. `package:http/testing.dart` (inside http) gives a
  `MockClient`, and the secure store and session events get small fakes of our own.
- `crypto`: needed for the key fingerprint (signing spec, section 2), but only when the
  device key is built, not in Module 3. **Flag for later: it is not yet in the decisions.**
  It is published by dart.dev, 3.0.8 on 26 Oct 2026.

---

## 3. Riverpod and errors

### 3.1 How providers are organised

- **One `ProviderScope` at the root**, in `main.dart`. Tests replace providers with
  `overrides`, which is how the fake HTTP client and fake secure store get in.
- **Providers live beside the code they expose:** network ones in
  `core/network/network_providers.dart`, auth ones next to `auth_controller.dart`. No single
  `providers.dart` for the whole app.
- **Three kinds, used for three jobs:**
  - `Provider` for objects that are built once and do not change: config, the pinned client,
    `ApiClient`, `AuthRepository`, the router.
  - `Notifier` for state that changes by method calls: `AuthController` (signed out, signed
    in, ...), `ServerStatusController` (unknown, waking, ready, unreachable).
  - `AsyncNotifier` / `FutureProvider` for screen data loaded from the API, from Module 4 on.
- **Only controllers call repositories; only repositories call `ApiClient`.** A widget reads
  a controller's state and calls its methods, for example `ref.read(authControllerProvider
  .notifier).logIn(username, password)`. It never sees JSON, a status code or a token.
- **Automatic retry is off for anything that talks to the API.** Riverpod 3 retries a
  failed provider on its own. A login, a password change or a sync must never be repeated
  behind the user's back, and retrying a refused request only burns rate-limit allowance
  (for example the 10 failed logins per username). Retrying is a user decision, shown as a
  "Try again" button.

### 3.2 From the server's error to a sentence on screen

The backend always answers an error with `{ "error": { "code", "message", "details"? } }`
(api.md, "Error format"). The app branches on `code` only, never on `message`.

**Step 1, `ApiClient` turns every failure into one `AppFailure`** (sealed, plain Dart):

| AppFailure | When | Example cause |
|---|---|---|
| `ServerRefused(status, code, serverMessage, details)` | Any response with a valid error envelope | 401 `INVALID_CREDENTIALS`, 429 `TOO_MANY_REQUESTS` |
| `NoConnection` | No network, DNS fails, connection refused | phone in airplane mode |
| `TimedOut` | No answer within the time limit (section 5.4) | very weak signal, a cold start that took too long |
| `InsecureConnection` | `HandshakeException` / `TlsException`: the server's chain does not end at a pinned root, or it offered less than TLS 1.3 | a network that intercepts TLS |
| `BadResponse(status)` | A response that is not the envelope: HTML from Cloudflare, a 502, empty body, invalid JSON | a Cloudflare error page during an outage |

`ApiClient` never puts the request body, the token or the response body into a failure, an
exception message or a log line. In debug builds it logs only method, path and status.

**Step 2, code that has to react branches on the code constant.** For example the auth
controller does `switch (failure.code) { case ApiCodes.tokenExpired: ... }`. All codes are
constants in `api_codes.dart`, copied from api.md, so a typo is a compile error.

**Step 3, the screen shows `failureText(failure)`:**

1. a sentence of the app's own for every code the app handles (for example
   `INVALID_CREDENTIALS` → "Wrong username or password.");
2. otherwise the server's `message` (api.md promises it is plain language and safe to show);
3. otherwise a fixed sentence per failure type, for example `NoConnection` → "No internet
   connection. Your work is safe on this phone." and `InsecureConnection` → "The connection
   is not safe, so the app stopped. Try another network."

`InsecureConnection` never offers "Try again" on the same screen as a casual retry: it is the
one failure that may mean someone is attacking the connection. `VALIDATION_FAILED` and
`WEAK_PASSWORD` keep their `details`, so a form can show each message under its field.

---

## 4. Navigation and role-based routing

### 4.1 Routes

| Path | Screen | Who can open it |
|---|---|---|
| `/start` | Splash: reading the saved session | everyone, at launch only |
| `/login` | Log in | signed out |
| `/register` | Request an account | signed out |
| `/activate` | Activate an officer or admin account | signed out |
| `/miner` | Miner home | miner |
| `/transporter` | Transporter home | transporter |
| `/buyer` | Buyer home | buyer |
| `/officer` | Officer home | officer |
| `/admin` | Administrator home | admin |
| `/account` | Own account and Log out | any signed-in user |

Later modules add pages under their role's path (for example `/miner/register-consignment`),
so the role check below covers them with no extra code.

**One redirect function decides everything** (`core/router/redirect.dart`, pure Dart):

1. Session not read yet → `/start`.
2. Signed out → only `/login`, `/register`, `/activate`; anything else → `/login`.
3. Signed in and on a signed-out page or `/start` → the role's home.
4. Signed in and the path belongs to another role → the role's home.
5. Otherwise stay.

go_router runs it before every navigation. The router is built once in a provider, and a
small `ChangeNotifier` that listens to `AuthController` is passed as `refreshListenable`, so a
logout anywhere moves the user to `/login` at once without rebuilding the router. The server
still checks every request; this only keeps the screens tidy (Mobile (7)).

A role the app does not know (a future server change) is treated as signed out, with
"This version of the app does not support your account. Please update it."

### 4.2 The five home screens (placeholders in Module 3)

Each home is a grid of large tiles, an icon with a short label under it, plus an account
icon in the top bar. In Module 3 every tile opens a "Coming soon" page; the tiles are there so
the layout, sizes and wording can be judged on the phone now.

| Role | Main tile (largest, first) | Other tiles |
|---|---|---|
| Miner | Register consignment | My consignments · Send my work |
| Transporter | Take custody (scan) | Check a consignment · My handoffs · Send my work |
| Buyer | Check a consignment | Record purchase · My purchases · Reports · Send my work |
| Officer | Alerts | Check a consignment · Reports · Audit trail |
| Administrator | Account requests | Accounts · GPS zones · Anchoring · Reports |

"Send my work" is the sync screen, named for what it does for the user. The officer's
alert count and the miner's recent list come with their modules.

### 4.3 How the server's refusal logs the user out

`ApiClient` knows whether a request carried a token. When a request **with a token** gets:

| Answer | What the app does |
|---|---|
| 401 `TOKEN_EXPIRED` | Session expired (Q2, decided): forget the token, keep who is signed in and their offline work, ask for the password again before the next server action |
| 401 `TOKEN_INVALID` or `TOKEN_MISSING` | Full logout: token and saved user cleared, go to `/login` with "Your session is not valid. Please log in again." |
| 403 `ACCOUNT_PENDING`, `ACCOUNT_SUSPENDED`, `ACCOUNT_REJECTED`, `ACCOUNT_NOT_ACTIVE` | Full logout, with that code's message on the login screen. Logging in again would give the same answer (api.md, "401 vs 403") |
| 403 `FORBIDDEN` | **Not** a logout. The app asked for something this role may not do, which is an app bug; show the message and stay |

`ApiClient` does not know about auth state. It reports the refusal through `SessionEvents`,
and `AuthController` listens and logs out. That keeps the dependency one-way (network does not
import auth). Several refused requests at once cause one logout, because logging out an
already signed-out session does nothing.

A 401 on a request **without** a token (`INVALID_CREDENTIALS` at login, `ACTIVATION_INVALID`)
is just a form error.

Logging out never deletes the local database, its key or the device signing key: later
modules keep unsynced work there, and NFR-04 says it must survive (section 6.3).

---

## 5. The API client

### 5.1 Base URL

- Given at build time: `flutter run --dart-define-from-file=env/api.json`, read with
  `String.fromEnvironment('API_BASE_URL')`. The real file is git-ignored; only
  `env/api.example.json`, with a fake value, is committed. The URL is not a secret, but the
  repository keeps hostnames out (as `deployment.md` does), and a different URL needs no code
  change.
- At start-up `app_config.dart` refuses a missing value, a value that is not `https://`, or
  one with a path, query or user info. The app then shows "This app was built without its
  server address" instead of starting. There is no `http://` path at all, not even for the
  local backend (Q3, decided).
- No other URL, key or secret is in the app. The app only holds the user's token, at run time.

### 5.2 Certificate pinning (Mobile (2), Deployment (11))

- Three PEM files in `assets/certs/`: **GTS Root R4**, **GlobalSign ECC Root CA – R4** and,
  as the backup, **ISRG Root X1**. You download each from its CA's own site (Google Trust
  Services, GlobalSign, Let's Encrypt), and F4 records each file's SHA-256 fingerprint
  beside the CA's published value, as Deployment (11) requires.
- `pinned_http_client.dart`:
  - `SecurityContext(withTrustedRoots: false)`, so the phone's own certificate store,
    including any CA a user or attacker installed, is ignored;
  - `setTrustedCertificatesBytes` once for each of the three files;
  - `minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3`;
  - `HttpClient(context: ...)` with **no** `badCertificateCallback`, so a bad chain fails
    closed;
  - wrapped in `IOClient` from package http.
- Why this covers every request: Dart's `HttpClient` does its own TLS (BoringSSL inside the
  Flutter engine). It does not use Android's network security config (as Mobile (2) notes),
  and it is also why TLS 1.3 works the same on Android 8.0 as on Android 17.

### 5.3 TLS 1.3: what Dart actually allows

Checked in the Dart 3.13.7 SDK on this laptop: `SecurityContext.minimumTlsProtocolVersion`
exists and accepts `TlsProtocolVersion.tls1_3`; its documentation says that a peer that
cannot do that version makes the connection throw a `TlsException`. So **the app can enforce
TLS 1.3 as its minimum itself**, which is what NFR-01 needs, given that the server cannot
(14 Nov limitation, "TLS 1.3 is enforced at Render's edge").

What it cannot do: pick cipher suites, or prove in a unit test that the setting works, since
unit tests make no real connections. That proof is the manual `tool/check_tls.dart` run in
section 9, against a test server that offers only TLS 1.2.

### 5.4 Timeouts

| Setting | Value | Why |
|---|---|---|
| `HttpClient.connectionTimeout` | 15 s | The TCP and TLS connection goes to Cloudflare, which answers quickly even when Render is asleep; 15 s allows for slow 3G |
| Whole request, normal calls | 30 s | NFR-03's 10 s is for sync on stable 3G; 30 s leaves room on a weak signal without leaving the user waiting for ever |
| Whole request, the wake-up health check | 90 s | Render's cold start is about 50–60 s (Deployment (1)) |
| `HttpClient.idleTimeout` | 15 s | Releases kept-alive connections promptly on a mobile network |

If http 1.6 can cancel a request (F4 checks), a timed-out request is cancelled. If not, the
app stops waiting and ignores the late answer; the server may still finish the request,
which is harmless for login and reads, and sync is already built to accept repeats
(signing spec, section 6).

### 5.5 "Waking the server"

- At launch, and again when the login screen opens, `ServerStatusController` calls
  `GET /health` (no token) with the 90 s limit.
- If no answer comes within 3 s, its state becomes **waking**, and screens that need the
  server show "Waking the server. This can take up to a minute the first time." with a
  progress indicator. The Log in button stays usable; a login sent meanwhile simply waits.
- 200 → **ready**. 503 → "The server is running but not ready. Try again in a minute."
  `NoConnection` → "No internet connection". `InsecureConnection` → the safety message.
- This is display only. It does not keep the server awake (Deployment (1)'s free hours, and
  the 14 Nov "cold start" limitation).

---

## 6. Login, the token and the device key

### 6.1 Auth states

| State | Meaning |
|---|---|
| `unknown` | Start-up: secure storage not read yet |
| `signedOut` | No saved user |
| `signedIn(user, token)` | A user and a token believed valid |
| `signedInNeedsPassword(user)` | The user is known, but the token expired (Q2): the home and offline work stay open, and the password is asked for before the next server action |

### 6.2 Where the token lives, and when it is cleared

- **Stored in flutter_secure_storage** (Mobile (3)), never in plain preferences, files or logs:
  - `auth.token`: the JWT;
  - `auth.expiresAt`: login time + `expiresIn` (at most 3600 s), minus 60 s;
  - `auth.user`: the user object from login (id, username, full name, role, status,
    `publicKeyFingerprint`). It holds a name and licence number, so it is kept there too.
- **Also kept in memory** in `AuthController`, so every request does not read storage.
- **At start-up:** read storage. No user → `signedOut`. A token not yet expired by the
  phone's clock → `signedIn` straight away, then `GET /auth/me` when the server answers, to
  pick up a suspension or a role change. The phone's clock is only a hint; the server's
  answer always wins.
- **Cleared:** when the user taps Log out; on the 401 and 403 answers in section 4.3; when the
  saved data cannot be read or parsed; when a role is unknown. A password change (later)
  replaces the token with the fresh one it returns.
- **Never cleared by logout:** the local database and its key, and the device signing key
  (section 6.3).
- **Android backup:** F1 sets `android:allowBackup="false"`. A restored backup on another
  phone would bring back storage that its Keystore cannot decrypt, and the token should not
  leave the phone in a cloud backup anyway. (Approved in Q5.)

### 6.3 Where the device key fits (built in a later module)

From Mobile (4), the signing spec (section 2) and api.md (`PUT /auth/me/public-key`):

1. After a miner, transporter or buyer logs in, the app asks the Kotlin Keystore channel for
   this phone's key, or creates one (P-256, inside the Keystore, never exported).
2. It compares the key's fingerprint with `user.publicKeyFingerprint`:
   - `null` → `PUT /auth/me/public-key`, then carry on;
   - the same → nothing to do;
   - different → this phone may not sign; the home shows "This phone is not your registered
     phone. Ask an administrator to reset your device key."
3. Officers and administrators skip this: they never sign, and the server refuses their key.

Two Module 3 choices keep this easy to add:

- `AuthController` exposes a "signed in" hook, so the key check slots in after login
  without touching the login screen.
- **The key alias includes the user id**, for example `minechain_signing_<userId>`, rather
  than one key per phone. The server allows a key on one account only (`PUBLIC_KEY_IN_USE`),
  so two people sharing one phone each need their own key.

---

## 7. Theme and layout

- **Material 3**, light and dark themes from a copper seed colour, with some colour pairs set
  by hand (Mobile (35)), following the phone's setting.
  Strong contrast, because the app is used outdoors in bright sun.
- **Every action is an icon with a word under it.** An icon alone is a guess for someone who
  has not seen it before; a word alone is harder for users with limited reading.
- **Large tap targets:** at least 56 dp for buttons and 96 dp tiles on the homes (Material's
  minimum is 48 dp). Few tiles per screen.
- **Plain language** (NFR-06): short sentences, everyday words ("Send my work", not "Sync";
  "Check a consignment", not "Verify provenance"), all in `app_text.dart`.
- **Status never by colour alone:** a tick or cross and a word as well, which also helps
  colour-blind users.
- **5-inch screens and larger, portrait and landscape:** about 360 × 640 logical pixels is
  the smallest target. Home grids use `LayoutBuilder`: 2 columns in portrait, 3–4 in
  landscape. Every screen scrolls, so nothing is cut off with the keyboard open or in
  landscape. `SafeArea` everywhere.
- **The phone's text size is respected**, never clamped, and screens are tested at 1.0, 1.3
  and 2.0 text scale (section 9).
- **Android 8.0+**: `minSdk = 26` in `build.gradle.kts` (F1); nothing in Module 3 needs a
  newer API.
- App name "MineChain" (`android:label`). A real launcher icon is left for later.

---

## 8. Android permissions

| Module | Permission | Why |
|---|---|---|
| **3 (this one)** | `android.permission.INTERNET` in the **main** manifest | Today it is only in the debug and profile manifests, so a release build would have no network |
| 3 | `android:usesCleartextTraffic="false"`, `android:allowBackup="false"` (attributes, not permissions) | No plain HTTP; no cloud backup of secure storage (section 6.2, Q5) |
| QR scanning (mobile_scanner, Mobile (5)) | `CAMERA` | Scanning the custody record's QR code |
| Registration with GPS (geolocator, Mobile (6)) | `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | One position fix at registration (FR-01). Foreground only, never background location |
| Later, if needed | `ACCESS_NETWORK_STATE` | Only if the sync module watches for the network coming back |

Each later permission is asked for at the moment it is first needed, with a plain sentence
saying why, not all at once at first launch.

---

## 9. Testing

### 9.1 Automated (`flutter test`, run by you when you choose)

| Kind | What | How |
|---|---|---|
| Unit | `app_config`: missing, `http://` and malformed URLs refused | plain values |
| Unit | `ApiClient`: the envelope becomes `ServerRefused` with code, message and details; HTML or empty bodies become `BadResponse`; the token goes only in the header; nothing secret in a failure's text | `MockClient` from `package:http/testing.dart` |
| Unit | Socket and TLS exceptions become `NoConnection` and `InsecureConnection` | a fake client that throws |
| Unit | `failureText`: known code, unknown code (server's message), each failure type | plain values |
| Unit | `redirect`: every path × every auth state × all five roles | pure function, table of cases |
| Unit | `AuthRepository` / `AuthController`: login saves token and user; start-up restore; each 401 and 403 code from section 4.3; logout leaves other stored keys alone | fake secure store, `MockClient`, Riverpod `ProviderContainer` with overrides |
| Widget | Login: wrong password message, waking banner, button disabled while sending | `ProviderScope` overrides |
| Widget | Each home renders with no overflow at 360 × 640 portrait, 640 × 360 landscape, text scale 2.0 | `tester.view.physicalSize`, `MediaQuery` text scaler |

No automated test makes a real network connection.

### 9.2 Manual checks with real connections

`tool/check_tls.dart`, run with `dart run tool/check_tls.dart <base URL>` on the laptop:

1. builds the same `SecurityContext` and calls `/health` on the API → must succeed;
2. calls a site whose chain ends at a different root → must fail with a handshake error
   (proves pinning);
3. with the system roots plus the TLS 1.3 minimum, calls a public test server that offers
   only TLS 1.2 → must fail; the same with a 1.2 minimum → must succeed (proves the minimum
   on its own, apart from pinning);
4. prints the SHA-256 fingerprint of each bundled PEM, to compare with the CA's site.

The test sites are chosen in F4 and named in the tool, never the API's own URL.

### 9.3 On the phone and an emulator

- **Samsung A57:** USB debugging on, then
  `flutter devices` and
  `flutter run -d <device id> --dart-define-from-file=env/api.json`.
  Hot reload (`r`) for layout, hot restart (`R`) for start-up and auth.
- **A small, old emulator:** there is only `Medium_Phone_API_36.0` now. Recommended: create
  one with a 5.0-inch screen (for example the "Pixel" profile, 1080 × 1920) and an
  **API 26** system image in Android Studio's Device Manager (about 1 GB to download). It
  checks minSdk 26, the smallest layout and TLS 1.3 on Android 8.0. Then
  `flutter emulators --launch <id>` and the same `flutter run`.
- **Landscape:** rotate the phone; on the emulator, the rotate buttons.
- **Large text:** Android Settings → Display → Font size at maximum.

---

## 10. Build order

Each piece is one commit, and each stops for you to read, run and test.

| Step | What | What you should see afterwards | Suggested commit |
|---|---|---|---|
| **F1** | Android settings: `minSdk = 26`, label "MineChain", `INTERNET` in the main manifest, cleartext off, backup off. `main.dart` replaced by one plain screen; scaffold test replaced; `cupertino_icons` removed | The app installs on the A57 and the API 26 emulator as "MineChain" and shows one plain screen | `chore: set Android 8.0 minimum, app name and network permission` |
| **F2** | Folder skeleton, `flutter_riverpod`, theme, sizes, `app_text.dart`, `action_tile`, `home_scaffold`; confirm and turn off Riverpod's automatic retry | A sample home with big icon tiles, readable in light and dark mode, 2 columns in portrait and more in landscape | `feat: add theme, shared widgets and Riverpod setup` |
| **F3** | `app_config` (`--dart-define-from-file`, https check), `env/api.example.json`, `.gitignore` entry; `AppFailure`, `api_codes`, `failure_text` with unit tests | Run **without** the settings file: a clear "built without its server address" screen. With it: the sample home | `feat: add build-time API address and typed app errors` |
| **F4** | Three PEMs with recorded fingerprints, `pinned_http_client`, `http` package, timeouts; `tool/check_tls.dart`; check `http` cancellation | The four manual checks in 9.2 pass. A temporary "Check server" tile shows "Server ready" | `feat: add pinned TLS 1.3 HTTP client` |
| **F5** | `ApiClient` (envelope, `SessionEvents`), `ServerStatusController` and banner, with unit tests | After the server has been idle 15 minutes: "Waking the server", then "Server ready". Airplane mode: "No internet connection" | `feat: add API client, error mapping and server wake-up status` |
| **F6** | `flutter_secure_storage`, `secure_store`, `session_store`, `User`, `AuthState`, `AuthRepository`, `AuthController`, with unit tests | Nothing new on the phone; this step is proven by its tests | `feat: add session storage and auth controller` |
| **F7** | `go_router`, routes, redirect function with tests, splash, login screen, five placeholder homes | Log in as each of the five roles and land on that role's home. Wrong password: "Wrong username or password." Close and reopen: still signed in | `feat: add login and role-based navigation` |
| **F8** | Account screen with Log out; the 401 and 403 handling of section 4.3; token expiry at start-up and on resume | Log out returns to login. Suspend the account from the admin account on another phone, tap anything: back to login with the suspension message | `feat: add logout and session refusal handling` |
| **F9** | Request an account, and activate an officer or admin account (Q4) | Request a miner account, approve it as admin, log in. Activate an officer with a code from `POST /admin/users` | `feat: add account request and activation screens` |
| **F10** | Widget tests at 5-inch, landscape and large text; README run instructions; new decisions (Q1–Q5) into `decisions.md` | Every screen usable at the largest font size and in landscape on the API 26 emulator | `test: add small-screen widget tests` and `docs: record mobile foundation decisions` |

Remember to check `git diff` for secrets before each commit, especially `env/api.json`, which
must stay ignored.

---

## 11. Questions and decisions

**Q1. flutter_secure_storage: 10.3.4 or 11.2.0?** Mobile (3) chose stable 10.x to avoid the
11.0 beta, but 11.x has been stable since 6 Aug 2026 (section 2).
*Recommended: 11.2.0.* It is the current stable line, the one getting fixes in the open, and
with no saved data there is nothing to migrate. Its minSdk 24 is below the app's 26. Mobile
(3) would be updated with a new row, keeping the old row unchanged.

Decision (16 Nov 2026): Approved: flutter_secure_storage 11.2.0. Mobile (3)'s premise (11.x
was a beta) is out of date; a new decisions row will be added in F10 and the old row kept
unchanged.

**Q2. When the 60-minute token expires, does the user lose access to the app?** If expiry
means full logout, a miner offline at a mine site cannot get back past the login screen
(login needs the server), so they could not record work: against the offline-first design
and NFR-04.
*Recommended: two levels.* `TOKEN_EXPIRED` (or the phone's own expiry time) forgets the token
but keeps who is signed in, so the role's home and offline work stay open; the password is
asked again only before the next server action ("Enter your password to send your work").
Any other refusal is a full logout. The cost is that anyone holding an unlocked phone can use
the app as its owner; a later module should require the phone to have a screen lock before
the signing key is made. In Module 3 the difference is small, but `AuthState` should be
shaped for it now.

Decision (16 Nov 2026): Approved: two-level logout as recommended. `TOKEN_EXPIRED` (or local
expiry) keeps the user and offline work, and the password is asked for before the next server
action; every other refusal is a full logout. Future improvement: require a device screen
lock before the signing key is created.

**Q3. Should the app ever talk to the local backend (`http://localhost:3000`)?**
*Recommended: no.* Always use the deployed API over pinned TLS, so pinning and TLS 1.3 are
tested in every run. The cost is the cold start and needing the network while developing. A
`http://` option would be a DEV-SHORTCUT that switches off the very checks that meet NFR-01.

Decision (16 Nov 2026): Approved: never use a local `http://` backend; always the deployed API
over pinned TLS 1.3. Consequence: development and testing write to the production database,
whose audit log is append-only, so test accounts and data use realistic demo names, and a
`pg_dump` is taken after major test sessions.

**Q4. Are account request (`POST /auth/register`) and activation (`POST /auth/activate`)
part of Module 3?** The login screen links to registration, and activation is the only way a
new officer or administrator can log in for the first time.
*Recommended: yes, as F9, after login works.* Both reuse the client, error mapping and form
widgets just built, and without activation the officer home cannot be reached in a demo.

Decision (16 Nov 2026): Approved: register and activate screens as F9, after login works.

**Q5. New small decisions to record:** `android:allowBackup="false"`; the base URL in a
git-ignored `env/api.json` via `--dart-define-from-file`; no Riverpod code generation and no
mocking package; the signing key alias includes the user id.
*Recommended: approve all four,* recorded in F10.

Decision (16 Nov 2026): Approved, all four: `android:allowBackup="false"`; base URL via a
git-ignored `env/api.json` with `--dart-define-from-file`; no Riverpod code generation and no
mocking package; signing key alias includes the user id.
