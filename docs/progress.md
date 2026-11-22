# Progress

The working plan to submission on **Sunday 22 November 2026, 12:00** (work stops at 10:00).
Updated after every subtask. How the levels work (Project → Day → Feature → Subtask → Steps)
is in `CLAUDE.md`, "Working agreement (autopilot)".

Last updated: 22 Nov 2026, the verification fix's server part (A) on
`fix/chain-check-pruned-receipts` (`npm test` 2318, `npm run test:db` 914). Scope (10): FR-16
cut, FR-14 kept and built. Next: the developer's commit, PR and Render settings (B), the two
0008 alerts cleared, then the dashboard plan. The
submission window is open until about 16:47 on Tue 24 Nov (news on 22 Nov); the day plan
for 22 Nov evening is in (b).

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

- ✅ Buyer purchase and "My purchases" (Scope (8)), 5/5; merged as PR #17
- ✅ Full chain on devices: miner → transporter → buyer, synced and anchored (MC-2026-LSK-0007
  "Verified", three steps on the chain, 20 Nov; buyer purchase T4, Q5)
- ➡️ Officer alerts: moved to Sat 21

### Sat 21 Nov

- ✅ Officer alerts (from Fri 20, 7/7): list, detail, "Confirm problem" and "Clear, no
  problem" (FR-08, Scope (2), (5)); phone check on MC-2026-LSK-0008: handoff cleared and on
  the chain, purchase flagged and confirmed (rejected). Merged as PR #18
- ✅ Admin accounts (8/8): list, create with activation code, edit name, suspend and
  reactivate, delete, reset a device key (FR-10, FR-12, Scope (3), (6)); Fred's device
  key reset on production. A password reset is not built: the API has none (Q1, a
  known limitation). Merged as PR #19 (`e3af2bd`)
- ✅ GPS zones (7/7): list, create (walked or typed corners, a sketch), rename, deactivate,
  reactivate (FR-11, Scope (7)). The walked zone is checked in daylight on 22 Nov, with the
  end-to-end test
- ✅ Reports (7/7, done 22 Nov): download the CSV and share it from the phone, and the
  officer's two audit trails (FR-09, FR-13); PR #21
- ➡️ Dashboard (FR-14): moved to 22–23 Nov, kept and built (Scope (10))
- ✅ FR-16 decision: the signed PDF certificate is cut (22 Nov, Scope (10))
- ⬜ End-to-end test of every role (it starts with the walked "Phone check site" zone and a
  registration inside it, GPS zones T6 steps 2 and 3)

### Sun 22 Nov, until 10:00

- ⬜ Final OWASP review and fixes
- ⬜ Release-build performance, including 3G on the emulator (NFR-03)
- ⬜ README with screenshots and Mapalo's design credit
- ⬜ Release tag (created by the developer)

### Open items

- ✅ Production migration `1794528000000_users-deleted`: closed. Run on 15 Nov, about 22:30,
  after a backup and before PR #8 was merged (`docs/deployment.md`, commit `efd8a5f`).
- ✅ Scope (4): FR-14 kept (17 Nov); FR-16 cut (22 Nov, Scope (10)). FR-15 and FR-16 are
  the only requirements left out.
- ⬜ The admin's "Anchoring" tile says "Coming soon": the server endpoints exist (Anchoring
  admin N1–N5), the app screen was never planned. Build it or take the tile away: the
  developer's choice.
- ✅ Day plan: approved by the developer on 18 Nov.

## (b) Today, Sun 22 Nov (evening; submission window until about 16:47 on Tue 24 Nov)

1. ✅ Reports: T5b re-check passed on the A57, T6 docs and the PR text done (7/7)
2. ⬜ Verification fix (server, approved 22 Nov: both parts): a pruned receipt is no
   longer called tampering, and Alchemy becomes the primary RPC with PublicNode as the
   fallback; then the two false 0008 alerts are cleared with a reason
   - ✅ (A) the code and docs, on `fix/chain-check-pruned-receipts` (2318 + 914 passed)
   - ⬜ the developer's commit, PR and merge (this deploys to Render)
   - ⬜ (B) Render settings: `SEPOLIA_RPC_URL` Alchemy, `SEPOLIA_RPC_URL_FALLBACK` PublicNode
   - ⬜ check on production: 0008 checked again reads "Verified" or "could not check", no new
     alert; then the officer clears the two 0008 alerts with a reason
