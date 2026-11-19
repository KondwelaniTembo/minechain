# Progress

The working plan to submission on **Sunday 22 November 2026, 12:00** (work stops at 10:00).
Updated after every subtask. How the levels work (Project → Day → Feature → Subtask → Steps)
is in `CLAUDE.md`, "Working agreement (autopilot)".

Last updated: 19 Nov 2026, after Design integration T11.

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
- ⬜ Design integration: bring in Mapalo's theme from the `design/mapalo-theme` branch,
  plus Mapalo's navigation bar beside the account button (Part 3, T10–T12)
  (`docs/plans/design-integration-plan.md`)
- ~~Bottom navigation as its own feature~~ Dropped 19 Nov in the morning, then brought back
  by the developer the same afternoon inside Design integration (Part 3)
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
2. ⬜ Design integration (T1–T11 done; T12 next)
3. ~~Bottom navigation~~ (dropped in the morning; back in the afternoon as Design integration Part 3)
4. ⬜ Hardening

## (c) Current feature: Design integration — 11/14

Plan: `docs/plans/design-integration-plan.md`, approved 19 Nov (Q1: scale the role down;
Q2: 3:1 for the icon; Q3: the `app_theme.dart` comment is fixed in T3).

- ✅ T1 App bar title: role always whole, "MineChain" only when whole; account button ≥ 56 dp
- ✅ T2 Theme test: copper icon on `secondaryContainer`, light and dark
- ✅ T3 Docs: Mobile (35) with Mapalo's credit, the copper vs error-red limitation, the
  foundation plan's seed wording, the status line of the bottom navigation suggestion
- ✅ T4 Phone check on the A57: light, dark, largest text (the T1 rule holds; twelve changes
  requested, recorded as Mobile (36))
- ✅ T5 Home header: copper password and server notices with a pill button; role pill with
  the username
- ✅ T6 Logo and brand block under the tiles; name out of the app bar; splash and login
- ✅ T7 Adaptive launcher icon from the same geometry (phone check of the icon in T14)
- ✅ T8 Copper fields (underline kept), sand cards with a copper outline, outlined chips at 56 dp
- ✅ T9 Stronger tile shadows (5 and 8), no mid-word breaks (fewer columns first, then a
  smaller label), 16 dp between the "Send my work" lines
- ✅ T10 Navigation bar and rail look in the theme, light and dark (peach pill, copper outline)
- ✅ T11 The shell: homes and "My account" in one frame with a plain bar; task pages outside
  it; the account button goes to Account
- ⬜ T12 The bar (rail in landscape), the account button to Account, the back button
- ⬜ T13 Docs: Mobile (36) completed, Mobile (37) navigation bar
- ⬜ T14 Phone check on the A57, including the navigation bar

T5–T11 approved 19 Nov (Q4–Q7 as proposed; Q8: server notices in copper too). Part 3
(T10–T12) added 19 Nov at the developer's request and approved (Q9–Q13 as proposed); the
old T10 and T11 are now T13 and T14.

For T13, T9's choices to record in Mobile (36): the "Send my work" gap is 16 dp, not the
plan's 8 dp (the lines already had 8 dp; the developer chose 16 on 19 Nov), and the 32 dp
above "Send now" is kept; columns drop one at a time (3, then 2, then 1), so landscape with
large text keeps two columns when the words fit; a label too wide even for one column is
drawn at a smaller font size and still wraps between words (not a one-line FittedBox).

**Schedule (19 Nov): behind by about one day.**
- Still open from Wed 18: Design integration (T10–T14: about 3 h 30 min of Claude Code
  time and 45 min of phone check) and Hardening. The navigation bar adds about 3 h; the
  developer accepted that on 19 Nov.
- Thu 19's two features (Consignment check, Transporter handoff) have not started.
