# MineChain codebase guide

A map of the whole repository: what the system does, where each part lives, how the parts
talk to each other, how to run and test them, and where to look when something breaks. It is
written for someone who has to debug or extend MineChain without the original tooling. It is
also the briefing for anyone writing about how the system was built.

State described: 23 Nov 2026, after PR #25 (dashboard) and the end-to-end run. The full
file-by-file listing is in the appendix at the end.

---

## 1. What MineChain is

MineChain is a prototype for verifying a mining supply chain. It is aimed at artisanal and
small-scale miners in Zambia. A bag of mineral (a **consignment**) carries a QR code, its
**custody record**. Every time the bag changes hands, the person holding the phone signs
what they saw: who, where (GPS), what mineral, what weight, when. The signed record is
checked by a server and then fixed on a public blockchain (Ethereum Sepolia), so nobody can
quietly change it later.

The chain of custody has three steps:

| Step | Who | App screen | Contract function |
|---|---|---|---|
| Registration (extraction) | Miner | "Register consignment" | `registerConsignment` |
| Handoff | Transporter | "Take custody" | `recordHandoff` |
| Purchase | Licensed buyer | "Record purchase" | `recordPurchase` |

Two more roles supervise the chain:

- **Regulatory officer:** alerts, consignment checks, reports, audit trails, dashboard.
- **System administrator:** accounts, account requests, GPS zones, reports, anchoring status.

### The four layers

```
 ┌───────────────────────── Android phone (mobile/) ─────────────────────────┐
 │ Flutter app: role screens, QR scan, GPS, P-256 key in Android Keystore,   │
 │ encrypted local database (SQLCipher scheme), offline queue, sync          │
 └───────────────┬───────────────────────────────────────────────────────────┘
                 │ HTTPS, TLS 1.3 only, pinned root CAs, JWT on every request
 ┌───────────────▼───────────── Render (backend/) ───────────────────────────┐
 │ Node.js + Express REST API                                                │
 │  routes → controllers → services → PostgreSQL (minechain-db)              │
 │  sync, signature check, 5 anomaly checks, alerts and holds, reports,      │
 │  accounts, GPS zones, dashboard, consignment view with live chain check   │
 │  anchoring worker (timer in the same process) ── recorder wallet ──┐      │
 └────────────────────────────────────────────────────────────────────┼──────┘
                                     JSON-RPC (Alchemy, PublicNode fallback)
 ┌────────────────────────────────────────────────────────────────────▼──────┐
 │ Ethereum Sepolia (contracts/): MineChain.sol, OpenZeppelin AccessControl  │
 │ only RECORDER_ROLE wallets may write; each write emits an event           │
 └───────────────────────────────────────────────────────────────────────────┘
```

Rules that shape everything:

- **The phone never talks to the blockchain.** Only the backend's recorder wallet writes,
  and only the backend reads the chain for checks.
- **Anomaly detection runs in the backend, not the contract.** There are five checks:
  duplicate consignment, quantity off by more than 10%, outside every licensed GPS zone,
  bad signature, and wrong handoff order. A failed check stores the step as *flagged*,
  creates an alert and **holds** the consignment. A held consignment is not anchored until
  an officer decides.
- **Offline first.** A step is signed and saved on the phone at once. It is sent when the
  network is back, automatically when the app returns to the front, or with "Send my work".
- **No personal data on chain.** The chain holds IDs, a hash of the signed record, the
  stage and the weight. Names, GPS and licence numbers stay in PostgreSQL.

### Live deployment

| Part | Where | Notes |
|---|---|---|
| API `minechain-api` | Render web service, Frankfurt, Free plan | Node 22.14.0. Sleeps when idle; the first request wakes it in about 30–60 s, and the app shows "waking up" |
| Database `minechain-db` | Render PostgreSQL, Free | Free databases expire after 30 days. See `docs/deployment.md`, "Presentation-window plan" (the 1 December refresh) |
| Contract | Sepolia `0x6419cB5268706E2aA4713AB3bCFc336248Ed158a` | Deployed 2 Nov 2026 with Hardhat Ignition. Viewable on sepolia.etherscan.io |
| RPC | Alchemy (main), PublicNode (fallback) | `SEPOLIA_RPC_URL`, `SEPOLIA_RPC_URL_FALLBACK` on Render |
| App | Android APK, built locally | Debug through `flutter run`; demo and checks use the obfuscated release build |

Secrets live only in Render's environment settings, `backend/.env` (local) and
`mobile/env/api.json` (local). They are never committed. `backend/.env.example` and
`mobile/env/api.example.json` show the names with fake values.

---

## 2. How one consignment moves through the code

Follow a bag from the mine to the buyer. Each line names the file that does the work.

1. **The miner scans and saves (phone).**
   - The QR code is checked: `mobile/lib/features/registration/domain/custody_record.dart`.
   - GPS has to be good enough to sign: `registration/domain/gps_fix.dart`,
     `steps/presentation/location_tracker.dart`.
   - The weight is converted to whole milligrams as text, never a float:
     `registration/domain/weight.dart`.
   - The exact nine-line text that gets signed is built in
     `registration/domain/registration_payload.dart` (format in `docs/signing-spec.md`).
   - `steps/data/save_signed_step.dart` builds the payload once and asks the Keystore to
     sign it. The Kotlin side is
     `mobile/android/app/src/main/kotlin/.../DeviceKeyPlugin.kt`, reached through
     `device_key/data/device_key_channel.dart`. The signed step goes in the encrypted
     table `local_steps` (`core/database/`). This is the "Saved on this phone" moment
     (NFR-03, under 3 s).
2. **The phone sends (sync).**
   - `sync/data/sync_service.dart` sends the waiting steps in a batch to
     `POST /sync/steps` (`sync/data/sync_api.dart`), through `core/network/api_client.dart`
     and the pinned HTTPS client `core/network/pinned_http_client.dart`.
   - The answer for each step (accepted, flagged, deferred, rejected, duplicate) is read by
     `sync/domain/sync_rules.dart` and shown in "Send my work"
     (`sync/presentation/send_work_screen.dart`).
3. **The server checks and stores.**
   - `backend/src/routes/sync.js` → `controllers/syncController.js` →
     `services/syncService.js`.
   - The payload is parsed strictly (`stepPayload.js`) and the P-256 signature verified
     against the user's registered key (`signatureService.js`).
   - Stage rules come from `custodyRules.js`. The anomaly checks are in `anomalyChecks.js`,
     and the GPS zone match in `zoneMatch.js`.
   - The step is stored in `transactions` as `passed` or `flagged`. A flagged step gets an
     `alerts` row, and the consignment is held (`anchorQueue.js`, `HELD`). A step that
     arrives before the one it depends on is deferred, and the phone retries it later.
4. **The worker anchors (backend → Sepolia).**
   - `backend/src/anchorWorker.js` runs a tick every `ANCHOR_INTERVAL_SECONDS`.
   - `services/anchorService.js` first reconciles steps already sent, then picks one
     eligible step with `anchorQueue.js`. Eligible means accepted, in custody order and not
     held.
   - `anchorCall.js` turns the step into a contract call, and `chain/chainClient.js` signs
     it with the recorder wallet and sends it.
   - When enough confirmations arrive, the step becomes `confirmed`, with `chain_tx_hash`
     and `block_number`.
   - Errors are sorted by `chain/chainErrors.js`.
5. **Someone checks the bag (verification).**
   - "Check a consignment" (`verification/presentation/consignment_check_screen.dart`)
     calls `GET /consignments/by-qr/{qrCode}`.
   - The server (`services/consignmentService.js`) loads the steps. For each confirmed step,
     `chainCheck.js` recomputes the hash from the stored payload, key and signature, and
     compares it with the event on chain (`chain/chainReader.js`, read-only).
   - The result is `match`, `mismatch`, `not_anchored_yet` or `chain_unavailable`. A
     mismatch raises a `record_tampered` alert.
   - `consignmentDisclosure.js` cuts the answer down to what the viewer's role may see
     (decision Scope (9)):
     - transporters see no weights before their own weigh-in;
     - buyers see no GPS until they own the bag;
     - only officers see flagged and rejected steps.
   - The app's banner comes from `verification/domain/verdict.dart`.
6. **An officer decides an alert.**
   - "Alerts" → one alert → "Confirm problem" (the step becomes `rejected` and is never
     anchored) or "Clear, no problem" (the step becomes `cleared`; the hold is released if
     no other alert is open).
   - Server: `services/alertService.js`. App: `features/alerts/`.

---

## 3. Top-level layout

| Path | What it is |
|---|---|
| `mobile/` | Flutter Android app (Dart, plus two Kotlin files for the Keystore and screen protection) |
| `backend/` | Node.js REST API, the anchoring worker, migrations, seed and helper scripts |
| `contracts/` | Solidity contract, its tests and the Hardhat Ignition deployment record |
| `docs/` | Specs, decisions, plans, test log, security review, deployment record (section 8) |
| `.claude/settings.json` | Permission rules used while building with Claude Code (not needed to run anything) |
| `CLAUDE.md` | Project brief and status log used while building |
| `README.md` | Front page of the repository |

---

## 4. The mobile app (`mobile/`)

**Stack:**

| What | Package or tool |
|---|---|
| Language and SDK | Flutter (Dart SDK ^3.13.7), Android only, minSdk 26 (Android 8.0), app id `io.github.kondwelanitembo.minechain` |
| State | `flutter_riverpod` 3.5.0 |
| Navigation | `go_router` 18.1.4 |
| HTTP | `http` 1.6.0 |
| Local database | `sqlite3` 3.9.1 built as SQLite3MultipleCiphers in the SQLCipher v4 scheme |
| Secure storage | `flutter_secure_storage` 11.2.0 |
| QR scanning | `mobile_scanner` 7.5.0 (ML Kit model bundled, so it works offline) |
| GPS | `geolocator` 14.1.2 |
| Sharing files | `share_plus` 13.3.1 |
| Other | `crypto` 3.0.8, `path_provider` 2.1.6 |

### 4.1 How the Dart code is organised

```
mobile/lib/
  main.dart          start-up: read config, open session, build the router
  core/              shared by every feature
  features/<name>/
    data/            API calls, local database, repositories
    domain/          plain Dart models and rules (no Flutter imports)
    presentation/    screens, widgets, Riverpod controllers and providers
```

**`core/`, folder by folder:**

| Folder | Responsibility | Look here when… |
|---|---|---|
| `config/` | The API address from `--dart-define-from-file=env/api.json`, checked at start-up | the app says the address is missing or wrong |
| `network/` | `api_client.dart` (the only HTTP code, adds the JWT); `pinned_http_client.dart` and `pinned_roots.dart` (TLS 1.3 only, three bundled root CAs); `server_status.dart` (the "waking up" banner); `session_events.dart` | a call fails, TLS or handshake errors, "No internet connection" when there is internet |
| `errors/` | `api_codes.dart` (every server code), `app_failure.dart` (the failure types), `failure_text.dart` (one plain sentence each), `field_errors.dart` | the wrong message appears for a failure |
| `router/` | `routes.dart` (every path), `app_router.dart` (path → screen), `redirect.dart` (one pure function deciding who may be where) | a screen opens for the wrong role, or a page bounces back to login or home |
| `database/` | The encrypted local database: key (`database_key.dart`), opening (`open_encrypted.dart`), tables and upgrades (`schema.dart`, version 2), busy handling | "saved work cannot be opened", the database is locked, an upgrade fails |
| `storage/` | `secure_store.dart`: the token and the database key in Android Keystore-backed storage | the login is lost after a restart |
| `text/` | `app_text.dart`: every sentence the user sees, in one file | to change any wording |
| `theme/`, `brand/`, `widgets/` | Copper theme, sizes, logo, shared widgets (home tiles, navigation bar, status lines, busy button) | layout, colour, overflow at large text |

**Features:**

| Feature folder | What it does | Screens (path) |
|---|---|---|
| `auth/` | Login, request an account (FR-12), activate an invited officer or admin account with a code (FR-10), the session (JWT, at most 60 min), the password prompt when the token runs out | `/login`, `/register`, `/activate`, splash `/start` |
| `account/` | "My account": who is signed in, refresh, log out | `/account` (Home/Account bar) |
| `device_key/` | Creates the P-256 key in the Android Keystore (screen lock required) and registers its public key with `PUT /auth/me/public-key`; warns when this phone is not the user's registered phone | notice on the home screen |
| `miner/`, `transporter/`, `buyer/`, `officer/`, `admin/…/admin_home_screen.dart` | The five home screens (big tiles) | `/miner`, `/transporter`, `/buyer`, `/officer`, `/admin` |
| `registration/` | Miner: scan, GPS, mineral, weight, sign, save (FR-01, FR-02, FR-07) | `/miner/register` |
| `handoff/` | Transporter: scan, server check with warnings, own weight, sign, save | `/transporter/custody` |
| `purchase/` | Buyer: the same page as handoff in "purchase" mode (`CustodyStepKind`) | `/buyer/purchase` |
| `steps/` | Shared by all three signing screens: `save_signed_step.dart`, local steps repository, GPS tracker, weight field, saved view, `later_step_payload.dart` | — |
| `consignments/` | "My consignments", "My handoffs", "My purchases": what this phone signed, with its sync state (read from the local database, Scope (8)) | `/miner/consignments`, `/transporter/handoffs`, `/buyer/purchases` |
| `sync/` | Sending the offline queue, automatic send on resume, "Send my work" | `/miner/sync`, `/transporter/sync`, `/buyer/sync` |
| `verification/` | "Check a consignment": scan, server answer, verdict banner, steps with chain results | `/transporter/check`, `/buyer/check`, `/officer/check` |
| `alerts/` | Officer: alerts list (Open, Confirmed, Cleared), one alert, "Confirm problem" or "Clear, no problem" with a reason | `/officer/alerts`, `/officer/alerts/:id` |
| `reports/` | CSV transactions report (officer, buyer, admin; FR-09) and audit trails (officer; FR-13), saved and shared through Android's share sheet | `/officer/reports`, `/buyer/reports`, `/admin/reports`; audit trail panels on the check result and on an alert |
| `dashboard/` | Officer analytics (FR-14): 7 days, 30 days or 12 months; mineral filter; volumes, minerals, zones, anomalies | `/officer/dashboard` |
| `admin/` | Account requests, accounts (create, rename, suspend, reactivate, reset key, delete, activation codes), GPS zones (list, create by walking or typing corners, rename, deactivate, reactivate), anchoring status (read-only) | `/admin/requests`, `/admin/accounts[/account,/new]`, `/admin/zones[/zone,/new]`, `/admin/anchoring` |

