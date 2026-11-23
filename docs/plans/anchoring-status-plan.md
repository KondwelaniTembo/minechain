# Anchoring status plan

Status: **done, 5/5** (approved 23 Nov 2026, Q1–Q5 as proposed (A); phone check passed
23 Nov, 02:00–02:07).
T1–T3 run one after another without stopping (CLAUDE.md, "Flow per feature"); the next
stop is the T4 phone check.

Branch: `feature/anchoring-status`, created by the developer from `main` after PR #22.

## 1. Goal

Scope (11), decided by the developer on 23 Nov (option A): the administrator's
**"Anchoring" tile opens a read-only status screen**, so the last "Coming soon" tile in the
app does something. It shows whether steps are reaching the blockchain, and if not, why.
"Run now" and "Retry" stay API-only.

With it, **two wording fixes** found in the verification fix's production check (23 Nov):

- the notes warning says "Kept for ever in the audit log": it becomes "forever";
- an alert raised by a missing blockchain transaction reads "The other details no longer
  matches the blockchain." (wrong verb, and "other details" says nothing).

**App only** (`mobile/` and `docs/`). `GET /admin/anchoring` exists and is deployed (api.md,
"Anchoring administration"); nothing deploys to Render.

This is not FR-14. The dashboard is the officer's analytics view and gets its own plan.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| `GET /admin/anchoring`: worker, counts, in flight, failed, waiting, held, last activity, problems; admin only, not rate-limited, no chain call | `backend/`, api.md | everything the screen shows |
| The anchoring codes (`ANCHORING_*`, problem codes, `anchor_error` codes) | `core/errors/api_codes.dart` | words for codes |
| `ApiClient`, the admin APIs' pattern (api → repository → controller) | `admin_zones_api.dart`, `admin_zones_repository.dart`, `zones_list_controller.dart` | the same layers |
| The password asked again when the session ends, then the read sent again | the zones and accounts lists (`ZonesNeedPassword`) | a session that ends on this screen |
| `AppText.chainWaiting`, `chainSent`, `chainConfirmed`, `chainFailed` | the reports filters | the four counts, same words everywhere |
| "Anchoring" tile with `showComingSoon` | `admin_home_screen.dart` | the way in |

## 3. The screen (`/admin/anchoring`)

Top to bottom; a section with nothing in it is left out. Times in local time, as elsewhere.
A refresh button in the app bar and pull-down refresh; "Updated 00:45" under the heading.

1. **Worker state**, one line and a colour:

   | `worker.state` | Words |
   |---|---|
   | `running` | Running: steps go to the blockchain on their own. |
   | `paused` | Paused: the wallet cannot pay, the fee is too high, or a sent step is waiting. |
   | `backoff` | Cannot reach the blockchain right now. Trying again. |
   | `stopped` | Stopped. The server must be fixed and restarted. |
   | `not_started` | Not started: the startup check did not pass. |
   | `disabled` | Anchoring is switched off on this server. |
   | anything else | State not known to this app version. |

2. **Problems**: the server's own messages, one per line, or "No problems."
3. **Counts**: Waiting · Sent, not confirmed yet · On the blockchain · Failed (approved steps
   only, as the server counts them; a flagged step waits for an officer, not the chain).
4. **Last activity**: "Last put on the blockchain: 22 Nov, 21:14" and "Worker last ran:
   00:41, nothing to send" (the tick's outcome in words).
