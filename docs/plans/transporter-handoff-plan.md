# Transporter handoff plan

Status: **approved 20 Nov 2026** (Q1–Q5 as proposed; Q3 changed in T2, see below). **Done**
(8/8, T5b added after the phone check): 1740 tests passed, 0 skipped; decisions Handoff
app (1)–(9) and two known limitations.

Branch: `feature/transporter-handoff`, created by the developer from `main` after PR #15.

## 1. Goal

FR-01, FR-02 and FR-07 for the transporter: **"Take custody"** of a bag at the mine. The
transporter scans the custody record's QR code, weighs the bag, and the phone records a
signed `handoff` step with their own weight, the GPS point and the time. It works offline:
the step is signed and saved in the encrypted database, then sent by "Send my work" or on
the next resume, exactly like a miner's registration.

The weight is **blind**: the transporter types what their own scale shows and never sees
the miner's figure first (Verification (6)). The server compares the two (more than 10% off
is flagged `QUANTITY_DISCREPANCY`, an officer reviews it).

**App only** (`mobile/` and `docs/`): the server already accepts handoffs
(`POST /sync/steps`, api.md, "Codes"), runs the order and quantity rules, and moves the
stage to `in_transit`. Nothing deploys to Render.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| The payload format, handoff = 8 lines, with a fixed example | `docs/signing-spec.md` §3, `docs/signing-vectors.json` | the bytes to sign |
| Field grammar checks (`isQrCode`, `isWeightMg`, `isCoordinate`, `isCapturedAt`, …) | `registration/domain/payload_format.dart` | the handoff builder, unchanged |
| Build once → sign with the Keystore key → one row (`SaveResult` types, screen-lock refusal) | `registration/data/register_consignment.dart` | the save, shared (T2) |
| `local_steps`: `type` column, `mineral` nullable | `steps/data/local_steps_repository.dart` | handoff rows, no migration |
| Sync: sends every due step as `{payload, signature}`, any type; deferral with back-off; flagged and rejected kept | `sync/` | sending handoffs, unchanged |
| GPS policy: within 25 m, not mocked, under 30 s old; permission flow | `registration/domain/gps_fix.dart`, `registration_controller.dart` | the handoff's place |
| Scanner with the custody record ID rule | `qr_scanner_view.dart`, `custody_record.dart` | the scan |
| The consignment check (repository and view) | `verification/` | the check before taking custody (Q1) |
| Typed weight → whole mg on text, unit per mineral | `registration/domain/weight.dart` | the weight field |
| "My consignments" list and state words | `consignments/presentation/` | "My handoffs" (T5) |
| Transporter home: "Take custody", "My handoffs", "Send my work" are "Coming soon" | `transporter_home_screen.dart` | the ways in |

## 3. How it fits

```
Transporter home
  "Take custody"  → /transporter/custody
      scan ─ custody record ID? ─ no → "not a MineChain custody record"
                                  └ yes → already handed off on this phone? → say when, stop (Q4)
                                        → online: the check (GET /consignments/by-qr) → mineral, warnings (Q1, Q2)
                                          offline: "no network" note, choose the mineral (Q1)
      → weight (in the mineral's unit) + GPS fix → Save
      → build payload once → sign (Keystore) → one local_steps row → "Saved on this phone"
  "My handoffs"   → /transporter/handoffs   (this phone's handoffs and their state)
  "Send my work"  → /transporter/sync       (the existing screen; sends every due step)
```

- Three new paths under `/transporter`, so the router's role rule keeps everyone else out.
- **No new server call except the optional check**, which is the existing endpoint.
- The check's answer is only advice for the screen: nothing from it goes into the signed
  payload, and nothing from it is stored except the mineral as a display hint (Q3).
