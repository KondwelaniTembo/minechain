# Miner registration plan (Module 4)

**Status:** plan only, written 17 Nov 2026 and approved by the developer the same day,
with Q1–Q6 decided (section 10). Nothing in it is built yet.

**Goal:** a miner can scan a custody record, capture a real GPS fix, choose the mineral, type
the weight and save, all offline. The step is signed on the phone with the Keystore key and
stored in the encrypted local database. When the network returns it is sent to
`POST /sync/steps` and its outcome is shown. This covers FR-01, FR-02, FR-07, and the phone's
part of FR-03 and FR-05.

---

## 0. What was checked for this plan (17 Nov 2026)

### 0.1 What the repository already says

**Signing spec (`docs/signing-spec.md`)**

- Keys: "ECDSA on P-256 … with SHA-256". The public key is "SubjectPublicKeyInfo (SPKI),
  DER-encoded, uncompressed point. This is always **exactly 91 bytes**", which is what
  `PublicKey.getEncoded()` returns for a Keystore EC key.
- Signatures: "**DER only**, as `SHA256withECDSA` produces … never more than 72 [bytes]".
  The phone "**must not hash the payload first**", and both keys and signatures are sent as
  standard base64 with padding.
- Bytes: "printable ASCII only", one `key=value` per line, "ends with LF, including the last
  line". A registration has 9 lines in a fixed order: header `minechain-step/1/registration`,
  `step_id`, `actor_id`, `qr_code`, `mineral`, `weight_mg`, `latitude`, `longitude`,
  `captured_at`.
- Section 4: "The phone must build the payload **once, when the step is captured**, store that
  exact string in the encrypted local database, sign it, and later send the same string. It
  must never rebuild the payload from stored fields before sending."
- The Dart formatters `formatCoordinate` (round to millionths, never `toStringAsFixed`) and
  `formatCapturedAt` (truncate to milliseconds, never `toIso8601String`) are given in the
  spec and are used as written.
- Section 6: "Time cannot be the replay defence." A step is identified by `step_id`, and "an
  exact copy … is a genuine retry", which the server answers with `duplicate`.
- The fingerprint is the lower-case hex SHA-256 of the 91 SPKI bytes:
  `sha256.convert(spkiBytes).toString()`.
- `docs/signing-vectors.json` holds fixed vectors that must never be regenerated.

**API (`docs/api.md`)**

- `PUT /auth/me/public-key`: only miners, transporters and buyers may call it. The body is
  `{ "publicKey" }` (124 base64 characters). Sending the same key again returns the same 200.
  Errors: 400 `INVALID_PUBLIC_KEY`; 409 `PUBLIC_KEY_ALREADY_REGISTERED` (this account already
  has a different key); 409 `PUBLIC_KEY_IN_USE` (another account has this key).
- `POST /sync/steps`: 1 to 50 steps of `{ payload, signature }`, and no other fields. The
  limit is **60 requests per 15 minutes per user**. The answer is 200 with one result per
  step, in order, and five outcomes: `created`, `duplicate`, `flagged`, `rejected`,
  `deferred`. "The app must branch on `code`, never on `message`." A failure part-way
  through: "Sending the whole batch again is safe".
- `GET /consignments/by-qr/{qrCode}`: transporters, buyers and officers only. **A miner gets
  403 `FORBIDDEN`**, so the miner's app cannot ask the server whether a QR code is already
  registered. Section 6 relies on this. QR grammar: "4–128 characters, each one of
  `A–Z a–z 0–9 . _ : / -`".

**Database (`docs/database-schema.md`)**: `transactions.idempotency_key` is "made by the phone
and included in the signed record. It is unique per actor". Weight and coordinates are
stored "from the signed text, with no floating-point step". `zone_id` and `received_at` are
set by the server.

**Decisions (`docs/decisions.md`)**

- Mobile (1): drift on SQLite3MultipleCiphers with the SQLCipher v4 scheme
  (`PRAGMA cipher='sqlcipher'`, `PRAGMA legacy=4`, then `PRAGMA key`). The key is 32 random
  bytes kept in flutter_secure_storage. "Encryption is to be proven on the A57 by a test, not
  assumed."
- Mobile (4): our own Kotlin channel, an EC P-256 key with `PURPOSE_SIGN`, `SHA256withECDSA`
  and `getEncoded()`.
- Mobile (5): mobile_scanner with the bundled ML Kit model. Mobile (6): geolocator.
  **Note for the report:** the project proposal names ZXing as the scanning library, but
  Mobile (5) chose mobile_scanner with ML Kit. The report should describe what was built.
- Mobile (11): two-level logout. Mobile (16): no code generation for Riverpod and no mocking
  package. Mobile (17): the key alias includes the user id. Mobile (19): `resetOnError: false`,
  because the secure store will hold the database key. Mobile (20): no automatic retry.
- Scope (8): "my consignments" comes from the phone's local database, so a reinstall loses
  the list.
- Anomaly rules (10): odd capture times are accepted, so the phone's clock is trusted.

