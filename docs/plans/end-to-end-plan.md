# End-to-end test plan (shortened)

Status: **run on 23 Nov 2026, 13:41–14:51: passed** (§5). The developer ran the device
steps with small changes to the plan (§5, "Changes from the plan"); Q2 was answered with
Patsani, Q3 and Q5 as proposed (A), and Q4 both ways (one alert cleared, one confirmed).

Branch: `chore/end-to-end`, created by the developer from `main` after PR #25.

## 1. Goal

One run of the whole system as built, on production, with every role, before the
release-build timing, the final security pass, the README and the submission zip. It
shows the core flow (registration → handoff → purchase → on the chain → verified) and
one anomaly path (flagged → officer alert → decision), plus the read-only screens each
role has (reports, dashboard, anchoring status).

It is **shortened**: each feature already had its own phone check (`testing-log.md`),
so this run repeats none of their edge cases. It checks that the parts work together
on the deployed system after all the merges.

Nothing in `mobile/`, `backend/` or `contracts/` changes in this plan. A fault found is
reported and fixed on its own branch after the developer agrees (§6).

## 2. Who does what

| Part | Who |
|---|---|
| The regression pass (every automated suite) | Claude Code |
| The device steps on production (A57 and `emulator-5554`), screenshots | the developer |
| Checking the screenshots against §4, the verdict, the `testing-log.md` entry | Claude Code |
| Commit, push, PR, merge | the developer |

## 3. Before the device steps

- Both devices run the debug build of `main` after PR #25:
  - A57: `flutter run -d R5GL82G1PTV --dart-define-from-file=env/api.json`
  - emulator: `flutter run -d emulator-5554 --dart-define-from-file=env/api.json`
  (two terminals in `mobile/`; never `--uninstall` or `flutter install`.)
- Two unused QR tags, called **A** and **B** below (the next two custody record IDs,
  for example `MC-2026-LSK-0010` and `-0011`). On the emulator the camera scans the tag
  from the laptop screen or its virtual scene, as in earlier checks.
- The emulator's location (Extended controls → Location) is set before each
  registration, as stated in the step.
- Note the dashboard's "Last 7 days" counts and the open alert count before E1 (they
  were 19 steps and 8 open alerts on 23 Nov 03:53), so the changes can be checked.
- Rules on production: never deactivate "ZCAS Campus (demo)"; the officer's notes are
  kept forever, so use the sample reasons given.

## 4. Device steps and expected results

| # | Device and account | Steps | Expected | Screenshot |
|---|---|---|---|---|
| E1 | emulator, administrator (`mc_adminkay`) | Home → "Anchoring"; then "GPS zones" | "Running: steps go to the blockchain on their own.", "No problems."; "ZCAS Campus (demo)" active | `e2e-01-admin-anchoring.png`, `e2e-02-admin-zones.png` |
| E2 | emulator, miner Mutale; location -15.419000, 28.288500 (inside ZCAS) | Airplane mode on → "Register consignment", scan tag A, copper, 5.000 kg, Save → "My consignments" → airplane mode off → "Send my work" → Send now | Saved offline ("Not sent yet"); after the send "Sent" with no review message; A on the list as accepted | `e2e-03-miner-saved-offline.png`, `e2e-04-miner-sent.png` |
| E3 | A57, transporter (account in Q2) | "Take custody", scan tag A, 4.950 kg (1% lighter), Save | The custody check finds A registered with no warning; saved and sent, accepted | `e2e-05-transporter-custody.png` |
| E4 | emulator, buyer Kay | "Check a consignment", scan A; then "Record purchase", scan A, 4.900 kg, Save | Check: two steps, the registration (and, if already anchored, the handoff) "Matches the blockchain"; purchase saved and sent, accepted | `e2e-06-buyer-check.png`, `e2e-07-buyer-purchase.png` |
| E5 | emulator, miner Mutale; location -12.802400, 28.213200 (Kitwe, outside every zone) | Register tag B, copper, 2.000 kg, Save, Send now | Sent but flagged: the review message for a place outside every licensed zone | `e2e-08-miner-outside-zone.png` |
| E6 | A57, `officer_demo` | "Alerts" → the new alert for B → "Clear, no problem", reason "End-to-end test: registered outside the zone on purpose. Cleared." | Open alerts = before + 1, then back to before; the alert reads GPS zone, medium; after clearing, B is not held | `e2e-09-officer-alert.png`, `e2e-10-officer-cleared.png` |
| E7 | A57, `officer_demo`, after a few minutes (the worker anchors one step per tick) | "Check a consignment", scan A; then scan B | A: "Verified: every step matches the blockchain.", three steps; B: its registration matches (or "Not on the blockchain yet", then again later) | `e2e-11-officer-verified-A.png`, `e2e-12-officer-check-B.png` |
| E8 | A57, `officer_demo` | "Dashboard", Last 7 days; "Reports" → transactions, the last 7 days, download and share to Sheets | Steps = before + 4 (2 registrations, 1 handoff, 1 purchase); alerts by kind shows one more GPS zone; the CSV has A's three rows and B's row, no `ï»¿` | `e2e-13-dashboard.png`, `e2e-14-report-csv.png` |
| E9 | emulator, administrator | "Anchoring" again | Waiting 0 (or only steps still in their tick), "No problems." | `e2e-15-admin-anchoring-after.png` |

