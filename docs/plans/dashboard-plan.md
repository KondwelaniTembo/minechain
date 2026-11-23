# Dashboard plan (FR-14)

Status: **approved 23 Nov 2026, Q1–Q5 as proposed (A).** Part 1 (T1, T2) done: `npm test`
2348, `npm run test:db` 932; merged as PR #24 and deployed. Part 2: **done, 6/6**
(`flutter test` 2623; phone check passed 23 Nov 03:32–03:53; T5b added; decisions
Dashboard app (1)–(6), three known limitations).

Branches, both created by the developer:

- **Part 1, server:** `feature/dashboard-api`, from `main` after PR #23. **Merging it deploys
  to Render.** This part is under "Ask first" (`backend/`); approving this plan approves it.
- **Part 2, app:** `feature/dashboard`, from `main` after Part 1's PR is merged and deployed,
  so the phone check runs against production.

## 1. Goal

FR-14 (Could Have, kept and built by Scope (4) and Scope (10)): "a dashboard showing
transaction volumes, anomaly frequencies and the geographic distribution of transactions by
mineral type and time period." In the proposal it is the regulatory officer's "Monitor
Supply Chain Dashboard": transaction volumes, active consignments and pending alerts.

The officer's home gets a **"Dashboard"** tile. It opens one read-only screen with, for a
chosen period and mineral:

1. **Right now:** open alerts, and consignments by stage (registered, on its way, bought).
2. **Volumes:** steps recorded, by type, with a bar per day (or per week for a long period),
   and the registered weight.
3. **By mineral:** steps and registered weight for each mineral.
4. **Where:** steps per licensed zone, plus "Outside every zone".
5. **Anomalies:** alerts raised, by rule and by severity, and how many are still open.

It is not the Anchoring screen (Scope (11)), and it changes nothing: no decisions, no
downloads. Detail stays where it is already: "Alerts", "Check a consignment", "Reports".

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| UTC day rules: `daySchema`, `utcDayRange`, `MAX_REPORT_DAYS` (366) | `backend/src/schemas/reports.js` | the same period rules for the dashboard |
| The FR-09 indexes `(captured_at)`, `(zone_id, captured_at)` | `transactions` | the counts by day and by zone |
| `db.transaction(fn, { isolation: 'repeatable read' })` | `backend/src/db` | every figure from one moment |
| Guards and error format, the `services` wiring | `backend/src/middleware`, `services/index.js` | the route |
| `insertCampusZone`, `loggedInSigner`, the real-stack helpers | `tests/db/realStackHelpers.js` | DB tests with real steps and alerts |
| `ApiClient`, the api → repository → controller layers, the password re-prompt when the session ends (`…NeedPassword`) | `features/admin/`, `features/alerts/` | the same layers |
| `weightInUnit(milligrams, unit)` | `registration/domain/weight.dart` | kilograms from text, no floats |
| Words for minerals, alert rules and severities | `AppText`, `alert_words.dart` | the same words on the dashboard |
| `HomeAction`, `HomeScaffold` | `core/widgets/home_scaffold.dart` | the new tile |

Missing: **no endpoint returns counts.** The transactions CSV holds steps but no alert
types, counts each download in the audit log and is limited to 20 per 15 minutes, so the
app cannot build the dashboard from it well (Q1).

## 3. How it fits

```
Officer's phone                          Render                       PostgreSQL
Dashboard screen ── GET /dashboard ──►  route (officer guard)  ──►  one REPEATABLE READ
  period chips        ?from&to&mineral   controller                   snapshot, fixed SQL:
  mineral chips   ◄── JSON counts ────   dashboardService.summary()   transactions, alerts,
                                                                       consignments, gps_zones
```

- Only the officer (Q2) reads it. Miners, transporters and buyers get 403, as with
  `/alerts`.
- Read-only, like `GET /alerts`: **not audited and not rate-limited** (nothing leaves the
  system but counts; no names, no ids of people, no coordinates).
- No chain call: anchoring states come from the database.

## 4. The endpoint (Part 1)

`GET /dashboard?from=YYYY-MM-DD&to=YYYY-MM-DD[&mineral=gold]`

- `from`, `to`: UTC days, both included, at most 366 days (the report rules, reused).
- `mineral`: optional, one of the six.
- Any other parameter, or one given twice: 400 `VALIDATION_FAILED`.
- `Cache-Control: no-store`.

**Which time counts.** A step belongs to the day its phone recorded it (`captured_at`, as in
the transactions report). An alert belongs to its step's day, so an alert and its step are
always in the same period. "Right now" ignores the period but follows the mineral.

