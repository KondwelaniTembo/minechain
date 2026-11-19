# Design integration plan (theme only)

Branch: `design/mapalo-theme` (main merged in at `ee2359f`). Feature on the Wed 18 Nov day
plan in `docs/progress.md`.

## What this feature is

Mapalo Maseko (GitHub `mapalomaseko`) restyled the app in commit `de7600d`:
- a burnt-copper theme with hand-set colour pairs and a patina-green tertiary colour;
- shadows that lift tiles, cards and banners off the page;
- a one-line app bar title, "MineChain" plus the role in a rounded label;
- a round, filled account button;
- copper icons on the sand tiles.

This feature finishes that work so it can be merged.
- **In scope:** it fixes one layout fault in the title, tests the parts that are not yet
  tested, credits the design and records its decisions.
- **Out of scope (Parts 1 and 2):** navigation does not change. The round account button
  in the top bar stays (navigation option A).
- **Added on 19 Nov (Part 3):** Mapalo's bottom navigation suggestion
  (`docs/plans/bottom-navigation-suggestion.md`), dropped earlier that day, is back at the
  developer's request. The account button stays as well, so there are two ways to reach
  "My account". See Part 3 (T10–T12).

## The fault being fixed

In `_AppBarTitle` (`mobile/lib/core/widgets/home_scaffold.dart`), "MineChain" and the role
label are each `Flexible`. When space runs out, both shrink and end in "…". At 360 dp wide
with the largest text, the role can show as "Admini…".
- **Why it matters:** the role is the part the user needs, because it says which kind of
  account they are in. "MineChain" is only branding.

The rule after the fix:
1. The role label is never cut. It is laid out at its full width.
2. "MineChain" is shown only when it fits whole next to the role. Otherwise it is left out,
   never shown as "Mine…".
3. If even the role alone is wider than the space (not expected for the five role words at
   360 dp and text size 2.0), it is scaled down to fit (`FittedBox`, `scaleDown`) rather
   than cut. See open question Q1.

How it works:
- A `LayoutBuilder` gives the width the app bar has left for the title.
- `TextPainter` measures both words with the phone's own text scale
  (`MediaQuery.textScalerOf`).
- `_AppBarTitle` then picks "both" or "role only". The text size is never clamped (plan
  section 7, the foundation plan).

## Subtasks

### T1. App bar title: the role always whole, "MineChain" only when whole

- **T1.a** Rewrite `_AppBarTitle` to follow the rule above. The role label keeps its colours
  (`primaryContainer` and `onPrimaryContainer`) and its shape. Comments explain why the role
  takes priority.
- **T1.b** Widget tests in `test/core/widgets/home_scaffold_test.dart`, in a new group "app
  bar title". The screen is 360×640 dp, the text scale is 1.0 and 2.0, and the roles are
  `Transporter` and `Administrator` (the two longest), so there are four cases. In each case:
  - the role text is found, and it is not cut: its paragraph's full width fits inside its
    laid-out width;
  - "MineChain" is either absent, or found and not cut, measured the same way;
  - no layout exception (no overflow).
- **T1.c** One more case, at 900 dp wide with text 1.0: both words are shown. This proves
  that "MineChain" is not simply always hidden.
- **T1.d** An account button test, at 360×640 with text 1.0 and 2.0: the button found by
  its tooltip (`AppText.myAccount`) is at least 56×56 dp (`AppSizes.tapTargetMin`).
  - It already sets `minimumSize` 56, so the test should pass as it is.
  - If the default 56 dp app bar squeezes it, the fix is the app bar's `toolbarHeight`, not
    a smaller button.

Note on the test font: Flutter tests draw every letter as a square as wide as the font size.
Words are much wider than with Roboto on the phone, so in the 360 dp tests "MineChain" will
usually be hidden. The tests check the rule, not how the real phone looks. T4 checks the
real phone.

Inputs: `home_scaffold.dart`, `AppText`, `AppSizes`. Outputs: the fixed title and five new
widget tests. Connects to the five role homes (all use `HomeScaffold`) and nothing else. No
routing, state or server change.

### T2. Theme test: copper icon on the sand tiles

- **T2.a** In `test/core/theme/app_theme_test.dart`, add a test in the existing light and
  dark loop: `primary` on `secondaryContainer`, the copper icon on the other home tiles
  (`action_tile.dart`). It needs at least **3:1**, WCAG's minimum for icons and other
  non-text graphics (1.4.11). See Q2.
  - Hand-computed today: about 5:1 in light and about 6:1 in dark, so it should pass. The
    test stops a later colour change from quietly making the icons hard to see.

