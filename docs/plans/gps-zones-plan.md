# GPS zones plan

Status: **approved** (21 Nov 2026, Q1–Q6 as proposed). T1–T5 run one after another
without stopping (CLAUDE.md, "Flow per feature"); the next stop is the T6 phone check.

Branch: `feature/gps-zones`, created by the developer from `main` after PR #19.

## 1. Goal

FR-11 for the system administrator, the app's side of Scope (3) and (7). From the
**"GPS zones"** tile on their home, the administrator:

- sees the licensed extraction zones, active or inactive;
- opens one and sees its name, licence number, status, dates, its corners and a sketch of
  its shape;
- **creates** a zone: name, optional licence number, and its corners, either by standing
  at each corner ("Add my location") or by typing them;
- **renames** a zone (the only edit, Scope (7));
- **deactivates** a zone with a reason, and is warned if no zone is left active;
- **reactivates** an inactive zone.

**App only** (`mobile/` and `docs/`). All five endpoints exist and are deployed (api.md,
"GPS zone management (FR-11)"); nothing deploys to Render.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| `GET /admin/zones`, `POST /admin/zones`, `/rename`, `/deactivate`, `/reactivate`, the zone view, the boundary rules and their field paths, `NO_ACTIVE_ZONES` | `backend/`, api.md "GPS zone management" | everything this feature reads and does |
| The admin home: "GPS zones" says "Coming soon" | `admin_home_screen.dart` | the way in (T2) |
| The Accounts pattern: list with chips and paging, the page opened through a provider (not go_router's `extra`), the actions answering with the new view | `admin/presentation/accounts_*`, `account_page_*` | the same shape for zones |
| `ReasonDialog<T>` (words passed in), the password asked over an open dialog (`_withPassword`) | `admin/presentation/reason_dialog.dart`, `account_page_screen.dart` | deactivate's dialog; an ended session during an action |
| `LocationTracker`, the fix policy (25 m at most, 30 s old at most, no fake-location apps) | `steps/presentation/location_tracker.dart`, `registration/domain/gps_fix.dart` | "Add my location" (T5) |
| `fieldErrorsFrom(details)` | `core/errors/field_errors.dart` | the server's messages under the name and on each corner |
| `INVALID_STATUS_TRANSITION` shown with the server's sentence | `failure_text.dart` | deactivate or reactivate when another administrator acted first |
| Production: one active zone, "ZCAS Campus (demo)", from the seed | `docs/deployment.md` | the phone check must never deactivate it |

## 3. How it fits

- **Actors:** the administrator only. Every path sits under `/admin`, so the router keeps
  every other role out, and the server refuses them with 403 anyway.
- **What a zone does:** sync checks every new registration against the **active** zones.
  A registration outside all of them is stored flagged (`GPS_ZONE`), raises an alert and
  holds the consignment. A change applies from the next sync; steps already stored keep
  their zone.
- **No read-one endpoint**, as for accounts: the zone page starts from the list's row
  (`openedZoneProvider`), and every action answers with the new zone view.
- **Never deleted, never reshaped.** The boundary and licence number are fixed at
  creation (Scope (7)). A new shape is a new zone, by the API's "Replacing a zone": rename
  the old one, create the new one with the old name, deactivate the old one. The zone page
  says so in one line (Q5).
- **Which actions show, by status:**

  | Status | Rename | Deactivate | Reactivate |
  |---|---|---|---|
  | active | ✓ | ✓ | |
  | inactive | ✓ | | ✓ |

- **Corners are `[latitude, longitude]`, latitude first.** The app always shows and sends
  them in that order. They are plain JSON numbers with at most 6 decimal places (about
  10 cm). Zones are not signed, so numbers are fine here (the "text, not floats" rule is for
  signed payloads). A test checks the exact bytes sent.
- **Who checks what.** The app checks what it can on its own: each corner is two numbers
  in range with at most 6 decimals, and there are 3 to 100 corners. The shape rules stay
  with the server: no repeated corner, no closed ring, inside Zambia (which catches swapped
  corners), at least 100 m², at most 50 km across. Their messages are shown on the corner
  they name ("Corner 4: repeats the first corner …") or under the corner list.

## 4. The screens

1. **GPS zones** (`/admin/zones`).
   - Two chips, "Active" (default) and "Inactive"; "2 active zones." from `total`; 20 at a
     time with "Show more"; pull down to refresh; read again on return from a zone.
   - Each card: name; licence number or "No licence number"; "5 corners"; "Created 10 Nov".
   - While the active list is empty, a warning card: "No zone is active. Every new
     registration is flagged as outside a licensed zone until you create or reactivate
     one."
   - A "Create zone" button (an extended floating button, as on Accounts).
   - Empty, offline, slow, an ended session: the shared sentences, "Try again" and the
     password prompt.
2. **Zone** (`/admin/zones/zone`).
   - Name, licence number, status in words, "Created 10 Nov, 09:00", "Changed 12 Nov, 11:30"
     when it differs.
   - **Shape:** a sketch of the corners joined in order, drawn by the app on a plain
     background (no map, Q2), with the corners numbered.
   - **Corners:** "Corner 1  −15.418327, 28.289494", one per line.
   - The fixed-boundary line: "The boundary and licence number cannot be changed. To change
     them, rename this zone, create a new one with its name, then deactivate this one."
   - The buttons of §3's table.
3. **Create zone** (`/admin/zones/new`).
   - Name (3–100 characters), licence number (optional, up to 50), both trimmed.
   - **Corners**, numbered, each with a remove button, and the live sketch once there are
     three.
   - **"Add my location"**: asks for location access the first time, shows "Finding your
     location… 40 m", and adds the first reading that passes the fix policy, rounded to 6
     decimals. Stand at each corner of the site in turn and tap it.
   - **"Type a corner"**: one field, "latitude, longitude", the way Google Maps shows a
     dropped pin (for example "-15.418327, 28.289494"). Refused as typed if it is not two
     numbers, out of range, or has more than 6 decimals (Q3).
   - "Create zone" is on with a name and at least 3 corners. `ZONE_NAME_TAKEN` goes under
     the name; field paths `boundary.N` and `boundary.N.M` go on corner N+1; `boundary` goes
     under the list.
   - Android back with unsaved corners asks "Leave without creating the zone?" first.
4. **The dialogs.**
   - **Rename:** the name filled in, 3–100 characters, "Save". The same name is not sent.
     `ZONE_NAME_TAKEN` under the field, with the server's sentence (it explains that
     inactive zones keep their names).
   - **Deactivate** (`ReasonDialog`): "Registrations synced after this are no longer
     matched to Kasempa North. Steps already stored keep their zone." The reason (3–500,
     "Kept for ever in the audit log."). When the active list last read held one zone, the
     dialog adds: "This is the only active zone. After this, every new registration is
     flagged." (Q4)
   - **The warning after deactivate:** when the answer carries `NO_ACTIVE_ZONES`, a dialog
     with the server's sentence and one "I understand" button, so it cannot be missed.
   - **Reactivate:** a confirm: "Registrations synced after this are checked against
     Kasempa North again."
   - Refusals keep the dialog and what was typed: `ZONE_NOT_FOUND`,
     `INVALID_STATUS_TRANSITION` (the server's sentence, then the list is read again),
     offline, an ended session (the password over the dialog, then the same text sent
     again).

## 5. Subtasks

- ✅ **T1 Zones data** (about 45 min).
  - `admin/domain/gps_zone.dart`: `GpsZone` (every field of the zone view), `ZoneStatus`,
    `GpsZonesPage`, `ZoneCorner` (`latitude`, `longitude`), `ZoneWarning`; `fromJson`
    returns null for anything unreadable; `toString()` without corners.
  - `admin/domain/corner_input.dart`: `parseCorner(text)` → a corner or the problem (not
    two numbers, out of range, more than 6 decimals); `roundCorner(reading)` for a GPS fix;
    `cornerLabel` for display. Plain Dart.
  - `admin/data/admin_zones_api.dart` and `admin_zones_repository.dart`: `zones(status,
    offset)`, `create(name, licenceNumber, corners)`, `rename(id, name)`, `deactivate(id,
    reason)` → zone and warning, `reactivate(id)`.
  - `api_codes.dart` and `failure_text.dart`: `ZONE_NOT_FOUND`'s sentence;
    `ZONE_NAME_TAKEN` left to the form, as `USERNAME_TAKEN` is.
  - `test/fakes/fake_zones_server.dart`: zones by status, names unique ignoring case
    (inactive included), the status table, the last-active warning, and a way to answer
    with given field details.
  - Tests: api.md's examples parsed (active, inactive, no licence number, the warning);
    an unreadable zone makes the page unreadable; the path, query and exact body bytes of
    every call (`[-13.45,25.82]`, not `"-13.45"`); `parseCorner` on good, swapped-looking,
    7-decimal, out-of-range, one-number and three-number input; each sentence.
- ✅ **T2 Zones list** (about 45 min).
  - `/admin/zones` (`AppRoutes.adminZones`), the "GPS zones" tile wired.
  - §4.1: chips, count, cards, paging, refresh on open, pull down and return, the
    no-active-zone card, empty and failure states.
  - Widget tests with the fake server, text 2.0 in portrait and landscape;
    `homes_test.dart`: "GPS zones" opens its path, "Anchoring" and "Reports" still "Coming
    soon" (changed by plan: the comment and `testing-log.md` say so).
- ✅ **T3 Zone page** (about 45 min).
  - `admin/presentation/zone_shape_view.dart`: the sketch (a `CustomPaint`; corners
    projected flat around their middle, scaled to fit, numbered), shared with T5.
  - The route and §4.2, `openedZoneProvider`, the buttons by status.
  - Tests: each status shows exactly its buttons; the corners in the server's order and
    exact text; the sketch's painter gets every corner (and draws nothing with fewer than
    three); the fixed-boundary line; text 2.0.
