# App endpoints: alerts, consignment view, account edit and delete — plan (15 Nov 2026)

**Status: Plan approved 15 Nov 2026. B1 (alerts) built 15 Nov 2026 in B1.1–B1.4:** B1.1
`453d3f9`, B1.2 `f37256e`, B1.3 `c11adc5`; B1.4 is the docs commit that adds this line. What
was built, and where it differs from this plan, is in `docs/api.md` ("Alerts (FR-08)"),
`docs/database-schema.md` (alerts, "Closing an alert") and `docs/decisions.md` ("Alerts
(1)–(8)" and their limitations). **B3 (account edit and soft delete) built 15 Nov 2026 in
B3.1–B3.4:** B3.1 `6a85bbf`, B3.2 `677764e`, B3.3 `e9d9d40`; B3.4 is the docs commit that adds
this sentence. Details in `docs/api.md` (`/admin/users/{id}/rename` and `/delete`),
`docs/database-schema.md` (users, "Deleted accounts") and `docs/decisions.md` ("Accounts
(21)–(30)" and their limitations). The users-deleted migration was run against the
production database on 15 Nov 2026, after a backup and before the merge (see §5). **B2
(consignment view and verification) built 15 Nov 2026 in B2.1–B2.6:** B2.1 `963bdb5`, B2.2
`4ca6b92`, B2.3 `e6ce0cc`, B2.4 `a063fab`, B2.5 `5c98e06`, the fix B2.5a `0ea38c2`; B2.6 is
the docs commit that adds this sentence. Details in `docs/api.md`
(`GET /consignments/by-qr/{qrCode}`), `docs/database-schema.md` (`record_tampered`),
`docs/contract-spec.md` (section 7) and `docs/decisions.md` ("Verification (1)–(14)" and
their limitations). All three parts of this plan are built. Written on 15 Nov 2026 for review in chat, to be built in
sub-steps B1.1–B3.4 on the backend branch planned for Mon 16 Nov 2026. Based on
`docs/decisions.md` Scope (2)–(9), `docs/api.md`, `docs/database-schema.md`,
`docs/signing-spec.md` (sections 3, 5 and 7), `docs/contract-spec.md` (section 7) and the code
in `backend/src`. Nothing here changes a decided behaviour without saying so; the places that
need a decision are in §6.

## 1. Findings that shape the design

- **A step can have several alerts** (one per rule, `alerts_one_per_rule_per_step`), for
  example a registration that is both off-zone and too heavy. Scope (5) says "review → step
  `rejected`, dismiss → step `cleared`". With two alerts, clearing the step on the first
  dismissal would let a later review try to reject a cleared step. The plan therefore derives
  the step's status from **all** its alerts after each close: any `reviewed` → `rejected`;
  every alert `dismissed` → `cleared`; otherwise it stays `flagged`. For a one-alert step this
  is exactly Scope (5).
- **Two kinds of flagged step can never be cleared.** The partial unique indexes allow one
  accepted registration and one accepted purchase per consignment, so clearing a flagged
  duplicate registration (or a second purchase) would fail with `23505`. A `handoff_order`
  step comes after the purchase, and the contract refuses any step from `Purchased`, so a
  cleared one could only end `failed`. Dismissing these is refused with a new 409.
- **Clearing a flagged handoff or purchase must move the stage.** Sync moves
  `consignments.stage` only for `passed` steps, and its own comment says the officer's clear
  moves it. Without that, a purchase behind a cleared handoff stays deferred
  (`STAGE_NOT_READY`) for ever. Forward only: handoff `registered → in_transit`, purchase
  `in_transit → purchased`; a relay leaves `in_transit` alone.
- **A `record_tampered` alert sits on an anchored step.** `transactions_anchor_only_if_approved`
  forbids `rejected` (or `flagged`) once a step is `submitted` or `confirmed`, so neither
  closing action can change that step's `review_status`. Detection cannot flag the step
  either; the alert alone holds the consignment through `HELD`.
- **`chainClient` cannot be built without the recorder key** (`requireSetting` on
  `RECORDER_PRIVATE_KEY`), and with `ANCHOR_ENABLED=false` `server.js` creates no chain client
  at all. Verification needs a separate, key-free reader. `loadConfig` already keeps a real
  `SEPOLIA_RPC_URL` and `MINECHAIN_CONTRACT_ADDRESS` while anchoring is off (only
  placeholders are dropped), so no new setting is needed.
- **The display columns are not all covered by the anchored hash.** The event carries the id,
  actor reference, weight and data hash; latitude, longitude and capture time are only inside
  `signed_payload`. Someone editing `transactions.latitude` would not change the hash. The
  check therefore also compares the stored columns with the parsed signed payload.
- **Deleting an invited account breaks a current rule.** `users_password_only_when_invited`
  says only an invited account may lack a password hash. The plan erases the hash on delete
  (see §4), so the migration replaces that constraint.
- **Admin account actions have no rate limit yet** (`api.md`: "None yet"). B3 adds one for
  the two new actions only; extending it to the existing ones is a question in §6.

## 2. B1 — Alerts (Scope (2) and (5))

### Endpoints

Router at `/alerts`: `noStore, requireAuth, requireRole('officer')` on the router, so an
administrator gets 403 `FORBIDDEN` on every path, existing or not (separation of duties,
Scope (5)).

| Method and path | Input | Answer |
|---|---|---|
| GET /alerts | query `status` (`open` default, `reviewed`, `dismissed`), `type` (optional, one of the six), `limit` 1–100 (20), `offset` 0–10 000 (0); `wholeNumber` from `schemas/adminUsers.js`; strict | 200 `{ alerts, total, limit, offset }` |
| GET /alerts/{id} | uuid param | 200 `{ alert }` with the consignment's other alerts |
| POST /alerts/{id}/review | `{ notes }` | 200 `{ alert, step, consignment }` |
| POST /alerts/{id}/dismiss | `{ notes }` | 200 `{ alert, step, consignment }` |

- **Order:** `open` lists oldest first, `(created_at, id)`, which uses
  `alerts_open_queue_idx`. Closed lists are newest closed first, `(reviewed_at DESC, id)`.
- **Alert view:** `id, type, severity, status, details` (as stored: ids, weights as text, zone
  name, never people's names), `createdAt`; `step { id, type, reviewStatus, anchorStatus,
  capturedAt, receivedAt }`; `consignment { id, qrCode, mineral, stage, held }` (`held` from
  `HELD`); `actor { id, username, role }`; `review { by: { id, username }, notes, at }` or
  `null`. No full names, keys, signatures or GPS (the officer opens the consignment view for
  those).
- **Notes:** trimmed, 3–500 characters, line breaks allowed (the reason rules, as
  `notesBodySchema`). Kept for ever in the audit log; `api.md` repeats the warning given for
  reasons.

### The close transaction (one function for both actions)

1. Read the alert's consignment id without a lock (404 `ALERT_NOT_FOUND` if none).
2. `SELECT … FROM consignments WHERE id = $1 FOR UPDATE`: the same lock sync takes first, so
   sync and a close on one consignment never deadlock.
3. `SELECT … FROM alerts WHERE id = $1 FOR UPDATE`, then the step's alerts and the step
   `FOR UPDATE`. Not `open` → 409 `INVALID_STATUS_TRANSITION` ("Only an open alert can be
   reviewed. This alert is dismissed.", via `withArticle`).
4. Dismiss only: 409 `STEP_CANNOT_BE_CLEARED` when the step is a registration and the
   consignment has another accepted registration, a purchase and it has another accepted
   purchase, or the alert type is `handoff_order`.
5. `UPDATE alerts SET status, reviewed_by, review_notes, reviewed_at = clock_timestamp()
   WHERE id = $1 AND status = 'open'` (the two-clocks rule in `database-schema.md`).
6. Except for `record_tampered`: work out the step's new status from all its alerts (§1) and
   `UPDATE transactions SET review_status … WHERE id = $1 AND review_status = 'flagged'`.
   If it became `cleared`, move the stage forward (§1) with sync's `CUSTODY_RULES`.
7. `audit.record` in the same transaction; `held` re-read with `isConsignmentHeld` for the
   answer.

**Built** (15 Nov 2026): B1.1 `453d3f9`, B1.2 `f37256e`, B1.3 `c11adc5`, B1.4 the docs
commit. Differences from the rows below: B1.2 also checks inside the service that the
reviewer is an active officer (Alerts (4)); the B1.3 real-stack test uses a **12% light
handoff, not 20%**, because after a cleared 20% light handoff no purchase weight is within
10% of both the handoff and the registration, so the purchase could never be accepted
(Alerts (8)).

| Sub-step | Contents | Size |
|---|---|---|
| **B1.1** Read side | `src/services/alertService.js` (`list`, `get`; fixed SQL, columns listed, `HELD` from `anchorQueue.js`), `src/schemas/alerts.js` (`listAlertsQuerySchema`, `alertIdParamsSchema`, `notesBodySchema`; `ALERT_TYPES` from `anomalyChecks.js`), wired as `services.alerts` in `services/index.js`. No routes yet | M |
| **B1.2** Close actions | `alertService.review()` and `.dismiss()` as above; stage step shared with sync (export `CUSTODY_RULES` or a small `custodyRules.js`, no behaviour change in sync) | L |
| **B1.3** HTTP | `src/routes/alerts.js`, `src/controllers/alertsController.js`, `createAlertActionLimiter` in `rateLimits.js` (60 per 15 min per officer, both POSTs together, after the guard, keyed by user id, fail closed), mounted in `app.js` with `rateLimits.alertActionsPerOfficer` | M |
| **B1.4** Docs | `api.md`: endpoints table, "Alerts (FR-08)" section, Rate limits table, Roles matrix row "Review anomaly alerts" → Built; `database-schema.md`: alerts rules (derived step status, the uncloseable cases, `reviewed_at` now written), Held consignments; `decisions.md` "Alerts (1)…" and limitations | S |

- **Migrations:** none.
- **Error codes:** reuse `VALIDATION_FAILED`, `FORBIDDEN`, `INVALID_STATUS_TRANSITION`,
  `TOO_MANY_REQUESTS`; new 404 `ALERT_NOT_FOUND`, 409 `STEP_CANNOT_BE_CLEARED` ("This step
  cannot be cleared: the consignment already has an accepted registration. Confirm the
  problem instead.", one fixed message per case).
- **Audit:** `alert.review` and `alert.dismiss`, entity `alert`, details `{ notes, alertType,
  transactionId, stepStatus: { from, to } | null, stage: { from, to } | null }`. Refusals and
  reads are not audited. The audit-trail CSV already shows `alert_reviewed` and
  `alert_dismissed` from the alerts table, so it needs no change.
- **Unit tests (≈ +30):** schemas (defaults, strict query, plain-digit paging, notes trimmed,
  blank and over-long notes); routes with a fake service (401, 403 for every non-officer role
  including admin on a made-up path, no-store on errors, 400 order params-then-body, 404/409
  passed through, 429 with `Retry-After`, limiter throws without `requireAuth`); the pure
  "new step status from alerts" function (every combination).
- **DB tests (≈ +28):** `tests/db/alertService.test.js`: list order for each status, type
  filter, total, paging past the end, `held` true/false, the duplicate exception; review →
  `rejected`; dismiss → `cleared`, hold released, the handoff then anchors on the fake chain;
  two alerts on one step (dismiss then review → `rejected`; dismiss both → `cleared`); a
  cleared handoff moves `registered → in_transit` and the deferred purchase then syncs; a
  relay leaves the stage; each `STEP_CANNOT_BE_CLEARED` case with nothing written;
  `record_tampered` close leaves `review_status` alone; second close → 409; audit write fails
  → nothing saved; `reviewed_at` ≥ the alert's `created_at`. Real stack in
  `tests/db/alertsRealStack.test.js` with `loggedInSigner`: a 20% light handoff (built with
  12%, see the note above the table) is flagged,
  the officer dismisses it over HTTP, the consignment anchors, the purchase is accepted.
- **Security checks:** officer only, admin refused; notes never in an error; fixed SQL with
  parameters only; no personal names in the view; `noStore` on the router; the limiter
  counts per officer.

## 3. B2 — Consignment view and verification (Scope (9))

### Endpoint

`GET /consignments/by-qr/{qrCode}`. Router guard `noStore, requireAuth,
requireRole('transporter', 'buyer', 'officer')`; then `createConsignmentViewLimiter`, 60 per
15 minutes per user (each view can cost several RPC calls on a free plan). The QR code is
checked with the `consignments.qr_code` rules (4–128 characters from `A–Z a–z 0–9 . _ : / -`);
`/` must be sent percent-encoded. No such code → 404 `CONSIGNMENT_NOT_FOUND` (reused from
sync).

### What each role sees (exactly Scope (9))

| | Transporter | Buyer, no accepted purchase | Buyer with an accepted purchase | Officer |
|---|---|---|---|---|
| Can open | any consignment | `in_transit` only; else 404 `CONSIGNMENT_NOT_FOUND` | that consignment | any |
| Steps listed | accepted (`passed`, `cleared`) | accepted | accepted | all, flagged and rejected included, with `reviewStatus` and alert ids/types/status |
| Weights | none until this transporter has a stored handoff on it (blind measurement) | yes | yes | yes |
| GPS | never | never; zone **name** only | yes | yes |
| Actor | role only, no names | role and username | role and username | role and username |
| Evidence (payload, signature, signer key) | no | no | yes | yes |
| Chain check | yes | yes | yes | yes, with mismatch field names |

Everyone sees `held` (true means "under review"), the stage, mineral, capture and receipt
times, and each step's anchor status and public transaction hash. Full names, licence
numbers, `actor_ref`, `anchor_error` and nonces are never returned. The rules live in one pure
function (`consignmentDisclosure.js`) whose output is built field by field, so a column added
later cannot leak.

### The chain check, per confirmed step

**Choice: the receipt of the stored `chain_tx_hash`, not `getLogs`.** Scope (9) already names
the lookup by stored hash; the reasons:

- **Cost is fixed.** One `eth_getTransactionReceipt` per step, plus one shared
  `eth_blockNumber`. `getLogs` needs a block range: from the deploy block (as
  `contract-spec.md` §7 describes) that is about 15 requests of 500 blocks for every day since
  deployment and grows for ever; the worker's narrower search from `received_at` still grows
  with the step's age. A view must answer within NFR-03's 10 s on a free RPC plan.
- **It is as safe.** The hash in the row is only a pointer; what is trusted is the event in
  the receipt, matched in full by `receiptEventMismatches` (contract address, event name,
  consignment id, actor reference, weight, data hash). Pointing `chain_tx_hash` at another
  transaction cannot help a forger: only the recorder wallet can emit a matching event, and
  the data hash in it is recomputed from the stored evidence.
- **It reuses tested code:** `getReceipt`, `decodeEvents` and `receiptEventMismatches` are what
  reconcile already uses. `getLogs` stays the worker's crash-recovery tool. `contract-spec.md`
  §7 is updated to describe both, with the receipt as the backend's method.

**Steps** (pure where possible, in `src/services/chainCheck.js`):

1. `hash_version` must be 1 (the only version ever written); recompute
   `anchorHash({ payload, signature, publicKey })` from the stored evidence (signing-spec §7).
   A `SigningError` on stored bytes means they were altered: `mismatch`.
2. Parse `signed_payload` (`parsePayload`) and compare it with the row: type, step id
   (`idempotency_key`), actor id, QR code, mineral (registration), `weight_mg`, latitude,
   longitude, `captured_at`, all as text; and the recomputed hash with `data_hash`.
3. Receipt of `chain_tx_hash`: `status` must be 1, `blockNumber` must equal `block_number`,
   and one event must match the step with the **recomputed** hash.
4. Receipt `null`: `mismatch` (`TX_NOT_FOUND`) only if the RPC's latest block is at least
   `block_number + confirmations`; otherwise `chain_unavailable` (the node is behind).
5. Any `ChainClientError`, the overall deadline (8 s per request, receipts fetched with at most
   3 in parallel), or no reader configured: `chain_unavailable`. Never `mismatch`.

Results: `match`; `mismatch` with the names of the fields that differ (officers only; values
never); `not_anchored_yet` for every step that is not `confirmed` (pending, submitted, failed,
flagged, rejected); `chain_unavailable`.

**On `mismatch`:** after the chain calls, one short transaction inserts a `record_tampered`
alert, severity `high`, details `{ source: "verification", fields, chainTxHash }`, with
`ON CONFLICT ON CONSTRAINT alerts_one_per_rule_per_step DO NOTHING`, `created_at`
`clock_timestamp()`. The alert holds the consignment through `HELD`; the answer shows
`held: true`. No database transaction is open during a network call. Like sync's alerts, the
raising is recorded by the alert row, not an audit entry.

### Read-only chain access with `ANCHOR_ENABLED=false`

- New `src/chain/chainReader.js`: `createChainReader(anchorConfig, options)` with
  `getReceipt`, `getBlockNumber`, `contractAddress` and `close` only. No `Wallet`; it never
  reads `recorderPrivateKey`. The provider set-up, fallback and event decoding move out of
  `chainClient.js` into `src/chain/rpc.js` and are shared by both (a pure move; existing
  chain client tests pass unchanged). Same secret rules: URLs stay in closures, errors become
  `ChainClientError`, warnings name the endpoint only by role (`primary`, `fallback`).
- **Guard against a wrong RPC:** before its first answer is trusted, the reader checks once
  that the node reports chain id 11155111 and that the contract has code; until that passes,
  every check is `chain_unavailable`. A misconfigured RPC (another network) would otherwise
  return no receipts and accuse honest miners.
- `server.js` creates the reader whenever `config.anchor.rpcUrl` and `contractAddress` are set,
  whatever `ANCHOR_ENABLED` says, passes it to `createServices({ chainReader })`, and closes
  it at shutdown. `null` (not configured) makes every check `chain_unavailable`. No network
  call at start-up. To verify locally with anchoring off, the developer puts the RPC URL and
  contract address in their own `.env`; the code never needs the recorder key for this.
- Tests use `tests/fakes/fakeChainReader.js` (or the fake chain client, which already has
  `getReceipt`), never Sepolia.

**Built** (15 Nov 2026): B2.1 `963bdb5`, B2.2 `4ca6b92`, B2.3 `e6ce0cc`, B2.4 `a063fab`, B2.5
`5c98e06`, B2.5a `0ea38c2` (a fix found while building B2.5), B2.6 the docs commit.
Differences from the rows below, each recorded in `docs/decisions.md` (Verification):

- **B2.1:** the network check also compares the contract's code hash with
  `EXPECTED_CODE_HASH` (refusal `WRONG_CONTRACT_CODE`), not only "has code" (Verification (2)).
- **B2.2:** the stored evidence is checked before any chain call, so a row that disagrees with
  itself is a `mismatch` even with no reader (Verification (4)); the signature is verified again
  (Verification (5)). `TX_NOT_FOUND` comes as `fields: ["chain_tx_hash"]` with `reason`.
- **B2.3:** four readings of the role table, settled before building: no transaction hash for
  a transporter before their own handoff, a zone name for transporters, no user ids (a `byYou`
  flag), and any stored handoff unlocks (Verification (6)–(9)).
- **B2.4:** `captured_at` is read as text so a microsecond edit is caught (Verification (13));
  the write transaction takes the consignment lock first and, for an officer, re-reads the
  alerts so the new one shows.
- **B2.5:** the QR code rule is shared with sync (`QR_CODE_PATTERN` exported from
  `stepPayload.js`).
- **B2.5a:** a malformed percent-escape in any path parameter answers 400, not a logged 500
  (Verification (14)).

| Sub-step | Contents | Size |
|---|---|---|
| **B2.1** Reader | `src/chain/rpc.js` (moved helpers), `chainReader.js` with the chain-id and code guard, fake reader, `server.js` and `services/index.js` wiring | M |
| **B2.2** Check logic | `src/services/chainCheck.js`: steps 1–5 as pure functions plus `checkStep(reader, row)`; uses `anchorHash`, `parsePayload`, `receiptEventMismatches` | M |
| **B2.3** Disclosure | `src/services/consignmentDisclosure.js`: one pure function `(viewer, consignment, steps, facts) → body`, the table above | M |
| **B2.4** Service | `src/services/consignmentService.js` `viewByQr()`: fixed SQL (consignment, steps in `(received_at, id)` order with zone name and actor role/username, `HELD`, "has accepted purchase", "has own handoff"), checks, the `record_tampered` insert; `services.consignments` | L |
| **B2.5** HTTP | `src/routes/consignments.js`, `consignmentsController.js`, `src/schemas/consignments.js` (`qrCodeParamsSchema`), `createConsignmentViewLimiter`, mounted in `app.js` | M |
| **B2.6** Docs | `api.md` "Consignment view and verification (FR-04)" with the role table, Rate limits, Roles matrix (verify and view rows → Built); `database-schema.md` `record_tampered` details and the verification rules; `contract-spec.md` §7; `decisions.md` "Verification (1)…" and limitations | S |

- **Migrations:** none.
- **Error codes:** reuse `VALIDATION_FAILED`, `FORBIDDEN`, `CONSIGNMENT_NOT_FOUND`,
  `TOO_MANY_REQUESTS`. `chain_unavailable` is a result inside a 200, never an error.
- **Audit:** none for views (reads are not audited, as for `GET /admin/anchoring`).
- **Unit tests (≈ +55):** check logic with the fixed vectors in `signing-vectors.json` (never
  regenerated): match; one changed byte in payload, key or signature; each altered column
  (weight, latitude, capture time, actor); wrong event name, address, id, actor ref, weight;
  reverted receipt; block number differs; null receipt with the node ahead (mismatch) and
  behind (unavailable); RPC error and deadline (unavailable); hash version 2. Disclosure for
  every role and state in the table, and a test that no body contains `full_name`,
  `licence_number`, `actor_ref` or coordinates where they are hidden. Reader: no key needed,
  guard refuses a wrong chain id, no URL in any error or log line (fake transport). Routes:
  guard, 403 for miner and admin, encoded `/`, bad QR code, 429.
- **DB tests (≈ +20):** `tests/db/consignmentView.test.js` with the fake reader: steps in
  custody order; flagged and rejected visible to officers only; blind weight before and after
  the transporter's own handoff; buyer refused before `in_transit` and after another buyer's
  purchase; evidence only for officer and owning buyer; a row edited by SQL after anchoring →
  `mismatch`, one `record_tampered` alert, consignment held, the next anchor waits; a second
  view adds no second alert; reader down → `chain_unavailable`, no alert. Real stack:
  register, hand off, purchase, anchor on the fake chain, scan as each role over HTTP.
- **Security checks:** the mobile app never talks to the chain; no key in the reader; RPC
  URLs never logged or returned; a chain failure is never shown as tampering; fixed SQL; the
  disclosure function is the only builder of the body; `noStore`; per-user limiter.

## 4. B3 — Account edit and soft delete (Scope (6))

### Endpoints (under the existing `/admin/users` guard)

> **Changed 15 Nov 2026 by the developer's decision (Accounts (23)):** built as
> `POST /admin/users/{id}/rename` (`{ fullName }`) and `POST /admin/users/{id}/delete`
> (`{ reason }`), not `PATCH` and `DELETE` as in the table below: the same shape as the other
> account actions and zone rename, and a `DELETE` body may be dropped by proxies or clients.

| Method and path | Body | From statuses | Answer |
|---|---|---|---|
| PATCH /admin/users/{id} | `{ fullName }` (`fullNameSchema`, strict: any other field such as `role`, `username`, `licenceNumber` → 400) | `pending`, `invited`, `active`, `suspended` | 200 `{ user }` |
| DELETE /admin/users/{id} | `{ reason }` (`reasonBodySchema`) | `active`, `suspended`, `invited` | 200 `{ user }` with `status: "deleted"` |

- **Rename:** the same name again → 200 with nothing written and no audit entry. `rejected`
  and `deleted` are final → 409 `INVALID_STATUS_TRANSITION` ("A deleted account cannot be
  changed.").
- **Delete, one locked transaction:** self → 403 `CANNOT_DELETE_SELF` before any SQL; lock the
  active admins (`LOCK_ACTIVE_ADMINS`, as suspend) → 409 `LAST_ACTIVE_ADMIN` with delete
  wording; `SELECT … FOR UPDATE` the target (404, 409 for `pending`: "use reject", `rejected`,
  `deleted`); then one `UPDATE` that sets `status = 'deleted'`, `status_reason`,
  `public_key = NULL` (device key revoked), `password_hash = NULL`, clears the activation
  code, expiry and count, and sets `tokens_valid_after = to_timestamp(<app server seconds> + 1)`
  so every token issued so far is cut off with the existing check (the app server's clock,
  as for a password change); then the audit entry.
- **Login and sessions:** with no hash, login answers `INVALID_CREDENTIALS`, the same as an
  unknown username (the invited path). `getAuthenticatedUser` also adds
  `AND status <> 'deleted'`, so a deleted account's token gets 401 `TOKEN_INVALID`, as
  `api.md` already promises, even if the cut-off were ever cleared.
- **History kept:** no row is removed; steps, alerts, approvals and audit entries keep their
  user id, and `actor_ref` stays, so anchored steps keep their meaning. The username stays
  taken (`users_username_lower_key` covers every status).

**Built** (15 Nov 2026): B3.1 `6a85bbf`, B3.2 `677764e`, B3.3 `e9d9d40`, B3.4 the docs
commit. Differences from the rows below:

- **POST routes** instead of `PATCH` and `DELETE` (the note above, Accounts (23)).
- **B3.1 adds a fourth rule,** `users_deleted_has_no_public_key`
  (`status <> 'deleted' OR public_key IS NULL`), at the developer's request, as defence in
  depth (Accounts (24)).
- **B3.2:** `notActiveError('deleted')` reuses `ACCOUNT_NOT_ACTIVE` with its own message
  rather than a new code (Accounts (27)); the login audit reason became `account_<status>`,
  so a deleted account is not logged as invited (Accounts (26)); the admin-race test follows
  the zone deactivate test, because suspend has no two-connection test (Accounts (30)).
- **B3.3:** the real-stack test makes the miner by registration and approval, since
  `POST /admin/users` creates only officers and administrators.

> **Production migration: done 15 Nov 2026, about 22:30.** `1794528000000_users-deleted` was
> run against the production database from the laptop, with `verify-full`, after a backup and
> **before** the pull request containing B3 was merged (`docs/deployment.md`, "Migrations
> after the first deploy"). Merging deploys automatically, and Render runs no migrations.

| Sub-step | Contents | Size |
|---|---|---|
| **B3.1** Migration | `backend/migrations/1794528000000_users-deleted.sql`: `users_status_valid` adds `deleted`; `users_status_reason_required` covers `deleted`; `users_password_only_when_invited` replaced by `users_password_null_when_invited_or_deleted` (`(password_hash IS NULL) = (status IN ('invited', 'deleted'))`); Down refuses while deleted rows exist (as users-activation). `tests/db/usersDeleted.test.js`; update the tests that assert the old constraint name | M |
| **B3.2** Service | `accountService.rename()` and `.deleteAccount()`; `ACCOUNT_STATUSES` adds `deleted` (list filter); `userService.getAuthenticatedUser` refuses deleted; `accountStatus.js` entry for `deleted`; `ACCOUNT_EVENT_ACTIONS` in `reportService.js` adds `user.rename` and `user.delete` | M |
| **B3.3** HTTP | `adminUsers.js` routes, controller methods, `renameUserBodySchema`; `createAccountEditLimiter` (20 per 15 min per admin, PATCH and DELETE together, after the guard), `rateLimits.accountEditsPerAdmin` | M |
| **B3.4** Docs | `api.md`: endpoints table, account statuses (six), shared rules and errors, the two sections, Rate limits, matrix row "Change an account's role; delete…" replaced; `database-schema.md` users rules and the deleted status; `decisions.md` "Accounts (21)…" and limitations | S |

- **Error codes:** reuse `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND`,
  `INVALID_STATUS_TRANSITION`, `LAST_ACTIVE_ADMIN`, `TOKEN_INVALID`, `INVALID_CREDENTIALS`;
  new 403 `CANNOT_DELETE_SELF`.
- **Audit:** `user.rename` (entity `user`, details `{ field: "fullName" }`, see §6 Q5) and
  `user.delete` (`{ from, to: "deleted", reason, keyFingerprint | null }`), same transaction.
- **Unit tests (≈ +25):** schemas (strict PATCH body, blank and over-long names, reason
  rules); routes (guard, 400 order, each error passed through, 429, limiter fail-closed);
  `notActiveError('deleted')`.
- **DB tests (≈ +30):** migration constraints with names; rename for each allowed status and
  each refused one; same name writes nothing; delete from active, suspended and invited; the
  key, hash and code gone; login → `INVALID_CREDENTIALS`; an earlier token → 401
  `TOKEN_INVALID`; the username can't be reused; steps, alerts and reports still show the
  user; self, last admin, two admins deleting each other at once (`pg_locks`, as for suspend);
  a second delete → 409; audit failure → nothing saved; Down refuses with a deleted row.
- **Security checks:** admin only; role, username and licence never editable; no hash, key or
  code in any answer or audit entry (fingerprint only); one transaction; the last-admin lock;
  the deleted account cannot sign in by any path (`/auth/login`, `/auth/activate`, old
  tokens).

## 5. Build order and totals

1. **B1.1 → B1.4.** Officers need the alerts list first (Scope (2)), it touches no chain code,
   and B2's `record_tampered` alerts are closed through it.
2. **B3.1 → B3.4.** Small and independent; it lands the only migration early, so the dev,
   test and Render databases are migrated once.
3. **B2.1 → B2.6.** The largest piece and the one with network risk; B2.1 can be built and
   committed on its own if the day runs short. **Built 15 Nov 2026** (hashes above §3's
   sub-step table).

Each sub-step is one commit with `npm test` and `npm run test:db` passing. Totals: about +110
unit and +78 DB tests; one migration. Render needs `npm run migrate` against the production
database after B3.1 (from the laptop, `verify-full`, per `deployment.md`).

**Production migration timing (still to do, B3 is built).** The B3.1 migration must be run against the production
database from the laptop, with `verify-full` as `deployment.md` describes, **before** the pull
request containing B3 is merged. Merging to `main` deploys to Render automatically, so code
that writes `status = 'deleted'` would otherwise go live against the old constraints.

## 6. Risks and open questions

**Questions (recommendation first):**

1. **Derived step status for several alerts** (§1) instead of a literal "dismiss → cleared".
   Recommended; it is Scope (5)'s intent, and the literal rule can overturn a rejection.
   **Decided 15 Nov 2026:** yes, derived step status.
2. **Refuse clearing duplicates, second purchases and `handoff_order` steps** with
   `STEP_CANNOT_BE_CLEARED`. Recommended: the database or the contract would refuse them
   anyway. **Decided 15 Nov 2026:** yes, refuse with `STEP_CANNOT_BE_CLEARED`.
3. **`record_tampered` closes:** the step's `review_status` is left alone (the CHECK forbids
   anything else), and closing releases the hold. The view keeps showing `mismatch` on every
   scan, because the check is live. The fix is restoring the row from a backup. Accept, or
   keep a tampered consignment held until it verifies again (needs more work).
   **Decided 15 Nov 2026:** accepted as described (closing releases the hold, the view keeps
   showing `mismatch`, the fix is restoring from a backup), recorded as a known limitation.
4. **Notes length 3–500**, the same as reasons, or longer (for example 2000) for case notes.
   **Decided 15 Nov 2026:** 3–500 characters.
5. **`user.rename` details:** recommended `{ field: "fullName" }` only, because the audit log
   is append-only and a name typed there can never be removed; the alternative `{ from, to }`
   keeps the history of names. **Decided 15 Nov 2026:** `{ field: "fullName" }` only.
6. **Delete needs a reason** (as suspend) and is allowed from `active`, `suspended` and
   `invited`, not `pending` (reject exists). Also: should deletion clear the password hash
   (recommended: login then answers like an unknown user) or keep it.
   **Decided 15 Nov 2026:** reason required; delete allowed from `active`, `suspended` and
   `invited`; the password hash is erased.
7. **Rate limits for the existing admin account actions** (approve, reject, suspend, …):
   leave as they are (recommended now), or add them to `createAccountEditLimiter` later.
   **Decided 15 Nov 2026:** leave the existing admin actions as they are; they are on the
   final review list.
8. **A buyer scanning a consignment that is not in transit gets 404**, the same as an unknown
   code. Alternatively 403 `FORBIDDEN`, which reveals the code exists.
   **Decided 15 Nov 2026:** 404.

**Risks:**

- **The view writes.** A GET can insert a `record_tampered` alert. Idempotent through the
  unique constraint, but it means any transporter's scan can hold a consignment if the
  database was altered. That is the intent, and false alarms are prevented by never treating
  chain errors as mismatches.
- **A deep reorg** could make a confirmed step's receipt disappear. Step 4 calls it
  `mismatch` only when the node is past the block; on Sepolia, with 2 confirmations, this is
  accepted as a known limit.
- **Only one `record_tampered` alert per step ever** (`alerts_one_per_rule_per_step`). After
  one is closed, a later mismatch on the same step raises no new alert (known limit; the
  result still shows `mismatch`).
- **RPC quota and latency.** Each view costs about 1 + n calls. The 60-per-15-minute limiter
  and the 8 s deadline bound it; a receipt cache (receipts deep enough never change) is a
  possible later step, not planned.
- **Render cold start** (50–60 s) still dominates the first scan after idle.
- **Sync during a delete.** Sync reads the device key `FOR SHARE` and the delete locks the
  user row `FOR UPDATE`, so the two run one after the other. A sync that reads the key after
  the delete commits finds `NULL` and answers `deferred` `NO_DEVICE_KEY`, so nothing is
  stored; one that read it first finishes before the delete. Covered by a DB test in B3.2.
- **Migration on Render** must run before the B3 code is deployed, or deletes fail on the old
  constraint.