Covered here: FR-01–FR-11, FR-13, FR-14 and the offline path of FR-07. FR-12 (account
requests) and the account and zone changes are not repeated (Q5).

## 5. Results (23 Nov 2026, 13:41–14:51, production)

Emulator: administrator `mc_adminkay`, miner Mutale, buyer Kay. A57: transporter Patsani,
`officer_demo`. Tag A was `MC-2026-LSK-0011` (amethyst, 20 g); tag B was
`MC-2026-LSK-0012` (gold, 26 g). Checked against the screenshots and against the three
audit-trail CSV files and the transactions CSV the developer shared.

| # | Result | What was seen |
|---|---|---|
| R | ✅ | Regression pass (T1): see `testing-log.md` |
| E1 | ✅ | 13:41: "Running: steps go to the blockchain on their own.", "No problems.", 10 on the blockchain, 0 waiting or failed. Two active zones ("Typed Check Zone Two", "ZCAS Campus (demo)", 9 corners), none inactive. Offline at 14:06–14:07: the loaded screen stays and says "No internet connection…"; a refresh with no screen loaded shows the offline page with "Try again" |
| E2 | ✅ | 13:49 in airplane mode: 0011 saved in 0.1 s; "Not sent: no internet connection. Your work is safe on this phone."; "My consignments" says "Safe on this phone and waiting to be sent." 13:51 online: "started automatically", 1 sent; "Send now" then "There was nothing to send." Server received it at 13:51:27, anchored 13:51:36 |
| E3 | ✅ | A57, Patsani: 0011 found, "Mineral: Amethyst, Stage: Registered", 19.7 g (1.5% lighter), saved in 0.1 s, sent in 0.7 s, accepted. 14:00: "Verified", both steps "Matches the blockchain" |
| E4 | ✅ | 14:09 Kay's check: "Verified", two steps. 14:10: purchase 19.8 g, saved 0.1 s, sent 1.2 s, accepted. 14:25 (officer): 0011 "Verified", "Stage: Bought", three steps, each "Passed the automatic checks", "No alerts" |
| E5 | ✅ | 14:19 offline at -12.820712, 28.211633 (Kitwe): 0012 saved; 14:20 online: "Since 14:19 — sent 2 times", "under review … outside every registered extraction zone" |
| E6 | ✅ | Open alerts 8 (14:17) → 9 (14:21). Alert: "288965 m outside ZCAS Campus (demo); 25 m is allowed.", held. Cleared 14:23 with a note; "Cleared. MC-2026-LSK-0012 is no longer held. Stage: Registered."; "Cleared" tab 4 |
| E7 | ✅ | 14:25: 0012 "Recorded, not on the blockchain yet" (the step had been sent, hash shown, not yet confirmed: observation O1). 14:26: "Verified", "Cleared by an officer, 1 alert, 0 open" |
| X1 | ✅ | Not in the plan: Patsani took custody of 0012 at 25.5 g inside ZCAS (14:31, 1.9% lighter, accepted). Before saving, the check hid the weight ("Weigh it before you take custody") as designed. 14:38: "Verified", two steps |
| X2 | ✅ | Not in the plan: Kay bought 0012 at 18 g in Kitwe (14:41): flagged "Weight differs by more than 10%" (30.7% lighter than the registration, 29.4% than the handoff); "Under review" on the check; open alerts 9. Confirmed 14:46 with a note: "Confirmed. The step will never go on the blockchain. MC-2026-LSK-0012 is no longer held. Stage: On its way."; "Confirmed" tab 2. The purchase was not GPS-flagged: the zone check is for registrations only (Anomaly rules) |
| E8 | ✅ (part) | Transactions report (gold only, 25 Oct – 23 Nov, 14:27): 3 rows, the two 0001 registrations and 0012's registration, which matches the database at 14:27. Audit trails: Mutale 27 rows, consignment 0012 8 rows, Kay 14 rows, then 15 after the decision (the `alert_reviewed` row). Every row's hash, block number, zone and notes agree with the screens. Kay's key fingerprint in the audit (`50a03528…`) matches "My account". The dashboard was not shown in this run; it passed its own check at 03:53 the same day (Dashboard T5) |
| E9 | ✅ | 14:50: "Running", "No problems.", waiting 0, sent 0, on the blockchain 15 (10 + 0011's three + 0012's registration and handoff; the rejected purchase never goes), failed 0, last put on 14:32. Accounts: 7 active, `officer_check` deleted, none invited |