### 4.2 Navigating the app (what the examiner will see)

Every signed-in user lands on their **home**: a grid of big tiles, the MineChain brand block
under them, and a **Home / Account** bar at the bottom (a side rail in landscape). The top
bar shows "Role · username".

| Role | Home tiles, in order | Where each tile goes |
|---|---|---|
| Miner | Register consignment · My consignments · Send my work | scan → GPS → mineral → weight → Save; list of own registrations; queue and send |
| Transporter | Take custody · My handoffs · Send my work · Check a consignment | scan → server check and warnings → weight → Save; list; queue; verify |
| Buyer | Record purchase · My purchases · Send my work · Check a consignment · Reports | as transporter, plus the CSV report |
| Regulatory officer | Alerts · Dashboard · Check a consignment · Reports · Audit trail | alert queue; analytics; verify with full detail; CSV report; audit trail (opens the check, then its audit panel) |
| Administrator | Account requests · Accounts · GPS zones · Reports · Anchoring | approve or reject sign-ups; manage accounts; manage zones; CSV report; blockchain status |

Signed out, there are three pages: **Login**, **Request an account** (miner, transporter or
buyer; the admin approves) and **Activate account** (officers and admins are created by an
admin and get a one-time code).

The tiles' exact order is in each home screen file. The words are in `core/text/app_text.dart`.

### 4.3 Android-specific code

`mobile/android/app/src/main/kotlin/…/`:

- **`DeviceKeyPlugin.kt`:** creates the non-exportable P-256 key and signs with it. It
  refuses with `NO_SCREEN_LOCK` on a phone without a screen lock.
- **`MainActivity.kt`:** sets `FLAG_SECURE` on release builds (no screenshots, blank in
  recent apps) and ignores touches through overlays.

`build.gradle.kts` turns on `buildConfig` so `BuildConfig.DEBUG` decides `FLAG_SECURE`.
Consequence: **thesis screenshots must be taken from a debug build (`flutter run`)**, because
the release build blocks them.

### 4.4 Running the app

```powershell
cd C:\dev\minechain\mobile
flutter pub get
flutter run -d <device-id> --dart-define-from-file=env/api.json      # debug, screenshots allowed
flutter build apk --release --obfuscate --split-debug-info=build/symbols --dart-define-from-file=env/api.json
adb -s <device-id> install -r build\app\outputs\flutter-apk\app-release.apk
```

- `flutter devices` lists the device IDs.
- Never use `flutter install`, and never uninstall the app. Either one erases the Keystore
  key and the local database, and the phone then needs an admin "Reset device key".
- `env/api.json` holds the API address (copy `env/api.example.json`).

---

## 5. The backend (`backend/`)

**Stack:**

| What | Package or setting |
|---|---|
| Runtime and framework | Node.js 22.14.0, Express 5 |
| Database | `pg` (parameterised SQL only), migrations with `node-pg-migrate` (plain `.sql` files) |
| Validation | Zod 4 |
| Passwords | `argon2` (Argon2id, 19 MiB, 2 passes) |
| Tokens | `jose` (HS256 JWT, at most 60 min) |
| Protection | `helmet`, `express-rate-limit` |
| Blockchain | `ethers` 6.17.0 |
| Tests | Vitest and Supertest |

### 5.1 Request flow

```
src/server.js   loads config, creates the db pool, the anchoring worker and the app, listens
src/app.js      helmet, JSON limit 100 kb, routes, notFound, errorHandler
  routes/       URL → middleware chain (requireAuth, requireRole, rate limiter, validate) → controller
  controllers/  read the request, call one service, send the response
  services/     all business rules and SQL
  middleware/   requireAuth (JWT), requireRole, validate (Zod), rate limits, noStore, errors
  schemas/      Zod schemas for every body and query
  chain/        everything that talks to Ethereum
```

Errors meant for the client are `AppError`s (`src/errors.js`): an HTTP status, a stable
`code` and a plain message. The app maps the codes in `mobile/lib/core/errors/api_codes.dart`.
The full API reference is `docs/api.md`.

### 5.2 Endpoints

| Method and path | Who | Service | Purpose |
|---|---|---|---|
| `GET /health` | public | — | Render health check, database ping |
| `POST /auth/register` | public | `userService` | Request an account (FR-12) |
| `POST /auth/login` | public | `userService`, `tokenService` | Login, returns a JWT |
| `POST /auth/activate` | public | `userService` | Activate an invited account with its code |
| `GET /auth/me` | signed in | `userService` | Who am I (role, status, key fingerprint) |
| `PUT /auth/me/public-key` | miner, transporter, buyer | `userService` | Register this phone's signing key |
| `POST /auth/me/password` | signed in | `userService` | Change password; older tokens stop working |
| `POST /sync/steps` | miner, transporter, buyer | `syncService` | Upload signed steps (FR-03, FR-07, FR-08) |
| `GET /consignments/by-qr/:qrCode` | transporter, buyer, officer | `consignmentService` | Consignment view and live chain check (FR-04) |
| `GET /alerts`, `GET /alerts/:id` | officer | `alertService` | Alert queue and detail |
| `POST /alerts/:id/review`, `/dismiss` | officer | `alertService` | "Confirm problem" or "Clear, no problem" |
| `GET /reports/transactions` | officer, buyer, admin | `reportService` | CSV report (FR-09) |
| `GET /reports/audit-trail` | officer | `reportService` | CSV audit trail (FR-13) |
| `GET /dashboard` | officer | `dashboardService` | Counts for the dashboard (FR-14) |
| `GET/POST /admin/users…` | admin | `accountService` | List, create, approve, reject, suspend, reactivate, reset key, new activation code, rename, delete |
| `GET/POST /admin/zones…` | admin | `zoneService` | List, create, rename, deactivate, reactivate |
| `GET /admin/anchoring`, `POST /run`, `POST /steps/:id/retry` | admin | `anchorStatusService` | Anchoring status, run a tick, retry a failed step |

### 5.3 Services in one line each

| Service | What it does |
|---|---|
| `syncService.js` | Stores each synced step: strict parse, signature check, stage rules, anomaly checks, alerts, deferral, idempotency |
| `stepPayload.js`, `signatureService.js`, `signingError.js` | The signed text format and the P-256 check (`docs/signing-spec.md`) |
| `anomalyChecks.js`, `zoneMatch.js`, `custodyRules.js` | The five checks (FR-08), point-in-zone with 25 m tolerance, which step may follow which |
| `anchorQueue.js`, `anchorService.js`, `anchorCall.js`, `anchorWorker.js` | Which step goes next, one tick (reconcile, then send one), the contract call, the timer |
| `anchorStatusService.js` | The admin's status view, retry and run-now |
| `chainCheck.js`, `consignmentService.js`, `consignmentDisclosure.js` | The live verification and what each role may see |
| `alertService.js` | Alert list and detail, the officer's two decisions, hold release |
| `reportService.js`, `csv.js`, `units.js` | CSV reports with CSV-injection protection, milligrams to kilograms |
| `dashboardService.js` | Counts by day, mineral, zone, alert rule and severity |
| `accountService.js`, `accountStatus.js`, `activationCode.js`, `userService.js`, `passwordPolicy.js`, `passwordService.js`, `tokenService.js` | Accounts, statuses, invitations, login, passwords, JWT |
| `zoneService.js`, `zoneShape.js` | GPS zones and their shape rules |
| `auditService.js` | Append-only `audit_logs` rows for every decision and admin action |
| `index.js` | Wires the real services together (tests wire fakes instead) |

### 5.4 Database (PostgreSQL)

The 11 migrations in `backend/migrations/` create these tables (full reference in
`docs/database-schema.md`):

| Table | What it holds |
|---|---|
| `users` | Accounts, roles, statuses (pending, active, suspended, rejected, invited, deleted), Argon2id hash, device public key, activation code hash, `tokens_valid_after` |
| `gps_zones` | Licensed extraction zones: polygon corners, licence number, active or inactive |
| `consignments` | One row per QR code: current stage (registered, in_transit, purchased) |
| `transactions` | Every signed step: payload, signature, signer key, GPS, weight in mg, `review_status` (passed, flagged, cleared, rejected), `anchor_status` (pending, submitted, confirmed, failed), `chain_tx_hash`, `block_number`, nonce |
| `alerts` | One per failed check: type, severity, details, status (open, reviewed, dismissed), officer notes |
| `audit_logs` | Append-only log of who did what (the database refuses updates and deletes) |

Commands:

```powershell
npm run migrate      # apply to DATABASE_URL
npm run seed         # first admin, demo zone, demo users (dev)
```

### 5.5 Running and testing the backend

```powershell
cd C:\dev\minechain\backend
npm install
copy .env.example .env      # then fill in real values locally; never commit .env
npm run migrate
npm run seed
npm run dev                 # http://localhost:<PORT>
npm test                    # unit and route tests (2348)
npm run test:db             # real SQL against TEST_DATABASE_URL (932)
node scripts/anchor-once.js # one anchoring tick by hand
```

Run vitest from PowerShell, not Git Bash. Git Bash's `/c/` path loads vitest twice.

**Deploying:** merging to `main` on GitHub redeploys `minechain-api` on Render. Migrations
are run by hand against production after a backup (see `docs/deployment.md`).

---

## 6. The smart contract (`contracts/`)

`contracts/contracts/MineChain.sol` (Solidity 0.8.34, Hardhat 3, OpenZeppelin
`AccessControl` 5.6.1):

**Roles:**
- `DEFAULT_ADMIN_ROLE`: the deployer.
- `RECORDER_ROLE`: the backend's recorder wallet. Only it may write.

**Write functions:**

| Function | Stage change | Event |
|---|---|---|
| `registerConsignment(id, actorRef, dataHash, weightMilligrams, …)` | None → Registered | `ConsignmentRegistered` |
| `recordHandoff(…)` | Registered/InTransit → InTransit | `HandoffRecorded` |
| `recordPurchase(…)` | InTransit → Purchased (final) | `PurchaseRecorded` |

`getConsignment(id)` is read-only.

**What is stored:**
- On chain: only `bytes32` IDs and hashes, the stage, the weight in milligrams and the
  timestamp. No names, no GPS.
- Kept by the server: the phone's P-256 signature (Ethereum cannot check P-256 cheaply).
  The chain fixes a hash of the signed record, so changing the stored record breaks the
  match.

**Commands:**

```powershell
cd C:\dev\minechain\contracts
npm install
npx hardhat test       # 37 tests, local network only
```

The deployment record is in `ignition/deployments/chain-11155111/`. The module is
`ignition/modules/MineChain.ts`, with parameters in `ignition/parameters/sepolia.json`.

---

## 7. Tests

| Suite | Where | Command | Count (23 Nov) |
|---|---|---|---|
| Flutter unit and widget | `mobile/test/` (mirrors `lib/`; fakes in `test/fakes/`) | `flutter test` | 2623 |
| Flutter on device | `mobile/integration_test/` (database encryption, device key) | `flutter test integration_test/<file> -d <id> --no-uninstall` | run by hand |
| Backend unit and route | `backend/tests/*.test.js` (fakes in `tests/fakes/`) | `npm test` | 2348 |
| Backend with real SQL | `backend/tests/db/` | `npm run test:db` | 932 |
| Contract | `contracts/test/` | `npx hardhat test` | 37 |

Other checks:
- `docs/signing-vectors.json` holds fixed test vectors that both the Dart and the Node
  tests check byte for byte. Never regenerate them.
- Every subtask's real numbers are in `docs/testing-log.md`.
- The phone checks are in each plan in `docs/plans/`.
- The production end-to-end run is in `docs/plans/end-to-end-plan.md`.
- The OWASP MASVS review is in `docs/security-review.md`.

---

## 8. The docs folder

| File | Use it for |
|---|---|
| `api.md` | Every endpoint: body, answers, codes, who may call it, what each viewer sees |
| `database-schema.md` | Tables, constraints, statuses, the two clocks convention |
| `contract-spec.md` | Contract, events, how the backend calls it, the chain check |
| `signing-spec.md`, `signing-vectors.json` | The exact signed text, key format, anchor hash |
| `decisions.md` | Every design decision with the alternatives and the reason, plus known limitations. Check it before changing behaviour |
| `deployment.md` | Render setup, environment variable names, TLS pinning, backups, the RPC change of 22 Nov, re-check list |
| `security-review.md` | MASVS v2 review, findings (H1 fixed; M1, M2, L1–L7) and device results |
| `testing-log.md` | Every test run with exact numbers |
| `progress.md` | Day plan and checklist used while building |
| `plans/*.md` | One plan per feature: subtasks, questions, phone check steps and results |
| `live-run-2026-11-09.md` | First real anchoring on Sepolia, with Etherscan links |