- What the server can answer later, already shown by the sync screen and the list:
  `QUANTITY_DISCREPANCY` and `HANDOFF_ORDER` (flagged, "under review"),
  `CONSIGNMENT_NOT_FOUND` (deferred: the miner's registration has not arrived yet),
  `STEP_NOT_ALLOWED_FOR_ROLE` (rejected; cannot happen from this screen).

## 4. The screen

1. **Scan.** The same camera block as registration and the check.
2. **What is known about the bag** (online): mineral, stage, and a warning when the check says
   so (Q2): "Under review", "does not match the blockchain", "already bought", or "not on
   the server yet". The transporter's view is the blind one, so no weight is ever shown.
   Offline: "No network: the consignment could not be checked. You can still record it;
   it is checked when it is sent." and the mineral chips.
3. **Weight**, in grams or kilograms by mineral, the same field and rules as registration.
4. **Location**: the same live GPS line as registration (searching, accuracy, mocked,
   blocked, settings).
5. **Save** (one tap): "Saved on this phone. Send it from Send my work." Then "Take custody
   of another".

NFR-06 counts taps after the scan: weight (typing), Save. The mineral chip only offline.

## 5. Subtasks

- ✅ **T1 Handoff payload** (about 30 min). `buildHandoffPayload` in
  `lib/features/handoff/domain/handoff_payload.dart`: 8 lines, the shared grammar checks,
  `PayloadFieldInvalid`. Unit tests: the signing spec's handoff example and the two handoff
  cases in `signing-vectors.json` byte for byte (read, never regenerated); each field
  refused; no `mineral` line.
- ✅ **T2 Shared save** (about 60 min, **touches signing: needs your OK in the plan**).
  Split `register_consignment.dart` into a shared `saveSignedStep` (key check, open the
  database, sign, insert one row, the `SaveResult` types) and the registration's own part;
  every registration test passes unchanged. `recordHandoff(qrCode, weightMg, fix, mineral)`
  on top of it (type `handoff`, mineral as the local hint, Q3). Repository:
  `handedOffOn(qrCode, actorId)` (earliest non-rejected handoff by this user, Q4) and the
  list query taking a type. Tests with the fake Keystore and a real encrypted test database.
- ✅ **T3 Take custody, scan and check** (about 60 min). Route `/transporter/custody`, the tile
  wired. Controller: scan with the custody record rule, Q4's refusal, the optional check
  through the existing `ConsignmentCheckRepository` (one request per scan; offline,
  timeout or 5xx fall through to "could not be checked", never a dead end), Q2's warnings,
  the mineral from the check or the chips. Widget tests with the fake camera and fake server.
- ✅ **T4 Take custody, weight, GPS and save** (about 75 min). The location handling moved
  out of `RegistrationController` into a shared controller both screens use (registration
  tests unchanged); weight field; Save through T2; the saved state; refusals (no screen lock,
  key not usable, phone busy). Widget tests: the whole flow online and offline, a 1.5 kg
  copper bag signs `weight_mg=1500000`, nothing saved on any refusal, text 2.0 in portrait
  and landscape.
- ✅ **T5 My handoffs and Send my work** (about 45 min). `/transporter/handoffs`: the
  "My consignments" list generalised by step type (handoffs say "Took custody of …"); the
  weight shown in the unit of the stored mineral hint. `/transporter/sync`: the existing
  screen, with its one miner-only link made role-aware. Both tiles wired; router tests that
  other roles cannot open the paths.
- ✅ **T6 Phone check** (the developer, 20 Nov, 14:38–15:01). Exact commands in the T5 report. On
  the emulator, Mutale registers a new consignment inside the demo zone and sends it; on the
  A57 the transporter takes custody with a weight within 10% (accepted; the check then shows
  the weights, because they have handed off), and of a second bag with one 20% lighter
  (flagged, "under review"); one handoff saved in airplane mode and sent afterwards.
  - Result: everything as planned. MC-2026-LSK-0007 at 1.9 kg was accepted, anchored and
    "Verified", with the transporter's own weight shown. MC-2026-LSK-0008 at 1.6 kg was saved
    in airplane mode (0.1 s) and waited on the phone. "Send my work" then said "no internet".
    After Send now it came back "under review" with the 10% message. Scanning either bag
    again was refused with the save time. Before the scan, airplane mode gave the "No
    network" notice and the chips, as Q1 and Q3 intend.
  - Seen, as designed:
    - The check for 0008 lists only the registration: the held handoff is not listed (the
      known limitation of 20 Nov after Verification app (10)).
    - The handoff on 0007 says "Outside every licensed zone": the zone rule applies to
      registrations only (Anomaly rules), so it is information, not a flag.
  - Found: "Send my work" shows only the **last** send. Two saves in a row became two sends
    of "1 sent" each, and the screen said "1 sent". At 14:57, an automatic "nothing to
    send" replaced the 14:56 report that had the review message. This is fixed by T5b.
- ✅ **T5b What the sends came to** (added 20 Nov after T6, approved by the developer:
  option 1, both parts; about 60 min). App only.
  - **(a) Send my work sums up the sends since you last looked.** The sync service keeps,
    besides `last`, a summary of every send that ended since the summary was last cleared:
    - It holds the number of sends, the first start time, how many were sent to the server,
      under review and rejected, every problem line, and the newest stop. The stop is
      worded from the newest send only, because it says how things are now.
    - A send with nothing to send adds nothing, so it never hides a summary that holds
      something.
    - The summary is cleared when the user taps Send now (a fresh summary starts) and when
      the user leaves "Send my work".
    - The heading reads, for example, "Since 14:40 — 2 sends after you saved". With one
      send, it stays the heading used today.
    - The counts at the top are unchanged.
  - **(b) The saved screen counts this visit's saves.** "Saved on this phone …" gains
    "2 saved this time." from the second save on, for "Register another" and "Take custody
    of another". The count lives in the screen's own controller, so "Back to home" (or the
    back arrow) starts again at zero.
  - Tests:
    - two saves, two sends, one summary of 2;
    - an automatic "nothing to send" after a review does not hide it;
    - Send now starts a fresh summary;
    - leaving and coming back clears it;
    - the count on both saved screens, and back to zero after "Back to home";
    - text 2.0.
  - A short phone re-check on the emulator: register two bags in a row, then open
    "Send my work".
  - As built: decisions Handoff app (8) and (9). Two points the spec left open: with no
    summary (just cleared, or only empty sends) the screen shows the last send as before;
    with different triggers the heading names none. Emulator re-check fine (20 Nov, 16:03–16:05);
    after it the heading became "Since 14:40 — sent 2 times after you saved" ("2 sends" read
    as a verb). 23 new tests, 1740 passed.