**Changes from the plan:** different tags and minerals (grams, not kilograms); a second
journey on tag B (X1, X2) that also showed the "Confirm problem" path; the CSV filtered to
gold; no dashboard screenshot. None of them weakens the result.

**Timing seen (debug build, Wi-Fi or 4G, not 3G):** every local save 0.1 s (NFR-03 asks
3 s); sends 0.5–1.9 s (NFR-03 asks 10 s on 3G). The release-build timing still stands
on its own (`progress.md`).

**Observation O1 (no change proposed):** a step that is sent to Sepolia but not yet mined
(`submitted`) shows "Not on the blockchain yet" together with its transaction hash, for
the 10–30 s until it is confirmed. That is accurate (it is not on the chain until mined),
and a second check a minute later shows "Verified".

**Not done:** the walked "Phone check site" zone (Q5, A); it stays a known gap from GPS
zones T6.

## 6. Subtasks

Done on 23 Nov: ✅ T1, ✅ T2 (13:41–14:51), ✅ T3 (no fault found), ✅ T4. Added at the
developer's request: ✅ T5, the final security review of the later features
(`security-review.md` §7). The submission zip was dropped by the developer on 23 Nov.

- ✅ **T1 Regression pass** (Claude Code): `npm test` and `npm run test:db` (in
  `backend/`, from PowerShell), full `flutter test` and `flutter analyze --no-pub` (in
  `mobile/`), and the contract's tests if Q1 is A. Expected: 2348, 932 and 2623 passed,
  0 skipped; the contract 37. Numbers to `testing-log.md`. Then **stop** for the device
  steps.
- ⬜ **T2 Device steps** (the developer): E1–E9 with the screenshots of §4.
- ⬜ **T3 Verdict** (Claude Code): each screenshot checked against §4, the results table
  filled in, the `testing-log.md` entry, `progress.md`. Any fault: described with the
  step and screenshot, and a proposed fix on its own branch. **Stop** for the developer's
  decision on each one; a fix is never made in this branch without agreement.
- ⬜ **T4 Docs and PR text**: this plan marked done, `CLAUDE.md` status, the PR title and
  description (docs only, nothing deploys).

## 7. Open questions (proposed answers marked A)

- **Q1 Contract tests.** (A) Run `npx hardhat test` in `contracts/` (local network only,
  no Sepolia, no change to the contract), so the regression pass covers every layer.
  (B) Skip them: the contract has not changed since the last run (12 Nov, 37 passed).
- **Q2 The transporter.** Which transporter account signs in on the A57 for E3? (A) The
  transporter from the handoff and buyer purchase checks, whose key is already on the
  A57. Please name it in your answer; it is not written in the docs.
- **Q3 The zone for the clean journey.** (A) The emulator's location inside "ZCAS Campus
  (demo)" (E2), as in the consignment check, so the run can be done indoors now.
  (B) The A57 at the "Typed Check Zone" filling station.
- **Q4 The anomaly decision.** (A) "Clear, no problem" (E6), so B is anchored and the
  open count returns to 8. (B) "Confirm problem": B is rejected and never anchored, and
  the open count also returns to 8, but the reject path was already shown on 0008.
- **Q5 What is left out.** (A) The walked "Phone check site" zone (GPS zones T6 steps
  2–3, carried since 21 Nov), account requests and the account and zone changes are not
  repeated; the walked zone is recorded as not done, the typed zone stands for it.
  (B) Add the walked zone (needs daylight and about 30 minutes outside).
