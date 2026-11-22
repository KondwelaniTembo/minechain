# Reports plan

Status: **done, 7/7** (approved 21 Nov 2026, Q1–Q6 as proposed; Q1 approves `share_plus`
13.3.1; T5b added after the phone check).
T1–T4 run one after another without stopping (CLAUDE.md, "Flow per feature"); the next
stop is the T5 phone check.

Branch: `feature/reports`, created by the developer from `main` after PR #20.

## 1. Goal

The app's side of FR-09 and FR-13, as Scope (3) puts it: **download the CSV and share it
from the phone.**

- **Transactions report (FR-09)**, from the "Reports" tile of the officer, the buyer and
  the administrator: choose a period and a few filters, download the file, and share it
  (Drive, Gmail, WhatsApp, a "save to device" target, whatever the phone offers). A buyer's
  file holds only their own purchases; the server sees to that.
- **Audit trail (FR-13)**, for officers only, in two kinds:
  - **one consignment**: its whole history, from the officer's "Check a consignment"
    result;
  - **one person**: everything they recorded in a period, from an alert's page (the alert
    names the person who recorded the step).

**App only** (`mobile/` and `docs/`). Both endpoints exist and are deployed (api.md,
"Reports (FR-09, FR-13)"); nothing deploys to Render.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| `GET /reports/transactions`, `GET /reports/audit-trail`, the file format, the filename rule, `REPORT_TOO_LARGE`, 20 downloads per 15 min | `backend/`, api.md "Reports" | everything this feature downloads |
| `ApiClient`: pinned TLS, the token, every failure as an `AppFailure`, `retryAfter` | `core/network/api_client.dart` | the download, through a new bytes method (T1) |
| "Reports" tiles on three homes and "Audit trail" on the officer's, all "Coming soon" | `officer_home_screen.dart`, `buyer_home_screen.dart`, `admin_home_screen.dart` | the ways in (T3, T4) |
| `ConsignmentView.id` (the consignment's id) | `verification/domain/consignment_view.dart` | the consignment's audit trail (T4) |
| `AlertActor.id` and `username` | `alerts/domain/alert.dart` | one person's audit trail (T4) |
| The password asked again when the session ends, then the same request sent again | `account_page_screen.dart` (`_withPassword`), the check screen's `_NeedsPassword` | a session that ends during a download |
| `MineralChips` | `registration/presentation/mineral_chips.dart` | the mineral filter |
| `path_provider` 2.1.6 | `pubspec.yaml` | the app's own cache folder for the file |

## 3. How it fits

- **Actors and paths.** One transactions screen, reached at `/officer/reports`,
  `/buyer/reports` and `/admin/reports`. Each sits under its role's prefix, so the
  redirect's role rule keeps miners and transporters out with no new rule, as
  Consignment check does. The server also refuses them with 403.
- **The audit trail is the officer's only.** Its buttons appear only on officer screens
  (`/officer/check` and `/officer/alerts/:id`). A buyer's or administrator's request would
  get 403 anyway.
- **From tap to file:**
  1. The app checks the period locally (to on or after from, at most 366 days counting
     both), the same rule the server applies.
  2. `GET` with the query, `Accept: text/csv`, and a 120 s time limit. A full
     10,000-row file is about 6 MB, which needs more than the usual 30 s on 3G.
  3. Answer 200: the body must be `text/csv`, or it is a `BadResponse`. The filename is
     taken from `Content-Disposition` only if it matches `^minechain-[a-z0-9.-]+\.csv$`;
     otherwise the app builds the same name itself. A name from the network never
     becomes a path unchecked.
  4. The bytes are written unchanged (BOM included, so Excel reads the letters right) to
     `<app cache>/reports/<filename>`, after deleting any earlier report there (Q5).
  5. The app counts the records (quotes taken into account, since an officer's notes may
     hold a line break) and shows "142 rows" or "No rows in this period".
  6. Android's share sheet opens with the file (Q6).
- **Refusals** come back as JSON, as everywhere, so the existing `_refusalFrom` reads
  them: `REPORT_TOO_LARGE` with its sentence, 429 with the server's sentence,
  `VALIDATION_FAILED` under the dates, `CONSIGNMENT_NOT_FOUND` and `USER_NOT_FOUND` with
  theirs. An ended session asks for the password, then sends the same request again.
- **Every download is in the server's audit log** (actor, IP, filters, row count). On
  production that is a record of each phone-check download, which is fine and expected.
- **What the file holds.** Usernames, roles, licence numbers, weights, coordinates and
  hashes, never full names or IP addresses (api.md). Once shared, the file is outside the
  app's control: that is what the regulator needs, and it is recorded as a limitation.

## 4. The screens

### 4.1 Reports (transactions)

Title "Reports", a back arrow to the home.

- **Period:** "From" and "To" buttons that open Flutter's own date range picker (no new
  package). Default: the 30 days ending today (Q4). One line under them: "Days are
  counted in UTC, Lusaka time minus 2 hours."