- ✅ **T7 Docs and PR** (about 20 min). `decisions.md` "Handoff app (1)…", `testing-log.md`,
  `progress.md`, `CLAUDE.md`, the PR description.

About 5 h of Claude Code time plus the developer's 30 minutes.

## 6. Questions

- **Q1 The weight unit, when the handoff has no mineral line.** The unit (g or kg) follows
  the mineral, but the transporter's payload has no mineral, and a wrong unit is a weight
  1000 times off (flagged by the 10% rule, so never silently accepted).
  - **(A, proposed)** Run the consignment check after the scan when there is a network: the
    mineral comes from the server and is shown, not chosen. Offline, the transporter picks
    the mineral from the same chips as registration, with "Check the custody record".
  - (B) Always pick the mineral, no check.
  - (C) Always kilograms. Gold and the gemstones would then be typed as small decimals,
    such as 0.0153 kg.
- **Q2 Taking custody when the check warns.**
  - **(A, proposed)** Warn and allow. The bag is physically in the transporter's hands, and
    the server already flags or defers what is wrong. Before Save, a held or mismatching
    consignment needs one extra "Record anyway" tap; "already bought" and "not on the server
    yet" are notes only.
  - (B) Block Save while held, mismatching or bought.
- **Q3 Keeping the mineral on the phone for a handoff.** `local_steps.mineral` is nullable
  and today "registrations only".
  - **(A, proposed)** Store the mineral the screen used, as an unsigned display hint, so
    "My handoffs" can show "Copper, 1.5 kg". Documented in the table comment and in
    decisions. No migration.
    - **As built (T2, the developer's choice):** the version 1 CHECK allows a mineral on
      registrations only, so the hint has its own column, `mineral_hint`, added by local
      schema version 2 (`ALTER TABLE … ADD COLUMN`). Decision Handoff app (1).
  - (B) Leave it null, and show handoff weights in mg.
- **Q4 Taking custody twice of the same bag on one phone.**
  - **(A, proposed)** Refuse, like registration does: "You recorded taking custody of this
    consignment on 20 Nov, 11:54." (rejected handoffs do not count).
  - (B) Allow it; the server stores it as a relay.
- **Q5 Folder.** `lib/features/handoff/` (proposed), with the shared save and location in
  their current folders.
