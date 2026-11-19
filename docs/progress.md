# Progress

The working plan to submission on **Sunday 22 November 2026, 12:00** (work stops at 10:00).
Updated after every subtask. How the levels work (Project → Day → Feature → Subtask → Steps)
is in `CLAUDE.md`, "Working agreement (autopilot)".

Last updated: 19 Nov 2026, after the "My account" back arrow (Mobile (39)), on
`fix/account-back-arrow`. Hardening merged as PR #13. Next: Thu 19's Consignment check.

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
2. ✅ Design integration (PR #11, merged 19 Nov)
3. ~~Bottom navigation~~ (dropped in the morning; back in the afternoon as Design integration Part 3)
4. ✅ Hardening (T1–T5, PR #13)
5. ✅ "My account" back arrow (Mobile (39), `fix/account-back-arrow`): tested, A57 fine;
   PR left

## (c) Current feature: Hardening — 5/5

Plan: `docs/plans/hardening-plan.md`, approved 19 Nov (Q1–Q5 as proposed). Branch
`chore/hardening`, created by the developer from `main`.

- ✅ T1 The review: `docs/security-review.md`, MASVS v2 group by group, with evidence and a
  rating per control. No Critical; one High (H1, the signing key works on a phone with no
  screen lock); Mediums M1 and M2; Lows L1–L5
- ✅ T2 Fixes (Q6: A): H1, a screen lock is required before a key is made and before every
  signature (`NO_SCREEN_LOCK`), and new keys are unusable while the phone is locked
  (Android 9+); M1, `FLAG_SECURE` when not debuggable; L1, touches through an overlay
  dropped. Checked on the emulator (no PIN: refused; PIN: saved) and the A57 (fine)
- ✅ T3 The skipped miner case in `homes_test.dart` replaced by three router tests, one per
  miner tile; tests 1437 passed, 0 skipped
- ✅ T4 Three device checks on the A57, all passed: the obfuscated release build works;
  nothing sensitive in the log; database encrypted, no backup, recent-apps card blank and
  screenshots blocked (after fixing `FLAG_SECURE` to use `BuildConfig.DEBUG`)
- ✅ T5 Docs: `decisions.md` Hardening (1)–(5) and five known limitations; the review marked
  with the T2 fixes and T4 results (new Low L6, `run-as` on the release build); PR description
  drafted

Design integration (14/14, T1–T14) is finished and merged as PR #11; its subtask list is in
`docs/plans/design-integration-plan.md`.

**Schedule (19 Nov): behind by about one day.**
- Still open from Wed 18: Hardening (Design integration merged as PR #11). The navigation
  bar added about 3 h; the developer accepted that on 19 Nov.
- Thu 19's two features (Consignment check, Transporter handoff) have not started.
