# CLAUDE.md

Guidance for Claude Code in this repository. This file is public, so keep it free of
secrets, personal details and text copied from private documents.

## Project summary

MineChain is a final-year BSc Computer Science project: a blockchain-anchored supply chain
verification app for mining in Zambia, aimed at artisanal and small-scale miners. It is a
prototype shown in a simulated supply chain, not a production system.

- **Stack:** Flutter Android app, Node.js REST API, Solidity contract on Ethereum Sepolia.
- **Roles:** miner, transporter, buyer, regulatory officer, system administrator.
- **Core flow:** a consignment is registered at extraction, handed off to a transporter and
  purchased by a licensed buyer. Each step is signed and anchored on-chain.
- **Deadline:** Sunday 22 November 2026, 12:00. Work stops at 10:00 that day.

### Four-layer architecture

| Layer | Lives in | Responsibility |
|---|---|---|
| Mobile Application | `mobile/` | Role-based UI, QR scanning, GPS capture, ECDSA key management, encrypted local database, offline sync |
| API Communication | `backend/` | REST API over TLS 1.3 with certificate pinning, JWT on every request |
| Backend Processing | `backend/` | Transaction processing, anomaly detection, reports, accounts, push notifications, PostgreSQL |
| Blockchain Ledger | `contracts/` | `registerConsignment`, `recordHandoff`, `recordPurchase`, each emitting an event |

Rules that shape the design:

- Only authorised backend wallets can write to the contract. Mobile never talks to the
  chain directly.
- Anomaly detection runs in the backend, not the contract. It has five checks: duplicate
  consignment ID, quantity discrepancy over 10%, GPS zone, ECDSA signature, and handoff order.
- A failed check creates an alert, notifies officers and holds the consignment.
- The app is offline-first: work is signed and cached locally, then synced when the network
  returns.

## Current status