Only a test changes; no app code.

### T3. Docs: credit, decision, limitation and wording

- **T3.a** `docs/decisions.md`, a new row **Mobile (35)**:
  - the copper theme by Mapalo Maseko (GitHub `mapalomaseko`, `de7600d`) is adopted;
  - navigation option A is kept, with the account button in the top bar;
  - the title rule from T1 is part of the decision;
  - the bottom bar is planned as the next feature on its own branch, merged only if approved
    on the phone.
- **T3.b** `docs/decisions.md`, a new row **Known limitation, copper and error red look
  alike**:
  - copper `primary` and Material's `error` are about 1.01:1 apart in brightness, so only
    their hue separates them;
  - this is accepted because status is never shown by colour alone: a word and a tick or
    cross go with it;
  - a user with red-green colour blindness may not tell copper from red, so a screen must
    never use copper or red as the only signal.
- **T3.c** `docs/plans/mobile-foundation-plan.md`, lines 70 and 432: "from one seed colour"
  becomes "a copper seed colour, with some colour pairs set by hand (Mobile (35))". The same
  wording is fixed in the header comment of `mobile/lib/core/theme/app_theme.dart` (comment
  only, see Q3).
- **T3.d** `docs/plans/bottom-navigation-suggestion.md`: the status line becomes "Planned as
  the next feature, on its own branch. Nothing here has been built or tested yet."

### T4. Phone check on the A57 (the developer)

Done by the developer on the Samsung Galaxy A57, in a debug build. I will give the exact
`flutter run` command in the T3 report.

1. **Light mode, default text:**
   - login, then the miner home: copper title, role label, round account button, tiles with
     copper icons;
   - "My account" opens;
   - the server status banner.
2. **Dark mode** (Settings → Display → Dark): the same screens.
3. **Largest text** (Settings → Display → Font size and style, the slider at maximum), in
   light and dark:
   - the role label is whole on every home seen, and "MineChain" is whole or absent, never
     "Mine…";
   - tiles grow and nothing overflows;
   - the account button is still easy to tap.
4. If the demo transporter or administrator account is at hand, repeat step 3 on that home,
   because "Administrator" is the longest role word.

Screenshots for the thesis, in `docs/screenshots/` or the thesis folder (the developer
decides):
- `design-miner-home-light.png`, `design-miner-home-dark.png`;
- `design-miner-home-largest-text-light.png`, `design-miner-home-largest-text-dark.png`;
- `design-account-dark.png`;
- `design-admin-home-largest-text.png` (if step 4 was done).

**T4 result (19 Nov, A57).** The T1 rule holds on the phone:
- at default text, both words show ("MineChain" and "Administrator");
- at the largest text, the role stays whole and "MineChain" is left out.

The developer then asked for twelve UI changes, which became T5–T11 below. The PR comes
after T11.

## Part 2: the developer's UI changes after the phone check (T5–T11)

Recorded as decision Mobile (36). They build on Mapalo's theme (Mobile (35), whose credit
stays), and every existing rule still applies:
- contrast in light and dark: text at least 4.5:1, icons and edges at least 3:1;
- tap targets at least 56 dp;
- a state is never shown by colour alone;
- no missed taps in tests (`warnIfMissed` stays on);
- a test for every change, failing on the old code where possible;
- 360×640 dp at text size 2.0, portrait and landscape.

All the contrast figures below were computed with the WCAG formula from the theme's
hand-set colours, and each new pair is asserted in `app_theme_test.dart` or in the screen's
own test.

### T5. Home header: the password notice and the role pill with the username (items 1, 6)

- **T5.a** The "Enter your password" notice (`home_header.dart`, `NeedsPasswordNotice`) moves
  from patina green to the colours of the main tile:
  - the notice: `primary` background with `onPrimary` text and key icon: 6.41:1 in light,
    7.68:1 in dark;
  - the "Enter password" button looks like the role pill: `primaryContainer` with
    `onPrimaryContainer` text (12.26:1 light, 7.48:1 dark), a rounded `tileRadius` shape and
    at least 56 dp tall;
  - the pill's edge against the notice: 4.98:1 light, 5.36:1 dark, so it reads as a separate
    button;
  - the key icon and the sentence stay, so the state is not shown by colour alone.
  - The same notice on "My account" (`_NeedsPasswordCard`) changes too (Q4), and so do the
    server's "waking up" and "not ready" notices (Q8).
