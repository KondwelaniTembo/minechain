# Buyer purchase plan

Status: **approved 20 Nov 2026** (Q1–Q5 as proposed). T1 done.

Branch: `feature/buyer-purchase`, created by the developer from `main` after PR #16.

## 1. Goal

FR-01, FR-02 and FR-07 for the licensed buyer, and the end of the custody chain:
**"Record purchase"**. The buyer scans the custody record's QR code, weighs the bag on
their own scale, and the phone records a signed `purchase` step with the weight, the GPS
point and the time. It works offline like the other two steps: signed, saved in the
encrypted database, then sent by "Send my work" or on the next resume.

Then **"My purchases"** (Scope (8): from the phone's database) and the buyer's
**"Send my work"**.

**App only** (`mobile/` and `docs/`). The server already accepts purchases
(`POST /sync/steps`), defers one while the consignment is still `registered`
(`STAGE_NOT_READY`), flags a second purchase (`HANDOFF_ORDER`, high) and one more than 10%
off (`QUANTITY_DISCREPANCY`), and moves the stage to `purchased`, which is final. Nothing
deploys to Render.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| The purchase payload, 8 lines, and its vectors ("purchase"; "handoff signature under a purchase header") | `docs/signing-spec.md` §3, `docs/signing-vectors.json` | the bytes to sign |
| `buildHandoffPayload`: the same 8 lines under the handoff header | `handoff/domain/handoff_payload.dart` | shared with purchase (T1) |
| `SignedStepSaver`: key check, database first, build once, sign, one row; `mineral_hint` already allowed on a purchase (local schema version 2) | `steps/data/save_signed_step.dart` | the save, unchanged |
| "Take custody": scan, Q4 on the phone, the consignment check, mineral from the server or the chips, warnings and "Record anyway", GPS, weight, Save, the saved view with "2 saved this time." | `handoff/` | the purchase screen, by kind (T2) |
| `handedOffOn(qrCode, actorId)` | `local_steps_repository.dart` | generalised by step type (T1) |
| "My consignments" / "My handoffs" by `StepListKind`; "Send my work" for any signing role | `consignments/`, `sync/` | "My purchases" and `/buyer/sync` (T3) |
| `buyer` in `signingRoles` (device key, sync on sign-in) | `device_key_controller.dart` | nothing to add |
| Buyer home: "Record purchase", "My purchases", "Send my work" say "Coming soon" | `buyer_home_screen.dart` | the ways in |

## 3. How it fits

- **Actors:** the buyer, after a transporter has handed the bag over. The server then
  compares the buyer's weight with the latest accepted step and the registration.
- **What a buyer's check can answer** (api.md, "What each viewer sees"):
  - `in_transit`: the consignment, its mineral and its accepted steps, with weights;
  - `purchased` with the buyer's own accepted purchase: the owner's view;
  - **404 for everything else**: not on the server yet, still `registered` (the handoff
    not sent, or flagged and held), or already sold to another buyer. The server answers
    these the same way on purpose, so the app cannot tell them apart.
- **What the server does with the purchase:** `in_transit` → accepted, stage `purchased`,
  anchored. `registered` or not found → deferred and resent with growing pauses until it
  can be placed. After another purchase → stored, flagged `HANDOFF_ORDER` (high).

## 4. The screen

The same page as "Take custody", with the buyer's words: "Record purchase", "Scan the
custody record", "Your weight", Save, then "Saved on this phone", "Record another
purchase" and "Back to home". The steps:

1. Scan. The custody record ID rule, then Q4: this buyer's earlier purchase of this code
   on this phone (not rejected) is refused with its local time.
2. The check, when there is a network: mineral, stage and warnings (Q2, Q3). Offline, a
   failed check, or 404: the mineral chips, "you can still record it".
3. GPS (started once a code is accepted, as on "Take custody"), the weight in the
   mineral's unit, Save.

## 5. Subtasks

- ✅ **T1 Purchase payload and save** (about 40 min).
  - `purchase/domain/purchase_payload.dart` `buildPurchasePayload`. The 8-line builder
    becomes one private function shared by both types, so the handoff output cannot drift.
    Tests: the "purchase" vector's text, bytes and SHA-256; the "handoff signature under
    a purchase header" vector's text is what a purchase builds from those fields; no
    `mineral` line; the refusals. Every handoff payload test passes unchanged.
  - `purchase/data/record_purchase.dart` `RecordPurchase.save(...)` on `SignedStepSaver`,
    with `recordPurchaseProvider`. The mineral is stored as the unsigned hint only.
  - Repository: `firstStepOn(qrCode, actorId, type)`; `handedOffOn` stays as a one-line
    call of it, so T3's tests are untouched.
  - As built: the shared builder is `steps/domain/later_step_payload.dart`
    (`buildLaterStepPayload`, `LaterStepType`), public because two folders use it; the
    header comes only from the enum. The spec has no written purchase example, so the
    positive vector is the reference. 22 new tests (payload 11, `RecordPurchase` 8,
    `firstStepOn` 3); the new tests share one Keystore fake, `test/fakes/signing_channel.dart`.
- ⬜ **T2 The "Record purchase" screen** (about 75 min).
  - A `CustodyStepKind` (`handoff`, `purchase`) carries what differs: words, the save,
    the step type for Q4, the home and paths, and the warning rules. `CustodyController`
    and `TakeCustodyScreen` take it. Every "Take custody" test passes unchanged.
  - `/buyer/purchase` (`AppRoutes.buyerPurchase`), the tile wired; other roles kept out.
  - The buyer's warnings (Q2, Q3); the weight never shown before Save (Q1).
  - Widget tests: the whole flow online (in transit, accepted path) and offline; a 1.9 kg
    copper bag signs `weight_mg=1900000` under the purchase header with no mineral line;
    Q4 refused; held and mismatch need "Record anyway"; 404 needs it too (Q3); bought by
    this buyer refused (Q2); "Record another purchase" and "2 saved this time."; refusals
    store nothing; text 2.0 in portrait and landscape.
- ⬜ **T3 My purchases and Send my work** (about 30 min).
  - `StepListKind.purchases` at `/buyer/purchases` ("Bought MC-…", the weight in the
    hint's unit); "Send my work" at `/buyer/sync`; both tiles wired; "Reports" stays
    "Coming soon" (Reports feature, Sat 21).
  - Router tests: each buyer tile opens its path, other roles are kept out.
- ⬜ **T4 Phone check** (the developer, about 30 min; see Q5).
  - A buyer account: request it in the app ("Request an account", role buyer), then
    approve it with the administrator's account requests screen.
  - On the emulator as that buyer:
    - MC-2026-LSK-0007 (accepted handoff, `in_transit`) at about 1.9 kg: accepted,
      then "Verified" in "Check a consignment" with the buyer's own step;
    - MC-2026-LSK-0008 (flagged handoff, still `registered`): 404, "Record anyway",
      then the purchase waits (`STAGE_NOT_READY`) on "Send my work";
    - one purchase saved in airplane mode and sent afterwards;
    - 0007 scanned again: refused with the save time.
- ⬜ **T5 Docs and PR** (about 20 min). `decisions.md` "Purchase app (1)…",
  `testing-log.md`, `progress.md`, `CLAUDE.md`, the PR description.

About 2.5 h of Claude Code time plus the developer's 30 minutes.

## 6. Questions

- **Q1 Does the buyer see the expected weight before weighing?** The API shows a buyer
  the weights of an `in_transit` consignment, unlike a transporter who has not weighed.
  - **(A, proposed)** No: the purchase screen never shows the earlier weights, the same
    as "Take custody". The buyer's figure is their own measurement, and the 10% rule
    stays a real comparison. A buyer can still look the weights up in "Check a
    consignment"; this is the screen's choice, not a rule.
  - (B) Show "Last recorded: 1.9 kg" and warn while typing when the figure is more than
    10% off. This catches a wrong unit before signing, but invites copying the figure.
- **Q2 The check says this buyer has already bought it** (stage `purchased`, owner view).
  - **(A, proposed)** Refuse, like Q4: "You bought this consignment on 20 Nov, 16:10."
    A second purchase by the same buyer can only be a mistake, and the server would flag
    it high.
  - (B) Warn and allow with "Record anyway", as "Take custody" does for a held one.
- **Q3 A 404 on a buyer's scan.** For a buyer it may mean the handoff is not on the server
  yet (common offline), the consignment is held, or **another buyer has bought it**.
  - **(A, proposed)** Say so in one sentence ("The server does not show you this
    consignment yet. The transporter's handoff may not have been sent, or it may be under
    review or already sold. You can still record it; it is checked when sent."), the
    mineral chips, and one "Record anyway" tap before Save. Stronger than the transporter's
    note, because here money may change hands.
  - (B) A note only, as on "Take custody".
  - (C) Block Save. This would stop the offline case, which FR-07 needs.
- **Q4 Structure.**
  - **(A, proposed)** One screen and controller by `CustodyStepKind`, kept in `handoff/`;
    the purchase payload and save in a new `purchase/` folder. No file moves, and the
    transporter's 100+ tests guard the change.
  - (B) A separate purchase screen built from the shared widgets: more code, two copies of
    the scan and check flow.
- **Q5 Let the T4 phone check count as "Full chain on devices".** The miner's
  registration (emulator) and the transporter's handoff (A57) are already done and
  anchored for MC-2026-LSK-0007. Adding the buyer's purchase there, and checking that it
  anchors, completes miner → transporter → buyer. This saves about 1 h on Sat 21.
  - **(A, proposed)** Yes, with the anchored purchase and one screenshot per role.
  - (B) No, keep a separate full-chain session.