- **Filters,** each "Any" by default:
  - Mineral: `MineralChips` plus "Any".
  - Step: Any, Registrations, Handoffs, Purchases.
  - Review: Any, Passed, Flagged, Cleared, Rejected. **Not shown to a buyer**, whose file
    holds accepted steps only.
  - On the chain: Any, Waiting, Sent, Confirmed, Failed.
- **"Download and share"** (one `BusyButton`; a double tap downloads once).
- **The result card:** the filename, "142 rows", the time downloaded, and "Share again".
  A failure shows its sentence in the card instead, and the form keeps every choice.
- A buyer sees one more line: "Your file holds only the consignments you bought."

### 4.2 Audit trail of one consignment

On the officer's "Check a consignment" result only, under the consignment block:
**"Download audit trail"**. It downloads `?consignmentId=<view.id>` and opens the share
sheet; the same result card appears under the button. The officer's "Audit trail" tile
opens this same check screen (Q2), so the officer scans first.

### 4.3 Audit trail of one person

On the alert page, in the step's block: **"Download audit trail of mutale_banda"**. A small
dialog asks for the period (the same From and To buttons, 30 days by default), then
downloads `?actorId=<actor.id>&from=…&to=…` and shares it.

## 5. Subtasks

- ✅ **T1 Download data** (about 60 min). Done: 65 new, full run 2402 passed.
  - `ApiClient.getFile(path, query, token, timeout, accept)` → `DownloadedFile(bytes,
    filename)`: the same failure mapping and session reporting as `_send` (shared code,
    not a copy); a 200 that is not `text/csv` is a `BadResponse`; the filename check of
    §3. The existing JSON methods are unchanged and their tests pass untouched.
  - `reports/domain/report_query.dart`: `TransactionsQuery` and `AuditTrailQuery`
    (`.consignment(id)` and `.person(id, from, to)`) → the query map; `utcDay(date)`;
    `periodProblem(from, to)` (order and 366 days, both counted); `fallbackFilename`.
    Plain Dart.
  - `reports/domain/csv_records.dart`: `countRecords(bytes)` (BOM skipped, quotes and
    `""` handled, the header not counted).
  - `reports/data/reports_api.dart`, `reports_repository.dart`,
    `report_file_store.dart` (writes to `<cache>/reports/`, deletes earlier files first,
    refuses any name that fails the check).
  - `api_codes.dart` and `failure_text.dart`: sentences for `REPORT_TOO_LARGE`,
    `USER_NOT_FOUND`, and the 429 on a report.
  - `test/fakes/fake_reports_server.dart`: both reports, the role rules, the buyer's
    limit, the 366-day rule, the row cap, the rate limit, the not-found ids.
  - Tests: the exact path and query of every kind (ids in lower case, no stray `?`, a
    filter left out when "Any"); 31 Jan to 31 Jan the next year (366 days with a leap
    day) and 367 days; `Accept: text/csv`; a JSON 200 refused; a hostile filename
    (`../x.csv`, `a"b.csv`, `MINECHAIN.csv`) replaced by the fallback; bytes written
    unchanged, BOM included; an earlier report deleted; `countRecords` on api.md's two
    examples, a header only, a notes cell with CRLF inside quotes, and `""` inside a cell;
    no CSV byte and no query in any log line (`debugPrint` captured).