- ✅ **T4 Rename, deactivate, reactivate** (about 50 min).
  - §4.4's dialogs; deactivate uses `ReasonDialog`; the warning dialog; each answer
    replaces the zone on the page with its message ("Kasempa North is inactive.").
  - The password-over-the-dialog helper moves out of `account_page_screen.dart` to a
    shared file if it fits as it is; its account tests must pass untouched.
  - Tests: each body exactly as sent; the same name not sent; `ZONE_NAME_TAKEN` under the
    field; the warning shown only when the answer has it, and the pre-warning only with one
    active zone; `INVALID_STATUS_TRANSITION` (the list read again); `ZONE_NOT_FOUND`;
    offline; an ended session sends the same text again; a double tap sends once.
- ✅ **T5 Create zone** (about 70 min).
  - `/admin/zones/new` and §4.3: the form, the corner list with remove, "Type a corner",
    "Add my location" (its own `LocationTracker`, started only by the tap and stopped after
    one fix), the live sketch, the server's messages on the right corner, leave-first on
    Android back.
  - Tests: the body bytes for a typed triangle; a GPS reading rounded to 6 decimals and
    added; a reading over 25 m, a stale one and a fake-location one are not added, with
    the location sentences the registration screen uses; location refused; "Create" off
    with 2 corners; 101 corners refused locally; `boundary.3` on corner 4, `boundary.1.0`
    on corner 2, `boundary` under the list; `ZONE_NAME_TAKEN` under the name; the new zone
    is in the "Active" list afterwards; leave-first; no corner in any log line
    (`debugPrint` captured).