**Requirements** (in the project's own words, from CLAUDE.md):

| ID | What this module must meet |
|---|---|
| FR-01 | Register a consignment by QR scan, with GPS, mineral, weight and time |
| FR-02 | Sign each step with the user's ECDSA key |
| FR-03 | Steps reach Sepolia through the backend; the phone's part is to deliver them |
| FR-05 | Full details of every step are kept; the phone keeps its signed copy |
| FR-06 | Only a signed-in miner reaches the screen |
| FR-07 | Cache in the encrypted database, sync on reconnect |
| NFR-01 | AES-256 at rest, TLS 1.3 with pinning (already built) |
| NFR-02 | No Critical or High MSTG findings; private keys never leave the device |
| NFR-03 | Local save within 3 s on a low-end phone |
| NFR-04 | 72 hours offline with no data loss |
| NFR-06 | Registration in three taps or fewer, plain language |
| NFR-07 | Faults fixable in four working hours: small, documented pieces |

**What the foundation already gives (F1–F10):**

- `SignedInEvents` in `auth_controller.dart` reports every fresh sign-in: a login, a
  re-entered password or a restored session. It was added for exactly this module.
- `User.publicKeyFingerprint`.
- `ApiClient` with its `AppFailure` types.
- `SecureStore` with `resetOnError: false`.
- The password prompt for `SignedInNeedsPassword`.
- The miner home with three "Coming soon" tiles.
- `MainActivity.kt`, which is still the empty `FlutterActivity`.

### 0.2 Packages (read from the pub.dev API on 17 Nov 2026)

Every "latest" version below is a stable release, with no `-dev` or `-beta` suffix.

| Package | Latest stable | Published | Needs | Publisher / repo | Use |
|---|---|---|---|---|---|
| mobile_scanner | **7.5.0** | 1 Nov 2026 | Dart ^3.7, Flutter ≥ 3.29, Android minSdk 23, compileSdk ≥ 34 | juliansteenbakker/mobile_scanner | QR scanning (Mobile (5)) |
| geolocator | **14.1.2** | 19 Oct 2026 | Dart ^3.5; pulls in geolocator_android ^5.1.0 | Baseflow | GPS fix and permission (Mobile (6)) |
| geolocator_android | 5.2.1 | 19 Oct 2026 | compileSdk 35; its changelog asks for Flutter ≥ 3.29 | Baseflow | comes in through geolocator |
| sqlite3 | **3.9.1** | 8 Nov 2026 | Dart ≥ 3.10; build hooks (native C build) | simolus3/sqlite3.dart | the encrypted database (Mobile (1)) |
| drift | 2.35.4 | 8 Nov 2026 | Dart ≥ 3.10, sqlite3 ^3.4.0 | simolus3/drift | only if Q1 keeps drift |
| drift_dev + build_runner | 2.35.3 / 2.17.1 | 8 Nov / 14 Oct 2026 | build_runner: Dart ^3.11 (2.17.0 was retracted) | simolus3, dart-lang | only if Q1 keeps drift |
| path_provider | **2.1.6** | 15 Jun 2026 | Dart ^3.10, Flutter ≥ 3.38 | flutter.dev | the database file's folder |
| crypto | 3.0.8 (already pinned) | 26 Oct 2026 | | dart.dev | key fingerprint; moves from dev to main dependencies |
| integration_test | Flutter SDK | | | flutter.dev | on-device tests (dev only) |

All of them fit Flutter 3.47.9, Dart 3.13.7 and minSdk 26.

**Considered and not added:**

- **permission_handler** (13.0.2, 4 Sep 2026): geolocator has its own permission calls and
  `openAppSettings()`, and mobile_scanner asks for the camera itself.
- **uuid** (4.6.0, 15 Jul 2026): a v4 UUID is about ten lines with `Random.secure()`, and
  those lines are tested against the spec's grammar.
- **pointycastle**: to verify signatures in Dart tests. On-device tests and the server's own
  check cover this instead (M1, M6).

**Honest notes:**

- **How sqlite3 3.x selects SQLite3MultipleCiphers is not confirmed.** The sqlite3 changelog
  documents user defines (`source`, `name`, per-OS maps) and records bumps of the bundled
  "SQLite3 Multiple Ciphers" library. It does not spell out the exact `source: sqlite3mc`
  line that Mobile (1) names. M3 reads the package README first. M3 is also the first native
  C build in this project, through a build hook, so the Android NDK must be installed. This
  is the **biggest risk today**.
- **Whether mobile_scanner bundles the ML Kit model by default** is not stated in its
  changelog. Its 3.5.0 entry added "the option to switch between bundled and unbundled". M4
  confirms the default from the README, because an unbundled model needs Google Play
  services to download it, which may fail offline.
- **geolocator_android 5.2.1 was shown as "unlisted"** on its changelog page.
  `flutter pub deps` in M4 shows which version is actually chosen.
- The release dates of earlier versions came from summaries and are not used for anything.

---

## 1. Steps

Each step is one commit and stops for you to read, run and test. Times are in section 9.

### M1. The Keystore channel (Kotlin and Dart)

**Builds:**

- A method channel `minechain/device_key` with three methods:
  - `publicKey(alias)`: the 91 SPKI bytes, or `null` if no key has this alias.
  - `createKey(alias)`: an EC P-256 key in `AndroidKeyStore`, with `PURPOSE_SIGN` and
    `DIGEST_SHA256`, and no user authentication (NFR-06; see section 7). It returns the
    public key. It refuses to overwrite an alias that already exists.
  - `sign(alias, bytes)`: `Signature.getInstance("SHA256withECDSA")` over the bytes exactly
    as given. It returns DER.
- Kotlin checks the alias against `minechain_signing_<lower-case uuid>` and refuses anything
  else.
- No method deletes or exports a private key.
- Errors come back as fixed codes (`KEY_NOT_FOUND`, `KEYSTORE_ERROR`), never as exception
  text.
- In Dart, `DeviceKeyChannel` wraps the channel and `deviceKeyAlias(userId)` builds the
  alias.

**Files:**

- `android/app/src/main/kotlin/.../DeviceKeyPlugin.kt`, registered in `MainActivity.kt`.
- `lib/features/device_key/data/device_key_channel.dart`.
- `lib/features/device_key/domain/key_alias.dart`.

**Tests:**

- Unit tests of the wrapper against a mocked channel (Flutter's `TestDefaultBinaryMessenger`):
  arguments, byte types, error mapping, and alias building.
- `integration_test/device_key_test.dart`, run on the A57:
  - create a key, then read it back;
  - the public key is 91 bytes and starts with the P-256 SPKI prefix;
  - a signature over the registration vector's payload is DER, at most 72 bytes;
  - a second `createKey` is refused.

**On the A57:** `flutter test integration_test/device_key_test.dart -d <A57>` passes. There is
nothing new on screen.

### A1. The administrator's "Account requests" screen (Q6)

This step is moved forward from Thursday's admin screens. Production has one administrator,
one **pending** miner and no active miner, so M2, M5 and M6 cannot be tested on the A57
without it.

**What the API offers** (`docs/api.md`, "Admin account management"):

- `GET /admin/users` lists one status, oldest request first: "With no query it lists the
  first page of pending requests". The query takes `status` (default `pending`), `limit`
  (default 20, 1–100) and `offset`. The answer is
  `{ users: [admin view], total, limit, offset }`. Admin only, with no rate limit yet.
- `POST /admin/users/{id}/approve`, with no body or `{}`: "The account becomes `active` and
  can log in. `approvedBy` and `approvedAt` are set." The answer is 200 with
  `{ user }` in the admin view, `"status": "active"`.
- `POST /admin/users/{id}/reject`, with `{ "reason" }` of 3–500 characters after trimming.
  The account becomes `rejected` "for good". The reason is "Kept permanently in the audit
  log" and is shown to administrators only.
- Errors for both: `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND`,
  `INVALID_STATUS_TRANSITION` ("the account is not pending", for example when another
  administrator acted first) and `ROLE_NOT_APPROVABLE`.

**What approval means for the miner:** no activation code. Codes exist only for officer and
administrator accounts created as `invited` (`POST /admin/users`). A miner's request
(`POST /auth/register`) already set the password they chose. Once approved, they **log in
with that username and password**. Before approval, the same login answers 403
`ACCOUNT_PENDING`.

Reject is included, because the API supports it cleanly with one request and a reason.
Because the reason can never be removed, the reject dialog says so: "This reason is kept
permanently. Keep it short and factual, without personal details."

**Builds:**

- Route `/admin/requests`, which the existing `/admin` role check covers. The "Account
  requests" tile on the admin home opens it.
- `AdminUsersApi`: `pendingRequests(limit, offset)`, `approve(id)` and `reject(id, reason)`.
- `AdminUser`, parsed from the admin view; unknown fields are ignored.
- An `AccountRequestsController` (`AsyncNotifier`, with no retry, as Mobile (20) requires).
- The screen:
  - a list of cards showing the full name, username, role with an icon and a word, licence
    number, and the request date;
  - "Showing 20 of N" with a "Show more" button;
  - an empty state, "No account requests waiting.";
  - Approve with a short confirmation;
  - Reject with a reason field, checked for 3–500 characters on the phone and again by the
    server.
- A row leaves the list once the server answers 200.
- `INVALID_STATUS_TRANSITION` → "Someone else has already dealt with this request." and the
  list reloads.
- New files:
  - `lib/features/admin/data/admin_users_api.dart`;
  - `lib/features/admin/domain/admin_user.dart`;
  - `lib/features/admin/presentation/account_requests_screen.dart` and its controller;
  - texts in `app_text.dart`.

**Tests:**

- `AdminUser` parsing.
- The API wrapper against `MockClient`: the paths, no body on approve, the reason body on
  reject.
- Widget tests:
  - the list, the empty state and "Show more";
  - Approve removes the row;
  - the reject dialog refuses 2 characters and accepts 3;
  - 409 reloads the list with the message;
  - no overflow at 360 × 640, in landscape and at text scale 2.0.
- The redirect tests already keep non-admins out of `/admin/...`.

**On the A57:**

1. Log in as the administrator and open "Account requests". The pending miner is listed.
2. Approve it, then log out.
3. Log in as that miner with the password chosen when the account was requested. The miner
   home opens.
4. In psql or `GET /admin/users?status=active`, the miner is `active` with `approvedBy` set.

### M2. Registering the key after sign-in

**Builds:**

- `DeviceKeyController`, a `Notifier` that listens to `SignedInEvents`. Signing roles only;
  officers and admins skip it.
- It follows the key lifecycle in section 4. Its states are `notNeeded`, `checking`,
  `ready`, `unregistered` (signing allowed, registration pending), `otherDevice` and `failed`.
- `PUT /auth/me/public-key` lives in `DeviceKeyApi`.
- The user returned by the PUT is saved through the session store, so
  `publicKeyFingerprint` is up to date.
- The miner home shows a notice for `otherDevice`: "This phone is not your registered phone.
  Ask an administrator to reset your device key."
- `crypto` moves to the main dependencies.

**Tests:**

- The controller against a fake channel, `MockClient` and a fake store, for every row of the
  table in section 4: 200; a repeat; the two 409 codes; no network (stays `unregistered`,
  tries again at the next sign-in); 401 and 403 through `SessionEvents`.
- The fingerprint against `signing-vectors.json` (read from `../docs/`).

**On the A57:**

- Log in as a seeded miner. In `GET /admin/users` (or psql), the miner now has a fingerprint.
- Log out and back in: there is no new audit entry, because a repeat writes nothing.

### M3. The encrypted local database (depends on Q1)

**Builds:**

- `LocalDatabase.open()`:
  - read the 32-byte key from the secure store, or create it with `Random.secure()` on the
    first open;
  - open `<app support dir>/minechain.db`;
  - `PRAGMA cipher='sqlcipher'`, `PRAGMA legacy=4`, `PRAGMA key="x'<hex>'"`;
  - then `PRAGMA journal_mode=WAL` and `PRAGMA synchronous=FULL`, so a committed row
    survives a battery pull (NFR-04);
  - migrations through `PRAGMA user_version`.
- Schema version 1, from section 2.
- `LocalStepsRepository` with `insert`, `listForActor`, `dueForSync` and `applyResult`. All
  SQL uses `?` parameters.
- The database key never appears in an error or a log.

**Tests:**

- The repository against an in-memory database, without the cipher. Pure logic only.
- `integration_test/db_encryption_test.dart`, on the A57. This is the proof Mobile (1) asks
  for:
  1. Open, write a row and close.
  2. The file's first 16 bytes are **not** `SQLite format 3\0`.
  3. Opening with no key fails, and opening with a wrong key fails.
  4. Opening with the right key reads the row back.
  5. `PRAGMA cipher` answers `sqlcipher`.
  6. A plain-SQLite build would fail step 2, which is why the test is needed at all.

**On the A57:** the encryption test passes. Optionally, copy the file off with
`adb exec-out run-as … cat` and see that it starts with random bytes.

### M4. The payload and the save (no screen yet)

**Builds:**

- Pure Dart in `features/registration/domain/`:
  - `formatCoordinate` and `formatCapturedAt`, copied from the spec;
  - `newStepId()`: v4, lower case;
  - grammar checks for the QR code, mineral and weight;
  - `buildRegistrationPayload(...)`;
  - `parseWeightToMg(text, unit)`: exact, by text, never `double` (Q2).
- `RegisterConsignment.save(...)`, in this order:
  1. build the payload once;
  2. sign it through the channel;
  3. insert the row with its signature in one transaction;
  4. only then report "saved".
- `save` refuses when the key state is `otherDevice` or there is no key.
- Android permissions: `CAMERA`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`.
- `flutter pub deps` confirms the mobile_scanner and geolocator versions.

**Tests:**

- Every positive and negative registration vector, byte for byte.
- Formatter edge cases from the spec, including `-0.0000004` → `0.000000`.
- The weight parser.
- `save` with fakes: nothing is stored if signing fails, and the stored payload equals the
  signed bytes.

**On the A57:** an integration test saves one step and times it. It must take under 3 s
(NFR-03); a Keystore signature is usually well under 100 ms.

### M5. The registration screen

**Builds:**

- `/miner/register` (the role check from F7 already covers it). The flow is in section 5.
- One screen, three parts:
  - **Scan:** mobile_scanner, QR codes only.
  - **Location:** geolocator, started as soon as the screen opens, so the fix is being found
    while the user scans.
  - **Details:** mineral chips, with the last-used mineral preselected; the weight field,
    with its unit beside it (Q2); a large Save button.
- After Save: "Saved on this phone. It will be sent when you are online."
- A local duplicate check (section 6).
- Permission-refused, location-off and no-fix screens (section 5).
- Every sentence lives in `app_text.dart`.

**Tests:**

- Widget tests with a fake scanner, a fake location source and a fake save:
  - Save stays disabled until the code, the fix, the mineral and a valid weight are all
    present;
  - each permission-refused screen;
  - the duplicate message;
  - the save message;
  - no overflow at 360 × 640, in landscape and at text scale 2.0 (as F10).

**On the A57, outdoors and in airplane mode:**

1. Scan a printed demo record, wait for the fix, choose gold, type a weight, Save.
2. Count the taps (Q5).
3. Refuse the camera permission once, then grant it from Settings.

### M6. Sync and "Send my work" (depends on Q4)

**Builds:**

- `SyncService.syncNow()`, with the design in section 3: one run at a time, batches of 50
  oldest first, each result matched to its row by `index` and `stepId`.
- The "Send my work" screen:
  - counts for waiting, sent, under review and needs attention;
  - a Send button;
  - the password prompt when the session needs it.
- Automatic triggers from Q4.
- `ServerRefused` gains `retryAfter`, read from the header, for 429.

**Tests:**

- `SyncService` against `MockClient` and an in-memory database:
  - each of the five outcomes and each code;
  - a lost response followed by a resend (it comes back `duplicate`);
  - a 500 part-way through;
  - 429 with `Retry-After`;
  - batches over 50;
  - a stepId that does not match;
  - two calls at once (only one runs);
  - backoff timing with the fake `Clock`;
  - another user's rows never sent.

**On the A57:**

1. Save two steps offline, turn airplane mode off, tap Send: both show "sent".
2. In psql, both are in `transactions` with `review_status = 'passed'`.
3. Scan the same record again on the **Android 8.0 emulator (`Pixel_5in_API_26`)**, signed in
   as a **second miner account**: that step comes back "under review"
   (`DUPLICATE_CONSIGNMENT`).
   - The second miner requests an account from the emulator's register screen, and the
     administrator approves it with A1.
   - The emulator has its own Keystore key, registered by M2.
   - Its location comes from the emulator's extended controls, so set a point inside the
     demo zone. Otherwise the step is also flagged `GPS_ZONE`.
   - Use realistic demo names (Mobile (12)).

This step is the end-to-end proof that a real Keystore signature verifies on the server
(signing spec, section 9, "Across both").

### M7. "My consignments" and the docs

**Builds:**

- "My consignments": the miner's own rows from the local database (Scope (8)), newest first,
  each with its state in words and an icon, never colour alone.
- Docs:
  - new `decisions.md` rows: packages and versions, the local schema, the sync rules, the
    answers to Q1–Q5, and the GPS policy;
  - a "Mobile app" note in `api.md` only if something there turned out unclear;
  - the CLAUDE.md status.

**Tests:** a widget test of the list in each state.

**On the A57:** the list matches what was synced, including one flagged step.

---

## 2. Local schema (version 1)

One table holds the work and one holds settings. **The payload is the truth.** The other
columns are copies made from the same values in the same function, for the lists, and a test
checks that they agree with the parsed payload.

### `local_steps`

| Column | Type | Mirrors on the server | Notes |
|---|---|---|---|
| `step_id` | TEXT PRIMARY KEY | `transactions.idempotency_key` | lower-case UUID from the payload |
| `actor_id` | TEXT NOT NULL | `transactions.actor_id` | which account signed it; sync sends only the signed-in user's rows |
| `type` | TEXT NOT NULL | `transactions.type` | `registration` only in this module; handoff and purchase later |
| `qr_code` | TEXT NOT NULL | `consignments.qr_code` | exactly as scanned |
| `mineral` | TEXT | `consignments.mineral_type` | registrations only |
| `weight_mg` | TEXT NOT NULL | `transactions.weight_mg` | **text**, never a number type, as in the payload |
| `latitude`, `longitude` | TEXT NOT NULL | `numeric(9,6)` columns | the formatted 6-decimal text |
| `captured_at` | TEXT NOT NULL | `transactions.captured_at` | the formatted payload time |
| `payload` | TEXT NOT NULL | `signed_payload` | the exact signed string, never rebuilt |
| `signature` | TEXT NOT NULL | `signature` | DER as standard base64 |
| `key_fingerprint` | TEXT NOT NULL | fingerprint of `signer_public_key` | which key signed it, to explain an `INVALID_SIGNATURE` later |
| `gps_accuracy_m` | REAL | none | local only, for display; never signed, so a float is fine |
| `sync_state` | TEXT NOT NULL | none | see below |
| `review_status` | TEXT | `review_status` | from the last result |
| `server_transaction_id` | TEXT | `transactions.id` | from `created`, `duplicate` or `flagged` |
| `last_code`, `last_message` | TEXT | | the server's code and its message, shown as given |
| `attempts` | INTEGER NOT NULL DEFAULT 0 | | |
| `next_attempt_at`, `first_deferred_at`, `synced_at`, `created_at` | TEXT | | UTC ISO times from the phone |

Indexes: `(actor_id, created_at)` for lists and sync, and `(qr_code, type)` for the
duplicate check.

**`sync_state` values** (CHECK constraint):

| State | Meaning | Sent again automatically? |
|---|---|---|
| `queued` | saved, never answered | yes |
| `deferred` | the server answered `deferred` | yes, after its backoff |
| `synced` | `created` or `duplicate` | no |
| `flagged` | stored on the server, under review | no |
| `rejected` | the server will never accept it as it is | no; kept and shown |

There is **no "sending" state** in the database. If the app is killed mid-send, a stored
"sending" would leave the row stuck. A row stays `queued` until its answer is written, and
the resend is safe (section 3).

### `settings`

Key/value rows such as `last_mineral`. Nothing secret goes here.

### What is never stored in the database

- The **private key**: it stays in the Keystore, and no method can read it out.
- The **password**.
- The **token**: it stays in secure storage (F6).
- The **database key**: it stays in secure storage.
- Raw GPS `double`s: only the formatted text is kept.
- Server-only facts: zone, anchor status, hashes.
- Other people's details.

Rows are **never deleted** by logout, sync or any outcome in this module. A `rejected` row is
signed evidence.

---

## 3. Sync design

### Why a resend is always safe

- `step_id` is inside the signed bytes, and the server allows each user each `step_id` only
  once (`UNIQUE (actor_id, idempotency_key)`).
- The app always resends the **stored** payload and signature, never a rebuilt or re-signed
  one. A re-signature would be a different DER value, so a different anchor hash, which the
  server answers with `STEP_ID_CONFLICT` (signing spec, section 6).
- So after a lost answer, a timeout or a 500, the app sends the same batch again, and
  everything already stored comes back `duplicate`.

### What happens in one run

1. **One run at a time.** An in-memory flag stops a second run; a second call returns "already
   sending".
2. **Check the session.** It must be `SignedIn`. With `SignedInNeedsPassword`, a run the user
   started shows the password prompt ("Enter your password to send your work"), and an
   automatic run simply stops.
3. **Check the key.** The state must be `ready`, or `unregistered`, in which case run the PUT
   first. With `otherDevice`, stop and show the notice. Sending would only produce flagged
   `INVALID_SIGNATURE` steps.
4. **Choose the rows.** The signed-in user's `queued` and `deferred` rows. An automatic run
   takes only rows whose `next_attempt_at` has passed. A tap on Send takes all of them, since
   retrying is the user's decision (Mobile (20)). Oldest first, up to 50.
5. **Send** `POST /sync/steps` with the default 30 s timeout. NFR-03's 10 s is for a stable 3G
   connection, and 50 steps are about 25 kB.
6. **Apply the results** in one local transaction, matched by `index` and checked by `stepId`.
   If a `stepId` does not match, that row is left `queued` and the app reports a bug.
7. **Repeat** until no due rows remain, or until a whole-request error stops the run.

### Each answer

| Answer | Local change | What the user sees |
|---|---|---|
| `created`, `duplicate` | `synced`, with `review_status` and `server_transaction_id` | "Sent" ✓ |
| `flagged` (any code) | `flagged`, with the code and message | "Under review", plus the server's message (for example `DUPLICATE_CONSIGNMENT`, `GPS_ZONE`) |
| `deferred` `NO_DEVICE_KEY` | `deferred`; run the key PUT and try once more in this run | "Waiting to be sent" |
| `deferred` (other codes) | `deferred`, attempts + 1, backoff | "Waiting to be sent"; after 72 h from `first_deferred_at`, "Not accepted yet after 3 days. Ask your administrator." |
| `rejected` `PAYLOAD_UNSUPPORTED_VERSION` | `rejected` | "Please update the app." |
| `rejected` `ACTOR_MISMATCH` | `rejected`. This should never happen, because only the user's own rows are sent | the message |
| `rejected` (other codes: `PAYLOAD_MALFORMED`, `SIGNATURE_MALFORMED`, `STEP_NOT_ALLOWED_FOR_ROLE`, `STEP_ID_CONFLICT`) | `rejected`, kept | "This record could not be accepted", the code, and "Show this to your administrator" |
| no connection, timeout, `BadResponse`, 500 | nothing changes | "Not sent. Your work is safe on this phone." |
| 429 | nothing changes; no automatic run before `Retry-After` | the server's message |
| 401, 403 | nothing changes; `SessionEvents` already handles it (F8) | as today |
| 400 `VALIDATION_FAILED`, 413 | nothing changes; stop the run | "Something is wrong with the app. Your work is safe on this phone." This is an app bug |
| `InsecureConnection` | nothing changes; stop the run | the existing safety message, with no casual retry |

**Backoff for deferred rows:** 1, 2, 4, 8, 16, 32 minutes, then every 60 minutes, measured
with the fake-able `Clock`. A tap on Send ignores it. The 60-requests-per-15-minutes limit is
far away: an automatic run starts at most once every 2 minutes.

### 72 hours offline (NFR-04)

- Saving needs only the Keystore key and the user id. It needs no token, no network and no
  server. `SignedInNeedsPassword` can still save (Mobile (11)).
- Rows never expire on the phone. WAL with `synchronous=FULL` means a committed row survives a
  crash or a flat battery.
- The server accepts old capture times (Anomaly rules (10)).
- Tests use the fake `Clock` to put 72 hours between saving and sending. A manual check on the
  A57 uses a shorter airplane-mode run with the app killed in between.

### "Your work is safe on this phone"

**Today this sentence is not true.** It is the `NoConnection` text in `app_text.dart`, shown
for any failure without a network, including on the login screen, and nothing is saved
locally yet.

- **M3** changes the `NoConnection` text to "No internet connection."
- **M5** uses "Saved on this phone" only after the insert has committed.
- **M6** uses "Your work is safe on this phone" only on the sync screen, and only when the
  rows are really in the database. It is shown with the count, for example "3 records are
  safe on this phone and waiting to be sent."

---

## 4. Key lifecycle

The alias is `minechain_signing_<userId>` (Mobile (17)). The check runs after every
`SignedInEvents` report for a miner, transporter or buyer, and again before each sync. It
compares the phone's key for **this** user with the server's `publicKeyFingerprint`.

| Phone key for this user | Server fingerprint | Case | What the app does | May sign? |
|---|---|---|---|---|
| none | `null` | first login on this phone | create the key, PUT it | yes, once created |
| exists | `null` | the PUT never got an answer, or an administrator reset the key and this same phone is back | PUT the existing key; never make a second one | yes |
| exists | equal | normal | nothing | yes |
| exists | different | the key was registered from another phone | `otherDevice` notice | **no** |
| none | not `null` | reinstall, a new phone, or cleared app data | `otherDevice` notice: "ask an administrator to reset your device key" (suspend → reset → reactivate, signing spec section 2) | **no** |

**PUT answers:**

- 200: `ready`.
- `PUBLIC_KEY_ALREADY_REGISTERED`: `otherDevice`.
- `PUBLIC_KEY_IN_USE`: `failed`, with the server's message. Two accounts on one phone get
  different aliases, so this means a bug.
- `INVALID_PUBLIC_KEY`: `failed`; this is an app bug.
- No network: stay `unregistered` and try again at the next sign-in or sync.

**Why the same key is registered again after a reset.** Unsynced steps on this phone were
signed with this key. A new key would make them all `INVALID_SIGNATURE`. The reset procedure
already makes the administrator confirm the real user before reactivating.

**Another user on the same phone.**

- Each user has their own alias, so each has their own key.
- Rows carry `actor_id`. Lists and sync show and send only the signed-in user's rows.
- Another account's unsynced rows wait until that person signs in again. The sync screen says
  "Some records on this phone belong to another account. They will be sent when that person
  logs in." It gives no names.
- Logout with unsynced rows asks first: "You have 2 records not sent yet. They stay safe on
  this phone, and will be sent the next time you log in."

**Never done:** deleting a key automatically, exporting a key, or creating a key for an
officer or administrator.

---

## 5. GPS policy (depends on Q3)

- **A location is never invented.** There is no last-known position (it could be from
  yesterday, somewhere else), no default point and no typed coordinates. Without a qualifying
  fix, Save stays disabled.
- **The fix:** geolocator's position stream at high accuracy, started when the screen opens.
  Take the first reading that is:
  - accurate to within **25 m** (Q3);
  - **not mocked**: `Position.isMocked`, set by Android when a fake-GPS app is active;
  - **fresh**: its own timestamp within 30 s of now.
- The screen shows the accuracy as it improves ("Finding your location… 40 m"), then
  "Location found ✓".
- **Waiting:** after 60 s without a qualifying fix: "Still looking. Stand in the open, away
  from buildings and trees." It keeps trying until the user leaves. There is no timeout that
  saves without a fix.
- **Location off:** "Turn on Location to register a consignment", with a button that opens the
  location settings (`Geolocator.openLocationSettings`).
- **Permission refused once:** a plain sentence on why the app needs it, and a button that
  asks again. **Refused for good:** a button that opens the app's settings. Only foreground
  location is ever asked for.
- **When it is captured:** the coordinates come from the fix. `captured_at` is the moment Save
  is tapped, by the phone's clock (the server trusts it; Anomaly rules (10)).
- **Format:** `formatCoordinate`, then a range check (signing spec, section 4).

**Demo note (the viva).**

- **Indoors, a 25 m fix may never arrive.** The viva room is indoors, and the app will
  rightly refuse to save without a fix. So record a complete registration **outdoors on
  video** beforehand: scan, fix, mineral, weight, Save, then Send and "Sent". Use it if the
  live fix does not come.
- **Check that the demo GPS zone covers the test location** before recording, with
  `GET /admin/zones` and the point the phone shows. A registration outside every active zone
  is stored but flagged `GPS_ZONE` and held. That is the correct behaviour, but it is not
  the "Sent ✓" the video should show. If the place does not match, record somewhere the zone
  covers. Do not change the zone to fit, because zone boundaries are never edited (GPS zones
  decisions).

---

## 6. QR codes

- **Camera permission:** mobile_scanner asks the first time the scanner opens. If it is
  refused, the screen explains why and offers "Open settings". There is no way to type a code
  instead: FR-01 says scan, and the spec says "exactly as scanned".
- **Format:** QR only (`BarcodeFormat.qrCode`).
- **A valid code** follows the server's grammar: 4–128 characters from
  `A–Z a–z 0–9 . _ : / -`, for example `MC-2026-000123`. The value is used **exactly as
  scanned**: never trimmed, never case-changed.
- Anything else, such as a website link or a shop barcode: "This is not a MineChain custody
  record." The camera stays open.
- **Duplicates:**
  - The phone cannot ask the server: a miner gets 403 on `GET /consignments/by-qr`.
  - **On the phone:** if `local_steps` already holds a registration with this `qr_code`, from
    any account on this phone, Save is blocked: "This custody record was already registered
    on this phone on 17 Nov." A second registration is always a mistake, such as a double
    scan.
  - **Across phones:** the server stores the second registration as flagged
    `DUPLICATE_CONSIGNMENT` and holds the consignment. The app shows "Under review" with the
    server's message.
- The "Check a consignment" flow (`GET /consignments/by-qr`, with `%2F` for `/`) belongs to
  transporters and buyers in a later module.

---

## 7. Security notes (OWASP MASVS / MSTG)

| Area | What this module does | Flag |
|---|---|---|
| **Storage** | Signed steps are in the SQLCipher-format database. Its key and the token are in secure storage. Backup and device transfer are off (Mobile (14)). Nothing is logged, not even payloads or QR codes. The weight field turns off suggestions and autocorrect. | On a rooted phone, the database key could be read from secure storage. Accepted for the prototype. |
| **Crypto** | Keystore P-256, which never leaves the Keystore. No hand-written crypto. `Random.secure()` makes the step id and the database key. The payload is not hashed before signing. The test vectors are compared byte for byte. | No key attestation, so the server cannot tell a hardware key from a software one (spec, known limits). The plan uses the TEE and not StrongBox: StrongBox is slower and not on every phone. |
| **Auth** | The key is used without a PIN or fingerprint (NFR-06). | **Anyone holding the unlocked phone can sign as the miner.** This is the known Mobile (11) limit; requiring a screen lock is a future improvement. |
| **Platform** | The channel has three methods, with the alias checked in Kotlin. There are no exported components and no WebView. Permissions are asked for when first needed. Mock locations are refused. | The channel is reachable only from this app's own Dart code. |
| **Network** | Pinned TLS 1.3 is unchanged (Mobile (21)). The token goes in the header only. | none |
| **Code** | Exact version pins. The new native code (Kotlin and the sqlite3mc build) is small and readable. | **A release build has no R8 or obfuscation settings yet**; review this before any release. |
| **Resilience** | | No root or emulator detection. It is out of scope, and should be listed as a known limit in the MSTG report. |

---

## 8. Things I would flag now

1. **Mobile (16) and drift.** drift needs `build_runner` and `drift_dev` to generate code.
   Mobile (16) rejected code generation for Riverpod only, but the reasons (fewer moving
   parts, easier to read) apply here too. See Q1.
2. **The sqlite3mc build** may need an NDK install and a slow first build. If it will not
   build by 15:30, fall back as described in section 9, rather than ship an unencrypted file.
3. **Three taps** depends on how they are counted (Q5). Typing the weight is unavoidable.
4. **The "safe on this phone" sentence** is shown today where it is not true (section 3).

---

## 9. Time plan for today (Tuesday 17 Nov, about 11:30–19:30)

| Step | Estimate | Planned slot |
|---|---|---|
| M1 Keystore channel, and lunch | 1 h 15 + lunch | 11:30–14:25 |
| A1 Account requests (Q6) | 1 h | 14:25–15:25 |
| M2 Register the key | 1 h | 15:25–16:25 |
| M3 Encrypted database | 1 h 30 (the riskiest) | 16:25–17:55 |
| M4 Payload and save | 45 min | 17:55–18:40 |
| M5 Registration screen, first part | 50 min of 2 h | 18:40–19:30 |
| M5 Registration screen, the rest | 1 h 10 | Wednesday 08:30–09:40 |
| M6 Sync and "Send my work" | 1 h 45 | Wednesday 09:40–11:25 |
| M7 List and docs | 45 min | Wednesday 11:25–12:10 |

**Realistic target today: M1, A1 and M2–M4, with M5 started.** That means a key registered
for a real, approved miner, an encrypted database proven on the A57, and the save tested.
M5 finishes on Wednesday morning; M6 and M7 were already planned for Wednesday.

**If it overruns:**

- **M3 will not build (sqlite3mc or NDK) within its 1 h 30 (by 17:55):** pause M3, do M4
  against the in-memory test database, and come back to M3. Never fall back to an unencrypted
  file, even as a DEV-SHORTCUT: it would break NFR-01 silently.
- **A1 overruns:** cut "Show more" and Reject first and keep Approve, since only Approve
  unblocks the testing. The cut parts move to Thursday's admin screens.
- **M5 overruns on Wednesday:** commit the screen without the landscape and large-text checks,
  which move to just before M6.
- **M2 hits a server surprise:** M3 and M4 do not depend on it, so continue with them.

---

## 10. Open questions

**Q1. Keep drift (Mobile (1)) or use the sqlite3 package directly?**
drift adds `drift_dev` and `build_runner` (code generation), which Mobile (16) avoided for
Riverpod. Using sqlite3 directly keeps exactly Mobile (1)'s cipher setup and pragmas, with two
tables of hand-written, parameterised SQL and migrations through `user_version`. It is the
same "real SQL" style as the backend.
*Recommended: sqlite3 3.9.1 directly, without drift.* The cost is no generated typed queries
and no reactive streams; the lists refresh after each save or sync instead. This would be
recorded as a new decision row, keeping Mobile (1) unchanged.

Decision (17 Nov 2026): Approved by the developer: sqlite3 3.9.1 directly, with no drift,
drift_dev or build_runner. A new decisions row is added in M7; Mobile (1) is kept unchanged.

**Q2. In what unit does the miner type the weight?**
The payload needs whole milligrams. Gold is weighed in grams, and copper and manganese in
kilograms.
*Recommended: the unit follows the mineral.*
- Gold, emerald and amethyst: grams, with up to 3 decimals.
- Copper, cobalt and manganese: kilograms, with up to 6 decimals.
- In both cases it converts exactly to milligrams through the text, never a `double`.
- The unit is shown beside the field, so no extra tap is needed.
- Zero is refused.

Decision (17 Nov 2026): Approved by the developer: the unit follows the mineral, as
recommended.

**Q3. What GPS accuracy is good enough?**
*Recommended: 25 m or better,* the same as the server's zone-edge tolerance. Outdoors, a phone
normally gets 5–15 m within a minute. Save stays blocked until then, with no override.

Decision (17 Nov 2026): Approved by the developer: 25 m or better, with no override. See the
demo note in section 5.

**Q4. When does sync run?**
*Recommended:* on the Send tap; at app start and resume; and a few seconds after each save
while signed in, if a network seems to be there. Automatic runs happen at most once every 2
minutes and respect the backoff. There is no background sync (WorkManager) in this module,
and no connectivity package: a failed attempt is cheap and safe.

Decision (17 Nov 2026): Approved by the developer: on the Send tap, at start and resume, and
after each save. No background sync.

**Q5. How are the three taps counted (NFR-06)?**
*Recommended:*
1. "Register consignment" on the home.
2. The mineral, which is skipped when the last-used mineral is right.
3. Save.

Scanning finishes by itself when the code is in view, and the GPS fix arrives on its own.
Typing the weight is data entry, not a tap. This counting would be recorded in the decisions
log so the claim in the report can be checked.

Decision (17 Nov 2026): Approved by the developer: Register, then the mineral (skipped when
remembered), then Save. It is recorded in the decisions log in M7.

**Q6. How can M2, M5 and M6 be tested on the A57 when production has no active miner?**
Production has one administrator and one **pending** miner, and nothing in the app can
approve a request yet (the admin home's tiles still say "Coming soon").
*Recommended: build the administrator's "Account requests" screen now, as step A1 after M1,*
moved forward from Thursday's admin screens. It lists pending requests and offers Approve,
plus Reject, which the API supports cleanly with a reason. An approved miner logs in with the
password they chose when requesting; no activation code is involved.

Decision (17 Nov 2026): Approved by the developer: A1 as described in section 1, from 14:25
to 15:25 today (section 9).