---

## 9. Debugging guide

### 9.1 General method

1. **Find the layer.** Did the phone save it ("Saved on this phone")? Did the server accept
   it ("Send my work" outcome)? Was it anchored (admin "Anchoring" screen, or
   `anchor_status` in `transactions`)? Does the check agree ("Check a consignment")?
2. **Read the code that comes back.** Every server refusal has a `code` (`docs/api.md`). The
   app's sentence for it is in `core/errors/failure_text.dart` or the feature's `*_words.dart`.
3. **Reproduce in a test first.** Each file has a mirror test (`lib/x/y.dart` →
   `test/x/y_test.dart`, `src/services/x.js` → `tests/x.test.js` or `tests/db/x.test.js`).
   Write the failing case, fix, then run the full suite.
4. **Check `decisions.md`** before "fixing" something. Many surprises are deliberate, for
   example a buyer not seeing a rejected purchase.

### 9.2 Symptom → where to look

| Symptom | Likely cause | Where |
|---|---|---|
| App stuck on "waking up" or "server not ready" | Render free service asleep or redeploying | Wait 60 s; Render dashboard logs; `GET /health` |
| "Could not make a secure connection" | TLS pinning: Render's certificate chain changed root | `core/network/pinned_roots.dart`, `mobile/tool/check_tls.dart`, `deployment.md` "TLS chain and pinning plan" |
| Logged out unexpectedly, or "Enter your password" | JWT expired (60 min) or password changed elsewhere | `auth/presentation/auth_controller.dart`, `session_expiry_watcher.dart`; server `requireAuth.js`, `tokens_valid_after` |
| A role sees the wrong screen or is bounced | Redirect rule | `core/router/redirect.dart` and its test |
| "This phone is not your registered phone" or cannot sign | Key reset, reinstall, or no screen lock | `device_key/`, `DeviceKeyPlugin.kt`; admin "Reset device key", then sign in again on the phone |
| "Saved work cannot be opened" | Database key lost or file damaged | `core/database/open_encrypted.dart`, `database_failure.dart` |
| GPS never good enough | Indoors or poor accuracy; policy in `gps_fix.dart` | `steps/presentation/location_tracker.dart` |
| Step flagged with `GPS_ZONE` | Point outside every active zone (25 m tolerance) | `zoneMatch.js`; admin "GPS zones" (is a zone active there?) |
| Step flagged with quantity discrepancy | More than 10% from the previous accepted step or the registration | `anomalyChecks.js` `checkQuantity` |
| Step stays "waiting" (`STAGE_NOT_READY`, deferred) | An earlier step has not arrived, or the consignment is held for review | `syncService.js`, `custodyRules.js`; officer "Alerts" |
| Step never gets a transaction hash | Worker off, wallet low on Sepolia ETH, RPC down, consignment held | Admin "Anchoring" screen; `anchorService.js`, `chainErrors.js`; Render env `ANCHOR_ENABLED`; top up the recorder wallet from a faucet |
| "Could not reach the blockchain" on a check | RPC unavailable | `chain/chainReader.js`, `rpc.js`; Render `SEPOLIA_RPC_URL` and fallback |
| False "tampered" alert with `TX_NOT_FOUND` | Provider pruned old receipts (fixed 22 Nov: treated as unavailable) | `chainCheck.js` step 4, `chainReader.getTransaction` |
| Report download fails or shows the wrong rows | Filters, 366-day limit, 10,000-row cap (`REPORT_TOO_LARGE`) | `reportService.js`, `reports/domain/report_request.dart` |
| Text cut off or overflow at large font size | Layout | the screen's widget test at 2.0 text scale; `core/text/text_width.dart` |
| Production database gone after 30 days | Render Free database expiry | `deployment.md`, "Presentation-window plan" (1 December refresh) and "Backups and restore" |

### 9.3 Useful one-off tools

| Tool | What it does |
|---|---|
| `node scripts/anchor-once.js [--until-idle]` | Run the anchoring worker by hand and print what it did |
| `npm run demo:journey` | Development shortcut (DEV-SHORTCUT): makes a demo chain signed by server-side keys. Never on production |
| `mobile/tool/check_tls.dart` | Checks the app's TLS 1.3 and pinning code against the real server (`dart run tool/check_tls.dart`) |
| `mobile/tool/make_launcher_icon.dart` | Regenerates the launcher icon from the logo geometry |

---

## Appendix: every file in the repository

Generated from `git ls-files` (633 files). The note after each file is the first line of its
own header comment. Files with no note are configuration, data or generated files, or their
name says what they are. Tests mirror the source tree and test the file of the same name.

#### `./`

- `.gitignore`
- `CLAUDE.md` — CLAUDE.md
- `LICENSE`
- `README.md` — MineChain

#### `.claude/`

- `settings.json`

#### `backend/`

- `.env.example`
- `.node-version`
- `.npmrc`
- `README.md` — backend/
- `package-lock.json`
- `package.json`
- `vitest.config.js`
- `vitest.db.config.js` — Config for `npm run test:db`: tests that run real SQL against minechain_test.

#### `backend/migrations/`

- `.gitkeep`
- `1793746952331_create-users.sql`
- `1793790119786_create-gps-zones.sql`
- `1793790136398_create-consignments.sql`
- `1793792423610_create-transactions.sql`
- `1793793756817_create-alerts.sql`
- `1793793775431_create-audit-logs.sql`
- `1794052800000_users-public-key-unique.sql`
- `1794139200000_transactions-anchor-nonce.sql`
- `1794398400000_clock-timestamp-defaults.sql`
- `1794441600000_users-activation.sql`
- `1794528000000_users-deleted.sql`

#### `backend/scripts/`

- `anchor-once.js` — `npm run anchor:once` (one tick) or `npm run anchor:once -- --until-idle`.
- `demo-journey.js` — DEV-SHORTCUT: server-side signing of a demo custody chain / remove before release (see src/cli/demoJourney.js) `npm run demo:journey`: creates three fresh demo users and syncs a registration,…
- `make-signing-vectors.js` — Writes docs/signing-vectors.json, the fixed test vectors shared by the backend and the Flutter tests (docs/signing-spec.md, section 9).
- `seed.js` — `npm run seed` (development) or `npm run seed -- --production-admin-only` (production).

#### `backend/src/`

- `anchorWorker.js` — The anchoring worker inside the API process (8 Nov plan, step 8, process model).
- `app.js`
- `config.js` — Used for one offline check only: the address checksum.
- `db.js`
- `errors.js` — An error the client is meant to see: it carries its own HTTP status, a stable code the app can branch on, and a plain-language message.
- `roles.js` — The five roles, exactly as the users_role_valid CHECK in the users migration allows.
- `server.js` — Loads backend/.env into process.env for local development.

#### `backend/src/chain/`

- `chainClient.js` — The anchoring worker's link to Ethereum (docs/contract-spec.md, section 6); the only other network code is the key-free, read-only chainReader.js.
- `chainErrors.js` — Sorts any error from the chain client into a small fixed set of codes, each with what the anchoring worker should do about it (docs/contract-spec.md, section 6).
- `chainReader.js` — Read-only chain access for verification (FR-04, plan B2 "Read-only chain access").
- `describe.js` — Turns chain facts into text for logs and the anchor:once script.
- `mineChainAbi.js` — What the backend knows about the deployed MineChain contract (docs/contract-spec.md).
- `preflight.js` — Startup checks for the anchoring worker (8 Nov plan, step 8).
- `rpc.js` — The JSON-RPC plumbing shared by the two modules that talk to Ethereum: chainClient.js (the anchoring worker, which signs) and chainReader.js (verification, which never signs).

#### `backend/src/cli/`

- `anchorOnce.js` — npm run anchor:once [-- --until-idle]: preflight, then one anchoring tick (or ticks until idle), printed for a person at a terminal.
- `demoJourney.js` — DEV-SHORTCUT: signs custody steps on the server with throwaway in-memory keys instead of phones / remove before release; real steps are signed on the device (NFR-02) npm run demo:journey: one…

#### `backend/src/controllers/`

- `adminAnchoringController.js` — HTTP in, service call, HTTP out.
- `adminUsersController.js` — Controllers translate HTTP into service calls and back.
- `adminZonesController.js` — Controllers translate HTTP into service calls and back.
- `alertsController.js` — HTTP in, service call, HTTP out.
- `authController.js` — Controllers translate HTTP into service calls and back.
- `consignmentsController.js` — HTTP in, service call, HTTP out.
- `dashboardController.js` — HTTP in, service call, HTTP out.
- `healthController.js`
- `reportsController.js` — Controllers translate HTTP into service calls and back.
- `syncController.js` — Controllers translate HTTP into service calls and back.

#### `backend/src/data/`

- `common-passwords.LICENSE`
- `common-passwords.txt`

#### `backend/src/middleware/`

- `errorHandler.js` — Errors raised by express.json() carry a `type`.
- `noStore.js` — Tells every phone, browser and proxy not to keep a copy of the response.
- `notFound.js` — Registered after every route, so Express only reaches it when nothing else matched.
- `rateLimits.js`
- `requireAuth.js` — RFC 6750 (Bearer tokens). The realm names the protected area; error="invalid_token" tells the client that the credentials it sent were refused, not simply missing.
- `requireRole.js` — Allows a request only if the logged-in user has one of the given roles.
- `validate.js` — Checks one part of the request (body by default) against a Zod schema before the controller runs.

#### `backend/src/routes/`

- `adminAnchoring.js` — Mounted at /admin/anchoring (anchoring admin plan §5).
- `adminUsers.js`
- `adminZones.js`
- `alerts.js` — Mounted at /alerts (app endpoints plan, B1).
- `auth.js` — register, /login and /activate are public: nobody has a token yet.
- `consignments.js` — Mounted at /consignments (app endpoints plan, B2).
- `dashboard.js` — Mounted at /dashboard (FR-14, dashboard plan T2).
- `health.js` — Public on purpose: Render's health checks and uptime monitors cannot log in.
- `reports.js` — Mounted at /reports (FR-09, FR-13).
- `sync.js` — Mounted at /sync. requireAuth and the sync limiter are made by createApp and passed in, so each app instance (and each test) has its own counter.

#### `backend/src/schemas/`

- `adminAnchoring.js` — The bodies come from schemas/adminUsers.js: reasonBodySchema (retry) and emptyBodySchema (run), so a reason means the same thing on every admin action.
- `adminUsers.js` — The six statuses, exactly as the users_status_valid CHECK allows since the users-deleted migration.
- `alerts.js`
- `auth.js` — Only roles people may request for themselves (FR-12).
- `consignments.js` — :qrCode in GET /consignments/by-qr/:qrCode (plan B2.5).
- `dashboard.js` — Query parameters for GET /dashboard (FR-14).
- `geo.js` — Six decimal places is about 11 cm, finer than phone GPS. transactions stores numeric(9,6), and PostgreSQL silently rounds extra places, so a stored point would differ from the signed one and…
- `gpsZones.js` — The two statuses, exactly as the gps_zones_status_valid CHECK in the migration allows.
- `reports.js` — Query parameters for the spreadsheet reports: GET /reports/transactions (FR-09) and GET /reports/audit-trail (FR-13).
- `sync.js` — POST /sync/steps: a batch of signed custody steps from the phone's offline queue.

#### `backend/src/seed/`

- `seed.js`
- `seedData.js` — Fixed data for `npm run seed`.

#### `backend/src/services/`