- **T5.b** The role pill shows the role and the username, for example "Miner · Clement".
  - `HomeScaffold` takes an optional `username`. The five homes read it from the
    signed-in user (`SignedIn` and `SignedInNeedsPassword` both carry `user.username`).
  - The rule:
    1. the role is never cut (T1);
    2. the username takes the space that is left and ends in "…" when it runs out;
    3. when fewer than 3 characters of the username would show, it is left out, never
       "C…";
    4. if the role alone is too wide, the T1 scale-down still applies.
  - TalkBack reads "Miner, signed in as Clement".
- **Tests:**
  - Widget tests at 360×640 dp, text 1.0 and 2.0, for Transporter and Administrator with a
    short and a long username: the role is whole; the username is whole, ends in "…" or is
    absent; the pill stays left of the account button; there is no overflow.
  - The notice's button: at least 56 dp tall, tapped without a miss, opens the prompt.
  - A contrast test for the pill's edge on the notice (at least 3:1).
- **Fails on the old code:** there is no username, and the notice uses `tertiaryContainer`.
- **Estimate:** 60 min.

### T6. The MineChain logo and name: in the app and below the tiles (items 7, 8 in-app, 12)

- **T6.a** An original logo: a pick and a shovel crossed in an X. It is drawn with a
  `CustomPainter` (`core/widgets/mine_chain_logo.dart`), which needs no package.
  - The shapes are kept in one place (`core/brand/logo_geometry.dart`) on a 108-unit grid as
    plain path commands (move, line, curve, close), so T7 builds the launcher icon from the
    same drawing.
  - It is drawn in `primary` (light copper on dark, deep copper on light: 6.1:1 and
    10.29:1 against the screen, both above 3:1).
  - The logo is decorative to TalkBack; the name next to it is read once.
- **T6.b** A "brand block" (the logo, about 72 dp, above "MineChain" in copper) sits
  directly under the tiles on every home, 32 dp below the last tile, inside the scrolling
  column. It is never pinned or cut, and at large text it scrolls with the tiles.
- **T6.c** "MineChain" leaves the app bar, which now holds only the role pill and the
  account button.
  - This replaces part 2 of the T1 rule ("MineChain only when whole"), by decision
    Mobile (36).
  - The T1 tests that check "MineChain" in the app bar change with it: they now check that
    the app bar has no "MineChain" and the brand block has one. The role-whole assertions
    stay as they are.
  - This is a planned change of behaviour, not a weaker test.
- **T6.d** The splash and login screens show the logo above the name. Splash keeps its
  progress indicator.
- **Tests:**
  - For each of the five homes in `homes_test.dart`, at 360×640 dp and text 2.0: the logo
    and "MineChain" can be reached by scrolling, are on screen, cause no overflow, and are
    whole.
  - Splash and login show the logo.
  - A painter test: the logo paints in the theme's `primary` in both themes.
- **Fails on the old code:** there is no logo and no brand block.
- **Estimate:** 75 min.

### T7. Android launcher icon from the same drawing (item 8, launcher)

No package is needed. The app's minimum is Android 8.0 (API 26, `minSdk = 26`), which
supports adaptive icons on every phone the app can run on.
- **T7.a** A small Dart script (`tool/make_launcher_icon.dart`, run by hand) writes
  `res/drawable/ic_launcher_foreground.xml` as an Android vector drawable from
  `logo_geometry.dart`.
- **T7.b** `res/mipmap-anydpi-v26/ic_launcher.xml` declares the adaptive icon:
  - the background is deep copper `#8F4E1E` (`res/values/ic_launcher_background.xml`);
  - the foreground is the logo in cream `#FFDCC6`, 4.98:1 against the copper;
  - a monochrome layer is added for Android 13 themed icons.
- **T7.c** The logo is drawn inside the central 66 dp circle of the 108 dp canvas, Android's
  safe zone, so a round mask never cuts it.
  - The old `mipmap-*/ic_launcher.png` files stay. Android 8+ always uses the anydpi-v26
    icon, so they are never shown, and removing them is not worth the risk.
- **Tests:** a drift test that runs the generator in memory and compares its output with the
  committed XML, like the backend's ABI drift test, so the app logo and the launcher icon
  cannot drift apart. A test that every point of the geometry lies inside the 66 dp circle.