- ✅ **T2 Share** (about 30 min). Done: 12 new, full run 2414 passed. Found in share_plus's
  Android code (13.3.1): it adds **no permission**, only a non-exported FileProvider
  (`<cache>/share_plus/`) and a non-exported receiver for the user's choice. It **copies**
  the file into `<cache>/share_plus/` and empties that folder at the start of the next
  share, so a second private copy stays until then. It grants read and write on that copy
  to the apps that can handle the share menu (the system's chooser), and read to the app
  picked. The original in `<cache>/reports/` is never shared. `unavailable` (the phone
  could not say) shows no line at all rather than "Not shared", which could contradict a
  share that happened.
  - Add **`share_plus: 13.3.1`** (Q1). After `flutter pub get`, read its Android manifest
    in the pub cache and record in the report any permission or provider it adds.
  - `reports/data/report_sharer.dart`: `ReportSharer.share(file)` behind a provider, so
    widget tests use a fake that records the call. The real one sends the file with
    `text/csv` and the filename as its subject.
  - Tests: the fake gets the path written by T1; `dismissed` and `unavailable` leave the
    card saying "Not shared", with "Share again"; a share that throws shows a sentence,
    not an error screen.
- ✅ **T3 Reports screen** (about 70 min). Done: 30 new. The filters use one shared
  `ReportFilterChips` ("Any" first) rather than `MineralChips`, which has no "Any".
  - The three routes, the three "Reports" tiles wired; `reports/presentation/
    reports_controller.dart` (the form, one download at a time) and `reports_screen.dart`
    (§4.1).
  - Tests: the default period; each filter changes the query and "Any" leaves it out;
    the buyer has no review filter and has its own line; a 367-day period refused
    locally with the sentence; `REPORT_TOO_LARGE`, 429 with its sentence, offline,
    `BadResponse`; an ended session asks for the password and sends the same query
    again; a double tap downloads once; the form keeps its choices after a failure; text
    2.0 in portrait and landscape; a miner sent to `/buyer/reports` goes home.
    `homes_test.dart`: the three tiles open their paths, and "Anchoring" stays "Coming
    soon" (changed by plan: the comment and `testing-log.md` say so).
- ✅ **T4 Audit trails** (about 50 min). Done: 19 new; full run after T3 and T4 2463
  passed, 0 skipped. The consignment's button sits at the foot of the check result, above
  "Scan again" (the result view already takes a footer), not under the consignment block.
  Each card shows only for its own consignment or person, so a card from an earlier one
  never appears under another result.
  - §4.2: the button on the check result, shown only when the screen is the officer's;
    the "Audit trail" tile opens `/officer/check`.
  - §4.3: the button and the period dialog on the alert page.
  - Both use the T3 controller's download and the same result card (moved to a shared
    widget if it fits as it is).
  - Tests: the button is on the officer's check result and absent for the transporter
    and the buyer; the query is the view's id; `CONSIGNMENT_NOT_FOUND` and
    `USER_NOT_FOUND` show their sentences; the person's query carries the actor's id and
    the period; the dialog refuses 367 days; the alert page's other buttons and their
    tests are unchanged; the tile opens the check.
- ✅ **T5 Phone check** (the developer, 22 Nov, 12:55–13:47 on the A57 as `officer_demo`,
  16:11–16:25 on the emulator as buyer Kay and the administrator; production). All seven
  steps of §6 as planned:
  - officer, 30 days: 19 rows, exactly the server's steps (0007's three steps confirmed;
    0008's purchase rejected and never anchored; the eight flagged registrations);
  - the 0008 audit trail had 11 rows with the officer's notes; Clement's trail had 13
    (3 account events, including the approval by `mc_adminkay`, 5 registrations and
    5 zone alerts); the dialog's 30 days ran 24 Oct to 22 Nov;
  - offline: "No internet connection", the filters kept;
  - buyer Kay: 6 rows, only 0007 and 0009, never 0008, no review filter, the buyer note;
  - administrator: 19 rows, no audit-trail button;
  - the app's row count matched WhatsApp's every time (WhatsApp counts the header);
    shared to WhatsApp, Gmail and Drive, and opened in Google Sheets on the A57.

  Found:
  - (a) Google Sheets on Android read the files as Western (Windows-1252), so the
    server's BOM showed as `ï»¿` before the first header, with that header's quotes;
  - (b) the failure card and the file's card ("Share again") appeared below the visible
    page, so "Download and share" seemed to do nothing offline;
  - (c) after a failure, changing the filters left the old card, whose "Try again"
    would have sent the old choices.

  Also found, outside Reports: checking 0008 raised two false high `record_tampered`
  alerts (`TX_NOT_FOUND`). PublicNode keeps receipts and logs for only about the last
  10,000 blocks (about 33 hours), while the transactions are still in their blocks. It
  is fixed on its own branch (server code plus a second RPC provider), not here.
- ✅ **T5b Fixes** (decided by the developer on 22 Nov: the BOM option A, the scrolling
  and the stale card). The repository writes the file without the BOM
  (`withoutByteOrderMark`), and everything after it byte for byte. `ReportStatusCard`
  scrolls itself into view when a new kind of card appears (the bar, a failure, the
  password, the file), with `keepVisibleAtEnd`, so the button stays in sight where it
  fits; a change of the share line does not move the page. A new choice in the form
  clears a failure or password card (`forgetFailure`), and a saved file's card stays.
  Two tests changed by decision, each with a comment: the repository's "byte for byte"
  test, and the double tap test, which now waits for the scroll, since a page ignores
  taps while it scrolls.