- 🟡 **T6 Phone check** (the developer, about 40 min). See §6.
  - Done 21 Nov, 20:32–21:15, A57 as the administrator: steps 1, 4 (the swapped corner;
    "Typed Check Zone" made from seven Google Maps pins at a filling station) and 7
    (airplane mode). All as planned; the swapped corner drew the other seven as one point
    beside it, which shows the mistake at a glance.
  - Left for daylight on 22 Nov: step 2 (the walked "Phone check site", at a second filling
    station) and step 3 (a registration matched to it), taken into the end-to-end test.
  - Steps 5 and 6 (rename, the name-taken refusal, online deactivate and reactivate): done,
    as expected. Found: the remove button on "Create zone" sat lower than its corner's
    line.
- ✅ **T6b Corner row** (found in T6): with a remove button, the corner's line is the
  button's 48 dp high with the text centred, so the icon sits level with it; an error
  stays underneath. The zone page's rows are unchanged. 2 new tests.
- ⬜ **T7 Docs and PR** (about 20 min). `decisions.md` GPS zones app (1)–(n) and the known
  limitations; `testing-log.md`, `progress.md`, `CLAUDE.md`; the PR description in chat.

About 4.5 h of Claude Code time plus the developer's 40 minutes. A fix found by T6 becomes
T6b, as before.

