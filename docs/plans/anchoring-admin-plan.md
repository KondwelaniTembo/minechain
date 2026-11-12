# Anchoring status and recovery — approved plan (12 Nov 2026)

**Status: built 12 Nov 2026 in N1–N5.** N1 `88ded46`, N2 `de7003c`, N3 `3769508`, N4 `6c67172`; N5 is the docs commit that adds this line. What was built, and where it differs from this plan, is in `docs/api.md` ("Anchoring administration"), `docs/database-schema.md` ("Admin status and retry") and `docs/decisions.md` ("Anchoring admin (1)–(12)").

Plan-only output reviewed in chat on 12 Nov 2026; built in sub-steps N1–N5.

## Decisions (12 Nov 2026)
1. The status shows the recorder and contract addresses (public on Sepolia; an admin needs the recorder address to fund it).
2. A retry changes the database only (no chain read inside the HTTP request).
3. Build "run one tick now".

## Requirement (proposal, System Administrator use case, in our words)
Monitor system health including blockchain synchronisation failures; an automated alert when one is detected; a manual re-synchronisation; every admin action in the audit trail. Mapping: monitoring = status view; automated alert = a `problems` list in that view (anchoring failures are not officer alerts — Anomaly rules (8)); re-synchronisation = run-now plus a safe retry for failed steps. A push notification needs the FCM token table (D10), which does not exist: known limitation.

## Findings that shape the design
- The worker already recovers every case it can prove safe: reconcile confirms a submitted row when the receipt or the on-chain dataHash shows it, returns it to pending only when another transaction used its nonce or it was mined and reverted, otherwise re-signs with the same nonce. A row is truly stuck only when its nonce is unused and the resend is refused (dry run refused, or fee above ANCHOR_MAX_FEE_GWEI); today that only logs a warning.
- recordHandoff is not idempotent on-chain: the contract accepts it from InTransit as well as Registered (relays). Releasing a stuck handoff while its signed copy may still be mined could anchor it twice. Registrations are protected by ALREADY_EXISTS; handoffs and purchases are not.
- Worker state lives only in memory; server.js creates the worker outside createApp; anchor:once runs in a separate process (its ticks appear only in the rows).