**Which steps count.** Every stored step, whatever its review status: the dashboard shows
activity, and the anomaly part shows what was flagged. Registered weight counts **accepted**
registrations only (`passed` or `cleared`), so a duplicate does not count a load twice.

**200 OK** (fake values):

```json
{
  "period": { "from": "2026-11-17", "to": "2026-11-23", "days": 7 },
  "mineral": null,
  "now": {
    "openAlerts": 8,
    "consignments": { "registered": 4, "in_transit": 3, "purchased": 2 }
  },
  "steps": { "total": 21, "registration": 9, "handoff": 7, "purchase": 5 },
  "registeredWeightMg": "18500000",
  "byDay": [
    { "day": "2026-11-17", "registration": 2, "handoff": 0, "purchase": 0 }
  ],
  "byMineral": [
    { "mineral": "gold", "steps": 12, "registeredWeightMg": "6500000" }
  ],
  "byZone": [
    { "zoneId": "…", "zoneName": "ZCAS Campus (demo)", "active": true, "steps": 15 }
  ],
  "outsideZones": 6,
  "anomalies": {
    "total": 5, "open": 3,
    "byType": { "duplicate_consignment": 1, "quantity_discrepancy": 2, "gps_zone": 1,
                "invalid_signature": 0, "handoff_order": 1, "record_tampered": 0 },
    "bySeverity": { "low": 0, "medium": 3, "high": 2 }
  }
}
```

- `byDay` has **every day** of the period, zeros included (`generate_series`), in order.
- `byMineral` and `byZone` list only non-zero rows, most steps first, then by name.
  A deactivated zone still appears, with `active: false`.
- `byType`, `bySeverity` and `consignments` always have every key.
- Weights are whole milligrams **as text** (sums in SQL `numeric`, never JavaScript
  numbers), as everywhere else.
- Errors: 400 `VALIDATION_FAILED`, 401 token errors, 403 `FORBIDDEN`, 500 `INTERNAL_ERROR`.

## 5. The screen (Part 2)

```
← Dashboard
[ 7 days ] [ 30 days ] [ 12 months ]          period chips (Q4)
[ All ] [ Gold ] [ Copper ] [ Cobalt ] …      mineral chips
Right now      8 open alerts · 4 registered · 3 on their way · 2 bought
Volumes        21 steps · 18.5 kg registered
               ▇ ▃ ▁ ▅ ▇ ▂ ▄   one bar per day (per week for 12 months)
               9 registrations · 7 handoffs · 5 purchases
By mineral     Gold    ████████ 12 · 6.5 kg
Where          ZCAS Campus (demo)  ███████ 15
               Outside every zone  ███ 6
Anomalies      5 raised, 3 still open
               Quantity differs ██ 2 …        High 2 · Medium 3 · Low 0
```

- Bars are plain Flutter widgets in the theme's colours (Q3), each row with its number in
  words beside it, so the screen reads without the bars (screen readers, small phones).
- The day chart: up to 31 bars; "12 months" groups days into weeks in the app (the server
  sends days). Each bar's total has a `Semantics` label ("17 Nov: 2 steps").
- Loading, an error with "Try again", the password re-prompt when the session ends, and an
  empty period ("No steps recorded in these 7 days").
- Periods end today in UTC: "7 days" is today and the 6 days before it.

## 6. Subtasks

### Part 1, server, `feature/dashboard-api`

**T1 Service and schema** (about 60–75 min)
- T1.a `src/schemas/dashboard.js`: `dashboardQuerySchema` from `daySchema` and the 366-day
  rule; unit tests (missing, bad day, `to` before `from`, 367 days, unknown mineral, extra
  or repeated parameter).
- T1.b `src/services/dashboardService.js` `summary({ from, to, mineral })`: five fixed,
  parameterised queries in one `REPEATABLE READ` transaction (now, steps by day and type,
  by mineral, by zone, alerts); zero-filling; weights as text. Wired as
  `services.dashboard`.
- T1.c `tests/db/dashboard.test.js`: steps on chosen days (inside and outside the period,
  at the UTC day edges), the mineral filter, a step outside every zone, a deactivated zone,
  a flagged duplicate not counted in weight, alerts of several types and states, an empty
  period (all zeros, every day listed).
- Out: `npm test`, `npm run test:db` totals.

**T2 Route, docs** (about 45 min)
- T2.a `src/routes/dashboard.js`, `controllers/dashboardController.js`, mounted at
  `/dashboard`, officer guard, `no-store`. Real-stack test: officer 200; miner,
  transporter, buyer, admin 403; no token 401; a bad query 400; the body holds no
  username, full name, licence number or coordinate.
