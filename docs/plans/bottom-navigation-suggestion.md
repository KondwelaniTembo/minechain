# Suggestion: a bottom navigation bar (Home and Account)

**Status: built on 19 Nov 2026** (decision Mobile (37); `docs/plans/design-integration-plan.md`,
Part 3, T10–T12). Dropped that morning to recover time, then brought back the same afternoon
at the developer's request.

Built differently from this suggestion in one way: the round account button in the top bar
**stays** beside the bar (point 3 under "How it could be built" was not done), and it opens
the same Account place. The rest follows the suggestion:
- `StatefulShellRoute.indexedStack`, so the home keeps its scroll position;
- no back arrow on "My account";
- Android back on Account goes Home;
- a rail on the side in landscape;
- task pages hide the bar.

One correction to "What to watch": a `StatefulShellRoute` does not send back from Account to
Home by itself. Android closes the app from any branch's first page, so a `PopScope` in the
frame does it (`core/widgets/app_navigation.dart`).

The text below is the suggestion as written, kept as history.

## Why consider it

Today the only way around the app is one round account button in the top bar, which pushes
`/account` on top of the home. It works, but:

- Account is a hidden destination: a new user has to guess what the round button does.
- A bottom bar puts both places one thumb-tap away, and shows where you are.
- It is common on Android, so it needs no explaining.

## What it would look like

Two destinations, no new pages: **Home** (the role's own home) and **Account**
(the existing `/account`). Android's `NavigationBar`, at the bottom, with an icon and a
word on each, to follow plan section 7 (icon and word, 56 dp tap targets).

## How it could be built

1. In `core/router/app_router.dart`, wrap the five homes and `/account` in one
   go_router `ShellRoute` (or `StatefulShellRoute.indexedStack` if each tab should keep its
   own scroll position). The shell builds a `Scaffold` with only a `bottomNavigationBar`; the
   screens keep their own `Scaffold` and app bar.
2. The Home destination goes to `homeOf(role)` (already in `redirect.dart`); Account goes to
   `AppRoutes.account`. The bar is shown only when signed in, so the login, register and
   activate pages stay outside the shell.
3. Remove the round account button from `HomeScaffold` (and its `onAccountPressed`
   parameter from the five homes), and the back arrow from `AccountScreen`: it is a tab
   now, not a page pushed on top.

## What to watch

- **Redirect rule 5** (`redirect.dart`) lets every signed-in role open exactly `/account`
  and its own home. A shell does not change that, but `redirect_test.dart` should be
  re-run.
- **`SignedInNeedsPassword`** keeps both tabs open (decision Mobile (11)); check that the
  "Enter your password" notice still shows on both.
- **Android's back button:** on the Account tab it should return to Home, and on Home it
  should leave the app. A `StatefulShellRoute` gives this behaviour for free; a plain
  `ShellRoute` needs a small `PopScope`.
- **Landscape on a 5-inch phone:** an 80 dp bar costs a lot of a 360 dp height. Consider
  hiding the labels in landscape, or a `NavigationRail` on the side.
- **Future role modules** (register consignment, scan, and so on) will be pages under each
  role's home. Decide whether the bar stays visible on them or hides inside a task; hiding
  it keeps a scan or a form free of accidental taps.

## Tests that would need changing

`test/core/router/app_router_test.dart`, `test/features/account/presentation/account_screen_test.dart`
(opening Account, the back arrow, the log out flow), `test/features/homes_test.dart` and
`test/core/widgets/home_scaffold_test.dart` (the account button's tooltip).