- ✅ **T6 Docs and PR** (about 20 min). Done: `decisions.md` Reports app (1)–(10), five
  known limitations and one future improvement; `testing-log.md`, `progress.md`,
  `CLAUDE.md`; the PR description in chat. The T5b re-check passed on the A57 (22 Nov).

About 3.5 h of Claude Code time plus the developer's 30 minutes. A fix found by T5
becomes T5b, as before.

**Commits.** T1–T4 all add to `app_text.dart`, `routes.dart` and `app_router.dart` and run
without a commit between them, so they go in one code commit (with `pubspec.yaml` and
`pubspec.lock`); the docs go in a second after T5 (a script in chat).

**Known limitations to record (T6):**

- Days are UTC days, not Lusaka days: a step at 01:00 in Lusaka on 10 Nov falls on 9 Nov.
  The screen says so.
- No actor or zone filter on the transactions report (Q3); the officer has the person's
  audit trail instead.
- A shared file is outside the app's control once it leaves.
- The latest report stays in the app's private cache until the next download (Q5), and
  share_plus's copy of it until the next share (T2).
- Excel or Sheets may show `weight_kg` with fewer decimals; the file itself always has
  six.

## 6. The phone check (T5, planned now so the steps are clear)

On production. Each download is recorded in the audit log and counts towards 20 per 15
minutes per account, so the check uses about 8.

1. A57 as `officer_demo`: "Reports", the default 30 days, "Download and share". The
   share sheet opens; send it to Google Drive (or Gmail to yourself). Open it in Google
   Sheets: the header row, `MC-2026-LSK-0007` with three steps, no strange characters,
   weights with six decimals.
2. Same screen, Review "Rejected": only rejected rows, with 0008's purchase among them.
3. "Check a consignment", scan 0008, "Download audit trail": rows for the registration,
   the handoff's alert and its clearing, the purchase's alert and its confirmation,
   with the notes typed in Officer alerts T5.
4. "Alerts", open one of 0001–0005, "Download audit trail of <username>", 30 days: that
   person's steps and their account events.
5. Airplane mode, "Download and share": "No internet connection", the form unchanged.
6. Emulator as buyer Kay: "Reports", 30 days: only consignments Kay bought (0007, and 0009
   if its purchase was accepted), never 0008, and no review filter.
7. Emulator as the administrator: "Reports" downloads; there is no audit-trail button
   anywhere.

**Screenshots for the thesis:** `reports-form-officer.png` (§4.1 with the result card),
`reports-share-sheet.png`, `reports-sheets-view.png` (the file open in Sheets, rows
cropped to demo data), `audit-trail-consignment.png` (the check result with its button).
The files hold demo usernames and licence numbers only, but crop the coordinates out of
the Sheets screenshot anyway.

## 7. Questions

- **Q1 Getting the file off the phone.** **(A, proposed)** `share_plus` **13.3.1**
  (Flutter Community, verified publisher, published about 1 Oct 2026; needs Flutter
  3.38.1+, AGP 8.12.1+, Kotlin 2.2.0+; this app has 3.47.9, 9.1.0 and 2.4.0). Android's
  share sheet offers Drive, Gmail, WhatsApp and the phone's own "save" targets, which is
  how a file reaches a regulator here. No storage permission: the file stays in the app's
  private cache and the chosen app gets a one-time read grant. (B) Our own Kotlin "Save
  as" (Android's document picker), no package, but about 1 h more and Kotlin this laptop
  does not compile in tests (Hardening, known limitation). (C) Both, about 1.5 h more.
- **Q2 Where the audit trails start.** **(A, proposed)** The consignment's from the
  officer's check result, with the "Audit trail" tile opening the check; the person's from
  the alert page. Both have the id already, and the officer cannot list users (that is
  the administrator's `/admin/users`). (B) A small "Audit trail" page that explains both
  ways and links to them (about 20 min more, and one more page to learn).
- **Q3 Transactions filters.** **(A, proposed)** Period, mineral, step, review (not for a
  buyer) and on-the-chain status. (B) Also a zone picker for the administrator, from
  `/admin/zones` (about 30 min more; the officer cannot read zones).
- **Q4 The default period.** **(A, proposed)** The 30 days ending today, with the UTC
  line. (B) Today only.
- **Q5 The file afterwards.** **(A, proposed)** Kept in the app's private cache until the
  next download replaces it, so "Share again" works and a slow receiving app (Gmail
  attaches after a pause) still finds it. (B) Deleted on leaving the screen, which can
  break a share still in progress.
- **Q6 The share sheet.** **(A, proposed)** Opens straight after the download, with
  "Share again" on the card. (B) The card first, then a "Share" tap.
