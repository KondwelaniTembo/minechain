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
- **Out of scope:** navigation does not change. The round account button in the top bar
  stays (navigation option A). Mapalo's bottom navigation suggestion
  (`docs/plans/bottom-navigation-suggestion.md`) is the **next** feature, built on its own
  branch, so it can be dropped without touching this one.

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

After T4 comes the PR for `design/mapalo-theme`, with Mapalo credited in the description.

## Checklist

- ⬜ T1 App bar title: role always whole, "MineChain" only when whole; account button ≥ 56 dp
- ⬜ T2 Theme test: copper icon on `secondaryContainer`, light and dark
- ⬜ T3 Docs: Mobile (35) with Mapalo's credit, the copper vs error-red limitation, the
  foundation plan's seed wording, the status line of the bottom navigation suggestion
- ⬜ T4 Phone check on the A57: light, dark, largest text

## Open questions

- **Q1.** If the role alone does not fit, should it be scaled down (the proposal) or wrap
  onto a second line? Scaling keeps the app bar's fixed height. A second line would need a
  taller app bar. Neither is expected to happen for the five role words.
- **Q2.** The icon contrast threshold. The proposal is 3:1, WCAG's rule for icons. The other
  theme tests use 4.5:1 because they check text. The colours pass 4.5:1 today, so asserting
  4.5:1 would also pass, but it is stricter than the standard asks.
- **Q3.** T3.c also changes a comment in `app_theme.dart`. Comment only, no behaviour. Is
  that fine inside a docs subtask?
