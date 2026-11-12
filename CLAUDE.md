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
- **Deadline:** Sunday 15 November 2026.

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

Updated 12 Nov 2026. Read this first in a new session, then `docs/decisions.md`.

- **Branch:** `feature/backend-logic`. Latest code commit `6c67172` (anchoring admin
  routes), followed by the anchoring admin docs commit (N5). `main` has Days 1–3 (PR #4).
- **Test totals (confirmed, run 12 Nov 14:05):** `npm test` 1841, `npm run test:db` 787,
  contract 37.
- **Dev database** (`minechain_dev`) is migrated to `1794441600000_users-activation`.
  `npm run test:db` migrates `minechain_test` itself (`tests/db/globalSetup.js`).

**Done on this branch** (docs updated for all of it):

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

1. Merge `feature/backend-logic` into `main` (open the PR).
2. Render deploy.
3. Flutter app.

**Working rules that held all weekend:**

- Manual mode. Never run git. Never run tests unless asked.
- One sub-step at a time, and stop after each. "Plan only" first on new or risky work.
- Refusal tests take a function that starts the action, not a promise already started.
- Values from signed payloads stay as text, never JavaScript floats.
- Rejected and deferred items (sync steps, refused tokens and roles) are never audited.
- Check `docs/decisions.md` before changing any decided behaviour.
- Never open or read any `.env` file. The recorder key and RPC URLs are secrets: never
  logged, printed or put in an error.
- On PowerShell, run scripts that take flags with `node scripts/...`, not `npm run ... --`.

Known limits are listed in `docs/decisions.md`; they are not repeated here.

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
| FR-14 | Analytics dashboard | C (cut) |
| FR-15 | Multi-language interface | C (cut) |
| FR-16 | Signed PDF provenance certificate | S |

FR-14 and FR-15 are cut unless time remains. Do not start them without being asked.

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

## Platform

- **Development:** Windows laptop with PowerShell. Give commands in PowerShell syntax.
- **Test device:** Samsung Galaxy A57 (Android 17).
- **Target:** Android only, so do not add iOS, web or desktop code.
