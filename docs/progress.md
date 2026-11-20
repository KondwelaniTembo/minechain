# Progress

The working plan to submission on **Sunday 22 November 2026, 12:00** (work stops at 10:00).
Updated after every subtask. How the levels work (Project → Day → Feature → Subtask → Steps)
is in `CLAUDE.md`, "Working agreement (autopilot)".

Last updated: 20 Nov 2026, after Transporter handoff T4, on `feature/transporter-handoff`
(4/7). Consignment check merged as PR #15. Next: T5, My handoffs and Send my work.

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
- ⬜ Transporter handoff (3/7, plan approved 20 Nov): scan, weigh, GPS, sign, cache, sync
  (FR-01, FR-02, FR-07)

### Fri 20 Nov

- ⬜ Buyer purchase and "My purchases" (Scope (8))
- ⬜ Full chain on devices: miner → transporter → buyer, synced and anchored
- ⬜ Officer alerts: list, detail, "Confirm problem" and "Clear, no problem"
  (FR-08, Scope (2), (5))

### Sat 21 Nov

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
2. ⬜ Transporter handoff, carried over from Thu 19 (about 4–5 h): 3/7
3. ⬜ Buyer purchase and "My purchases" (about 3–4 h)
4. ⬜ If time is left: Full chain on devices; Officer alerts. Otherwise both move to Sat 21,
   and FR-14 (dashboard) is the first cut there

Done on Thu 19 (session ended 20 Nov, 00:40): Hardening (PR #13), "My account" back arrow
(PR #14), Consignment check T1–T5 (1584 tests passed, 0 skipped).

## (c) Current feature: Transporter handoff — 3/7

Plan: `docs/plans/transporter-handoff-plan.md`, approved 20 Nov (Q1–Q5 as proposed). Branch
`feature/transporter-handoff`, created by the developer from `main` after PR #15. App only
(`mobile/`, `docs/`); nothing deploys to Render.

- ✅ T1 Handoff payload: `buildHandoffPayload` (8 lines, no `mineral`), the shared grammar
  checks; the spec's example and the handoff vectors byte for byte; 22 new tests
- ✅ T2 Shared save: `SignedStepSaver` shared by registration and `RecordHandoff`
  (registration tests unchanged); local schema version 2 adds `mineral_hint` (Q3 changed,
  Handoff app (1)); `listOfTypeForActor`, `handedOffOn`; 39 new tests
- ✅ T3 Take custody: scan and check: `/transporter/custody`, the tile wired; Q4 on the
  phone first; one check per scan; 404, offline, failed and ended-session sentences, the
  chips; Q2's warnings and "Record anyway"; shared gate and chips; 30 new tests
- ✅ T4 Take custody: weight, GPS and save: the location moved into a shared
  `LocationTracker` (registration tests unchanged), started only once a code is accepted;
  the weight in the mineral's unit; Save with Q4 checked again; every refusal stores
  nothing; the send after a save; shared location view, weight field and saved view;
  18 new tests
- ⬜ T5 My handoffs and Send my work
- ⬜ T6 Phone check (the developer)
- ⬜ T7 Docs and PR

Consignment check (7/7) is merged as PR #15; its subtasks are in
`docs/plans/consignment-check-plan.md`.

Hardening (5/5, PR #13) and the "My account" back arrow (PR #14) are finished; their
subtasks are in `docs/plans/hardening-plan.md` and `docs/decisions.md` Mobile (39).

**Schedule (20 Nov, 00:40): behind by about one day.**
- Thu 19 finished Wednesday's Hardening and the back arrow, and Consignment check T1–T5.
- Carried to Fri 20: the end of Consignment check and all of Transporter handoff.
- Likely carried to Sat 21: Full chain on devices and Officer alerts. FR-14 is the first
  feature to cut if Saturday runs short.