**Commits.** T1–T5 all add to `app_text.dart`, `routes.dart` and `app_router.dart` and run
without a commit between them, so they go in one code commit; the docs go in a second after
T6 (a script in chat).

**Known limitations to record (T7):**

- No map: the sketch shows the shape, not where it lies on the ground (Q2).
- The app cannot catch a shape whose edges cross (a "bow-tie"); neither can the server
  (api.md, "Not checked"). The sketch makes one easy to see.
- Corners cannot be reordered while creating; remove and add again.
- No search by name; the list is paged 20 at a time.
- A "walked" zone is only as good as each reading (up to 25 m off).

## 6. The phone check (T6, planned now so the steps are clear)

On production, so it follows three rules: **never deactivate "ZCAS Campus (demo)"**, never
leave no zone active, and remember that zones are never deleted, so a check zone stays in
the list for good. `NO_ACTIVE_ZONES` is checked by the widget tests only.

1. A57, signed in as the administrator: "GPS zones" shows "ZCAS Campus (demo)" active.
2. **Walked zone:** "Create zone", name "Phone check site", stand at 4 corners of a yard or
   building and tap "Add my location" at each; the sketch; Create. It is in "Active".
3. As Clement on the A57, register a consignment standing inside it and send it: it is
   accepted with no "outside a licensed zone" flag.
4. **Typed zone:** "Create zone", "Typed check zone", type a triangle near the campus.
   First type a closed ring (the last corner again as the first): the server's sentence on
   corner 4; remove it. Then a swapped corner ("28.29, -15.42"): "is outside Zambia" on it;
   fix it; Create.
5. Rename "Typed check zone" to "Typed check zone (old)"; try to rename it to "phone check
   site": the name-taken sentence.
6. Deactivate "Typed check zone (old)" (reason "Made for the phone check"): no warning
   (other zones are active); it is in "Inactive"; Reactivate it; deactivate it again.
7. Airplane mode: Deactivate keeps the dialog, the reason and "No internet connection".

**Privacy:** a zone's corners sit in the production database (never on the chain), seen
only by administrators. Walk a public place rather than a home, or keep the corner list out
of the thesis screenshots.

## 7. Questions

- **Q1 Entering the corners.** **(A, proposed)** Both "Add my location" (walk the site) and
  "Type a corner" (one "latitude, longitude" field, as Google Maps shows a dropped pin).
  (B) Typed only (about 30 min less, but an administrator at the site cannot just walk
  it). (C) Tap the corners on a map: needs a new map package and map tiles downloaded from
  a third party, which fails offline and adds about 3 h.
- **Q2 The shape.** **(A, proposed)** A plain sketch drawn by the app (no map), on the zone
  page and live while creating, so a mistyped corner or a bow-tie is easy to see. (B) No
  sketch, the corner list only.
- **Q3 A typed corner with more than 6 decimals.** **(A, proposed)** Refused as typed,
  with the rule, as the server does: what you type is what is stored. (B) Rounded to 6
  decimals (about 10 cm) without asking. A GPS reading is always rounded, in both.
- **Q4 The last active zone.** **(A, proposed)** A pre-warning in the deactivate dialog
  when the list last read held one active zone; after the answer, the server's warning in
  a dialog that must be closed; and the warning card on the list while none is active.
  (B) Only the server's warning, as a message at the bottom of the screen.
- **Q5 Replacing a boundary.** **(A, proposed)** The one-line explanation on the zone page;
  the administrator does the three steps by hand. (B) A guided "Replace boundary" flow that
  does them in order (about 1 h more, and three calls that can fail half-way).
- **Q6 "Phone check site" after the check.** **(A, proposed)** It stays active: the
  consignments you register there in the end-to-end test are then not flagged. (B)
  Deactivate it at the end of T6, leaving only "ZCAS Campus (demo)" active.
