# Progress

The working plan to submission on **Sunday 22 November 2026, 12:00** (work stops at 10:00).
Updated after every subtask. How the levels work (Project → Day → Feature → Subtask → Steps)
is in `CLAUDE.md`, "Working agreement (autopilot)".

Last updated: 19 Nov 2026, after Design integration T2.

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
- ⬜ Design integration: bring in Mapalo's theme from the `design/mapalo-theme` branch;
  navigation option A is kept here, and bottom navigation is the next feature
  (`docs/plans/design-integration-plan.md`)
- ⬜ Bottom navigation (Mapalo's suggestion; Home + Account; try on its own branch, merge
  only if approved on the phone)
- ⬜ Hardening: OWASP MASVS/MSTG review of the miner module, fix every Critical and High
  finding, replace the skipped miner case in `homes_test.dart`, 3 device checks

### Thu 19 Nov

- ⬜ Consignment check: scan and verify, with the provenance view (FR-04, Scope (9)),
  shared by transporter, buyer and officer
- ⬜ Transporter handoff: scan, weigh, GPS, sign, cache, sync (FR-01, FR-02, FR-07)

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

## (b) Today, Wed 18 Nov

1. ✅ Workflow setup
2. ⬜ Design integration (T1, T2 done, T3 next)
3. ⬜ Bottom navigation (own branch)
4. ⬜ Hardening

## (c) Current feature: Design integration — 2/4

Plan: `docs/plans/design-integration-plan.md`, approved 19 Nov (Q1: scale the role down;
Q2: 3:1 for the icon; Q3: the `app_theme.dart` comment is fixed in T3).

- ✅ T1 App bar title: role always whole, "MineChain" only when whole; account button ≥ 56 dp
- ✅ T2 Theme test: copper icon on `secondaryContainer`, light and dark
- ⬜ T3 Docs: Mobile (35) with Mapalo's credit, the copper vs error-red limitation, the
  foundation plan's seed wording, the status line of the bottom navigation suggestion
- ⬜ T4 Phone check on the A57: light, dark, largest text