- `accountService.js` — How long an activation code works.
- `accountStatus.js` — One place for the answer an account gets when it exists and is genuine but is not allowed in.
- `activationCode.js` — Single-use activation codes for officer and admin accounts created by an administrator (FR-10).
- `alertService.js` — The officer's view of anomaly alerts (FR-08; decisions.md Scope (2) and (5)), and the two ways an officer closes one: "Confirm problem" (review) and "Clear, no problem" (dismiss).
- `anchorCall.js` — Turns one stored custody step into the contract call that anchors it, and checks that a receipt's event really belongs to that step (docs/contract-spec.md, sections 5 and 6).
- `anchorQueue.js` — Which stored steps the anchoring worker may send next, and the lock that keeps it to one worker at a time (8 Nov plan, step 8).
- `anchorService.js` — The anchoring worker's single tick (8 Nov plan, step 8; 9 Nov plan for 8.7).
- `anchorStatusService.js` — The administrator's view of anchoring (anchoring admin plan §1, N2): what the worker is doing, what is waiting, what is stuck or failed, and a list of problems.
- `anomalyChecks.js` — The anomaly checks run on each stored custody step (FR-08).
- `auditService.js` — A safety net, not the main protection: callers decide what goes into details, and must never pass secrets.
- `chainCheck.js` — The chain check behind the consignment view (FR-04; plan Â§3, "The chain check, per confirmed step").
- `consignmentDisclosure.js` — What each role may see of one consignment (FR-04; plan §3, "What each role sees", from decisions.md Scope (9)).
- `consignmentService.js` — The consignment view (FR-04; plan §3, B2.4): one scan by a transporter, buyer or officer returns the consignment, its steps and a live chain check per confirmed step, cut down to what that role…
- `csv.js` — CSV for spreadsheet reports (FR-09, FR-13).
- `custodyRules.js` — Where a handoff or purchase may happen, and where it moves the consignment (the contract's stage rules, contract spec section 5).
- `dashboardService.js` — The regulatory officer's dashboard (FR-14; docs/plans/dashboard-plan.md): counts only, for a period and optionally one mineral.
- `index.js` — The one place where the real services are connected to each other.
- `passwordPolicy.js` — 12 rather than NIST rev. 4's 15 for single-factor passwords: NFR-06 asks for plain, easy use by miners with limited English, and a three-word passphrase such as "gold river kasempa" meets 12. The…
- `passwordService.js` — OWASP Password Storage Cheat Sheet minimum for Argon2id: 19 MiB of memory, 2 passes, 1 thread.
- `reportService.js` — Spreadsheet reports: the transactions report (FR-09) and the audit trail (FR-13).
- `signatureService.js` — Keys, signatures and the anchor hash: docs/signing-spec.md, sections 2, 5 and 7.
- `signingError.js` — The one error type for everything in docs/signing-spec.md: payloads (stepPayload.js) and, from 5c, keys and signatures (signatureService.js).
- `stepPayload.js` — The signed payload, format version 1: docs/signing-spec.md, section 3.
- `syncService.js` — Stores signed custody steps synced from the phone's offline queue (FR-03, FR-07): POST /sync/steps.
- `tokenService.js`
- `units.js` — Weight units for reports (FR-09).
- `userService.js` — Wrong codes allowed against one activation code.
- `wording.js` — Small helpers for the fixed plain-language messages services send back.
- `zoneMatch.js` — Which licensed GPS zone a point falls in (FR-08's GPS zone rule, FR-11's zones).
- `zoneService.js` — Licensed GPS zones, managed by administrators (FR-11).
- `zoneShape.js` — Shape checks for a licensed GPS zone's boundary (FR-11), beyond the per-corner rules in schemas/geo.js.

#### `backend/tests/`

- `accountEdits.test.js`
- `activationCode.test.js`
- `adminAnchoringRoutes.test.js` — The anchoring admin routes with the real app and token checks, and a fake service behind them.
- `adminUsersRoutes.test.js` — Fake secret, long enough for the 43-character rule.
- `adminUsersSchemas.test.js`
- `adminZonesRoutes.test.js` — Fake secret, long enough for the 43-character rule.
- `alertClose.test.js` — The rule, written out independently of the code under test: any reviewed -> rejected; all dismissed -> cleared; otherwise flagged.
- `alertsRoutes.test.js` — The alert routes with the real app and token checks, and a fake service behind them.
- `alertsSchemas.test.js`
- `anchorCall.test.js`
- `anchorOnce.test.js`
- `anchorStatusService.test.js`
- `anchorWorker.test.js`
- `anomalyChecks.test.js`
- `app.test.js` — Same shape as the object createDb() returns, so the app cannot tell the difference.
- `auditService.test.js` — A fake db that records the query, so these tests need no database.
- `authActivate.test.js` — All values fake. The code is in display form, as the administrator read it out.
- `authChangePassword.test.js` — Fake secret, long enough for the 43-character rule.
- `authLogin.test.js`
- `authPublicKey.test.js` — Fake secret, long enough for the 43-character rule.
- `authRegister.test.js`
- `authSchemas.test.js`
- `chainCheck.test.js` — The fixed vectors (never regenerated): real payloads, keys and signatures, with the anchor hash each one must give.
- `chainClient.test.js` — Real ethers, real config, fake HTTP: every request goes to rpcTransport below instead of the network, so these tests prove the adapter's own logic without touching Sepolia.
- `chainErrors.test.js`
- `chainReader.test.js` — Real ethers, real config, fake HTTP (as in chainClient.test.js): every request goes to rpcTransport below, so no test here can reach Sepolia.
- `config.test.js` — Fake values only. Each test overrides just the variable it is about, so a failure points at a single rule.
- `consignmentDisclosure.test.js` — Fake people and records only.
- `consignmentService.test.js` — The service's shape without a database: a fake db that knows when a transaction is open, and a reader that fails the test if it is called while one is.
- `consignmentsRoutes.test.js` — The consignment view route with the real app and token checks, and a fake service behind it.
- `csv.test.js`
- `dashboardRoutes.test.js` — GET /dashboard with the real app and token checks, and a fake service behind it.
- `dashboardSchemas.test.js`
- `db.test.js` — A stand-in for pg.Pool that records calls, so these tests need no database.
- `demoJourney.test.js` — The refusal comes before anything is read or written, so these need no database: every dependency here fails the test if it is touched at all.
- `errorHandler.test.js` — A throwaway app with routes that fail on purpose, so the handler is tested on its own.
- `fakeChainClient.test.js` — The worker's tests (8.7) will trust this fake, so it is tested itself: that it has the real client's interface, and that it follows the contract's rules.
- `geoSchemas.test.js`
- `gpsZonesSchemas.test.js`
- `malformedPathRoutes.test.js` — A malformed percent-escape in a route parameter (B2.5a), through the real app: Express 5's router fails to decode it while matching the route, and errorHandler answers a fixed 400.
- `mineChainAbi.test.js`
- `passwordPolicy.test.js`
- `passwordService.test.js` — Real Argon2 with the real settings (about 50 ms a hash), so these tests prove what production does, not a faster stand-in.
- `preflight.test.js`
- `publicKeySchema.test.js` — Shape of a fake base64 SPKI: 124 characters, as a 91-byte key takes.
- `reportsRoutes.test.js` — Fake secret, long enough for the 43-character rule.
- `reportsSchemas.test.js`
- `requireAuth.test.js` — Fake secret, long enough for the 43-character rule.
- `requireRole.test.js` — Fake secret, long enough for the 43-character rule.
- `roles.test.js`
- `signatureService.test.js`
- `signingVectors.test.js`
- `stepPayload.test.js` — The two examples from docs/signing-spec.md, section 3, field for field.
- `syncLimiter.test.js`
- `syncRoutes.test.js` — Fake secret, long enough for the 43-character rule.
- `syncSchema.test.js`
- `tokenService.test.js` — Fake secrets, long enough for the 43-character rule.
- `units.test.js`
- `userService.test.js`
- `usernameSchema.test.js` — usernameSchema now stands alone so the seed script (and later admin user creation) can reuse it.
- `validate.test.js` — A small schema in the style the auth routes will use: strict, with trimming and a default.
- `zoneMatch.test.js`
- `zoneShape.test.js`

#### `backend/tests/db/`

- `accountCreation.test.js` — Officer and administrator accounts created by an administrator (FR-10), before activation exists (A4): creation, a new code, and how every existing path treats an invited account.
- `accountEdits.test.js` — Account rename and soft delete (B3.2) against the real database: what each writes, what it refuses, what a deleted account can no longer do, and what history it keeps.
- `accountEditsRealStack.test.js` — Account rename and soft delete through the whole stack (B3.3): a miner made through the API signs a step, an administrator renames then deletes the account over HTTP, and afterwards the miner's…
- `accountService.test.js`
- `activation.test.js` — FR-10 end to end: an administrator creates an officer through the API, and the officer activates the account with the code and their own password.
- `adminUsers.test.js`
- `adminZones.test.js` — GPS zone management (FR-11) through the whole stack: HTTP, the admin guard, validation, the zone service, PostgreSQL, and then sync reading the zones an admin set up.
- `alertClose.test.js`
- `alertService.test.js` — The read side of the officers' alert queue (plan B1.1): order for each status, the type filter, the total, paging, the held flag by the queue's own rule (including the duplicate exception), and…
- `alerts.test.js`
- `alertsRealStack.test.js` — An officer's decision end to end (app endpoints plan, B1.3): accounts made through the API, real P-256 signatures over HTTP, a flagged handoff that holds its consignment, the officer listing and…
- `anchorAdminActions.test.js`
- `anchorAdminRealStack.test.js` — The anchoring admin endpoints through the whole stack, as server.js wires it: the real app, services and worker, the test's database, and the fake chain.
- `anchorQueue.test.js`
- `anchorService.test.js` — The worker against the in-memory chain: every row of the crash table and the error table from the Step 8 plan.
- `anchorStatus.test.js` — The admin anchoring status against real rows (plan §1, §6 "Status").
- `anomalyRules.test.js` — The anomaly rules through the real sync service (FR-08): each finding is stored as a flagged step with its alert, and the consignment's stage does not move.
- `auditService.test.js`
- `audit_logs.test.js`
- `authLogin.test.js`
- `authMe.test.js`
- `authPublicKey.test.js`
- `authRegister.test.js`
- `clockDefaults.test.js` — The clock-timestamp-defaults migration: two columns whose order matters inside one database transaction default to clock_timestamp() (the time of the INSERT), not now() (the time the transaction…
- `connection.test.js`
- `consignmentView.test.js` — The consignment view (plan B2.4) against the real database: steps signed with real P-256 keys and synced over HTTP, anchored by the real worker on the in-memory chain, and checked through the fake…
- `consignmentViewRealStack.test.js` — The consignment view end to end (app endpoints plan, B2.5): accounts made through the API, real P-256 signatures over HTTP, the anchoring worker on the in-memory chain, the fake reader over that…
- `consignments.test.js`
- `dashboardRealStack.test.js` — The dashboard (FR-14) through the whole stack: accounts made through the API, real P-256 signatures synced over HTTP, then GET /dashboard as an officer.
- `dashboardService.test.js` — The officer's dashboard counts (FR-14) against the real database.
- `demoJourney.test.js` — The whole journey through the real services, on the rolled-back test transaction.
- `fixtures.js` — Valid example rows for the DB tests.
- `flaggedChain.test.js` — A flagged step end to end (Step 9.5): real accounts made through the API, real P-256 signatures over HTTP, the anomaly rules in sync, and the anchoring worker against the in-memory chain.
- `globalSetup.js` — Vitest calls this once before the database tests.
- `gps_zones.test.js`
- `helpers.js` — SQLSTATE codes PostgreSQL puts on err.code.
- `lostDevice.test.js`
- `passwordChange.test.js` — Password change through the whole stack (POST /auth/me/password): the fresh token works at once, every older token is refused, and nothing secret is written anywhere.
- `realStackHelpers.js` — Shared helpers for the DB tests that drive the whole stack: a phone's key and signatures, signed sync items, HTTP calls, and the anchoring worker's test doubles.
- `reportService.test.js`
- `reports.test.js` — Reports (FR-09, FR-13) through the whole stack: accounts made through the API, real P-256 signatures synced over HTTP, then CSV downloads, parsed back here.
- `seed.test.js`
- `syncChain.test.js`
- `syncService.test.js`
- `transaction.test.js`
- `transactions.test.js`
- `userAuthenticate.test.js`
- `userPublicKey.test.js`
- `userService.test.js`
- `users.test.js`
- `usersActivation.test.js` — The users-activation migration: the 'invited' status, an optional password hash, the activation code columns and tokens_valid_after.
- `usersDeleted.test.js` — The users-deleted migration: the 'deleted' status, a reason for it, and no password hash on a deleted account.
- `zoneService.test.js`

#### `backend/tests/fakes/`

- `fakeChainClient.js` — An in-memory chain client for tests.
- `fakeChainReader.js` — An in-memory chain reader for tests: the same methods, shapes and errors as src/chain/chainReader.js, plus controls for what verification must survive (the RPC down, a node on the wrong network, a…

#### `contracts/`

- `.gitignore`
- `AGENTS.md` — Hardhat + ethers project
- `CLAUDE.md`
- `README.md` — contracts/
- `hardhat.config.ts`
- `package-lock.json`
- `package.json`
- `tsconfig.json`

#### `contracts/.agents/skills/hardhat/`

- `SKILL.md` — Hardhat 3

#### `contracts/.agents/skills/hardhat-toolbox-mocha-ethers/`

- `SKILL.md` — Hardhat toolbox: ethers + Mocha

#### `contracts/.claude/skills/hardhat/`

- `SKILL.md` — Hardhat 3

#### `contracts/.claude/skills/hardhat-toolbox-mocha-ethers/`

- `SKILL.md` — Hardhat toolbox: ethers + Mocha

#### `contracts/contracts/`

- `MineChain.sol` — Exact version, not ^0.8.34: deployed code cannot be changed, so the compiler that built it should never vary between machines or over time.

#### `contracts/ignition/deployments/chain-11155111/`

- `deployed_addresses.json`
- `journal.jsonl`

#### `contracts/ignition/deployments/chain-11155111/artifacts/`

- 1 generated deployment file(s) (compiled artifact / build info); never edit by hand.

#### `contracts/ignition/deployments/chain-11155111/build-info/`

- 1 generated deployment file(s) (compiled artifact / build info); never edit by hand.

#### `contracts/ignition/modules/`

- `MineChain.ts`

#### `contracts/ignition/parameters/`

- `sepolia.json`

#### `contracts/scripts/`

- `check-roles.ts` — Read-only check of the roles on the deployed Sepolia contract.

#### `contracts/test/`

- `MineChain.ts`

#### `docs/`

- `README.md` — docs/
- `api.md` — MineChain API
- `contract-spec.md` — MineChain contract specification
- `database-schema.md` — Database schema
- `decisions.md` — Decisions log
- `deployment.md` — MineChain deployment
- `live-run-2026-11-09.md` — Live anchoring run on Sepolia, 9 November 2026
- `progress.md` — Progress
- `security-review.md` — Security review of the mobile app (OWASP MASVS v2)
- `signing-spec.md` — MineChain signing specification
- `signing-vectors.json`
- `testing-log.md` — Testing log

#### `docs/plans/`

- `admin-accounts-plan.md` — Admin accounts plan
- `anchoring-admin-plan.md` — Anchoring status and recovery — approved plan (12 Nov 2026)
- `anchoring-status-plan.md` — Anchoring status plan
- `app-endpoints-plan.md` — App endpoints: alerts, consignment view, account edit and delete — plan (15 Nov 2026)
- `bottom-navigation-suggestion.md` — Suggestion: a bottom navigation bar (Home and Account)
- `buyer-purchase-plan.md` — Buyer purchase plan
- `consignment-check-plan.md` — Consignment check plan
- `dashboard-plan.md` — Dashboard plan (FR-14)
- `design-integration-plan.md` — Design integration plan (theme only)
- `end-to-end-plan.md` — End-to-end test plan (shortened)
- `gps-zones-plan.md` — GPS zones plan
- `hardening-plan.md` — Hardening plan
- `miner-registration-plan.md` — Miner registration plan (Module 4)
- `mobile-foundation-plan.md` — Mobile foundation plan (Module 3)
- `officer-alerts-plan.md` — Officer alerts plan
- `reports-plan.md` — Reports plan
- `transporter-handoff-plan.md` — Transporter handoff plan

#### `mobile/`

- `.gitignore`
- `.metadata`
- `README.md` — mobile/
- `analysis_options.yaml` — This file configures the analyzer, which statically analyzes Dart code to check for errors, warnings, and lints.
- `pubspec.lock`
- `pubspec.yaml`

#### `mobile/android/`

- `.gitignore`
- `build.gradle.kts`
- `gradle.properties`
- `settings.gradle.kts`

#### `mobile/android/app/`

- `build.gradle.kts`

#### `mobile/android/app/src/debug/`

- `AndroidManifest.xml`

#### `mobile/android/app/src/main/`

- `AndroidManifest.xml`

#### `mobile/android/app/src/main/kotlin/io/github/kondwelanitembo/minechain/`

- `DeviceKeyPlugin.kt`
- `MainActivity.kt`

#### `mobile/android/app/src/main/res/drawable/`

- `ic_launcher_foreground.xml`
- `launch_background.xml`

#### `mobile/android/app/src/main/res/drawable-v21/`

- `launch_background.xml`

#### `mobile/android/app/src/main/res/mipmap-anydpi-v26/`

- `ic_launcher.xml`

#### `mobile/android/app/src/main/res/mipmap-hdpi/`

- `ic_launcher.png`

#### `mobile/android/app/src/main/res/mipmap-mdpi/`

- `ic_launcher.png`

#### `mobile/android/app/src/main/res/mipmap-xhdpi/`

- `ic_launcher.png`

#### `mobile/android/app/src/main/res/mipmap-xxhdpi/`

- `ic_launcher.png`

#### `mobile/android/app/src/main/res/mipmap-xxxhdpi/`

- `ic_launcher.png`

#### `mobile/android/app/src/main/res/values/`

- `ic_launcher_background.xml`
- `styles.xml`

#### `mobile/android/app/src/main/res/values-night/`

- `styles.xml`

#### `mobile/android/app/src/main/res/xml/`

- `backup_rules.xml`
- `data_extraction_rules.xml`

#### `mobile/android/app/src/profile/`

- `AndroidManifest.xml`

#### `mobile/android/gradle/wrapper/`

- `gradle-wrapper.properties`

#### `mobile/assets/certs/`

- `README.md` — Pinned root certificates
- `globalsign_ecc_root_r4.pem`
- `gts_root_r4.pem`
- `isrg_root_x1.pem`

#### `mobile/env/`

- `api.example.json`

#### `mobile/integration_test/`

- `db_encryption_test.dart` — Proof, on the phone, that the local database is really encrypted (decision Mobile (1): "Encryption is to be proven on the A57 by a test, not assumed").
- `device_key_test.dart` — The real Android Keystore, on the phone (plan M1).

#### `mobile/lib/`

- `main.dart` — The MineChain app, F8: the API address is checked at start-up and handed to the rest of the app through Riverpod (F3); the saved session is read at start-up (F6); go_router shows the splash, the…

#### `mobile/lib/core/`

- `clock.dart` — "What time is it?", as something that can be swapped.

#### `mobile/lib/core/brand/`

- `logo_geometry.dart` — The MineChain logo, a pick and a shovel crossed in an X, described as plain shapes (decision Mobile (36)).

#### `mobile/lib/core/config/`

- `app_config.dart` — The app's build-time settings: for now, only the API's address.
- `config_provider.dart` — Gives the checked settings to the rest of the app through Riverpod.

#### `mobile/lib/core/database/`

- `database_failure.dart` — Every way opening the encrypted local database can fail, as a small fixed set of types (plan M3).
- `database_key.dart` — The local database's key: 32 random bytes, made on the first open and kept in the secure store (decision Mobile (1)).
- `local_database.dart` — The app's encrypted local database (plan M3), and how work reaches it without freezing the screen.
- `local_settings.dart` — Small values kept between uses in the local database's `settings` table (plan §2), for example the last mineral chosen, so the registration screen can preselect it (plan Q5: "the mineral, skipped…
- `open_encrypted.dart` — Opening the database file with its key (decision Mobile (1), plan M3).
- `schema.dart` — The local database's tables (plan §2; schema version 2) and how a file is brought up to date.
- `sqlite_busy.dart` — Telling "the file is in use right now" apart from every other SQLite refusal.

#### `mobile/lib/core/errors/`

- `api_codes.dart` — The codes the API sends, copied from docs/api.md, as constants.
- `app_failure.dart` — Every way a request to the API can fail, as a small, fixed set of types (plan section 3.2).
- `failure_text.dart` — Turns an AppFailure into one plain sentence for the screen (plan section 3.2, step 3).
- `field_errors.dart` — Sorts a refusal's `details` by field, so a form can show each message under the field it is about (plan section 3.2: VALIDATION_FAILED and WEAK_PASSWORD keep their details).

#### `mobile/lib/core/network/`

- `api_client.dart` — The one place that talks HTTP to the MineChain API (plan sections 3.2, 4.3 and 5).
- `network_providers.dart` — Riverpod providers for the network layer.
- `pinned_http_client.dart` — The app's only way to make HTTPS connections: trusts three bundled root certificates and nothing else, and refuses anything below TLS 1.3 (plan sections 5.2-5.4; decisions Mobile (2) and…
- `pinned_roots.dart` — Loads the three pinned root certificates that are packed inside the app.
- `server_status.dart` — Whether the API is up, for display only (plan section 5.5).
- `session_events.dart` — A one-way signal from the network layer: "the server refused this user's session" (plan section 4.3).

#### `mobile/lib/core/riverpod/`

- `no_retry.dart` — Turns off Riverpod's automatic retry, everywhere in the app.

#### `mobile/lib/core/router/`

- `app_router.dart` — The app's navigation: which widget each path shows, and the redirect that keeps every user on the screens their sign-in state and role allow (plan section 4.1, decision Mobile (7)).
- `redirect.dart` — Which screen the user may be on, decided in ONE pure function (plan section 4.1, rules 1-5).
- `routes.dart` — Every screen's address ("path"), in one place (plan section 4.1).

#### `mobile/lib/core/storage/`

- `secure_store.dart` — A tiny key-value store for secrets (the login token today; the local database key in a later module), backed by flutter_secure_storage.

#### `mobile/lib/core/text/`

- `app_text.dart` — Every sentence and label the user sees, in one file.
- `text_width.dart` — Measuring text before it is drawn, for layouts that must choose by the real size of a word: the app bar's role pill, the home tiles' labels and the navigation bar's words.

#### `mobile/lib/core/theme/`

- `app_theme.dart` — The app's look: colours, text styles and button sizes, for light and dark mode, built from a copper seed colour with some pairs set by hand (decision Mobile (35); the design is by Mapalo Maseko).
- `sizes.dart` — Sizes used across the app, in one place, so every screen feels the same and a change (bigger tiles, more space) is made once.

#### `mobile/lib/core/widgets/`

- `action_tile.dart` — A big tile with an icon and a short word or two under it: the building block of every home screen.
- `app_navigation.dart` — The frame around the signed-in user's two places, Home and Account, with the navigation bar that moves between them (decision Mobile (37), from Mapalo Maseko's suggestion in…
- `busy_button.dart` — A form's main button that is disabled, with a small spinner and "Sending…", while its request runs, so it cannot be sent twice.
- `coming_soon.dart` — The short "Coming soon" message for buttons whose screens are not built yet.
- `field_errors_mixin.dart` — One way, shared by every form, to keep the sentences shown under fields ("Enter your username.", or a server detail such as "That username is already taken.") and to clear a field's sentence as…
- `form_message.dart` — A problem sentence under a form: "Wrong username or password.", "No internet connection.
- `form_page.dart` — The frame of a signed-out form page (register, activate): a top bar with a back arrow to the login screen, the server status, then the form, all scrolling.
- `home_scaffold.dart` — The shared layout of the five role home screens: a top bar with the title and an account button, then a grid of big tiles with the role's main action first.
- `mine_chain_logo.dart` — The MineChain logo (a pick and a shovel crossed) and the "brand block" that shows it with the name: below the tiles on every home, and on the splash and login screens (decision Mobile (36)).
- `password_field.dart` — A password text field with a show/hide button, for the forms that set a new password (register, activate).
- `pill_button.dart` — The button used on a copper notice ("Enter password", "Try again").
- `server_status_banner.dart` — A strip at the top of a screen saying what is happening with the server: waking up, not ready, or why it could not be reached (plan section 5.5).
- `status_line.dart` — An icon and a sentence, never colour alone (plan section 7): "Location found, 6 m", "Under review".

#### `mobile/lib/features/account/presentation/`

- `account_screen.dart` — The signed-in user's own account (plan section 4.1, /account): who is signed in on this phone, and Log out.

#### `mobile/lib/features/admin/data/`

- `admin_anchoring_api.dart` — The anchoring status endpoint, as docs/api.md ("Anchoring administration") documents it (anchoring status plan, T2): GET /admin/anchoring no query (any parameter is refused) 200 { worker, counts,…
- `admin_anchoring_repository.dart` — The administrator's anchoring status, on top of AdminAnchoringApi (anchoring status plan, T2).
- `admin_users_api.dart` — The admin account endpoints, as docs/api.md documents them.
- `admin_users_repository.dart` — The administrator's account actions, on top of AdminUsersApi.
- `admin_zones_api.dart` — The GPS zone endpoints, as docs/api.md ("GPS zone management (FR-11)") documents them (GPS zones plan, T1): GET /admin/zones?status=<active/inactive>&limit=<1-100>&offset=<0-10000> 200 { "zones":…
- `admin_zones_repository.dart` — The administrator's GPS zone actions, on top of AdminZonesApi (GPS zones plan, T1).

#### `mobile/lib/features/admin/domain/`

- `account_actions.dart` — Which actions the account page offers (admin accounts plan §3, T3): the server's table of "from which status", plus the two rules the app can see for itself (your own account; a key to reset).
- `account_request.dart` — A pending account request, as the administrator's list shows it.
- `admin_account.dart` — One account as the administrator's "Accounts" screens show it (admin accounts plan, T1), read from the API's "admin view of a user" (docs/api.md, "Admin account management"): id, username,…
- `anchoring_status.dart` — The anchoring status as the administrator's "Anchoring" screen shows it (anchoring status plan, T2), read from GET /admin/anchoring (docs/api.md, "Anchoring administration").
- `corner_input.dart` — A zone's corners as the administrator types them, or as the phone's GPS gives them (GPS zones plan §3, Q1 and Q3).
- `gps_zone.dart` — One licensed extraction zone as the administrator's "GPS zones" screens show it (GPS zones plan, T1), read from the API's zone view (docs/api.md, "GPS zone management (FR-11)", "The zone view"):…
- `zone_actions.dart` — Which actions a zone's page offers, by its status (GPS zones plan §3): / Status / Rename / Deactivate / Reactivate / / active / ✓ / ✓ / / / inactive / ✓ / / ✓ / The boundary and the licence number…

#### `mobile/lib/features/admin/presentation/`

- `account_page_controller.dart` — The state behind one account's page (admin accounts plan, T3–T5): the account, the action running now, and a new activation code to show once.
- `account_page_screen.dart` — One account's page (admin accounts plan §4.2 and §4.5, T3 and T4): who it is, its status and why, its device key, and the actions its status allows (account_actions.dart).
- `account_requests_controller.dart` — The state behind the "Account requests" screen (plan A1): the pending list, and approving or rejecting one request at a time.
- `account_requests_screen.dart` — "Account requests": the administrator's list of pending requests from miners, transporters and buyers, with Approve and Reject (plan A1, FR-12).
- `account_words.dart` — The small words and icons both "Accounts" pages build from an account (admin accounts plan, T2 and T3): the status in its three forms, the line that says why an account is where it is, and the…
- `accounts_list_controller.dart` — The state behind the administrator's "Accounts" list (admin accounts plan, T2): one list per status (Q2: "Active", "Suspended", "Invited", "Rejected", "Deleted"), fetched 20 at a time.
- `accounts_screen.dart` — "Accounts": the administrator's list of every account by status (admin accounts plan §4.1, T2; FR-10, Scope (3)).
- `activation_code_view.dart` — The activation code, shown once (admin accounts plan §4.4, T5): after "Create account" and after "New activation code".
- `admin_home_screen.dart` — The administrator's home (plan section 4.2).
- `anchoring_screen.dart` — "Anchoring": the administrator's read-only view of how steps are reaching the blockchain (anchoring status plan §3, T3; Scope (11)), from GET /admin/anchoring.
- `anchoring_status_controller.dart` — The anchoring status screen's state (anchoring status plan, T3): one read of GET /admin/anchoring when the screen opens, and again on the refresh button, pull-down and "Try again" (Q2: no timer,…
- `anchoring_words.dart` — The anchoring status in the screen's words (anchoring status plan, T3).
- `create_account_screen.dart` — "Create account" (admin accounts plan §4.3–4.4, T5; FR-10): a new officer or administrator account, then its activation code, shown once.
- `create_zone_controller.dart` — The state behind "Create zone" (GPS zones plan §4.3, T5): the corners so far, the GPS while "Add my location" looks for a fix, the send, and the server's messages put back on the field or corner…
- `create_zone_screen.dart` — "Create zone" (GPS zones plan §4.3, T5; FR-11): a name, an optional licence number, and the corners, added by standing at each one ("Add my location") or by typing them ("Type a corner"), with a…
- `reason_dialog.dart` — The administrator's "with a reason" dialog: Reject a request (A1), and Suspend, Reset device key and Delete an account (admin accounts plan, T4).
- `zone_page_controller.dart` — The state behind one zone's page (GPS zones plan, T3 and T4): the zone and the action running now.
- `zone_page_screen.dart` — One zone's page (GPS zones plan §4.2 and §4.4, T3 and T4): its name, licence number, status and dates, a sketch of its shape, its corners, and the actions its status allows (zone_actions.dart).
- `zone_shape_view.dart` — A sketch of a zone's shape (GPS zones plan §4.2 and §4.3, Q2): the corners joined in order and numbered, north up, on a plain background.
- `zone_words.dart` — The small words and icons the "GPS zones" pages build from a zone (GPS zones plan, T2 and T3).
- `zones_list_controller.dart` — The state behind the administrator's "GPS zones" list (GPS zones plan, T2): one list per status ("Active", "Inactive"), fetched 20 at a time.
- `zones_screen.dart` — "GPS zones": the administrator's list of licensed extraction zones (GPS zones plan §4.1, T2; FR-11, Scope (3) and (7)).

#### `mobile/lib/features/alerts/data/`

- `alerts_api.dart` — The four alert endpoints, as docs/api.md ("Alerts (FR-08)") documents them: GET /alerts?status=<open/reviewed/dismissed>&limit=<1-100>&offset=<0-10000> 200 { "alerts": [alert view, ...], "total",…
- `alerts_repository.dart` — The officer's alerts, on top of AlertsApi.

#### `mobile/lib/features/alerts/domain/`

- `alert.dart` — An anomaly alert, as the officer's alerts screens show it (officer alerts plan, T1), read from the API's "alert view" (docs/api.md, "Alerts (FR-08)"): id, type, severity, status, details,…

#### `mobile/lib/features/alerts/presentation/`

- `alert_detail_controller.dart` — The state behind one alert's page (officer alerts plan, T3) and its two decisions, "Confirm problem" and "Clear, no problem" (T4).
- `alert_detail_screen.dart` — One alert (officer alerts plan §4.2–4.3, T3 and T4): what the check found, the step, the consignment, the other alerts on it, and, while it is open, the two decisions.
- `alert_widgets.dart` — The pieces both alert pages use (officer alerts plan, T2 and T3): the card in the list, the info lines, the state message, and the small words built from an alert (its step, who recorded it, the…
- `alert_words.dart` — The plain words for an alert (officer alerts plan §4, T1): its heading, its severity, and "what the check found" as sentences built from `details`.
- `alerts_list_controller.dart` — The state behind the officer's alerts list (officer alerts plan, T2): one list per status (Q1: "Open", "Confirmed", "Cleared"), fetched 20 at a time.
- `alerts_screen.dart` — "Alerts": the regulatory officer's list of anomaly alerts (officer alerts plan §4.1, T2; FR-08, Scope (2)).

#### `mobile/lib/features/auth/data/`

- `auth_api.dart` — The auth endpoints Module 3 needs, as the API documents them (docs/api.md): POST /auth/login body { "username", "password" } 200 { "token", "tokenType": "Bearer", "expiresIn": <seconds, at most…
- `auth_repository.dart` — The rules for signing in, staying signed in, and signing out (plan section 6.2, decision Q2), on top of the API (AuthApi) and the saved session (SessionStore).
- `session_store.dart` — The saved session on the phone, so the user stays signed in after the app is closed (plan section 6.2).

#### `mobile/lib/features/auth/domain/`

- `auth_state.dart` — Where the app is with signing in (plan section 6.1, decision Q2).
- `user.dart` — A MineChain account, as the API describes it (docs/api.md, the `user` object in POST /auth/login and GET /auth/me): id, username, fullName, licenceNumber (or null), role, status, createdAt,…

#### `mobile/lib/features/auth/presentation/`

- `activate_screen.dart` — Activate an officer or administrator account (FR-10, plan section 4.1, activate).
- `auth_controller.dart` — The app's sign-in state, and the only way to change it (plan sections 4.3, 6.1-6.3; decision Q2).
- `home_header.dart` — What every role's home shows above its tiles: the server status (F5) and, while the token has expired, a notice that the password will be asked for.
- `licence_number_formatter.dart` — The licence number's shape while it is typed: ZM-ABC-1234 (agreed for the prototype): two letters, a dash, three letters, a dash, four digits.
- `login_screen.dart` — The login screen (plan sections 4.1, 5.5 and 6).
- `password_prompt.dart` — "Enter your password": the dialog shown when the token has expired and the user is still signed in (decision Q2).
- `register_screen.dart` — Request an account (FR-12, plan section 4.1, /register).
- `session_expiry_watcher.dart` — Checks whether the token has run out each time the app comes back to the screen (plan section 6.2, decision Q2).
- `splash_screen.dart` — Shown for the moment it takes to read the saved session at start-up.

#### `mobile/lib/features/buyer/presentation/`

- `buyer_home_screen.dart` — The buyer's home (plan section 4.2).

#### `mobile/lib/features/consignments/presentation/`

- `my_consignments_provider.dart` — What "My consignments" and "My handoffs" list (plan M7, Scope (8), decision Mobile (34); by step type since Transporter handoff T5): the signed-in user's steps of one type on this phone, newest…
- `my_consignments_screen.dart` — "My consignments" (plan M7): the miner's own registrations on this phone, newest first, each with its state in words and an icon, never colour alone (decision Mobile (34)).

#### `mobile/lib/features/dashboard/data/`

- `dashboard_api.dart` — The officer's dashboard endpoint, as docs/api.md ("GET /dashboard") documents it (dashboard plan, T3): GET /dashboard?from=YYYY-MM-DD&to=YYYY-MM-DD[&mineral=gold] 200 { period, mineral, now,…
- `dashboard_repository.dart` — The officer's dashboard, on top of DashboardApi (dashboard plan, T3).

#### `mobile/lib/features/dashboard/domain/`

- `dashboard_period.dart` — The dashboard's three periods (dashboard plan, Q4 A): the last 7 days, 30 days or 12 months, each ending today in UTC, as UTC days for GET /dashboard (docs/api.md, "GET /dashboard").
- `dashboard_summary.dart` — The officer's dashboard (FR-14; dashboard plan, T3) as read from GET /dashboard (docs/api.md, "GET /dashboard"): counts only.

#### `mobile/lib/features/dashboard/presentation/`

- `dashboard_controller.dart` — The dashboard screen's state (dashboard plan, T4): one read of GET /dashboard when the screen opens, and again when the officer picks another period or mineral, pulls down, taps refresh or "Try…
- `dashboard_screen.dart` — "Dashboard": the regulatory officer's view of the supply chain (FR-14; dashboard plan §5, T4), from GET /dashboard.
- `dashboard_widgets.dart` — The dashboard's building blocks (dashboard plan, T4, Q3 A): plain Flutter boxes in the theme's colours, no chart package.
- `dashboard_words.dart` — The dashboard's words for its choices and rows (dashboard plan, T4).

#### `mobile/lib/features/device_key/data/`

- `device_key_api.dart` — PUT /auth/me/public-key, as docs/api.md documents it: Login needed: miner, transporter or buyer.
- `device_key_channel.dart` — The Dart end of the "minechain/device_key" platform channel (plan M1, decision Mobile (4)).

#### `mobile/lib/features/device_key/domain/`

- `key_alias.dart` — The Keystore name ("alias") of a user's signing key (decision Mobile (17)).
- `key_fingerprint.dart` — The name the server gives a device key (signing spec, section 2): "the lower-case hex SHA-256 of its SPKI DER bytes, 64 characters".

#### `mobile/lib/features/device_key/presentation/`

- `device_key_controller.dart` — Registers this phone's signing key for the signed-in user (plan M2 and §4, decision Mobile (17)).
- `device_key_notice.dart` — The home's warning when this phone may not sign (plan M2 and §4): "This phone is not your registered phone.

#### `mobile/lib/features/handoff/data/`

- `record_handoff.dart` — Saving a handoff on the phone (Transporter handoff T2): the transporter takes custody of a bag and signs their own weight, place and time.

#### `mobile/lib/features/handoff/domain/`

- `custody_check.dart` — What "Take custody" knows about a bag after the scan (transporter handoff plan, Q1 and Q2), and the warnings that follow from it.
- `handoff_payload.dart` — The handoff payload, version 1 (signing spec, section 3): the eight lines of steps/domain/later_step_payload.dart under `minechain-step/1/handoff`.

#### `mobile/lib/features/handoff/presentation/`

- `custody_controller.dart` — The state behind "Take custody" (transporter handoff plan, T3): scan the bag's custody record, refuse a second handoff of it by this account on this phone (Q4), ask the server what it knows (Q1,…
- `take_custody_screen.dart` — "Take custody" (transporter handoff plan, FR-01, FR-02, FR-07): the transporter scans the bag's custody record, sees what the server knows about it (or that it could not be checked), weighs it on…

#### `mobile/lib/features/miner/presentation/`

- `miner_home_screen.dart` — The miner's home (plan section 4.2).

#### `mobile/lib/features/officer/presentation/`

- `officer_home_screen.dart` — The regulatory officer's home (plan section 4.2).

#### `mobile/lib/features/purchase/data/`

- `record_purchase.dart` — Saving a purchase on the phone (buyer purchase plan T1): the licensed buyer signs their own weight, place and time for a bag they are buying.

#### `mobile/lib/features/purchase/domain/`

- `purchase_payload.dart` — The purchase payload, version 1 (signing spec, section 3): the eight lines of steps/domain/later_step_payload.dart under `minechain-step/1/purchase` (buyer purchase plan T1).

#### `mobile/lib/features/registration/data/`

- `location_source.dart` — Where GPS readings come from, behind a small interface so widget tests can put a fake in its place and the geolocator plugin never loads there.
- `register_consignment.dart` — Saving a registration on the phone (plan M4).

#### `mobile/lib/features/registration/domain/`

- `custody_record.dart` — What a scanned QR code must look like to count as a MineChain custody record (decision Mobile, custody record IDs).
- `gps_fix.dart` — The GPS policy (plan §5, Q3 approved 17 Nov 2026): which readings may be signed as the place of extraction.
- `mineral.dart` — The minerals a consignment can be (api.md and the signing spec: "`gold`, `copper`, `cobalt`, `manganese`, `emerald` or `amethyst`"), and the unit the miner types the weight in (plan, Q2, approved…
- `payload_format.dart` — The value rules of the signed payload, version 1 (signing spec, sections 3 and 4), on the phone's side.
- `registration_payload.dart` — The registration payload, version 1 (signing spec, section 3): exactly nine `key=value` lines, in this order, each ending with LF, the last one included.
- `weight.dart` — The typed weight, turned into whole milligrams for the payload (plan M4, Q2) exactly, through the text and whole numbers only.

#### `mobile/lib/features/registration/presentation/`

- `mineral_chips.dart` — The six mineral chips, shared by "Register consignment" and, when the server could not say, "Take custody" (transporter handoff plan, Q1).
- `mineral_text.dart` — The words for a mineral and its unit, shared by the registration screen and "My consignments", so a mineral is named the same everywhere.
- `qr_scanner_view.dart` — The camera view that reads the custody record's QR code (plan §6), behind a small builder function so widget tests can put a fake in its place and the camera plugin never loads there.
- `register_consignment_screen.dart` — "Register consignment" (plan M5, FR-01): scan the custody record, wait for a real GPS fix, choose the mineral, type the weight, Save.
- `registration_controller.dart` — The state behind the registration screen (plan M5, §5, §6): the scanned code, the GPS fix as it improves, the mineral, the typed weight, and the save.

#### `mobile/lib/features/reports/data/`

- `report_file_store.dart` — Where a downloaded report is kept (reports plan, T1, Q5): one folder, `reports/`, inside the app's private cache, holding at most one file.
- `report_sharer.dart` — Hands a saved report to Android's share sheet (reports plan, T2, Q1): Drive, Gmail, WhatsApp, the phone's own "save" targets, whatever is installed.
- `reports_api.dart` — The two report endpoints, as docs/api.md ("Reports (FR-09, FR-13)") documents them: GET /reports/transactions?from&to[&mineral&type&reviewStatus&anchorStatus] officer, buyer (own purchases only)…
- `reports_repository.dart` — Report downloads, on top of ReportsApi and ReportFileStore (reports plan, T1): download, choose a safe name, write the file, count its rows.

#### `mobile/lib/features/reports/domain/`

- `csv_records.dart` — How many rows a downloaded report has (reports plan, T1), for the line "142 rows" under the file.
- `report_request.dart` — What a report download asks the server for (reports plan, T1): the path, the query, and the name to save the file under if the server's name is not usable.
- `saved_report.dart` — A report the phone has downloaded and written to its private cache (reports plan, T1), and the rule for the name it is written under.

#### `mobile/lib/features/reports/presentation/`

- `audit_trail_panel.dart` — The officer's two audit trails (reports plan, T4, Q2; FR-13): - ConsignmentTrailPanel, on "Check a consignment"'s result: the whole history of the consignment just checked; - PersonTrailPanel, on…
- `report_download_controller.dart` — One report download and its share (reports plan, T3; used again by T4): download → write the file → open the share sheet.
- `report_widgets.dart` — The pieces every report download shows (reports plan, T3 and T4): the period buttons, the filter chips, and the card under the button that says how the download and its share went.
- `reports_screen.dart` — "Reports" (reports plan, T3, §4.1): the transactions report (FR-09) for the officer, the buyer and the administrator, at /officer/reports, buyer/reports and /admin/reports.

#### `mobile/lib/features/steps/data/`

- `local_steps_repository.dart` — The phone's saved custody steps (plan M3 and §2), on the local database.
- `save_signed_step.dart` — Saving any custody step on the phone (plan M4, shared since Transporter handoff T2): build the payload once, sign it with the device key, store it with its signature, and only then say "saved".

#### `mobile/lib/features/steps/domain/`

- `consignment_list_item.dart` — One row of "My consignments" (plan M7, decision Mobile (34)): only what the list shows, read by its own query, so the payload, signature, key fingerprint and coordinates never leave the database's…
- `later_step_payload.dart` — The payload of a step that follows the registration, version 1 (signing spec, section 3): a handoff or a purchase.
- `local_step.dart` — A custody step as this phone keeps it (plan §2, table local_steps).

#### `mobile/lib/features/steps/presentation/`

- `location_status_view.dart` — What the GPS is doing, in words, with the one button that can help (registration plan M5, §5; shared since Transporter handoff T4): "Finding your location… 40 m", "Location is off" with "Turn on…
- `location_tracker.dart` — The GPS part of every screen that signs a custody step (registration plan M5, §5; shared since Transporter handoff T4): ask for access, follow the readings, apply the fix policy, and say in one…
- `saved_view.dart` — What a screen that signs a custody step shows after Save (registration plan M5; shared since Transporter handoff T4): the committed "Saved on this phone", the way on to the next bag, and home.
- `saved_work_gate.dart` — The two gates in front of every screen that signs a custody step (registration plan §4; shared since Transporter handoff T3): the encrypted database must open, and this phone must be allowed to sign.
- `weight_field.dart` — The weight field of every screen that signs a custody step (registration plan M5; shared since Transporter handoff T4).

#### `mobile/lib/features/sync/data/`

- `sync_api.dart` — POST /sync/steps (api.md): one batch of saved steps, exactly as they were signed.
- `sync_service.dart` — Sends the saved steps to the server (plan M6 and §3; FR-03, FR-07).

#### `mobile/lib/features/sync/domain/`

- `sync_report.dart` — What one sync run came to, for the "Send my work" screen.
- `sync_rules.dart` — The rules for reading the server's sync answers (plan §3, api.md "POST /sync/steps").

#### `mobile/lib/features/sync/presentation/`

- `send_work_screen.dart` — "Send my work" (plan M6): what is waiting on this phone, a Send button, the progress of a send, and what the sends came to.
- `sync_on_resume.dart` — Starts an automatic send each time the app comes back to the front (plan Q4), like SessionExpiryWatcher does for the token's expiry.

#### `mobile/lib/features/transporter/presentation/`

- `transporter_home_screen.dart` — The transporter's home (plan section 4.2).

#### `mobile/lib/features/verification/data/`

- `consignment_check_api.dart` — The one endpoint the consignment check needs, as docs/api.md documents it: GET /consignments/by-qr/{qrCode} 200 { "consignment": {...}, "steps": [...] }, cut down per role transporter, buyer or…
- `consignment_check_repository.dart` — The consignment check, on top of ConsignmentCheckApi.

#### `mobile/lib/features/verification/domain/`

- `consignment_view.dart` — What GET /consignments/by-qr/{qrCode} answers (docs/api.md), as Dart values: one consignment, its custody steps in order, and the server's live chain check of each step (Scope (9), Verification…
- `verdict.dart` — The one-line answer at the top of a consignment check: can this record be trusted? (plan section 4).

#### `mobile/lib/features/verification/presentation/`

- `check_result_view.dart` — The answer to "Check a consignment" (consignment check plan §4, T4): the verdict banner, the consignment, then one card per custody step in the order the server sent them.
- `consignment_check_controller.dart` — The state behind "Check a consignment" (consignment check plan, T3): scan a custody record, ask the server, show the answer.
- `consignment_check_screen.dart` — "Check a consignment" (consignment check plan): one screen for the transporter, the buyer and the officer, at /transporter/check, buyer/check and /officer/check (Q3).

#### `mobile/test/`

- `flutter_test_config.dart` — Settings for every test under test/. `flutter test` finds this file by its name and runs testExecutable around each test file's main().
- `widget_test.dart` — The app as main() starts it: the checked settings, both themes and the router; and the error app for a build with no address.

#### `mobile/test/core/brand/`

- `launcher_icon_test.dart` — The launcher icon (plan T7) cannot drift from the app's logo: the committed foreground must be exactly what tool/make_launcher_icon.dart writes from logo_geometry.dart today, like the backend's…
- `logo_geometry_test.dart` — The logo's shapes: well formed, and every point inside Android's safe zone, so a round launcher-icon mask (T7) never cuts the pick or the shovel.

#### `mobile/test/core/config/`

- `app_config_test.dart` — AppConfig.check with plain strings, so no --dart-define is needed.

#### `mobile/test/core/database/`

- `database_key_test.dart` — The database key: made once, kept, never replaced behind the user's back.
- `schema_test.dart` — Schema versions 1 (plan §2) and 2 (Transporter handoff T2) and migrations, on an in-memory database on the laptop.
- `sqlite_busy_test.dart` — "Busy" told apart from every other SQLite refusal, on real SQLite: two connections to one file in a temporary folder, the first holding an exclusive lock, the second (no busy timeout) refused at once.

#### `mobile/test/core/errors/`

- `api_codes_test.dart` — Keeps lib/core/errors/api_codes.dart and docs/api.md in step.
- `app_failure_test.dart` — toString() is what ends up in logs and crash reports, so it must carry only what is safe: status, code, counts.
- `failure_text_test.dart`
- `field_errors_test.dart`

#### `mobile/test/core/network/`

- `api_client_file_test.dart` — ApiClient.getFile (reports plan, T1): a file answer instead of JSON, with the same refusals and session events as every other call.
- `api_client_test.dart` — ApiClient against a pretend server: MockClient answers each request with whatever the test says, so there is no network and no waiting.
- `pinned_http_client_test.dart` — The pinned TLS setup, with no network: the bundled roots load, build a TLS 1.3-only context, and are the files that were verified; bad input fails loudly.
- `server_status_test.dart` — ServerStatusController with a pretend server and pretend time.

#### `mobile/test/core/riverpod/`

- `no_retry_test.dart` — Proves that noRetry really stops Riverpod from running a failed provider again, and that the test itself could see a retry if one happened.

#### `mobile/test/core/router/`

- `app_router_test.dart` — The real router, wired to a stand-in auth controller: the redirect really moves users to the right screen.
- `navigation_shell_test.dart` — T11 (Mobile (37)): the frame with the navigation bar around the homes and "My account", in the real app and router with a stand-in auth controller.
- `redirect_test.dart` — The redirect rules as a table: every sign-in state, every kind of path, all five roles.

#### `mobile/test/core/theme/`

- `app_theme_test.dart` — Checks the WCAG AA contrast (at least 4.5:1) of the colour pairs the app draws text with, in both themes, using the colours the theme really builds (some come from the seed, the copper and patina…

#### `mobile/test/core/widgets/`

- `action_tile_test.dart`
- `home_scaffold_test.dart` — The home layout on a 5-inch phone (about 360 x 640 dp), turned both ways, at normal and very large text.
- `mine_chain_logo_test.dart` — The logo is painted in the theme's copper in both themes, hidden from TalkBack (the name beside it is read instead), and sized as asked.
- `server_status_banner_test.dart` — The banner in each state, with a stand-in controller that holds a fixed state and counts "Try again" taps.

#### `mobile/test/fakes/`

- `android_back.dart` — TEST ONLY: Android's back button, sent the way the system sends it.
- `app_harness.dart` — TEST ONLY: the whole app (real router, real screens) with a stand-in auth controller and server status, at a chosen screen size and text scale.
- `auth_fixtures.dart` — TEST ONLY: sample accounts and API answers, with the fake values api.md uses (ids like 3f2b6c1e-0000-4000-8000-000000000001, tokens containing FAKE).
- `fake_accounts_server.dart` — TEST ONLY: a stand-in for the "Accounts" endpoints (admin accounts plan, T1; docs/api.md "Admin account management") behind package http's MockClient.
- `fake_admin_server.dart` — TEST ONLY: a stand-in for the three admin endpoints the "Account requests" screen uses (docs/api.md), behind package http's MockClient.
- `fake_alerts_server.dart` — TEST ONLY: a stand-in for the four alert endpoints (docs/api.md, "Alerts (FR-08)"), behind package http's MockClient.
- `fake_anchoring_server.dart` — TEST ONLY: a stand-in for GET /admin/anchoring (anchoring status plan, T2; docs/api.md "Anchoring administration") behind package http's MockClient.
- `fake_check_server.dart` — TEST ONLY: a stand-in for GET /consignments/by-qr/{qrCode} (docs/api.md), behind package http's MockClient.
- `fake_controllers.dart` — TEST ONLY: stand-ins for the auth and server-status controllers, so screen and router tests need no network, no secure storage and no timers.
- `fake_dashboard_server.dart` — TEST ONLY: a stand-in for GET /dashboard (dashboard plan, T3; docs/api.md "GET /dashboard") behind package http's MockClient.
- `fake_device_key_channel.dart` — TEST ONLY: a stand-in for the Keystore channel.
- `fake_registration.dart` — TEST ONLY: stand-ins for the registration screen's plugins and save, so the camera, the GPS and the Keystore never load in widget tests.
- `fake_report_files.dart` — TEST ONLY: stand-ins for the phone's side of a report (reports plan, T2 and T3): the file store and the share sheet.
- `fake_reports_server.dart` — TEST ONLY: a stand-in for the two report endpoints (reports plan, T1; docs/api.md "Reports (FR-09, FR-13)") behind package http's MockClient.
- `fake_secure_store.dart` — TEST ONLY: an in-memory SecureStore, so tests never touch the phone's Keystore.
- `fake_sync_server.dart` — TEST ONLY: a stand-in for POST /sync/steps (docs/api.md), behind package http's MockClient, plus waiting steps to send.
- `fake_zones_server.dart` — TEST ONLY: a stand-in for the GPS zone endpoints (GPS zones plan, T1; docs/api.md "GPS zone management (FR-11)") behind package http's MockClient.
- `flaky_database.dart` — A LocalDatabase that fails chosen calls, for the "phone was busy" tests.
- `signing_channel.dart` — The Keystore for save tests: "signs" by recording the bytes and returning a fixed DER signature, or refuses with [refuse]. Shared from buyer purchase T1 on; the older handoff and registration…
- `word_breaks.dart` — Finds where a drawn paragraph breaks a line inside a word ("My consig nments"), for the T9 rule that a tile label only wraps between words.

#### `mobile/test/features/`

- `homes_test.dart` — The five homes: their tiles, the main tile first, the expired-password notice, and no overflow on a small screen, turned, or at large text.

#### `mobile/test/features/account/presentation/`

- `account_screen_test.dart` — The account screen and the password prompt, inside the real app and router with a stand-in auth controller: what is shown, that Log out asks first, that the router follows the sign-in state, and…

#### `mobile/test/features/admin/data/`

- `admin_accounts_repository_test.dart` — The "Accounts" calls of AdminUsersApi and AdminUsersRepository against the fake accounts server (admin accounts plan, T1): what is sent (path, query, token, exact body), and what each answer becomes.
- `admin_anchoring_repository_test.dart` — AdminAnchoringApi and AdminAnchoringRepository against the fake anchoring server (anchoring status plan, T2): what is sent, and what each answer becomes.
- `admin_users_repository_test.dart` — AdminUsersApi and AdminUsersRepository against the fake server: what is sent (path, query, token, body), and what each answer becomes.
- `admin_zones_repository_test.dart` — AdminZonesApi and AdminZonesRepository against the fake zones server (GPS zones plan, T1): what is sent (path, query, token, exact body bytes), and what each answer becomes.

#### `mobile/test/features/admin/domain/`

- `account_actions_test.dart` — actionsFor (admin accounts plan §3, T3): exactly the actions each status allows, in the page's order, with the two rules the app can see itself.
- `account_request_test.dart`
- `admin_account_test.dart` — AdminAccount, ActivationCode and InvitedAccount read from api.md's examples (admin accounts plan, T1).
- `anchoring_status_test.dart` — AnchoringStatus.fromJson (anchoring status plan, T2): api.md's example read in full, every state and outcome in words the screen can use, the nulls the docs allow, and any answer that is not the…
- `corner_input_test.dart` — Typed and GPS corners (GPS zones plan, T1, Q1 and Q3): what is taken, what is refused and why, how a corner is shown, and which corner a server field path names.
- `gps_zone_test.dart` — GpsZone, its page and the deactivation warning read from api.md's examples (GPS zones plan, T1): every field, both statuses, no licence number, and anything unreadable refused rather than guessed.
- `zone_actions_test.dart` — Which buttons a zone's page shows, by status (GPS zones plan §3, T3).

#### `mobile/test/features/admin/presentation/`

- `account_page_actions_test.dart` — The five actions on an account's page (admin accounts plan §4.5, T4): suspend, reset device key, reactivate, delete and edit name.
- `account_page_helpers.dart` — TEST ONLY: shared steps for the "Accounts" page tests (admin accounts plan, T2–T5): open the list as an administrator the way a user does (the "Accounts" tile), pick a status, open one account…
- `account_page_screen_test.dart` — One account's page inside the real app and router, opened from its card (admin accounts plan, T3): every line for each status, exactly the buttons the status allows, your own account, the device…
- `account_requests_controller_test.dart` — AccountRequestsController with the real repository and ApiClient, talking to the fake server.
- `account_requests_screen_test.dart` — The "Account requests" screen inside the real app and router, with the fake server behind the real repository and ApiClient: each state, approve, reject, refresh, and fitting small screens and…
- `accounts_screen_test.dart` — The "Accounts" list inside the real app and router, with the fake accounts server behind the real repository and ApiClient (admin accounts plan, T2): the five lists, every card line, paging,…
- `anchoring_screen_test.dart` — The "Anchoring" status screen inside the real app and router, with the fake anchoring server behind the real repository and ApiClient (anchoring status plan, T3): every section, every worker…
- `anchoring_words_test.dart` — The anchoring status in words (anchoring status plan, T3): lengths of time, step names, the state's tone, and the singular and plural lines.
- `create_account_screen_test.dart` — "Create account" and the activation code, shown once (admin accounts plan §4.3–4.4, T5), inside the real app and router against the fake accounts server; and "New activation code" on an invited…
- `create_zone_screen_test.dart` — "Create zone" inside the real app and router (GPS zones plan §4.3, T5): typed corners and their problems, "Add my location" with the fix policy, the live sketch, the exact body sent, the server's…
- `zone_page_actions_test.dart` — The three actions on a zone's page (GPS zones plan §4.4, T4): rename, deactivate (with the last-zone pre-warning and the server's warning, Q4) and reactivate.
- `zone_page_helpers.dart` — TEST ONLY: shared steps for the "GPS zones" page tests (GPS zones plan, T2–T5): open the list as an administrator the way a user does (the "GPS zones" tile), pick a status, open one zone from its…
- `zone_page_screen_test.dart` — One zone's page inside the real app and router (GPS zones plan, T3): every line, the sketch, the corners in the server's order, the fixed-boundary line, the buttons by status, a page opened…
- `zones_screen_test.dart` — The "GPS zones" list inside the real app and router, with the fake zones server behind the real repository and ApiClient (GPS zones plan, T2): the two lists, every card line, the no-active-zone…

#### `mobile/test/features/alerts/data/`

- `alerts_repository_test.dart` — AlertsApi and AlertsRepository against the fake server: what is sent (path, query, token, body), and what each answer becomes (officer alerts plan, T1).

#### `mobile/test/features/alerts/domain/`

- `alert_test.dart` — Alert.fromJson and its parts: api.md's examples read as they are, and anything unreadable gives null (officer alerts plan, T1).

#### `mobile/test/features/alerts/presentation/`

- `alert_decision_test.dart` — "Confirm problem" and "Clear, no problem" inside the real app and router, with the fake server behind the real repository and ApiClient (officer alerts plan §4.3, T4): the notes rules, exactly…
- `alert_detail_screen_test.dart` — One alert's page inside the real app and router, with the fake server behind the real repository and ApiClient (officer alerts plan, T3): every section for open and closed alerts, the other alerts…
- `alert_page_helpers.dart` — TEST ONLY: shared steps for the alert page and decision tests (officer alerts plan, T3 and T4): open the list as an officer, open one alert the way an officer does (a tap on its card), and find…
- `alert_words_test.dart` — The words for each alert type (officer alerts plan §4, T1): headings, severities and the sentences from `details`, with weights in the mineral's unit worked out from milligram text.
- `alerts_screen_test.dart` — The officer's "Alerts" list inside the real app and router, with the fake server behind the real repository and ApiClient (officer alerts plan, T2): the cards, the three lists (Q1), paging,…

#### `mobile/test/features/auth/data/`

- `session_store_test.dart`

#### `mobile/test/features/auth/domain/`

- `user_test.dart`

#### `mobile/test/features/auth/presentation/`

- `activate_screen_test.dart` — The activate screen inside the real app and router, with a stand-in auth controller: checks before sending, what is sent, the router moving to the home on success, the plain sentence for a bad…
- `auth_controller_test.dart` — AuthController and AuthRepository together, against a pretend server (MockClient), an in-memory secure store and a fixed clock.
- `licence_number_formatter_test.dart` — The licence number formatter on its own: plain values in, plain values out.
- `login_screen_test.dart` — The login screen with a stand-in auth controller: what is sent, what is shown, and that it fits small screens and large text.
- `register_screen_test.dart` — The register screen inside the real app and router, with a stand-in auth controller: what is checked before sending, what is sent, where each server answer is shown, the confirmation, the way…
- `session_expiry_watcher_test.dart` — The resume hook: coming back to the app asks AuthController.checkExpiry(), and the hook is really in place around the whole app.

#### `mobile/test/features/consignments/presentation/`

- `my_consignments_screen_test.dart` — "My consignments" inside the real app and router, with the real repository on an in-memory database, the real sync service, and a fake server behind MockClient (plan M7, decision Mobile (34)).
- `my_handoffs_screen_test.dart` — "My handoffs" and the transporter's "Send my work" (transporter handoff T5), inside the real app and router, with the real repository on an in-memory database, the real sync service and a fake server.
- `my_purchases_screen_test.dart` — "My purchases" and the buyer's "Send my work" (buyer purchase T3), inside the real app and router, with the real repository on an in-memory database, the real sync service and a fake server.

#### `mobile/test/features/dashboard/data/`

- `dashboard_repository_test.dart` — DashboardApi and DashboardRepository against the fake dashboard server (dashboard plan, T3): what is sent, and what each answer becomes.

#### `mobile/test/features/dashboard/domain/`

- `dashboard_period_test.dart` — The dashboard's periods as UTC days (dashboard plan, T3, Q4).
- `dashboard_summary_test.dart` — Reading GET /dashboard's answer strictly (dashboard plan, T3), and grouping its days into weeks.

#### `mobile/test/features/dashboard/presentation/`

- `dashboard_screen_test.dart` — The officer's "Dashboard" inside the real app and router, with the fake dashboard server behind the real repository and ApiClient (dashboard plan, T4): every section, the period and mineral chips,…

#### `mobile/test/features/device_key/data/`

- `device_key_channel_test.dart` — Tests the Dart wrapper only.

#### `mobile/test/features/device_key/domain/`

- `key_alias_test.dart`
- `key_fingerprint_test.dart` — The fingerprint must be exactly the server's: lower-case hex SHA-256 of the 91 SPKI bytes (signing spec, section 2).

#### `mobile/test/features/device_key/presentation/`

- `device_key_controller_test.dart` — DeviceKeyController: every row of the plan's §4 table and every PUT answer, with a fake Keystore channel, the real ApiClient on a MockClient, and a fake secure store under the real SessionStore.
- `device_key_display_test.dart` — What the device key state looks like on screen: the "Device key" row on My account (signing roles only), and the miner home's notice when this phone may not sign.

#### `mobile/test/features/handoff/data/`

- `record_handoff_test.dart` — RecordHandoff.save with a fake Keystore channel that "signs" by recording the bytes, and the real repository on an in-memory database (the same schema as the phone, no cipher).

#### `mobile/test/features/handoff/domain/`

- `handoff_payload_test.dart` — The handoff payload against docs/signing-spec.md (section 3's handoff example) and docs/signing-vectors.json, byte for byte.

#### `mobile/test/features/handoff/presentation/`

- `take_custody_screen_test.dart` — "Take custody". T3: the way in, the scan with the custody record rule, Q4's refusal, the optional check (Q1) and its warnings (Q2), and the mineral. T4: the GPS (started only after a code is…

#### `mobile/test/features/purchase/data/`

- `record_purchase_test.dart` — RecordPurchase.save with a fake Keystore that "signs" by recording the bytes, and the real repository on an in-memory database (the phone's schema, no cipher).

#### `mobile/test/features/purchase/domain/`

- `purchase_payload_test.dart` — The purchase payload against docs/signing-vectors.json, byte for byte.

#### `mobile/test/features/purchase/presentation/`

- `record_purchase_screen_test.dart` — "Record purchase" (buyer purchase plan, T2): the "Take custody" page with kind: purchase, opened from the buyer's home.

#### `mobile/test/features/registration/data/`

- `register_consignment_test.dart` — RegisterConsignment.save with a fake Keystore channel that "signs" by recording the bytes, and the real repository on an in-memory database.

#### `mobile/test/features/registration/domain/`

- `custody_record_test.dart` — The custody record ID format: MC-<4 digits>-<3 capitals>-<4 digits>, checked exactly as scanned.
- `gps_fix_test.dart` — The GPS policy (plan §5, Q3): 25 m, not mocked, fresh within 30 s.
- `payload_format_test.dart` — The value rules (signing spec, sections 3 and 4), including every example the spec gives for the two formatters.
- `registration_payload_test.dart` — The registration payload against docs/signing-vectors.json, byte for byte: the positive vector is built exactly, and no negative vector can ever be produced.
- `weight_test.dart` — The typed weight to whole milligrams, exactly (plan Q2: the unit follows the mineral).

#### `mobile/test/features/registration/presentation/`

- `register_consignment_screen_test.dart` — The registration screen inside the real app and router, with a fake camera, a fake GPS, a fake save, and the real repository and settings on an in-memory database.

#### `mobile/test/features/reports/data/`

- `reports_repository_test.dart` — Downloading a report to the phone (reports plan, T1): the fake server, the real ApiClient and a real file store in a temporary folder.

#### `mobile/test/features/reports/domain/`

- `csv_records_test.dart` — Counting a report's rows (reports plan, T1).
- `report_request_test.dart` — The report requests and the period rule (reports plan, T1).
- `saved_report_test.dart` — The names a report is written under (reports plan, T1).

#### `mobile/test/features/reports/presentation/`

- `audit_trail_test.dart` — The officer's audit trails (reports plan, T4, §4.2–4.3): one consignment from "Check a consignment"'s result, one person from an alert's page.
- `report_download_controller_test.dart` — The download-then-share controller (reports plan, T2 and T3), without screens: the fake server, the real repository, the fake store and share sheet.
- `reports_screen_test.dart` — "Reports" (reports plan, T3, §4.1): the transactions report for the officer, the buyer and the administrator, through the whole app (real router, real screens) with the fake server, store and…

#### `mobile/test/features/steps/data/`

- `local_steps_repository_test.dart` — LocalStepsRepository on an in-memory database (same schema, no cipher).

#### `mobile/test/features/steps/domain/`

- `consignment_list_item_test.dart` — A record's status on "My consignments": the same rules as the counts on "Send my work" (Mobile (34)).

#### `mobile/test/features/sync/data/`

- `sync_service_test.dart` — SyncService (plan M6, §3): the real service, repository and ApiClient, with an in-memory database, a fake server behind MockClient, a fixed clock, a stand-in auth controller and a fixed device key…

#### `mobile/test/features/sync/domain/`

- `sync_rules_test.dart` — Reading one sync result, and the backoff (plan §3).

#### `mobile/test/features/sync/presentation/`

- `send_work_screen_test.dart` — "Send my work" inside the real app and router, with the real sync service and repository on an in-memory database, and a fake server behind MockClient.

#### `mobile/test/features/verification/data/`

- `consignment_check_repository_test.dart` — ConsignmentCheckApi and ConsignmentCheckRepository against the fake server: what is sent (path, token, method, no body), and what each answer becomes.

#### `mobile/test/features/verification/domain/`

- `consignment_view_test.dart` — ConsignmentView.fromJson against docs/api.md, "GET /consignments/by-qr": the example body, each viewer's field set from "What each viewer sees", absent vs null, and the strict refusals.
- `verdict_test.dart` — verdictFor: each verdict, and that the worst one wins (plan section 4).

#### `mobile/test/features/verification/presentation/`

- `check_page_helpers.dart` — TEST ONLY: shared by the result page tests (T4, T5).
- `check_result_roles_test.dart` — "Check a consignment", T5: what each viewer sees on the result page.
- `check_result_view_test.dart` — "Check a consignment", T4: the result page (plan §4).
- `consignment_check_screen_test.dart` — "Check a consignment", T3: the way in from each home, the scan step, and every way a check can end; the result page itself is in check_result_view_test.dart.

#### `mobile/tool/`

- `check_tls.dart` — Manual check of the app's TLS settings against real servers (plan section 9.2).
- `make_launcher_icon.dart` — Writes the launcher icon's foreground (plan T7.a), an Android vector drawable, from the same shapes that draw the logo in the app.