5. **Waiting**: the oldest waiting time; how many are on held consignments ("an officer
   must decide first"); how many are behind a failed step.
6. **Sent, not confirmed yet** (`inFlight`): step type, "sent 10 minutes ago", "Stuck" when
   the server says so, the last refusal's code, and the transaction hash with Copy.
7. **Failed** (newest 50): step type, code, attempts, when, and "Can be retried" when the
   server says so (no button, Scope (11)).
8. **Held consignments**: QR code, steps waiting, open alerts.
9. **Wallet and contract**: the recorder wallet address ("Fund this one with Sepolia test
   ETH when it runs low") and the contract address, each with Copy. Both are public.

## 4. Subtasks

- **T1 Wording fixes** (about 30 min).
  - `AppText` "Kept for ever" → "Kept forever".
  - `noLongerMatches`: the verb follows the noun, so "other details" takes "match" (Q4).
  - An alert whose only field is `chain_tx_hash` reads "The blockchain transaction for this
    step could not be found." (Q4, `alert_words.dart`).
  - Tests: the sentences, one alert detail widget test per case; tests that look for the
    old text change by decision, with a comment and a `testing-log.md` note.
- **T2 Data** (about 45 min).
  - `admin/domain/anchoring_status.dart`: the parts of the answer the screen shows, read
    leniently (an unknown state or outcome is kept as unknown; a malformed answer is a
    failure, never a crash). Big numbers (`nonce`) stay text.
  - `admin/data/admin_anchoring_api.dart` (`status()`) and
    `admin_anchoring_repository.dart`.
  - Tests: the full api.md example, every `null` the docs allow, an unknown state, a
    malformed answer; a fake server `test/fakes/fake_anchoring_server.dart`.
- **T3 Screen** (about 90 min).
  - `admin/presentation/anchoring_status_controller.dart` (loading, needs password,
    failed, loaded; refresh keeps the old answer on screen while it loads),
    `anchoring_words.dart`, `anchoring_screen.dart`; route `AppRoutes.adminAnchoring`
    (`/admin/anchoring`); the tile wired with `push()`.
  - Tests: each worker state's words; problems and "No problems."; empty sections left
    out; stuck, refused and retryable rows; Copy; refresh and pull-down; the password
    state; a failure with "Try again"; text 2.0 in portrait and landscape. In
    `homes_test.dart`, the admin's "Coming soon" case goes, changed by plan: no tile says
    it now (comment and `testing-log.md`).
- **T4 Phone check** (the developer, about 15 min): see section 5.
- **T5 Docs** (about 20 min): decisions "Anchoring app (1)–(n)" and known limitations,
  `progress.md`, `testing-log.md`, the PR text.

## 5. The phone check (T4)

The emulator or the A57, as the administrator, on production:

1. Home → "Anchoring": "Running", "No problems.", counts that make sense (0007's three
   steps and 0008's two among "On the blockchain"), "Last put on the blockchain" a time on
   20–21 Nov or later.
2. Pull down: "Updated" changes.
3. Airplane mode, refresh: a plain failure, the last answer still shown; airplane mode off,
   "Try again" works.
4. Copy the wallet address; paste it somewhere to check it is whole.
5. As `officer_demo` on the A57, open any open alert and tap "Clear, no problem": the
   warning says "Kept forever in the audit log", then Cancel. (The missing-transaction
   sentence needs no phone step: T1's widget tests cover it.)

Screenshots: `anchoring-status-running.png`, `anchoring-status-offline.png`.

## 6. Known limitations (to record in T5)

- Read-only: "Run now" and "Retry" stay in the API (Scope (11)).
- No wallet balance: the status makes no chain call by design (api.md); the preflight log
  line on Render has it.
- No live updates: it refreshes when opened, on the button and on pull-down (Q2).

## 7. Questions

- **Q1. What the screen shows.**
  **(A, proposed)** All nine parts of section 3, the summary first. (B) Only the state,
  problems, counts and last activity. A is the same answer with more of it shown; the
  details are what an administrator needs when something is wrong.
- **Q2. Refreshing.**
  **(A, proposed)** When opened, the refresh button and pull-down, as the other admin
  lists. (B) Also every 30 s while open. B costs requests on a free server that sleeps.
- **Q3. Naming a step in "Sent" and "Failed".**
  **(A, proposed)** Its type and a short step id, with Copy for the full one. (B) Add the
  QR code to those rows on the server: a `backend/` change that deploys, for a rare case.
- **Q4. The missing-transaction alert sentence.**
  **(A, proposed)** When `chain_tx_hash` is the only field: "The blockchain transaction for
  this step could not be found."; and "other details" takes "match". (B) Only the verb.
- **Q5. Failed steps that can be retried.**
  **(A, proposed)** Say "Can be retried" with no button. (B) Leave it out, as the app cannot
  retry. A tells the administrator a retry through the API is worth trying.