Updated 19 Nov 2026. Read this first in a new session, then `docs/progress.md` (the day
plan and the current feature's subtasks), then `docs/decisions.md`.

- **Done: Hardening** (`docs/plans/hardening-plan.md`, on a new branch the developer creates
  from `main`, suggested `chore/hardening`). An OWASP MASVS/MSTG review of the app as built
  (foundation, miner module, design), fixing every Critical and High finding, replacing the
  skipped miner case in `homes_test.dart`, and three device checks. Plan approved 19 Nov
  (Q1–Q5 as proposed).
  - T1 done: `docs/security-review.md` (MASVS v2, control by control). No Critical; one High
    (H1, the signing key worked on a phone with no screen lock); M1 no `FLAG_SECURE`, M2 root
    can read the database key (accepted); L1 tapjacking, L2/L3 no release build run yet,
    L4 root-CA pinning (accepted), L5 ML Kit's Google statistics library (accepted).
  - T2 done (Q6: option A), tests 1434 passed, 1 skipped. `DeviceKeyPlugin.kt` refuses
    `createKey` and `sign` with `NO_SCREEN_LOCK` unless `KeyguardManager.isDeviceSecure`;
    new keys get `setUnlockedDeviceRequired(true)` on API 28+; Dart maps it to
    `DeviceKeyError.noScreenLock`, `AppText.screenLockNeeded` (key check) and
    `SaveNoScreenLock` / `AppText.saveNoScreenLock` (save). `MainActivity.kt`: `FLAG_SECURE`
    when the app is not debuggable, `filterTouchesWhenObscured` on the decor view. The
    Kotlin was not compiled here (Gradle too slow on this laptop); the developer's
    `flutter run` in the T2 phone check compiles it.
  - T2 phone check fine (19 Nov): emulator refused Mutale's existing key without a PIN and
    signed with one; the A57 (Clement, lock set) registered as before. Keys made before T2
    keep working; no new key or registration.
  - T3 done: the skipped miner case in `homes_test.dart` is now three "miner tiles" router
    tests; tests 1437 passed, 0 skipped.
  - T4 done (19 Nov, A57): the obfuscated release build (`flutter build apk --release
    --obfuscate --split-debug-info=build/symbols`, then `adb install -r`, never
    `flutter install`) works; logcat holds no token, payload, QR code or password (the
    `Bearer` lines are Samsung network services); database header random; no
    `ALLOW_BACKUP`. `FLAG_SECURE` first failed (window flags had no 0x2000): the runtime
    `FLAG_DEBUGGABLE` check was replaced by `BuildConfig.DEBUG` (`buildFeatures.buildConfig
    = true` in `build.gradle.kts`); then recent-apps blank and screenshots blocked.
    `run-as` worked on the release build on normal firmware (`user`, `ro.debuggable=0`):
    record as a Low finding. The build warned about unobfuscated DWARF info (`--strip`).
  - T5 done: `decisions.md` Hardening (1)–(5) plus five known limitations (L6 `run-as`,
    M2, L4, L5, untested Kotlin); `security-review.md` marked with T2/T4 results and a new
    Low L6 (re-check in the final OWASP review); PR description drafted. Hardening 5/5.
  - Merged as PR #13 (`229b65a`).
  - Then `fix/account-back-arrow`: "My account" has a back arrow that goes to the Home
    branch (`goBranch`), decision Mobile (39), reversing Q10 of Mobile (37). Tests 1438
    passed, 0 skipped. A57 check fine. Left: PR. Next feature: Consignment check (Thu 19).

- **Design integration merged as PR #11** (`d86e33c`, 19 Nov;
  `docs/plans/design-integration-plan.md`, T1–T14). Mapalo Maseko's copper theme, the home
  header and brand block, the launcher icon (`mobile/tool/make_launcher_icon.dart`), and the
  Home/Account navigation bar (rail under 480 dp height, Android back on Account goes Home,
  the bar's 1.3× word cap kept, Q14). Decisions Mobile (35)–(38). Tests 1430 passed,
  1 skipped. Only `mobile/` and `docs/` changed, so nothing was deployed to Render.
  - The schedule is about one day behind plus the bar's 3 h, which the developer accepted;
    see `docs/progress.md`.
  - Rules learned in this feature:
    - run `dart format` only on files you changed, never the whole of `lib/`;
    - a test whose behaviour changed by decision says so in a comment and in
      `docs/testing-log.md`;
    - drafted commit messages have no Co-Authored-By line;
    - a widget test that reads an animated colour or border pumps twice: `pump()`, then
      `pump(300 ms)`. The first frame only starts the animation;
    - give the developer the commit the way "Git rules", "How the developer commits", says
      (Source Control for one commit, a whole-paste script for two or more).

- **Mobile app, miner module built** (`docs/plans/miner-registration-plan.md`) on
  `feature/miner-registration`. Mobile foundation (login, homes, pinned TLS 1.3, secure
  storage); the Keystore signing key and its registration (M1–M2); the administrator's
  account requests screen (A1); the encrypted local database on sqlite3 with sqlite3mc (M3);
  signed registration payloads (M4); the registration screen with QR, GPS and the custody
  record ID check (M5); sync and "Send my work" (M6); "My consignments" (M7). Checked on the
  Samsung A57 and the API 26 emulator, including a second miner's duplicate flagged
  `DUPLICATE_CONSIGNMENT`. Decisions: Mobile (1)–(34).
  - Mobile working rules: one permission request at a time; a busy database is never
    "cannot be opened" and calls run one at a time (Mobile (26)); state words are shared by
    "Send my work" and "My consignments"; widget tests keep missed taps fatal, avoid
    `pumpAndSettle` while a progress bar runs, and reach lazy list rows with `scrollTo`.

- **App endpoints plan built** (`docs/plans/app-endpoints-plan.md`) on
  `feature/backend-app-endpoints`: B1 officer alerts, B3 account rename and soft delete, B2
  consignment view and verification (`GET /consignments/by-qr/{qrCode}`, B2.1–B2.6, last
  code commit `0ea38c2`), merged as PR #8. The users-deleted migration was run on
  production on 15 Nov, after a backup and before the merge (`docs/deployment.md`, `efd8a5f`).

- **Backend complete, merged and deployed.** `feature/backend-logic` is merged into `main`
  (PR #5). Latest commit `044af61` pins Node 22.14.0 for Render.
- **Deployed on Render** (minechain-api and minechain-db, Frankfurt, Free) on 13–14 Nov,
  with anchoring running in production since 14 Nov. Setup, checks, backups, the
  1 December database refresh and the re-check list are in `docs/deployment.md`; the
  reasons are in `docs/decisions.md`, "Deployment (1)–(12)".
- **Test totals (confirmed by the developer, 15 Nov, after B2.5a):** `npm test` 2300,
  `npm run test:db` 914. Contract 37 (last run 12 Nov; the contract has not changed).
- **Databases:** production and `minechain_dev` both have all 11 migrations, including
  `1794528000000_users-deleted` (15 Nov, `docs/deployment.md`). `npm run test:db` migrates
  `minechain_test` itself (`tests/db/globalSetup.js`).

**Done on `feature/backend-logic`, now merged** (docs updated for all of it):

- Seed script (`npm run seed`): first admin, demo GPS zone, demo users.
- Admin account endpoints (FR-10, FR-12): list, approve, reject, suspend, reactivate,
  reset-key.
- Signing: `docs/signing-spec.md` v1, `stepPayload`, `signatureService`, and the fixed
  vectors in `docs/signing-vectors.json` (never regenerate them).
- Device key registration (`PUT /auth/me/public-key`) and the unique-key migration.
- Sync (`POST /sync/steps`): registration, handoff and purchase; stage rules; deferral of
  out-of-order steps; bad signatures stored as flagged with an alert; per-user limiter;
  real-signature chain test.
- Step 8, anchoring (FR-03), done and proven live on Sepolia
  (`docs/live-run-2026-11-09.md`):
  - `src/chain/`: minimal ABI with a drift test, chain client (the only network code;
    primary and fallback RPC; secrets hidden), error classification, preflight;
  - `src/services/`: `anchorCall`, `anchorQueue` (eligibility, advisory lock),
    `anchorService.runOnce()` (reconcile, then one send; crash and error tables);
  - the worker timer in `server.js`, `anchor:once` and `demo:journey` (DEV-SHORTCUT);
  - migration `transactions-anchor-nonce`; sync's `received_at = clock_timestamp()` fix;
  - tests use `tests/fakes/fakeChainClient.js`; no test touches Sepolia.

**Step 9, anomaly rules (FR-08), complete (9.1–9.5)**, with docs (`api.md` sync codes,
`database-schema.md` alert details and held consignments, `decisions.md` "Anomaly rules
(1)–(10)" and their known limitations):

- 9.1 `src/services/zoneMatch.js`: point-in-polygon on `[lat, lng]`, nearest-edge distance
  (local equirectangular projection; floats allowed here, nothing derived is signed),
  25 m tolerance, deterministic zone choice.
- 9.2 `anomalyChecks.js`: `checkDuplicate` (high), `checkHandoffOrder` (handoff after
  purchase medium, second purchase high), `checkQuantity` (medium; more than 10% off the
  previous accepted step OR the accepted registration, BigInt, no division),
  `checkGpsZone` (medium; registrations only; flags all when no zone is active). A check
  whose context is absent (`undefined`) returns null. Code = most severe finding, ties by
  check order; `FLAGGED_MESSAGES` for every sync-time code.
- 9.3 `syncService.js`: context gathered under the consignment lock; zones read once per
  sync call; `zone_id` set for every step; a duplicate QR code and a step after purchase
  are stored flagged (codes `QR_CODE_ALREADY_REGISTERED` and `CONSIGNMENT_CLOSED` are
  gone); purchase at `registered` is still deferred. DB tests give syncing tests an active
  campus zone (`insertCampusZone`); `tests/db/anomalyRules.test.js` covers each rule.
- 9.4 `anchorQueue.js`: a flagged duplicate of an accepted registration neither holds the
  consignment (ALL its alerts are excused) nor blocks the ordering gate;
  `isConsignmentHeld()` exposes the same rule. Alerts on any other step still hold.
- 9.5 tests and fix:
  - `7ef7b17`: shared helpers moved to `tests/db/realStackHelpers.js` (no behaviour change);
  - `ec2f0bd`: `tests/db/flaggedChain.test.js`. Accounts are made through the API
    (`loggedInSigner`: register, admin approve, login, key). A 20% lighter handoff is
    flagged, holds the consignment and stays off the fake chain, and the purchase after it
    is deferred. A second test shows a hold also blocks an unanchored registration;
  - `fe4abdb`: the `STAGE_NOT_READY` message names both causes (an earlier step not
    arrived, or waiting for review); the code and outcome are unchanged.

**FR-11, GPS zones API, complete (Z1–Z4)**, with docs (`api.md` "GPS zone management
(FR-11)", `database-schema.md` gps_zones rules, `decisions.md` "GPS zones (1)–(7)" and their
known limitations):

- Z1 `aab4def`: `src/services/zoneShape.js` (no repeated or closing corner, at least 3
  different corners, at least 100 m², at most 50 km each side, `ZAMBIA_BOUNDS` to catch
  `[lng, lat]` swaps), run by `zoneBoundarySchema` after the corner rules (`.pipe()`), so
  the seed obeys them too; `src/schemas/gpsZones.js`; `wholeNumber` exported.
- Z2 `1132b70`: `src/services/zoneService.js` (`list`, `create`, `rename`, `deactivate`,
  `reactivate`), wired as `services.zones`. Boundary and licence number never updated
  (a test reads the `UPDATE` statements). Deactivate locks all active zones `ORDER BY id`,
  counts afterwards and returns `NO_ACTIVE_ZONES` when none is left; two-connection race
  test with `pg_locks`.
- Z3 `958fb08`: `src/routes/adminZones.js` and `adminZonesController.js`, mounted at
  `/admin/zones` behind the `/admin/users` guard. `tests/db/adminZones.test.js` drives
  create, a matched registration, deactivate with the warning, then a `GPS_ZONE` flag.

**FR-09 and FR-13, CSV reports, complete (R1–R4)**, with docs (`api.md` "Reports (FR-09,
FR-13)", `database-schema.md` Reports and the two-clocks convention, `decisions.md`
"Reports (1)–(13)", "Reports fix (1)–(3)" and their known limitations):

- R1 `808dc8e`: `src/services/csv.js` (`toCsv`: column kinds text/number/time, every field
  quoted, CRLF, BOM; text cells starting with = + - @ tab CR get a leading '; malformed
  number/time cells throw without the value), `src/services/units.js` (`mgToKg`, exact
  text), `src/schemas/reports.js` (UTC days, both included, at most 366; exactly one id).
- R2 `367ba9a`: `src/services/reportService.js` (`transactions`, `auditTrail`, wired as
  `services.reports`): fixed SQL, buyer limit in the query, 10,000-row cap refused with 422
  `REPORT_TOO_LARGE`, audit entry in the same `REPEATABLE READ` transaction; `db.transaction`
  takes `{ isolation }` (fixed table, `Object.hasOwn`).
- R3 `64f3a36`: `src/routes/reports.js` (guard officer/buyer/admin, audit trail officer
  only), `reportsController.js` (safe filename, file built before sending),
  `createReportLimiter` (20 per 15 minutes per user); real-stack tests include CSV injection
  from a registration licence number to the downloaded bytes.
- Fixes: `ea70b86` report ties by `received_at`; `3af2c80` sync dates alerts with
  `clock_timestamp()`; `a1f8c6b` migration `1794398400000` makes it the default for
  `transactions.received_at` and `alerts.created_at`, after a read-only sweep of every
  `now()`.

**FR-10, officer and admin account creation, complete (A1–A6)**, with docs (`api.md`
`POST /admin/users`, `/activation-code`, `/auth/activate`, `/auth/me/password` and the five
account statuses, `database-schema.md` users rules, `decisions.md` "Accounts (1)–(20)" and
their known limitations):

- A1 `7b11afc`: migration `1794441600000_users-activation`: status `invited`, NULL
  `password_hash` only while invited, `activation_code_hash` (32 bytes),
  `activation_expires_at`, `activation_failed_attempts`, `tokens_valid_after`; its Down
  refuses while invited rows exist.
- A2 `cc5bf4f`: `src/services/activationCode.js`: 12 Crockford base32 characters (60 bits,
  `randomInt`), `normalise` (ASCII check before upper-casing; O→0, I/L→1), SHA-256,
  `timingSafeEqual`.
- A3 `ad00033`: `accountService.createAccount` (officer/admin only, `ROLE_NOT_CREATABLE`)
  and `reissueActivation`; expiry `clock_timestamp()` + 72 h; invited login = unknown
  username; `activationExpiresAt` in the admin view. `857da61`: "an" before vowel statuses
  in refusal messages, with a pinned row per action.
- A4 `aee6d96`: `userService.activate` (policy first; one 401 `ACTIVATION_INVALID`; 5th
  wrong code erased in the counting `UPDATE`; failures audited outside the transaction,
  `code_changed` for a lost race), `createActivationLimiter` (30 per 15 min per IP), routes
  `POST /auth/activate`, `POST /admin/users`, `POST /admin/users/{id}/activation-code`.
- A5 `071c00e`: `POST /auth/me/password`: cut-off `tokens_valid_after` = the fresh token's
  `iat` (one clock, the app server's); older tokens get `TOKEN_INVALID`; 400 refusals;
  `createPasswordChangeLimiter` (10 failures per 15 min per user). `verify()` returns `iat`.
- A6 `5b6344c`: docs.

**Anchoring admin, complete (N1–N5)**, plan `docs/plans/anchoring-admin-plan.md` (`1fa1a13`),
with docs (`api.md` "Anchoring administration", `database-schema.md` "Admin status and
retry" and the two meanings of `anchor_error`, `decisions.md` "Anchoring admin (1)–(12)" and
their known limitations):

- N1 `88ded46`: worker `snapshot()` and `runNow()` (refusals `ANCHORING_DISABLED`,
  `NOT_STARTED`, `STOPPED`, `BUSY`; `runAnchoringNow` / `anchoringSnapshot` for `null`);
  a refused resend stored on the `submitted` row (`NOTE_RESEND`, same hash only, cleared on a
  good resend); balance checked before a resend is signed; `STUCK_AFTER_SECONDS` moved to
  `anchorQueue.js`, shared with `anchor:once`.
- N2 `de7003c`: `src/services/anchorStatusService.js` `status()` (database and worker memory
  only, one `REPEATABLE READ` snapshot, the queue's exported SQL fragments and
  `peekEligibleStep`), `RETRYABLE_ANCHOR_ERRORS`, `splitAnchorError`, `findProblems`; wired
  as `services.anchoring`.
- N3 `3769508`: `retry()` (`FOR UPDATE`, 404 / 409 `INVALID_STATUS_TRANSITION` /
  409 `ANCHOR_NOT_RETRYABLE`, one `UPDATE`, `transaction.anchor_retry` in the same
  transaction) and `run()` (409 refusals, `anchoring.run` after the tick; a failed audit
  write leaves a log line); `withArticle` moved to `services/wording.js`.
- N4 `6c67172`: `src/routes/adminAnchoring.js` at `/admin/anchoring` (GET status, POST
  `/run`, POST `/steps/{id}/retry`), `createAnchoringActionLimiter` (20 per 15 min per admin,
  both POSTs together, GET unlimited); `server.js` creates the worker before the app and
  passes it to `createServices`; real-stack tests (failed → retry → confirmed; stuck → fee
  lowered → same-nonce resend; no secrets in the body).
- N5: these docs.

**Next, in order:**

1. ~~Check M7 on the A57, then the pull request for `feature/miner-registration`~~ (merged as
   PR #10).
2. The remaining role modules in the app: transporter handoff, buyer purchase, the officer's
   alerts list and consignment check (Scope (2), (9)), and the admin screens and reports
   (Scope (3)). The order by day is in `docs/progress.md`.

**Working rules that held all weekend:**

- Autopilot: see "Working agreement (autopilot)" below for what Claude Code runs itself,
  what it never does, and what it asks about first.
- One sub-step at a time, and stop after each. "Plan only" first on new or risky work.
- Refusal tests take a function that starts the action, not a promise already started.
- Values from signed payloads stay as text, never JavaScript floats.
- Rejected and deferred items (sync steps, refused tokens and roles) are never audited.
- Check `docs/decisions.md` before changing any decided behaviour.
- Never open or read any `.env` file. The recorder key and RPC URLs are secrets: never
  logged, printed or put in an error.
- On PowerShell, run scripts that take flags with `node scripts/...`, not `npm run ... --`.

Known limits are listed in `docs/decisions.md`; they are not repeated here.

## Working agreement (autopilot)

In force from 18 Nov 2026 until submission. `.claude/settings.json` enforces the command
lists below as permission rules. Those rules match command text and are a guard rail, not a
security boundary, so these written rules still apply in full.

**Roles.** Claude Code plans, writes code, formats, analyses, runs tests, fixes its own
failures, updates docs, keeps `docs/progress.md`, and drafts commit messages and PR
descriptions. The developer approves plans, does the phone and emulator checks, commits
through VS Code Source Control, pushes, and opens and merges PRs on GitHub.

**Allowed without asking:** `flutter analyze`, `flutter test` (unit and widget),
`dart format`, `flutter pub get`, backend `npm test` and `npm run test:db`, and read-only git
(`status`, `diff`, `log`, `show`, `branch`, `fetch`).

**Never:**

- `git commit`, `push`, `merge`, `rebase`, `reset`, checking out files, creating or deleting
  branches; `gh pr create` or `gh pr merge`.
- `flutter run`, or any integration test on a device. Ask instead; integration tests always
  need `--no-uninstall`.
- Reading or printing `mobile/env/api.json`, any `.env`, keystores or keys.
- Calling the production API or creating accounts.
- Deleting or skipping tests, adding `warnIfMissed: false`, or loosening an assertion to make
  a test pass.

**Ask first:**

- Any new or upgraded package: check it is current and maintained, and give the exact version.
- Anything under `backend/`, `contracts/`, database migrations or Render settings (merging
  these deploys to production).
- Any design decision not in the approved plan.
- Anything touching signing, keys, the encrypted database or auth.

**Levels of work.** Project → Day → Feature (a module, for example "Verification") → Subtask
(T1, T2 …, one commit each, about 30–60 minutes) → Steps (T3.a, T3.b … inside a subtask, no
separate commit).

`docs/progress.md` holds (a) the whole-project checklist, all features to submission grouped
by day; (b) today's features in order; (c) the current feature's subtasks with ✅/⬜. It is
updated after every subtask. `docs/testing-log.md` gets the real test numbers after every
subtask.

**Flow per feature.**

1. Write or update `docs/plans/<feature>-plan.md`: numbered subtasks T1…Tn (steps where
   useful), inputs and outputs, how it connects to other parts, open questions. Show the
   subtask list as a checklist, then STOP for approval.
2. For each subtask: implement → `dart format` → `flutter analyze --no-pub` → focused tests →
   full `flutter test` → fix failures (stop and report after two failed fix attempts on the
   same problem) → secret checks on the working tree (git diff and untracked files: no
   `api.json`, `.env`, keystores, private keys or the Render host name) → append the test
   numbers to `docs/testing-log.md` → update `docs/progress.md` → STOP with the subtask
   report. Wait for "next" before the next subtask.

**Subtask report**, always in this order and short:

1. What was done (3 sentences at most).
2. How it fits: which actors, screens, data and server calls are involved, in plain words.
3. Tests: commands run and exact results.
4. Hygiene: the secret-check result and the files changed.
5. Phone check: "needed" or "not needed". If needed: the exact `flutter run` command, the
   device (the A57 or `emulator-5554`), the steps, what to look for, and which screenshots to
   keep for the thesis, with suggested file names.
6. Commit message (Conventional Commits).
7. Learning notes: 2–4 terms explained simply.
8. Decisions and limitations recorded in `docs/decisions.md` (or "none").
9. Feature progress: the current feature's subtask checklist, for example
   "Verification 3/7: ✅ T1 … ⬜ T7".
10. After the feature's last subtask, also "Day progress" (today's features with ✅/⬜) and
    the drafted PR title and description (what, how tested, known limitations).
11. For the chat: a 4–6 line plain-text summary for the tutor (feature, subtask, what
    changed, test numbers, anything that needs a human decision).
12. Context: say if a new session would be wise.

**End of session** ("end of session" or "last task today"): update this file's status and
next steps, and `docs/progress.md`; then show the whole-project checklist (all days, ✅/⬜,
what moved), what carries over to tomorrow, and an 8–12 line "For the chat" handover. Before
suggesting a new session at any time, update this file's status first so the next session can
continue from it alone.

## Repo layout

| Path | Contents |
|---|---|
| `contracts/` | Solidity contract and tests (Hardhat 3) |
| `backend/` | Node.js REST API |
| `mobile/` | Flutter Android app |
| `docs/` | Architecture, API and contract specs, database schema, decisions log |
| `private/` | Git-ignored local documents |

`private/` must never be referenced in committed files: no quotes, links, paths or section
numbers. Read it locally for detail, then put what is needed in your own words. The only
exceptions are the ignore entry in `.gitignore` and this rule.

## Requirements summary

Priorities: **M** Must, **S** Should, **C** Could.

### Functional

| ID | Summary | Priority |
|---|---|---|
| FR-01 | Register a consignment by QR scan with GPS, mineral, weight, time | M |
| FR-02 | Sign each transaction with the user's ECDSA key | M |
| FR-03 | Record signed transactions on Sepolia through the contract | M |
| FR-04 | Verify a consignment by QR scan and signature check | M |
| FR-05 | Log full details and chain hash of every transaction for audit | M |
| FR-06 | JWT login and role-based access for all five roles | M |
| FR-07 | Cache offline in an encrypted database, sync on reconnect | M |
| FR-08 | Flag anomalies and push alerts to officers | M |
| FR-09 | Filtered transaction reports, exported as spreadsheets | M |
| FR-10 | Admin manages accounts and role permissions | M |
| FR-11 | Admin manages licensed GPS extraction zones | S |
| FR-12 | Users request accounts, admin approves | S |
| FR-13 | Officers download audit trails as spreadsheets | S |
| FR-14 | Analytics dashboard | C (kept) |
| FR-15 | Multi-language interface | C (cut) |
| FR-16 | Signed PDF provenance certificate | S |

FR-15 is cut; do not start it without being asked. FR-14 is kept (Scope (4), 17 Nov) and is
the first feature to cut if time runs short. FR-16 is decided on Saturday 21 Nov.

### Non-functional

| ID | Area | Summary | Priority |
|---|---|---|---|
| NFR-01 | Security | AES-256 at rest, TLS 1.3 with pinning, JWT valid 60 minutes at most | M |
| NFR-02 | Security | No Critical or High OWASP MSTG findings; private keys never leave the device | M |
| NFR-03 | Performance | Local save within 3s on a low-end device; sync within 10s on stable 3G | M |
| NFR-04 | Reliability | 72 hours offline with no data loss | M |
| NFR-05 | Scalability | At least 500 users across several zones | M |
| NFR-06 | Usability | Registration in three taps or fewer, plain language | S |
| NFR-07 | Maintainability | Faults fixable in four working hours; contract functions documented and emit events | S |
| NFR-08 | Data integrity | Detect and resolve offline sync conflicts without data loss | M |
| NFR-09 | Compatibility | Android 8.0 (API 26) or later, screens of 5 inches or larger | M |

## Approved decisions

Do not change these without asking. Record new decisions in `docs/`.

- **Contracts:** Hardhat 3.
- **Flutter state management:** Riverpod.
- **Local encrypted database:** SQLCipher. The package is still to be confirmed, so propose
  options with trade-offs rather than picking one.
- **Hosting:** Render, with PostgreSQL as the server database.
- **Ledger:** public Ethereum Sepolia. It is "permissioned" only through contract access
  control: anyone can read it, and only the authorised account can write. Never describe it
  as a private or permissioned chain.

## Teaching rules

The developer is a student learning while building.

- Explain the plan and the reason for it before writing code.
- Work in small steps, and stop at sensible points so the work can be read and tested.
- Comments explain why, not what.
- After major code, add a short **Learning notes** section in the reply covering what was
  built, why, and what to look at.
- Explain new concepts simply, with a concrete example, the first time they appear.
- Never generate huge files in one go. Build them up across steps.

## Security rules

- No secrets in code or Git: keys, JWT secrets, passwords, RPC URLs with API keys.
- `.env` files stay ignored. Commit `.env.example` with fake values only.
- Use a throwaway Sepolia wallet only, never one that has held real funds.
- ECDSA private keys live in the Android Keystore and never leave the device.
- Tokens go in secure storage, never in plain preferences or logs.
- Validate all input on the server, even if the app already validated it.
- Use parameterised queries only. Never build SQL by joining strings.
- Sepolia is public, so never put personal data on-chain. Store hashes and references.
- Mark any development shortcut so it can be found and removed:

  ```
  // DEV-SHORTCUT: <what this skips> | <what must replace it before release>
  ```

## Code structure

**Flutter:** organise by feature, each with its own layers.

```
mobile/lib/
  core/            shared theme, networking, helpers
  features/
    <feature>/
      data/          API calls, local database, repositories
      domain/        models and business rules, no Flutter imports
      presentation/  screens, widgets, Riverpod providers
```

**Backend:** requests flow in one direction.

```
backend/src/
  routes/        URLs mapped to controllers
  controllers/   read the request, call a service, send the response
  services/      business logic, including anomaly checks
  middleware/    authentication, role checks, validation, error handling
```

**Tests:** cover logic, key screens, the contract and the API.

- Contract: every function, including rejected unauthorised callers.
- Backend: service logic, especially each anomaly rule, plus API endpoints.
- Mobile: domain logic, sync and conflict handling, and widget tests for key screens.

## Git rules

- Never run `git commit`, `git push` or create branches. The developer does all Git
  operations.
- Read-only commands such as `git status`, `git diff` and `git log` are allowed.
- Before the developer commits, remind them to check for secrets.
- Use Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`.
- Suggest a commit message when a step is finished, but do not run it.
- **How the developer commits** (asked for on 19 Nov):
  - **One commit with every changed file:** say so, give the message, and the developer
    uses VS Code Source Control (stage all, commit, push).
  - **Two or more commits:** give one PowerShell script that can be pasted and run whole.
    It names the exact files for each commit, because only Claude Code knows which files
    belong to which subtask.
  - The script runs each step only if the one before it worked, by checking
    `$LASTEXITCODE` (PowerShell 5.1 has no `&&`). It ends with `git push`, then
    `git --no-pager log --oneline -<n>` so the developer sees the result.
  - No pager in a script: never put a bare `git diff`, `git log` or `git show` in it. Their
    pager waits for `q`, and every later line waits too. Use `git --no-pager ...`.
  - When a docs file holds rows for two subtasks, it goes into the later commit, and the
    report says so.

## Platform

- **Development:** Windows laptop with PowerShell. Give commands in PowerShell syntax.
- **Test device:** Samsung Galaxy A57 (Android 17).
- **Target:** Android only, so do not add iOS, web or desktop code.
