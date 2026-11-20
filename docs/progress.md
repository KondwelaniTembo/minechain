# Progress

The working plan to submission on **Sunday 22 November 2026, 12:00** (work stops at 10:00).
Updated after every subtask. How the levels work (Project → Day → Feature → Subtask → Steps)
is in `CLAUDE.md`, "Working agreement (autopilot)".

Last updated: 20 Nov 2026, 21:30, after Buyer purchase T5, on `feature/buyer-purchase` (5/5).
Next: the developer commits (two commits), opens and merges the PR; then Officer alerts (Sat 21).

## (a) Whole project

### Done before 18 Nov

- ✅ Smart contract on Sepolia (PR #1)
- ✅ Backend foundation and logic: sync, signing, anchoring, anomaly rules, GPS zones,
  reports, accounts, anchoring admin (PRs #4, #5)
- ✅ Deployment on Render (PR #6)
- ✅ App endpoints: officer alerts, account rename and soft delete, consignment view and
  verification (PR #8); the users-deleted migration ran on production on 15 Nov, after a
  backup and before the merge (`efd8a5f`, `docs/deployment.md`)
- ✅ Mobile foundation: login, role homes, pinned TLS, secure storage (PRs #7, #9)
- ✅ Miner module: device key, encrypted local database, signed registration, sync,
  "My consignments" (PR #10)

### Wed 18 Nov

- ✅ Workflow setup: autopilot working agreement, permissions, progress and testing logs
  (PR #12)
- ✅ Design integration: bring in Mapalo's theme from the `design/mapalo-theme` branch,
  plus Mapalo's navigation bar beside the account button (Part 3, T10–T12)
  (`docs/plans/design-integration-plan.md`; PR #11, merged 19 Nov, `d86e33c`)
- ~~Bottom navigation as its own feature~~ Dropped 19 Nov in the morning, then brought back
  by the developer the same afternoon inside Design integration (Part 3)
- ✅ Hardening (PR #13): OWASP MASVS/MSTG review of the miner module, fix every Critical and High
  finding, replace the skipped miner case in `homes_test.dart`, 3 device checks
  (`docs/plans/hardening-plan.md`)

### Thu 19 Nov

- ✅ Consignment check (7/7, PR #15): scan and verify, with the provenance
  view (FR-04, Scope (9)), shared by transporter, buyer and officer
- ✅ Transporter handoff (8/8, plan approved 20 Nov): scan, weigh, GPS, sign, cache, sync;
  the "Send my work" summary and the saved count (T5b) (FR-01, FR-02, FR-07)

### Fri 20 Nov

- ✅ Buyer purchase and "My purchases" (Scope (8)), 5/5; PR to be opened by the developer
- ✅ Full chain on devices: miner → transporter → buyer, synced and anchored (MC-2026-LSK-0007
  "Verified", three steps on the chain, 20 Nov; buyer purchase T4, Q5)
- ➡️ Officer alerts: moved to Sat 21

### Sat 21 Nov

- ⬜ Officer alerts (from Fri 20): list, detail, "Confirm problem" and "Clear, no problem"
  (FR-08, Scope (2), (5)). Test case ready: MC-2026-LSK-0008's handoff is under review
  (more than 10% off); clearing it should let the buyer's waiting purchase in, and that
  purchase (1.6 kg against a 2 kg registration) is itself more than 10% off, so expect a
  second alert
- ⬜ Admin accounts: list, create with activation code, edit name, suspend and reactivate,
  delete, reset a device key and a password (FR-10, FR-12, Scope (3), (6)); includes
  resetting the demo accounts' device key (Fred) and password (Mutale)
- ⬜ GPS zones: list, create, rename, deactivate (FR-11, Scope (7))
- ⬜ Reports: download the CSV and share it from the phone (FR-09, FR-13)
- ⬜ Dashboard (FR-14, kept under Scope (4); the first feature to cut if time runs short)
- ⬜ FR-16 decision: the signed PDF certificate, build or cut (Scope (4))
- ⬜ End-to-end test of every role

### Sun 22 Nov, until 10:00

- ⬜ Final OWASP review and fixes
- ⬜ Release-build performance, including 3G on the emulator (NFR-03)
- ⬜ README with screenshots and Mapalo's design credit
- ⬜ Release tag (created by the developer)

### Open items

- ✅ Production migration `1794528000000_users-deleted`: closed. Run on 15 Nov, about 22:30,
  after a backup and before PR #8 was merged (`docs/deployment.md`, commit `efd8a5f`).
- ✅ Scope (4): FR-14 kept (17 Nov); FR-16 is decided on Sat 21 Nov.
- ✅ Day plan: approved by the developer on 18 Nov.

## (b) Today, Fri 20 Nov (from 11:30)

1. ✅ Consignment check, carried over from Thu 19 (7/7; merged as PR #15): ✅ two result-page
   fixes (1587 tests passed); ✅ the rest of T6 (offline, a verified result); ✅ T7 docs
2. ✅ Transporter handoff, carried over from Thu 19: 8/8 (T5b added); merged as PR #16
3. ✅ Buyer purchase and "My purchases": 5/5; its phone check also covered
   "Full chain on devices" (Q5). Commits and PR by the developer
4. ✅ Full chain on devices (inside Buyer purchase T4); ➡️ Officer alerts moved to Sat 21,
   where FR-14 (dashboard) is the first cut

Done on Thu 19 (session ended 20 Nov, 00:40): Hardening (PR #13), "My account" back arrow
(PR #14), Consignment check T1–T5 (1584 tests passed, 0 skipped).

## (c) Current feature: Buyer purchase — 5/5

Plan: `docs/plans/buyer-purchase-plan.md`, approved 20 Nov (Q1–Q5 as proposed). Branch
`feature/buyer-purchase`, created by the developer from `main` after PR #16. App only
(`mobile/`, `docs/`); nothing deploys to Render.

- ✅ T1 Purchase payload and save: one 8-line builder for handoff and purchase
  (`later_step_payload.dart`, handoff tests unchanged); `buildPurchasePayload` against the
  purchase vectors byte for byte; `RecordPurchase`; `firstStepOn`; 22 new tests, 1762 passed
- ✅ T2 The "Record purchase" screen (`CustodyStepKind`, `/buyer/purchase`, Q1–Q3); the
  91 handoff tests unchanged; 24 new, 1786 passed
- ✅ T3 My purchases and Send my work (`/buyer/purchases`, `/buyer/sync`); the buyer's
  "Coming soon" case now taps "Reports" (changed by plan); 20 new, 1806 passed
- T2 and T3 ran without stopping (the developer away, 20 Nov), so neither is committed.
  Files by subtask:
  - T2 only: `mobile/lib/features/handoff/domain/custody_check.dart`,
    `mobile/lib/features/handoff/presentation/custody_controller.dart`,
    `mobile/lib/features/handoff/presentation/take_custody_screen.dart`,
    `mobile/test/features/purchase/presentation/record_purchase_screen_test.dart`;
  - T3 only: `mobile/lib/features/consignments/presentation/my_consignments_screen.dart`,
    `mobile/test/features/homes_test.dart`,
    `mobile/test/features/consignments/presentation/my_purchases_screen_test.dart`;
  - both: `mobile/lib/core/router/app_router.dart`, `mobile/lib/core/router/routes.dart`,
    `mobile/lib/core/text/app_text.dart`,
    `mobile/lib/features/buyer/presentation/buyer_home_screen.dart`. So T2 alone would
    not build, and T2 and T3 go in one code commit;
  - docs (T2, T3, T5): `docs/plans/buyer-purchase-plan.md`, `docs/progress.md`,
    `docs/testing-log.md`, `docs/decisions.md`, `CLAUDE.md`: the second commit.
- ✅ T4 Phone check, also "Full chain on devices" (Q5): emulator (buyer, admin) and A57
  (transporter), 20 Nov 20:14–21:20, all as planned (results in the plan)
- ✅ T5 Docs and PR: decisions Purchase app (1)–(6) ((5) confirmed by the developer), one
  known limitation, the T4 results, CLAUDE.md, the PR text

Transporter handoff (8/8) is merged as PR #16; its subtasks are in
`docs/plans/transporter-handoff-plan.md`.

Consignment check (7/7) is merged as PR #15; its subtasks are in
`docs/plans/consignment-check-plan.md`.

Hardening (5/5, PR #13) and the "My account" back arrow (PR #14) are finished; their
subtasks are in `docs/plans/hardening-plan.md` and `docs/decisions.md` Mobile (39).

**Schedule (20 Nov, 21:30): behind by about one feature.**
- Thu 19 finished Wednesday's Hardening and the back arrow, and Consignment check T1–T5.
- Fri 20 finished Consignment check, Transporter handoff, Buyer purchase and the full
  chain on devices.
- Carried to Sat 21: Officer alerts. Suggested Saturday order, Musts first: Officer alerts,
  Admin accounts, Reports, GPS zones, the FR-16 decision, the dashboard (FR-14, the first
  cut), the end-to-end test.