## 1. GET /admin/anchoring — status (database + worker memory only, no chain calls, no secrets)
Response shape:
- `worker`: `state` (running | backoff | paused | stopped | not_started | disabled), `startedAt`, `lastTick { at, outcome, code, stepId }`, `recorderAddress`, `contractAddress`.
- `counts`: pending / submitted / confirmed / failed — approved steps only (passed or cleared).
- `inFlight[]`: stepId, consignmentId, type, chainTxHash, nonce, submittedAt, ageSeconds, `stuck` (submitted > 5 min — STUCK_AFTER_SECONDS moved into anchorQueue.js and shared with anchor:once), `lastRefusal`.
- `failed[]` (newest 50): stepId, consignmentId, type, code and detail split from the fixed anchor_error text, error, attempts, chainTxHash, updatedAt, `retryable` (allow-list in §2).
- `pending`: oldestReceivedAt, oldestAgeSeconds, onHeldConsignments, behindFailedStep, sendableNow (nextEligibleStep without FOR UPDATE) — computed with the queue's own HELD and ordering SQL exported from anchorQueue.js.
- `held[]`: consignmentId, qrCode, pendingSteps, openAlerts.
- `lastConfirmed`: stepId, anchoredAt.
- `problems[]`: WORKER_DISABLED, WORKER_NOT_STARTED, WORKER_STOPPED, WORKER_BACKOFF, WORKER_PAUSED, STUCK_SUBMITTED, FAILED_STEPS, NO_RECENT_TICK (last tick older than three intervals, or older than the backoff cap while backing off).
- Never contains RPC URLs, keys, ANCHOR_* secrets, provider text or personal data.
- No heartbeat table: the process answering the status also runs the timer, so a worker snapshot (startedAt, preflight result — names of failed checks only — and each tick's `{ at, outcome, code, stepId }`) is accurate. To cover anchor:once ticks, the status also reads the latest anchor_submitted_at and anchored_at from the rows.

## 2. Recovery, state by state
**failed → pending (retry): allow-list only.**

| anchor_error code | Retry? | Why |
|---|---|---|
| INVALID_STAGE:None | Yes | Registration may be on-chain now; the dry run checks again |
| UNKNOWN | Yes | Often transient; the dry run checks again |
| MAX_ATTEMPTS | Yes | A reverted transaction changed nothing on-chain |
| INVALID_STAGE:Registered / InTransit / Purchased | No | The chain's stage forbids it; it would fail again |
| INVALID_INPUT:*, STEP_TYPE_UNKNOWN, BYTES32_INVALID, WEIGHT_INVALID | No | Data the contract refuses; a backend bug |
| ID_ALREADY_ANCHORED | No | Needs investigation |
| RECEIPT_MISMATCH:* | Never | Something was written on-chain; a retry could anchor twice |

The allowed codes cannot be on-chain by the worker's own rules, so a database-only retry is safe. One statement:
`UPDATE transactions SET anchor_status='pending', anchor_attempts=0, chain_tx_hash=NULL, anchor_nonce=NULL, anchor_submitted_at=NULL, anchor_error='RETRY_REQUESTED: an administrator asked for this step to be tried again' WHERE id=$1 AND anchor_status='failed'`. The previous error, attempts and hash go into the audit entry.

**Stuck submitted: no admin release (fixed procedure).** Reconcile already releases every provably safe case. For "nonce unused, resend refused": the status shows the step (stuck, age, nonce, hash); worker change — when a resend is refused, write the refusal as fixed text into that row's anchor_error, WHERE the hash still matches, so `lastRefusal` shows it. Procedure: fee or funds → raise ANCHOR_MAX_FEE_GWEI or fund the wallet, the worker resends with the same nonce; refused dry run → a bug, stop and investigate; last resort (future, worker-owned script only) burn the nonce with a 0-value self-transaction — never by hand.

**confirmed: never touched.** **Pending held by an alert or behind a failed step:** no action here (an officer releases holds; retrying the failed step frees the steps behind it).

## 3. POST /admin/anchoring/run — one tick now
Calls runOnce() on the same service instance as the timer (shares the stopped flag and the advisory lock). Refusals, all 409: ANCHORING_DISABLED (ANCHOR_ENABLED false), ANCHORING_NOT_STARTED (preflight failed), ANCHORING_STOPPED, ANCHORING_BUSY. Returns `{ outcome, reconciled, stepId, code }`; one tick only, never "until idle". Useful after a fix; does not solve Render spin-down (any request wakes the service anyway).

## 4. Concurrency
Run-now takes the session advisory lock (tryAnchorLock), never waits. Retry is a single UPDATE … WHERE anchor_status='failed' (the worker never writes failed rows); a second concurrent retry matches nothing → 409. Status uses plain reads.

## 5. Endpoints
Router guard: noStore, requireAuth, requireRole('admin') (403 even on unknown paths).

| Method and path | Body | Answer |
|---|---|---|
| GET /admin/anchoring | none (strict empty query) | 200 status |
| POST /admin/anchoring/run | none or {} | 200 { summary } |
| POST /admin/anchoring/steps/{id}/retry | { reason } (reasonBodySchema, 3–500) | 200 { step } |

Errors: VALIDATION_FAILED; 404 STEP_NOT_FOUND; 409 INVALID_STATUS_TRANSITION ("Only a failed step can be retried. This step is pending." via withArticle); 409 ANCHOR_NOT_RETRYABLE ("This step failed for a reason a retry cannot fix (RECEIPT_MISMATCH). It needs investigating."); 409 ANCHORING_DISABLED / NOT_STARTED / STOPPED / BUSY. Limiter createAnchoringActionLimiter: 20 per 15 minutes per admin on the two POSTs, fails closed without requireAuth; GET unlimited. Audit: `anchoring.run` (no entity; { outcome, code, stepId }); `transaction.anchor_retry` (entity transaction; { reason, previousError, previousAttempts, previousTxHash }). Refusals and the GET are not audited.
Wiring: createAnchorWorkerFromConfig returns { start, stop, runNow, snapshot }; server.js passes it to createApp as services.anchoring (null when disabled — status then shows the database side with state "disabled"); a new anchorStatusService holds the queries and the retry.

## 6. Testing with the fake chain
Produce states by driving the fake chain (inserted rows only for INVALID_INPUT): INVALID_STAGE:None and UNKNOWN via revertNextEstimate with low maxAttempts; MAX_ATTEMPTS via revertNextMined; RECEIPT_MISMATCH via the mismatched event. Stuck: send → dropTransaction → move the clock past the grace period → fee above the cap → row stays submitted with lastRefusal FEE_TOO_HIGH, nothing can change it → lower the fee, run-now → same-nonce resend confirms; refused dry run on resend → stays submitted with the refusal stored; nonce taken by hand → reconcile returns it to pending by itself. Retry: each allowed code → pending → confirmed after a tick; each refused code → ANCHOR_NOT_RETRYABLE with row and audit unchanged; pending/submitted/confirmed → 409; unknown id → 404; audit holds previous error and hash; nothing saved when the audit write fails; a second retry → 409. Run: each 409 state, summary passed back, anchoring.run written. Status: exact keys, counts, held and behind-failed with a real open alert, oldest age from the injected clock, last confirmed, each problems code, and no RPC URL, key or ANCHOR_ value anywhere in the body (fake config with marked fake secrets). Routes: guard, no-store, validation, 429, errors passed through.

## 7. Sub-steps
| Step | Contents | Approx. tests |
|---|---|---|
| N1 | Worker snapshot + runNow (refusal states, shared service); store resend refusal on the submitted row; one STUCK_AFTER_SECONDS (anchorWorker.js, anchorService.js, anchorQueue.js, cli/anchorOnce.js) | +12 unit, +4 DB |
| N2 | anchorStatusService.status(), allow-list constant, splitting anchor_error (exported SQL fragments from anchorQueue.js; services/index.js) | +5 unit, +18 DB |
| N3 | retry() and run(), each audited | +16 DB |
| N4 | Routes, controller, schema, limiter, wiring through server.js and createApp, route tests, real-stack test (stuck → fee fixed → run now; failed → retry → confirmed) | +35 unit, +4 DB |
| N5 | Docs: api.md, database-schema.md (Anchoring), decisions.md ("Anchoring admin (1)…" + limitations: no admin release for submitted, no push alert, anchor:once ticks missing from the snapshot, spin-down), CLAUDE.md | 0 |
Totals: about +52 unit, +42 DB; no migration.