- **Phone check:** the icon on the A57's home screen and in the app drawer.
- **This touches `mobile/android/**`,** which is on the ask-first list. Approving this plan
  approves only the three new resource files above: no manifest, Gradle or signing change.
- **Estimate:** 45 min.

### T8. Login fields, cards and mineral chips (items 2, 3, 4, 9)

- **T8.a** Login fields in copper: the label, prefix icon, border and focused border use
  `primary`, with a 2 dp focused border.
  - 6.1:1 on the light screen, 10.29:1 on dark.
  - Done as an `inputDecorationTheme` in `app_theme.dart`, so the weight field on "Register
    consignment" matches (Q5).
  - The error state keeps Material's red border and its sentence under the field. Copper
    and red are only 1.01:1 apart (the Mobile (35) limitation), so the sentence is what
    marks an error, and a test checks it is shown.
- **T8.b** Cards on "My account" and "My consignments", proposed through `cardTheme`:
  - **Colour:** `secondaryContainer`, the tiles' sand (`#F3E0D2` light, `#4B392D` dark),
    with `onSecondaryContainer` text (12.92:1 light, 8.53:1 dark).
  - **Copper icons on it:** 5.01:1 light, 6.07:1 dark.
  - **Shadow:** elevation 3 with the warm shadow, like the tiles.
  - **Edge:** a 1 dp `primary` outline, 6.1:1 against the light screen, so the edge is
    clear even where the shadow is weak. The fill alone is only 1.22:1 from the light
    screen, which is why the outline is needed.
  - **Why not a darker sand:** I measured `#EAD3C2`. It is 1.37:1 from the screen, but
    copper text on it falls to 4.45:1 and the error red to 4.49:1, both below 4.5:1, so it
    is rejected.
  - The error lines in "My consignments" were checked on the new card: red `#BA1A1A` is
    about 5.4:1 light, and `#FFB4AB` is 6.43:1 dark.
- **T8.c** Mineral chips (`register_consignment_screen.dart`, through `chipTheme`):
  - **Unselected:** the screen colour with a 1.5 dp `primary` outline (6.1:1 light,
    10.29:1 dark) and elevation 2.
  - **Selected:** `primary` fill with `onPrimary` text (6.41:1, 7.68:1), elevation 4, and
    the existing tick, so the choice is not shown by colour alone.
  - Tap height stays at least 56 dp (the test asserts it).
- **Tests:**
  - Contrast tests for every new pair.
  - Widget tests: the login field borders and labels use `primary`; an error still shows its
    sentence; both cards use the new colour and outline; the chips' outline, elevation and
    tap height.
  - The register screen's existing 360×640 / text 2.0 portrait and landscape tests run
    unchanged.
- **Fails on the old code:** the default borders, the card colour and the chips are all
  different.
- **Estimate:** 60 min.

### T9. Tiles: stronger shadows, no word broken in the middle, more space on "Send my work" (items 10, 11, 5)

- **T9.a** Tile elevation goes from 3 to 5 for the other tiles and from 6 to 8 for the main
  tile, with the same warm shadow colour. The same values apply in light and dark.
- **T9.b** "My consig / nments": Flutter breaks a single word that is wider than its line.
  The proposal (Q6):
  - the home uses **one column** when the longest word of any tile's label does not fit in
    a two-column tile at the current text size, so the text keeps the size the user chose;
  - only if a word does not fit even the full width is that one label scaled down
    (`FittedBox`-style, measured like T1).
- **T9.c** "Send my work": an 8 dp gap between the four status lines above "Send now"
  (`send_work_screen.dart`, `_Counts`).
- **Tests:**
  - At 360×640 and text 2.0, portrait and landscape, every line of every tile label ends at a
    space or at the end of the label, never inside a word. This is checked from the
    paragraph's line metrics, and it fails on the old code ("My consig|nments").
  - The tile elevations.
  - The gap between the count lines is at least 8 dp.
  - The existing "no overflow, every tile reachable" tests stay.
- **Estimate:** 60 min.

## Part 3: the navigation bar (T10–T12)

Asked for on 19 Nov by the developer: Mapalo's bottom navigation bar **and** the round
account button, both, for usability. Recorded as decision Mobile (37), which reverses the
morning's "dropped" note.

**What the user sees:**
- On every home and on "My account", a bar with two destinations: **Home** and
  **Account**, each an icon and a word (plan section 7), at least 56 dp to tap.
