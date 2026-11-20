# Officer alerts plan

Status: **approved** (20 Nov 2026, Q1–Q6 as proposed). T1–T4 done, run without stopping
as agreed; T5 phone check done (21 Nov), and it found two misleading lines, fixed in T5b
and re-checked on the A57; T6 done. **7/7.**

Branch: `feature/officer-alerts`, created by the developer from `main` after PR #17.

## 1. Goal

FR-08 for the regulatory officer, delivered as the in-app alerts list of Scope (2) (push
notifications are a future improvement). The officer opens **"Alerts"** on their home and
sees the open alerts, oldest first. They open one and read, in plain words, what the check
found, which step and consignment it is on and who recorded it. Then they close it with
**"Confirm problem"** or **"Clear, no problem"**, with a short note.

**App only** (`mobile/` and `docs/`). The four endpoints exist since B1 (api.md, "Alerts
(FR-08)"): `GET /alerts`, `GET /alerts/{id}`, `POST /alerts/{id}/review`,
`POST /alerts/{id}/dismiss`. Nothing deploys to Render.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| The four alert endpoints, officers only, notes 3–500 characters, 60 decisions per 15 min, `Cache-Control: no-store` | `backend/`, api.md "Alerts (FR-08)" | everything this feature reads and does |
| The alert view: `id, type, severity, status, details, createdAt, step, consignment (qrCode, mineral, stage, held), actor (username, role), review`; the detail adds `otherAlerts` | api.md "The alert view" | the models (T1) |
| `details` per alert type, weights as whole milligrams in text | database-schema.md "alerts" | the plain-word sentences (T1) |
| A list with pull-down refresh, "Show more" paging, a dialog with a reason field, the session and network states | `admin/` "Account requests" (A1) | the pattern for the list and the decision (T2, T4) |
| `ApiClient`, the token and password-prompt handling, `failure_text.dart` | `core/` | the calls and their errors |
| Weights in the mineral's unit from milligrams (`weightInUnit`, `unitSymbol`) | `registration/` | "1.6 kg" in the sentences |
| The officer home: "Alerts" (primary tile), "Check a consignment" (built), "Reports" and "Audit trail" say "Coming soon" | `officer_home_screen.dart` | the way in |
| The "I have an activation code" screen | `auth/presentation/activate_screen.dart` | the officer's first sign-in (T5) |

## 3. How it fits

- **Actors:** the regulatory officer only. An administrator gets 403 from every `/alerts`
  path (Scope (5)), and the app keeps every other role out by redirect rule 4: all paths
  sit under `/officer`.
- **Where alerts come from:** sync's anomaly checks (duplicate, quantity, GPS zone,
  signature, handoff order) and the consignment view's chain check (`record_tampered`).
  This feature creates none; it reads and closes them.
- **What a decision does on the server:**
  - "Confirm problem" (review): the alert is `reviewed`, its step `rejected` and never
    anchored; the stage does not move.
  - "Clear, no problem" (dismiss): the alert is `dismissed`; the step is `cleared` once none
    of its alerts is open or reviewed, then anchored like a passed step. A cleared handoff
    or purchase moves the stage forward.
  - The hold is released when no alert on the consignment is open.
  - Three steps can never be cleared (409 `STEP_CANNOT_BE_CLEARED`): a duplicate
    registration, a second purchase, any step with a `handoff_order` alert.
  - A decision cannot be undone (known limitation, Alerts).
- **The test case waiting on production:** MC-2026-LSK-0008. Its handoff (1.6 kg against a
  2 kg registration) is open as `quantity_discrepancy` and holds the consignment, and the
  buyer's 1.6 kg purchase waits on the emulator (`STAGE_NOT_READY`). Clearing the handoff
  moves the stage to `in_transit`; the buyer's next send is then accepted by the stage rule
  but flagged again, because it is also more than 10% off the registration. That second
  alert shows a purchase alert and the other decision.

## 4. The screens