3. ✅ Scope (10): FR-16 cut; FR-14 (dashboard) kept and built, decided by the developer
   (the earlier "cut FR-14" here was a proposal the developer did not agree to)
4. ⬜ Dashboard (FR-14): plan first, then build
5. ⬜ End-to-end test of every role, shortened, with the typed zone
6. ⬜ README, final pass (security over the last features), `CLAUDE.md` status
7. ⬜ The submission zip (`git archive`, committed files only) and the release tag

The thesis starts on Mon 23 Nov, in chat.

## (b) Sat 21 Nov

1. ✅ Officer alerts (7/7), merged as PR #18
2. ✅ Admin accounts (8/8), merged as PR #19
3. ✅ GPS zones (7/7; walked zone on 22 Nov)
4. ⬜ Reports (T1–T4 done; the T5 phone check next)
5. ⬜ The FR-16 decision
6. ⬜ Dashboard (FR-14, the first cut)
7. ⬜ End-to-end test of every role

### Fri 20 Nov (from 11:30)

1. ✅ Consignment check, carried over from Thu 19 (7/7; merged as PR #15): ✅ two result-page
   fixes (1587 tests passed); ✅ the rest of T6 (offline, a verified result); ✅ T7 docs
2. ✅ Transporter handoff, carried over from Thu 19: 8/8 (T5b added); merged as PR #16
3. ✅ Buyer purchase and "My purchases": 5/5; its phone check also covered
   "Full chain on devices" (Q5). Merged as PR #17
4. ✅ Full chain on devices (inside Buyer purchase T4); ➡️ Officer alerts moved to Sat 21,
   where FR-14 (dashboard) is the first cut

Done on Thu 19 (session ended 20 Nov, 00:40): Hardening (PR #13), "My account" back arrow
(PR #14), Consignment check T1–T5 (1584 tests passed, 0 skipped).

## (c) Current feature: Verification fix — 1/4

No plan file: the fix was approved on 22 Nov as described in `CLAUDE.md` (found in Reports
T5). Branch `fix/chain-check-pruned-receipts`, from `main` after PR #21. **Server code:
merging deploys to Render.** Decisions Verification fix (1), (2), one known limitation.

- ✅ A. `chainCheck.js` step 4 (`receiptPruned`), `chainReader.getTransaction`, the fake
  reader; docs (`contract-spec.md` 7.1 and 7.2, `api.md` the chain check, `decisions.md`,
  `deployment.md`); 18 new tests, `npm test` 2318, `npm run test:db` 914
- ⬜ The commit, PR and merge (developer)
- ⬜ B. Render settings (developer): Alchemy primary, PublicNode fallback
- ⬜ Production check (0008 again, no new alert), then the officer clears the two 0008 alerts

## (c) Earlier: Reports — 7/7

Plan: `docs/plans/reports-plan.md`, approved 21 Nov (Q1–Q6 as proposed; Q1 adds
`share_plus` 13.3.1). Branch `feature/reports`, from `main` after PR #20. App only (`mobile/`, `docs/`);
nothing deploys to Render.

- ✅ T1 Download data: `ApiClient.getFile`, the queries, the record count, the file store;
  65 new, full run 2402 passed
- ✅ T2 Share: `share_plus` 13.3.1, `ReportSharer`, the download controller; 12 new, 2414
- ✅ T3 Reports screen: the form, the result card, the three routes and tiles; 30 new
- ✅ T4 Audit trails: the check result's button, the alert page's button and period
  dialog, the "Audit trail" tile; 19 new; full run after T3 and T4: 2463 passed, 0 skipped
- ✅ T5 Phone check (the developer, 22 Nov, A57 and emulator, production): all seven steps as
  planned; three rough edges found (the BOM in Sheets, cards out of sight, a stale failure
  card), plus false `record_tampered` alerts on 0008 from PublicNode's pruned receipts
  (fixed on its own branch)
- ✅ T5b Fixes: no BOM in the saved file, the card scrolls into view, a new choice clears a
  failure; 18 new, 2481 passed. Re-check passed on the A57 (22 Nov)
- ✅ T6 Docs and PR: decisions Reports app (1)–(10), five known limitations, one future
  improvement; the PR text in chat
- Commits: (1) code, T1–T4 and T5b, with `pubspec.yaml` and `pubspec.lock`; (2) docs

### GPS zones — 7/7, merged as PR #20 (`2fbf65b`)

Plan: `docs/plans/gps-zones-plan.md`, approved 21 Nov (Q1–Q6 as proposed). Branch
`feature/gps-zones`, created by the developer from `main` after PR #19. App only
(`mobile/`, `docs/`); nothing deploys to Render. T1–T5 run without stopping (CLAUDE.md,
"Flow per feature").

- ✅ T1 Zones data: `GpsZone`, `parseCorner`, the five calls, `fake_zones_server.dart`
- ✅ T2 Zones list: `/admin/zones`, two chips, the no-active-zone card, the tile wired
- ✅ T3 Zone page: details, corners, the shape sketch, buttons by status
- ✅ T4 Rename, deactivate (with the last-zone warning), reactivate
- ✅ T5 Create zone: typed corners and "Add my location", the live sketch, the server's
  messages on the right corner. A race found by the session test (the router's redirect
  re-run put the page back); fix A, approved by the developer: close after the end of the
  frame. Full run 2335 passed, 0 skipped
- T1–T5 ran without stopping, so none is committed: one code commit (T1–T5), then a docs
  commit after T6
- ✅ T6 Phone check (the developer, 21 Nov, A57, production): the lists, the zone page,
  "Typed Check Zone" from seven Google Maps pins, the swapped corner's server message,
  airplane mode on Deactivate, all as planned. The walked zone and a registration matched
  to it move to daylight on 22 Nov, inside the end-to-end test
- ✅ T6 part 2: rename, the name-taken refusal, online deactivate and reactivate fine
- ✅ T6b Corner row: the remove button level with its corner; 2 new, 2337 passed
- ✅ T7 Docs and PR: decisions GPS zones app (1)–(8), five known limitations, one future
  improvement; the PR text in chat
- Commits: (1) code, T1–T5 (`08cd99a`); (2) docs (`f159f07`); (3) T6b with its docs

### Admin accounts — 8/8, merged as PR #19 (`e3af2bd`)

Plan: `docs/plans/admin-accounts-plan.md`, approved 21 Nov (Q1–Q6 as proposed; Q1: no
password reset, a known limitation). Branch `feature/admin-accounts`, created by the
developer from `main` after PR #18. App only (`mobile/`, `docs/`); nothing deploys to
Render.

- ✅ T1 Accounts data: `AdminAccount`, `ActivationCode`, the eight calls, four sentences,
  `fake_accounts_server.dart`; 48 new
- ✅ T2 Accounts list: `/admin/accounts`, five chips, cards, paging, the tile wired; 33 new
- ✅ T3 Account page: `actionsFor`, the details and the buttons by status; 24 new
- ✅ T4 The five actions and the shared `ReasonDialog` ("Account requests" unchanged); the
  opened account moved to a provider (found by a test); 26 new
- ✅ T5 Create account and the code page, "New activation code"; 25 new; full run 2144
  passed, 0 skipped
- T1–T5 ran without stopping, as the developer asked, so none is committed. Every code
  file is new or touched by several subtasks (`app_text.dart`, `routes.dart`,
  `app_router.dart`), so T1–T5 go in one code commit; the docs in a second after T6.
- ✅ T6 Phone check (the developer, 21 Nov, emulator and A57): all as planned; three
  rough edges found
- ✅ T6b Fixes: "My account" refresh, the password asked for inside an open dialog, the
  code on one line; 15 new, 2159 passed
- ✅ T7 Docs and PR: decisions Admin accounts app (1)–(8), three known limitations, two
  future improvements; the PR text in chat
- Commits: (1) code, T1–T5 and T6b; (2) docs

### Officer alerts — 7/7, merged as PR #18 (`c24254a`)

Plan: `docs/plans/officer-alerts-plan.md`, approved 20 Nov (Q1–Q6 as proposed). Branch
`feature/officer-alerts`, created by the developer from `main` after PR #17. App only
(`mobile/`, `docs/`); nothing deploys to Render.

- ✅ T1 Alerts data and words: `Alert` and its parts, the words per alert type, the API and
  repository, `ALERT_NOT_FOUND`'s sentence; 97 new, 1903 passed
- ✅ T2 Alerts list: `/officer/alerts`, the tile wired, Q1's "Open", "Confirmed", "Cleared";
  33 new (30 + 3 in `homes_test.dart`)
- ✅ T3 Alert detail: `/officer/alerts/:id`, every section, Q2's "only confirm"; 19 new
- ✅ T4 The two decisions: the dialog, the message from the answer, every refusal, Q3 never
  queued; 24 new, 1979 passed
- T1–T4 ran without stopping, as agreed, so none is committed. Files by subtask:
  - T1 only: `mobile/lib/features/alerts/domain/alert.dart`,
    `mobile/lib/features/alerts/presentation/alert_words.dart`,
    `mobile/lib/features/alerts/data/alerts_api.dart`,
    `mobile/lib/features/alerts/data/alerts_repository.dart`,
    `mobile/lib/core/errors/failure_text.dart`, `mobile/test/fakes/fake_alerts_server.dart`,
    `mobile/test/features/alerts/domain/alert_test.dart`,
    `mobile/test/features/alerts/presentation/alert_words_test.dart`,
    `mobile/test/features/alerts/data/alerts_repository_test.dart`,
    `mobile/test/core/errors/failure_text_test.dart`;
  - T2 only: `alerts_list_controller.dart`, `alerts_screen.dart`, `alert_widgets.dart`
    (also used by T3) in `mobile/lib/features/alerts/presentation/`,
    `mobile/lib/features/officer/presentation/officer_home_screen.dart`,
    `mobile/test/features/alerts/presentation/alerts_screen_test.dart`,
    `mobile/test/features/homes_test.dart`;
  - T3 and T4: `alert_detail_controller.dart`, `alert_detail_screen.dart` (one page, the
    dialog inside it), and the tests `alert_detail_screen_test.dart`,
    `alert_decision_test.dart`, `alert_page_helpers.dart`;
  - all four: `mobile/lib/core/text/app_text.dart` (T1's words are there too, by the
    one-file rule for sentences), `mobile/lib/core/router/routes.dart`,
    `mobile/lib/core/router/app_router.dart`. So T1 alone would not build either, and
    T1–T4 go in one code commit (the plan had T1 alone);
  - docs: `docs/plans/officer-alerts-plan.md`, `docs/progress.md`, `docs/testing-log.md`,
    `CLAUDE.md`: the docs commit after T5.
- ✅ T5 Phone check (20 Nov 23:46 – 21 Nov 00:27, A57 as `officer_demo`, emulator as buyer):
  all eight steps as planned (results in the plan); two misleading lines found
- ✅ T5b Fixes: "Holds this consignment" only on open alerts; a rejected step "Never put
  on the blockchain" on the Check page and left out of its verdict; 9 new, 1988 passed.
  Files: `mobile/lib/features/alerts/presentation/alert_widgets.dart`,
  `mobile/lib/core/text/app_text.dart`,
  `mobile/lib/features/verification/domain/verdict.dart`,
  `mobile/lib/features/verification/presentation/check_result_view.dart`,
  `mobile/test/features/alerts/presentation/alerts_screen_test.dart`,
  `mobile/test/features/verification/domain/verdict_test.dart`,
  `mobile/test/features/verification/presentation/check_result_roles_test.dart`. Nothing
  is committed yet, so they join the T1–T4 code commit. A57 re-check passed (21 Nov)
- ✅ T6 Docs and PR: decisions Officer alerts app (1)–(9), Verification app (11), two known
  limitations, one future improvement; the PR text in chat
- Commits: (1) code, T1–T4 and T5b; (2) docs, every docs file and `CLAUDE.md`

### Buyer purchase — 5/5, merged as PR #17 (`93c1a94`)

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