- T2.b Docs: `api.md` "Dashboard (FR-14)", `database-schema.md` (the queries and which time
  counts), `decisions.md` Dashboard (1)–(n).
- **Stop:** the server commit (one, Source Control), PR, merge (deploys), and a check that
  Render is live (`/health`). I never call production.

### Part 2, app, `feature/dashboard`

**T3 Data** (about 45 min)
- `features/dashboard/domain/dashboard_summary.dart` (the model, strict parsing, weeks
  from days), `dashboard_period.dart` (the three periods as UTC days from a given clock);
  `data/dashboard_api.dart`, `dashboard_repository.dart`;
  `test/fakes/fake_dashboard_server.dart`. Unit tests for parsing (missing keys refused,
  weights stay text), week grouping and the period days.

**T4 Screen** (about 75–90 min)
- `presentation/dashboard_controller.dart` (a family by period and mineral),
  `dashboard_words.dart`, `dashboard_widgets.dart` (`CountBar`, `DayBars`, the section
  card), `dashboard_screen.dart`; route `AppRoutes.officerDashboard`
  (`/officer/dashboard`); the officer's "Dashboard" tile (first after "Alerts").
- Widget tests: each section from the fake server, chip changes reload, empty period,
  error and "Try again", the session re-prompt, the officer tiles in `homes_test.dart`
  (a new tile, changed by plan).

**T5 Phone check** (the developer, A57 as `officer_demo`, production)

T3 and T4 done (2622 tests passed). Steps, planned at T4's end:

1. Home: a "Dashboard" tile, second after "Alerts". Open it: "Last 7 days" chosen, a
   spinner, then the cards. The line under the chips reads "17 Nov 2026 to 23 Nov 2026, UTC
   days" (or the week ending today).
2. "Right now": the open alerts match the "Alerts" list's Open count (8 on 23 Nov).
3. "Last 30 days": every step since 25 Oct, so the whole demo history, a bar per day.
   Note "N steps recorded". In "Reports", download the transactions report for the same
   30 days (the dates shown on the dashboard) and check that it says the same N records.
4. "Last 12 months": "Steps per week", the same N.
5. A mineral chip (Gold): the counts drop to gold only; "Any" brings them back.
6. "Where": "ZCAS Campus (demo)" and any typed or walked zone; "Anomalies": the rules that
   fired, then High, Medium, Low.
7. Airplane mode, tap refresh: the cards stay, "No internet connection" at the bottom.
   Back out and open again while offline: the full-page message with "Try again".
8. Settings → Display → font size largest: open again and scroll to the end; nothing cut
   off.

Screenshots for the thesis: `dashboard-7-days.png` (top), `dashboard-30-days-volumes.png`,
`dashboard-where-anomalies.png`, `dashboard-12-months.png`, `dashboard-offline.png`.

**T6 Docs and PR text**
- `decisions.md` Dashboard app (1)–(n) and known limitations; `progress.md`,
  `testing-log.md`, `CLAUDE.md`.

Known limitations expected: phone clocks decide the day (as in reports); days are UTC, so
a step at 01:00 in Lusaka counts on the day before; no map, only zones by name (Q3);
counts are not refreshed while the screen is open (pull down to refresh).

## 7. Questions

**Q1. Where the numbers come from.**
- **A (proposed):** a new read-only endpoint `GET /dashboard` (section 4). One small
  request; alert types included; no audit noise.
- B: app only, from the transactions CSV plus `GET /alerts`. Nothing deploys, but each
  view downloads up to 10,000 rows, writes a `report.transactions_export` audit entry,
  uses up the 20-per-15-minutes report limit, and the alerts list would have to be paged
  through.

**Q2. Who sees it.**
- **A (proposed):** the officer only, as in the proposal's use case.
- B: the officer and the administrator (a tile on the admin's home too).

**Q3. Charts.**
- **A (proposed):** plain Flutter bars, no new package; "Where" is a list of zones.
- B: `fl_chart` (a new package, checked for version first), and maybe dots on a zone
  sketch. More time, a new dependency a day before submission.

**Q4. Periods.**
- **A (proposed):** three chips (7 days, 30 days, 12 months) and the mineral chips.
- B: also "Choose dates", reusing the Reports date pickers.

**Q5. The officer's home.**
- **A (proposed):** a "Dashboard" tile only.
- B: the tile plus a "Right now" line on the home itself (open alerts), as the proposal's
  wireframe shows; one more request each time the home opens.