- The bar shows where you are: the current destination sits in a copper pill.
- The round account button in the top bar stays. It goes to the same "My account" as the
  bar's Account, so there is one account page with two ways in (Q9).
- Inside a task ("Register consignment", "Send my work", "My consignments", "Account
  requests") the bar is hidden. The task covers the whole screen and its back arrow returns
  to the home (Q11).
- Android's back button on Account returns to Home; on Home it leaves the app.

**Rules it must keep:**
- Redirect rules 1–5 are unchanged: each role still reaches only its own home and
  `/account`, and signed-out users never see the bar.
- `SignedInNeedsPassword` keeps both destinations open (Mobile (11)), and the "Enter your
  password" notice shows on both.
- 360×640 dp at text 2.0, portrait and landscape: no overflow, the bar's words whole.
- Contrast in light and dark: text at least 4.5:1, icons at least 3:1.
- No new package: go_router 18.1.4 (already in the app) has `StatefulShellRoute`.

### T10. The bar's look in the theme

- `NavigationBarThemeData` and `NavigationRailThemeData` in `app_theme.dart`, light and dark:
  - background: the screen's colour (`surface`, like the top bar), raised by the warm
    shadow (elevation 3);
  - selected: a peach pill (`primaryContainer`, the role pill's colour) with a copper
    outline, an `onPrimaryContainer` icon and a bold copper word;
  - unselected: `onSurfaceVariant` icon and word (medium weight);
  - words at 14 sp, always shown (`alwaysShow`, rail `all`), never an icon alone.
  - As built: the peach pill is only 1.2:1 from the light screen, so its copper outline
    (6.1:1) is what marks it. Words 6.1:1 (chosen) and 8.9:1 light, 10.3:1 and 10.9:1 dark;
    the chosen icon 12.3:1 light, 7.5:1 dark.
- **Tests:** each colour pair's contrast, light and dark (`app_theme_test.dart`); the words
  are always shown.
- **Fails on the old code:** the theme has no navigation bar settings.
- **Estimate:** 45 min.

### T11. The shell: one frame around the homes and "My account"

- `core/router/app_router.dart`: the five homes and `/account` go inside one
  `StatefulShellRoute.indexedStack` with two branches, Home and Account. "Indexed stack"
  keeps the home alive while Account is shown, so its scroll position is kept.
- The task pages stay outside the shell, on the root navigator, so a `push()` covers the bar
  (Q11).
- Home's branch holds all five home paths; the redirect already puts each role on its own,
  and the bar's Home goes to `homeOf(role)`.
- **Tests (`app_router_test.dart`, `redirect_test.dart` re-run):**
  - every role: home → Account → Home, the right home each time;
  - log out as a miner, log in as an administrator: Home is the admin home, not the miner's
    (the shell must not keep the old role's page);
  - a task page has no bar; its back arrow returns to the home, with the bar;
  - `SignedInNeedsPassword`: both destinations open, the notice on both;
  - signed out: no bar on login, register, activate.
- **Estimate:** 60 min.
- **As built:** the shell needs a bar to be tested, so T11 also brought in a plain
  `NavigationBar` (`core/widgets/app_navigation.dart`, outlined and filled icons) and moved
  the five homes' account button from `push` to `go` (Q9): a push across the shell's
  branches would leave a second account page. T12 keeps the rest below.

### T12. The bar, the account button and the back button

- `core/widgets/app_navigation.dart`: the bar (Home, Account), built by the shell.
  - Portrait: Material 3 `NavigationBar` at the bottom.
  - Landscape on a phone (height under 480 dp): a `NavigationRail` on the side with icon and
    word, so an 80 dp bar does not take a quarter of a 360 dp screen (Q12).
  - At large text the bar grows with the words instead of cutting them.
  - The icon is outlined when not chosen and filled when chosen (`Icons.home_outlined` /
    `Icons.home`), so the choice is shown by shape as well as colour (T10's theme comment
    relies on this).
  - TalkBack reads "Home, tab 1 of 2" and "Account, tab 2 of 2" (Flutter gives the tab
    semantics).
- The account button in `HomeScaffold` now switches to the Account destination (`go`, not
  `push`), so the bar shows Account as selected (Q9).
- `AccountScreen`: no back arrow, because it is a destination now, not a page on top
  (Q10). Android back on Account goes to Home (`PopScope`).
- **As built (T12):** Flutter's `NavigationBar` draws its words at most 1.3× their size
  (`_kMaxLabelTextScaleFactor`), whatever the phone's setting; the rail follows the phone.
  The bar's height and word fit are measured at that 1.3× limit, so at text 2.0 the bar
  grows only a little. The rail is as wide as its widest word, up to 144 dp for a word; past
  that the rail's words shrink just enough to stay whole. A test records both behaviours, so
  a Flutter upgrade that changes them shows up. Whether to keep the 1.3× limit is Q14.
- **Tests:**
  - 360×640 and text 2.0, portrait (bar) and landscape (rail), on each home and on
    Account: no overflow, both words whole, every tile still reachable;
  - the account button and the bar's Account open the same page, with Account selected;
  - Android back: Account → Home, then the app closes;
  - each destination at least 56 dp; TalkBack names;
  - `account_screen_test.dart`: the back-arrow tests change by decision (Q10), with a
    comment and a row in `docs/testing-log.md`.
- **Estimate:** 75 min.

### T13. Docs

- Complete Mobile (36) in `docs/decisions.md` with what was built (colours, rules, the
  measured contrasts) and with the answers to Q4–Q6.
- Mark Mobile (35)'s title rule part 2 as replaced by Mobile (36); Mapalo's credit is
  unchanged.
- Add a row on the launcher icon approach.
- Add Mobile (37), the navigation bar (Q9–Q12), credited to Mapalo's suggestion; take it off
  the future improvements list; set the suggestion file's status to "built".
- **Estimate:** 30 min.

### T14. Phone check on the A57 (the developer)

- **Light and dark, default and largest text:**
  - homes: the pill with the username, the brand block below the tiles, the stronger tile
    shadows, and no broken words;
  - the password notice: log in, wait for the token to expire or use the test path, check
    its colours and that the button is easy to tap;
  - login: the copper fields and the logo; splash;
  - "My account" and "My consignments": the cards;
  - "Register consignment": the chips;
  - "Send my work": the spacing.
- **Navigation bar (Part 3):** on each home you can sign in as, in portrait and landscape:
  Home → Account → Home with the bar, and Account with the top bar's button; Android back on
  Account goes Home and on Home closes the app; a task page ("Register consignment") has no
  bar; the bar's words whole at the largest text; light and dark.
- **Launcher icon:** on the home screen and in the app drawer, with the round mask.
- **Screenshots:**
  - `ui2-miner-home-light.png`, `ui2-miner-home-dark.png`
  - `ui2-admin-home-largest-text.png`
  - `ui2-password-notice.png`
  - `ui2-login-light.png`
  - `ui2-account-light.png`
  - `ui2-consignments-light.png`
  - `ui2-chips-light.png`
  - `ui2-send-work.png`
  - `ui2-launcher-icon.png`
  - `ui2-nav-bar-home.png`, `ui2-nav-bar-account.png` (portrait)
  - `ui2-nav-rail-landscape.png`
- **Estimate:** 45 min (the developer).

After T14 comes the PR for `design/mapalo-theme`, crediting Mapalo for the theme and the
navigation bar idea, and noting that Mobile (36) and (37) hold the developer's changes.

## Checklist

- ✅ T1 App bar title: role always whole, "MineChain" only when whole; account button ≥ 56 dp
- ✅ T2 Theme test: copper icon on `secondaryContainer`, light and dark
- ✅ T3 Docs: Mobile (35) with Mapalo's credit, the copper vs error-red limitation, the
  foundation plan's seed wording, the status line of the bottom navigation suggestion
- ✅ T4 Phone check on the A57: light, dark, largest text (the T1 rule holds; twelve changes
  requested)
- ✅ T5 Home header: copper password notice with a pill button; role pill with the username
- ✅ T6 Logo (CustomPainter) and brand block under the tiles; name out of the app bar; splash
  and login
- ✅ T7 Adaptive launcher icon from the same geometry, no package
- ✅ T8 Copper login fields, sand cards with a copper outline, outlined chips
- ✅ T9 Stronger tile shadows, no mid-word breaks, spacing on "Send my work"
- ✅ T10 Navigation bar look in the theme, light and dark
- ✅ T11 The shell: homes and "My account" in one frame; task pages outside it
- ✅ T12 The bar (rail in landscape), the account button to the Account destination, the
  back button (75 min)
- ✅ T13 Docs: Mobile (36) completed, Mobile (35) title rule marked replaced, Mobile (37)
  navigation bar (30 min)
- ✅ T14 Phone check on the A57, including the navigation bar (the developer, 19 Nov: fine)

T10 and T11 were renumbered T13 and T14 on 19 Nov when Part 3 was added. Part 3 adds about
3 h of Claude Code's time and 15 min to the phone check.

## Open questions

- **Q1.** If the role alone does not fit, should it be scaled down (the proposal) or wrap
  onto a second line? Scaling keeps the app bar's fixed height. A second line would need a
  taller app bar. Neither is expected to happen for the five role words.
- **Q2.** The icon contrast threshold. The proposal is 3:1, WCAG's rule for icons. The other
  theme tests use 4.5:1 because they check text. The colours pass 4.5:1 today, so asserting
  4.5:1 would also pass, but it is stricter than the standard asks.
- **Q3.** T3.c also changes a comment in `app_theme.dart`. Comment only, no behaviour. Is
  that fine inside a docs subtask?

Q1–Q3 were answered on 19 Nov: scale down, 3:1, yes.

- **Q4.** Should the password notice on "My account" (`_NeedsPasswordCard`) get the same
  copper colours as the one on the homes? The proposal is yes, so the same state looks the
  same everywhere.
- **Q5.** Should the copper field style apply to every text field (the proposal: through
  the theme, so the login and weight fields match) or only to the login screen?
- **Q6.** For long words at large text, should the home switch to one column (the proposal:
  the text keeps its size), or should the word be scaled down a little in two columns? Down
  to the size needed, "consignments" at text 2.0 on a 360 dp phone would be drawn at about
  1.3×.
- **Q7.** Where should the brand block sit: directly under the tiles (the proposal), or
  pushed to the bottom of the screen when there is room? Under the tiles is simpler and
  never moves with the screen height.
- **Q8.** The green server notices ("server waking up") keep patina green, since only the
  password notice was asked about. Is that right?

Answered on 19 Nov:
- Q4–Q7 as proposed;
- **Q8: no.** The server's "waking up" and "not ready" notices take the same copper as the
  password notice, and their "Try again" becomes the same pill button. This is added to
  T5. Server problems keep the red error colours: a pill on red would hardly show
  (`primaryContainer` and `errorContainer` are nearly the same pink).
- The Bottom navigation feature is dropped. The top bar's account button stays.
  **Reversed later on 19 Nov:** the developer asked for the bar and the button both (Part 3).

Part 3 (the navigation bar), open:

- **Q9.** What does the top bar's account button do now? The proposal: it goes to the same
  Account destination as the bar, and the bar shows Account as selected. One account page,
  two ways in. The other way: it keeps pushing a separate account page on top of the home,
  which would leave two copies of "My account" in the app.
- **Q10.** Does "My account" keep its back arrow? The proposal: no. It is a destination of
  the bar now, like Home, and Material puts no back arrow on those. Home is one tap away on
  the bar, and Android's back button goes there too.
- **Q11.** Is the bar shown inside a task ("Register consignment", "Send my work", …)? The
  proposal: no. The task covers the screen, so a scan or a form has no stray buttons to hit
  by accident, and the screen keeps its full height. Its back arrow returns to the home.
- **Q12.** In landscape, where is the bar? The proposal: a rail on the side with icon and
  word, because at the bottom it takes 80 of the 360 dp of height. The other way: the
  same bottom bar in both orientations (simpler, less room in landscape).
- **Q13.** Built on this branch, before the docs and the phone check (the proposal), so one
  docs pass, one phone check and one PR cover the theme and the bar. The other way: the PR
  for the theme first, then the bar on its own branch (safer to drop, but a second phone
  check and PR).

Q9–Q13 were answered on 19 Nov: all as proposed.

- **Q14 (found in T12).** Flutter's bar caps its words at 1.3× the normal size, which goes
  against plan section 7's "the phone's text size is never clamped". The proposal: keep
  Flutter's cap for the bar only. The words stay whole, the page titles and tiles keep the
  full size, the account button reaches the same page, and Material caps the words on
  purpose so the bar stays smaller than the page. The other way: replace Flutter's
  destinations with our own widgets that follow the full size (about 45 min more, and a much
  taller bar at the largest text).

Q14 was answered on 19 Nov: keep Flutter's 1.3× cap, for the bar only. T13 records it in
Mobile (37) as a known limitation. The developer checked T10–T12 on the A57 the same day:
fine.