1. **Alerts list** (`/officer/alerts`). Open alerts, oldest first (the server's order),
   20 at a time with "Show more". Each card, never colour alone:
   - the finding as a heading ("Weight differs by more than 10%");
   - the severity as an icon and a word ("High", "Medium", "Low");
   - the QR code and mineral; "Handoff by transporter patsani"; "Raised 20 Nov, 14:56";
   - "Holds this consignment" while `held`.

   Pull down to refresh; also read again when the screen opens and when coming back from
   an alert. Empty: "No open alerts." Offline, slow, an ended session: the shared sentences
   and "Try again" (or the password prompt), as on "Account requests".
2. **Alert detail** (`/officer/alerts/{id}`):
   - **What the check found**, in sentences from `details` (examples below);
   - **The step**: its type, who recorded it (username and role), the phone's time and when
     the server received it;
   - **The consignment**: QR code, mineral, stage in words, held or not;
   - **Other alerts on this consignment** (`otherAlerts`): finding, status, when; with the
     sentence "Clearing this alert does not release the consignment while another is
     open." when one is open;
   - **open:** two buttons, "Confirm problem" and "Clear, no problem";
   - **closed:** the decision, who made it, when, and the notes.
3. **The decision** (a dialog, like "Reject request"): what it does in one sentence, a notes
   field (3–500 characters, a counter, an example hint, "Kept for ever in the audit log. Do
   not add personal details."), "Cancel" and the decision's button, enabled at 3 characters.
   On success: back to the list, which no longer shows the alert, and a message built from
   the answer, for example "Cleared. MC-2026-LSK-0008 is no longer held. Stage: On its way."
   Refusals keep the dialog's notes and say why (409 already closed by another officer, 409
   cannot be cleared, 429, offline).

The sentences from `details` (T1), weights in the mineral's unit, worked out from the
milligram text with whole numbers only:

| Type | Heading | Sentence |
|---|---|---|
| `quantity_discrepancy` | Weight differs by more than 10% | "This handoff: 1.6 kg. The registration: 2 kg. This handoff is 0.4 kg (20%) lighter." One line per baseline in `details` (the registration, the previous step), the failed ones first |
| `gps_zone` | Registered outside the licensed zones | "142 m outside ZCAS Campus (demo); 25 m is allowed." or "No licensed zone was active." |
| `duplicate_consignment` | QR code already registered | "Registered before by the same miner." / "… by another miner."; both minerals when they differ |
| `invalid_signature` | Signature does not match | "The signature was not made by this account's registered device key (50a03528)." |
| `handoff_order` | Recorded after the purchase | "This handoff was recorded after the consignment was bought." |
| `record_tampered` | Record changed after it was put on the blockchain | "The weight no longer matches the blockchain." (`fields` in words) |
| anything else | Unknown alert | "This version of the app cannot show its details." (the decisions still work) |

## 5. Subtasks

- ✅ **T1 Alerts data and words** (about 45 min).
  - `alerts/domain/alert.dart`: `Alert`, `AlertType`, `AlertSeverity`, `AlertStatus`, the
    step, consignment, actor and review parts, `OtherAlert`, `AlertDecisionResult`;
    `fromJson` that returns null for anything unreadable.
  - `alerts/domain/alert_words.dart`: the heading and the sentences per type (§4),
    plain Dart, BigInt arithmetic on the milligram text.
  - `alerts/data/alerts_api.dart` and `alerts_repository.dart`: `openAlerts(offset)`,
    `alert(id)`, `confirmProblem(id, notes)`, `clear(id, notes)`, with the session and
    password-prompt handling the admin repository uses.
  - `api_codes.dart` and `failure_text.dart`: `ALERT_NOT_FOUND`, `STEP_CANNOT_BE_CLEARED`
    (the server's message shown as given), `INVALID_STATUS_TRANSITION` for an alert.
  - Tests: api.md's examples parsed; one unreadable alert makes the page unreadable (as
    for account requests); the paths, query and body sent; every type's sentence, the
    weights in kg and g, a gain and a loss, an unknown type; each error code's sentence.
- ✅ **T2 Alerts list** (about 60 min).
  - `/officer/alerts` (`AppRoutes.officerAlerts`); the "Alerts" tile wired; other roles kept
    out.
  - The list of §4.1 with paging, pull-down refresh, refresh on open and on return, and
    the empty, offline, slow and ended-session states.
  - Widget tests with a fake server: cards in the server's order with every line; "Show
    more"; refresh; empty; each failure; held; text 2.0 in portrait and landscape; the
    officer tiles in `homes_test.dart` ("Alerts" opens its path; "Reports" and "Audit trail"
    still "Coming soon").
- ✅ **T3 Alert detail** (about 50 min).
  - `/officer/alerts/:id`, opened from a card; the sections of §4.2 for open and closed
    alerts; `otherAlerts` with the hold sentence; not found (404) and the failures.
  - Widget tests: each section from a fake answer; a closed alert shows its decision and no
    buttons; other alerts; 404; text 2.0 in portrait and landscape.
- ✅ **T4 The two decisions** (about 60 min).
  - The dialog of §4.3; the answer's message; back to the list without the alert.
  - Widget tests: notes under 3 characters keep the button off and over 500 are refused
    as typed; the body sent is exactly `{ "notes": … }` trimmed; each answer's message
    (cleared and moved, cleared still held, confirmed); 409 already closed (the list is
    read again); 409 cannot be cleared (the server's sentence, "Confirm problem" still
    there); 429; offline; an ended session; a double tap sends once.
- ✅ **T5 Phone check** (the developer, about 40 min; see Q5).
  - An officer account: created with the admin's token (Q5), then activated in the app
    with "I have an activation code".
  - On the A57 as the officer:
    - the list shows 0008's `quantity_discrepancy` (handoff by the transporter) and any
      older open alerts;
    - its detail: "This handoff: 1.6 kg. The registration: 2 kg …", held;
    - "Clear, no problem" with a note: "no longer held, Stage: On its way";
    - on the emulator as the buyer, "Send my work", Send now: the purchase is accepted and
      "under review" (more than 10% off);
    - back on the A57, refresh: the new purchase alert; "Confirm problem" with a note: the
      step is rejected, never anchored;
    - "Check a consignment" on 0008 as the officer: the handoff cleared and on the chain
      after anchoring, the purchase not.
  - Screenshots for the thesis (names in the T5 report).
  - **Result (20 Nov 23:46 – 21 Nov 00:27, A57 as `officer_demo`, emulator as buyer
    Kay):** every step as planned.
    - Officer account: created by the developer's script with `mc_adminkay` (Q5),
      "Officer officer_demo created (invited)", code valid 72 h. The first activation
      failed with "This activation code is not valid" because the username was mistyped
      (`offier_demo`; 1 of 5 attempts), the second worked.
    - List: "9 open alerts.", 0008's card last ("Weight differs by more than 10%",
      Medium, "MC-2026-LSK-0008, Copper", "Handoff by transporter Patsani", "Raised
      20 Nov, 14:56", "Holds this consignment").
    - Detail: "This handoff: 1.6 kg." and "The registration: 2 kg. This handoff is 0.4 kg
      (20%) lighter."; Stage Registered; "Held: it is not put on the blockchain while an
      alert on it is open."; "No other alerts."; both buttons.
    - Clear (00:08) with a note: "Cleared. MC-2026-LSK-0008 is no longer held. Stage: On
      its way."; "8 open alerts."; the "Cleared" list: "Cleared by officer_demo, 21 Nov,
      00:08".
    - Emulator: the waiting purchase was sent by the automatic send at 00:13 ("1 sent to
      the server — 1 under review", the 10% message); a later Send now: "There was nothing
      to send."
    - Refresh: "9 open alerts.", the new card "Purchase by buyer Kay", "Raised 21 Nov,
      00:13"; its detail adds "The previous step: 1.6 kg, the same weight." and the
      cleared handoff alert under "Other alerts".
    - Confirm (00:25): "Confirmed. The step will never go on the blockchain.
      MC-2026-LSK-0008 is no longer held. Stage: On its way."; the "Confirmed" list:
      "Confirmed by officer_demo, 21 Nov, 00:25". The cleared alert's page then reads
      "Cleared by an officer", "Not held.", the other alert "Confirmed", and the notes.
    - Check a consignment on 0008: registration and handoff "Matches the blockchain"
      with their transaction hashes, the handoff "Cleared by an officer, 1 alert, 0 open";
      the purchase "Rejected: an officer confirmed the problem".
    - The expired session asked for the password before any alert was shown.
  - **Two misleading lines found, fixed in T5b:**
    - the cleared handoff card said "Holds this consignment" at 00:19, while the purchase
      alert on the same consignment was open (the line came from the consignment, not
      the alert);
    - on the Check page the rejected purchase said "Not on the blockchain yet" and "Not
      sent to the blockchain yet", and the verdict at the top would stay "Recorded, not on
      the blockchain yet" for good, though a rejected step is never sent.
  - The confirm note typed was the expected message itself, not a reason. Harmless, but it
    is kept in the audit log; in the demo, type the officer's reason.
- ✅ **T5b Fixes from the phone check** (approved by the developer, 21 Nov).
  - `alert_widgets.dart`: "Holds this consignment" only on an open alert.
  - `verdict.dart`: a rejected step's "not on the blockchain yet" or "could not check"
    no longer counts towards the verdict (a mismatch on it still does); only rejected
    steps listed means "nothing to check". An officer now gets the verdict every other
    viewer gets, as they are never shown the rejected step.
  - `check_result_view.dart`: a rejected step's check line reads "Never put on the
    blockchain" (block icon), and "Not sent to the blockchain yet" is left out.
  - Tests: 9 new (1 list, 7 verdict, 1 Check page) and 3 lines added to the officer's
    flagged-and-rejected test. Re-check on the A57 (21 Nov), passed: the cleared card has
    no hold line; Check on 0008 reads "Verified", the purchase "Never put on the
    blockchain".
- ✅ **T6 Docs and PR** (about 20 min). `decisions.md` Officer alerts app (1)–(9),
  Verification app (11), two known limitations (Q6; decisions final) and one future
  improvement; `testing-log.md`, `progress.md`, `CLAUDE.md`, the PR description.

About 4 h of Claude Code time plus the developer's 40 minutes.

**Commits.** T1 touches only new files and the two error files, so it is its own commit.
T2, T3 and T4 all add to `app_text.dart`, `routes.dart` and `app_router.dart`, so they go in
one code commit (as T2 and T3 did for Buyer purchase). Then one docs commit after T5. If the
developer is present between subtasks, each can be committed on its own instead; the
subtask reports say which files to stage.

## 6. Questions

- **Q1 Closed alerts.** The API lists `open`, `reviewed` or `dismissed`, one at a time.
  - **(A, proposed)** A three-way switch at the top of the list: "Open", "Confirmed",
    "Cleared". Open is the default; the other two show the decision, who made it and when.
    It lets the officer (and the examiner) see past decisions without the audit trail.
  - (B) Open alerts only. Closed ones are seen in the audit trail CSV (Reports feature).
- **Q2 "Clear, no problem" on a step that can never be cleared.**
  - **(A, proposed)** The app hides "Clear" only where it is certain from the alert alone:
    a `handoff_order` alert, with the sentence "This step was recorded after the purchase,
    so it can only be confirmed." For a duplicate registration or a second purchase, both
    buttons show and the server's 409 sentence explains.
  - (B) Always both buttons; the server's 409 explains every case.
- **Q3 Offline decisions.**
  - **(A, proposed)** Decisions need the network: no queue. A decision is the officer's
    word, not a signed custody step, and a queued one could meet another officer's
    decision later (409). Offline says "No network: the decision was not sent."
  - (B) Queue decisions like custody steps. More code, and a later 409 nobody sees.
- **Q4 From an alert to "Check a consignment".**
  - **(A, proposed)** Not in this feature: the officer scans the bag's code on "Check a
    consignment" as now.
  - (B) A "Check this consignment" button on the detail that opens the check with the code
    already filled in (about 30 min more: the check screen gains a start without a scan).
- **Q5 An officer account for the phone check.** No officer exists on production, and the
  admin's "Create account" screen is part of Admin accounts (Sat 21, later).
  - **(A, proposed)** The developer runs a short PowerShell script given in chat: it asks
    for the API address and the admin's password (nothing stored, nothing printed but the
    activation code), logs in, calls `POST /admin/users` with role `officer`, and prints the
    code. The officer then activates in the app. Claude Code never runs it.
  - (B) Do the officer phone check after Admin accounts' "Create account" screen, later on
    Saturday.
- **Q6 Known limitation to record.** The transporter's "My handoffs" and the buyer's "My
  purchases" keep "Sent to the server — under review" after an officer decides: the phone
  only knows the answer sync gave. Proposed: record it as a known limitation, not fix it
  (the officer's decision is seen in "Check a consignment").
