# Admin accounts plan

Status: **approved** (21 Nov 2026, Q1–Q6 as proposed). T1–T5 run without stopping as
the developer asked; T6 phone check done (emulator and A57), and it found three rough
edges, fixed in T6b (approved by the developer, 21 Nov); T7 done. 2159 tests passed,
0 skipped. A short re-check of T6b on the phones is left. **8/8** (T6b added).

Branch: `feature/admin-accounts`, created by the developer from `main` after PR #18.

## 1. Goal

FR-10 and FR-12 for the system administrator, the app's side of Scope (3) and (6). From
the **"Accounts"** tile on their home, the administrator:

- sees every account by status (active, suspended, invited, rejected, deleted);
- opens one and sees its details, its device key and why it is suspended, rejected or
  deleted;
- **creates** an officer or administrator account and is shown its activation code once;
- **edits the full name** (the only field that can change, Scope (6));
- **suspends** and **reactivates**;
- **resets the device key** of a suspended account (a lost or replaced phone);
- issues a **new activation code** for an invited account;
- **deletes** an account (a soft delete, final).

Approving and rejecting requests stay on "Account requests" (A1), unchanged.

**App only** (`mobile/` and `docs/`), if Q1 is answered (A). All the endpoints exist
(api.md, "Admin account management"); nothing deploys to Render.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| `GET /admin/users?status=…` and the nine actions, the admin view of a user, the error table | `backend/`, api.md "Admin account management" | everything this feature reads and does |
| `AdminUsersApi`, `AdminUsersRepository` (pending list, approve, reject), the pinning set-up failure as `InsecureConnection` | `admin/data/` | grows by the new calls (T1) |
| `AccountRequest` (a part of the admin view) | `admin/domain/` | left as it is; the new `AdminAccount` reads the whole view |
| "Account requests": list, paging, pull-down refresh, the password prompt, confirm and reason dialogs, a row busy at a time | `admin/presentation/` | the pattern for the list and the actions; its reason dialog is moved out to be shared (T4) |
| The admin home: "Accounts" says "Coming soon" | `admin_home_screen.dart` | the way in (T2) |
| `Role`, `AccountStatus` (all six), `roleLabel` | `auth/domain/user.dart`, `account_screen.dart` | words for role and status |
| The error codes (`USER_NOT_FOUND`, `INVALID_STATUS_TRANSITION`, `CANNOT_SUSPEND_SELF`, `CANNOT_DELETE_SELF`, `LAST_ACTIVE_ADMIN`, `NO_PUBLIC_KEY`, `USERNAME_TAKEN`, `ROLE_NOT_CREATABLE`) | `core/errors/api_codes.dart` | constants exist; no sentences yet in `failure_text.dart` (T1) |
| "I have an activation code" | `auth/presentation/activate_screen.dart` | the new officer's first sign-in (T6) |
| The phone's key check after sign-in: server key `null` → the phone registers its key | `device_key_controller.dart` | what Fred's phone does after a reset (T6); no change |
| `FLAG_SECURE` in release builds | `MainActivity.kt` (Hardening) | the activation code page cannot be screenshotted in release |

## 3. How it fits

- **Actors:** the administrator only. Every path sits under `/admin`, so redirect rule 4
  keeps every other role out, and the server refuses them with 403 anyway.
- **No read-one endpoint.** There is no `GET /admin/users/{id}`. The detail page starts
  from the row the list gave it, and every action answers with the account's new admin
  view, which replaces it. So the detail page is opened from the list only; a restarted
  app opens the list again (a known limitation, below).
- **Which actions show, by status** (the server's table; the app hides what the server
  would refuse, and still shows the server's sentence if it refuses anyway):

  | Status | Edit name | Suspend | Reactivate | Reset device key | New activation code | Delete |
  |---|---|---|---|---|---|---|
  | active | ✓ | ✓ (not your own) | | | | ✓ (not your own) |
  | suspended | ✓ | | ✓ | ✓ when it has a key | | ✓ |
  | invited | ✓ | | | | ✓ | ✓ |
  | rejected, deleted | final, no actions | | | | | |

  Your own account shows "This is your account. You cannot suspend or delete it." The
  last-active-administrator rule is left to the server (409 `LAST_ACTIVE_ADMIN`): the app
  cannot count the active administrators without loading every page.
- **A lost or replaced phone** (signing spec, section 2): suspend, reset the key,
  reactivate; the person signs in on the new phone, which registers its key. On an active
  account with a key, the detail page says so in one line, so the administrator knows
  the order.
- **What the person sees afterwards:** suspended: their next request is refused
  (`ACCOUNT_SUSPENDED`), as today; deleted: their session ends (`TOKEN_INVALID`); renamed:
  "My account" shows the new name on the next `/auth/me`.
- **Pending accounts** are not in this list: they belong to "Account requests". Renaming a
  pending request is allowed by the API but not offered in the app (Q5).

## 4. The screens

1. **Accounts** (`/admin/accounts`).
   - A row of status chips at the top: "Active" (default), "Suspended", "Invited",
     "Rejected", "Deleted". One status at a time, as the API lists them. The chips wrap at
     large text instead of scrolling sideways.
   - "12 active accounts." from `total`; 20 at a time with "Show more"; pull down to
     refresh; read again on return from an account.
   - Each card: full name; username; role; licence number (miners) or "No licence number";
     and, by status: the reason ("Suspended: Lost device reported"), or for an invited
     account "Code valid until 24 Nov, 09:00", "Code expired" or "No code: too many wrong
     tries".
   - A "Create account" button (an extended floating button, label and icon).
   - Empty: "No suspended accounts." and so on. Offline, slow, an ended session: the
     shared sentences, "Try again" and the password prompt, as on "Account requests".
2. **Account** (`/admin/accounts/account`, the row passed with the route).
   - Name, username, role, status in words, licence number, "Requested 5 Nov" or "Created
     11 Nov", "Approved 6 Nov" when approved, the reason when there is one.
   - **Device key** (miners, transporters, buyers): "Registered (50a03528)" with the start
     of the fingerprint, the same eight characters the person's "My account" shows, or
     "None registered".
   - The actions of §3's table as full-width buttons, the delete one in the error colour
     and last.
   - After each action: a message ("Mutale Banda is suspended."), and the page shows the
     account from the answer.
3. **Create account** (`/admin/accounts/new`).
   - Username (3–32 characters, `A–Z a–z 0–9 _ . -`, the same check as the register
     screen), full name (1–100), role: "Regulatory officer" or "Administrator" (two
     radio choices, no default, so the role is always chosen on purpose).
   - "Create account" sends `POST /admin/users`. `USERNAME_TAKEN` puts the server's
     sentence under the username, as on the register screen.
4. **Activation code** (shown after Create and after "New activation code").
   - The code in large monospaced letters, grouped as the server gives it
     ("7KQ4-M2XD-9TNE"), the username, and "Valid until 24 Nov, 09:00 (72 hours)."
   - "This code is shown only once. Give it to Chanda Mwale yourself, in person or by
     phone. They open the app, tap "I have an activation code", and choose their own
     password."
   - No copy button (Q3). "Done" goes back to the account; Android back asks "Leave
     without the code? It cannot be shown again." first.
   - The code lives only in this page's state: never logged, never stored, gone when the
     page closes.
5. **The dialogs.**
   - **Reason** (suspend, reset key, delete): what the action does in one sentence, the
     reason field (3–500 characters, counter, an example hint, "Kept for ever in the audit
     log. Do not add personal details."), "Cancel" and the action's button, enabled at 3
     characters. The same widget as "Reject request", moved to a shared file.
     - Suspend: "Mutale Banda will not be able to use MineChain until reactivated."
     - Reset key: "Removes the device key of Mutale Banda's lost phone. Records it already
       signed keep verifying. Reactivate the account when the person has the new phone."
     - Delete: "Deleting cannot be undone. Mutale Banda can never sign in again, and the
       username stays taken. Every record they made is kept." The button reads "Delete
       for good".
   - **Confirm** (reactivate, new code): one sentence and the button. New code: "The old
     code stops working at once."
   - **Edit name**: the full name filled in, 1–100 characters, "Save". The same name again
     closes with no message (the server writes nothing).
   - Refusals keep the dialog open with what was typed and say why: the server's
     `INVALID_STATUS_TRANSITION` sentence (it names the actual status, for example when
     another administrator acted first, and the page then reads the list again), 403
     self, 409 last administrator, 409 no device key, 429 (rename and delete: 20 per
     15 minutes), offline.

## 5. Subtasks

- ✅ **T1 Accounts data** (about 45 min).
  - `admin/domain/admin_account.dart`: `AdminAccount` (every field of the admin view),
    `AdminAccountsPage`, `ActivationCode` (`code`, `expiresAt`, `toString()` without the
    code), `fromJson` that returns null for anything unreadable; `toString()` with role
    and status only.
  - `admin_users_api.dart` and `admin_users_repository.dart`: `accounts(status, offset)`,
    `create(username, fullName, role)`, `rename(id, fullName)`, `suspend(id, reason)`,
    `reactivate(id)`, `resetKey(id, reason)`, `newActivationCode(id)`, `delete(id,
    reason)`; each action returns the new `AdminAccount` (create and new code with the
    `ActivationCode`); reasons and names sent trimmed. The pending list, approve and reject
    unchanged.
  - `failure_text.dart`: sentences for the codes in §2; `INVALID_STATUS_TRANSITION` and
    `LAST_ACTIVE_ADMIN` show the server's message, as `STEP_CANNOT_BE_CLEARED` does.
  - Tests: api.md's examples parsed (every status, an invited account with and without a
    code, a deleted one); an unreadable row makes the page unreadable; the path, query and
    exact body of every call; the code never in a `toString()`; each code's sentence.
  - `test/fakes/fake_admin_server.dart` grows to hold accounts by status and answer the
    nine actions with the server's rules (status table, self, last admin, no key).
  - **Done.** As planned, with one change: the fake is a new file,
    `test/fakes/fake_accounts_server.dart`, so the "Account requests" tests keep the fake
    they were written against. `USERNAME_TAKEN` is not in `failure_text.dart` (an existing
    test uses it as the example of a code the app leaves to the server); the create form
    puts it under the username field, as the register screen does. 48 new tests.
- ✅ **T2 Accounts list** (about 60 min).
  - `/admin/accounts` (`AppRoutes.adminAccounts`), the "Accounts" tile wired.
  - §4.1: the chips, the count, the cards with every line, paging, refresh on open,
    on pull-down and on return, the empty and failure states.
  - Widget tests with the fake server: each status's cards in the server's order; the
    invited lines (valid, expired, no code); switching chips reads that status; "Show
    more"; empty; offline, slow, ended session; text 2.0 in portrait and landscape (the
    chips wrap); the admin tiles in `homes_test.dart` ("Accounts" opens its path;
    "GPS zones", "Anchoring" and "Reports" still "Coming soon").
  - **Done** as planned: `accounts_list_controller.dart` (a family by status),
    `accounts_screen.dart`, `account_words.dart`; the card's code line uses `clockProvider`,
    so tests have a fixed "now". 33 new tests.
- ✅ **T3 Account page** (about 45 min).
  - The route, §4.2: every field, the device key line, the action buttons by §3's table,
    your own account's sentence, the lost-phone line.
  - Widget tests: each status shows exactly its buttons; your own active account has no
    Suspend or Delete; a suspended account without a key has no Reset; the fingerprint's
    eight characters; officers and administrators have no device key line; text 2.0.
  - **Done.** `domain/account_actions.dart` (`actionsFor`, plain Dart), `account_page_controller.dart`,
    `account_page_screen.dart`. On a suspended account Reset comes before Reactivate (the
    lost-phone order). **Changed in T4:** the page no longer gets its account from the
    route's `extra` but from `openedAccountProvider`, set by the list. The T4 test "token
    expired on the page" found that when the 60-minute token runs out on the page, the
    router re-runs its redirect and rebuilds the page without the `extra`, so the page
    said "Open this account from the Accounts list". 24 new tests.
- ✅ **T4 Suspend, reactivate, reset key, delete, edit name** (about 70 min).
  - The reason dialog moved from `account_requests_screen.dart` to
    `admin/presentation/reason_dialog.dart` with its words passed in; "Account requests"
    uses it unchanged (its tests must pass untouched).
  - §4.5's dialogs; each answer replaces the account on the page and gives its message;
    a refusal keeps the dialog and its text.
  - Widget tests: each action's body exactly as sent; each message; a short reason keeps
    the button off and 501 characters are refused as typed; 409 another administrator
    acted first (the server's sentence, the list read again); `CANNOT_SUSPEND_SELF`,
    `LAST_ACTIVE_ADMIN`, `NO_PUBLIC_KEY`, 429, offline, ended session; a double tap sends
    once; delete leaves the account final with no buttons; the same name sends and says
    nothing.
  - **Done.** `reason_dialog.dart` (`ReasonDialog<T>`); the 43 "Account requests" tests
    pass unchanged. Two small differences from the steps above, both to keep one
    behaviour across the app: a short reason leaves the button on and says "Write at
    least 3 characters." when pressed (as "Reject" always did), and the same name again
    is not sent at all (nothing to write; the server would answer 200 and write nothing).
    `CANNOT_SUSPEND_SELF` cannot be reached from the page (no button), so it is tested in
    the repository and `failure_text` tests. 26 new tests.
- ✅ **T5 Create account and the activation code** (about 60 min).
  - `/admin/accounts/new` (§4.3) and the code page (§4.4), also opened by "New
    activation code" (with its confirm).
  - Widget tests: the username check (too short, a bad character, spaces trimmed); no role
    chosen keeps "Create" off; the body sent is exactly `{ username, fullName, role }`;
    `USERNAME_TAKEN` under the field; the code page shows the code, expiry and the
    sentence; Android back asks first, "Done" does not; the new account is in the
    "Invited" list afterwards; "New activation code" on an invited account shows a new
    code; the code in no log line (`debugPrint` captured in one test).
  - **Done.** `create_account_screen.dart`, `activation_code_view.dart`. The username's
    characters and length are left to the server, as on the register screen (the helper
    text gives the rule; the server's sentence goes under the field), so the local checks
    are: each field filled and a role chosen. "Leave" on a new code from the account page
    returns to the account's details, not off the page. 25 new tests.
- ⬜ **T6 Phone check** (the developer, about 40 min).
  - On the emulator as the administrator (`mc_adminkay`):
    - "Accounts": the active list holds the demo accounts; switch to "Invited" and
      "Suspended";
    - create an officer, `officer_check` ("Check Officer"); the code page; on the A57,
      "I have an activation code" with it; the officer signs in and sees "Alerts";
    - **Fred's device key:** open Fred, Suspend (reason "Phone replaced, key reset for
      the demo"), Reset device key (same reason), Reactivate; Fred signs in on his phone
      and "My account" shows a new "Registered (…)" key, the same eight characters the
      administrator's page then shows after a refresh; Fred records and sends a step,
      which is accepted;
    - edit a full name and see it on that person's "My account";
    - delete `officer_check` (reason "Account made for the phone check"): it is in
      "Deleted", and the A57's officer session ends at its next request;
    - suspend your own account: no button; offline: the no-network sentence.
  - Screenshots for the thesis (names in the T6 report).
  - **Result (21 Nov, 12:09–17:36, emulator as `mc_adminkay`, A57 as `officer_check`,
    then Fred):** as planned.
    - List: "7 active accounts." with every card line; the other four chips' empty
      sentences.
    - Created `officer_check` ("Check Officer"): code page "Valid until 24 Nov, 12:13
      (72 hours)." and the shown-once sentence; the card under "Invited" with "Activation
      code valid until 24 Nov, 12:13"; its page with Edit name, New activation code,
      Delete. Activated on the A57 with "I have an activation code": officer home,
      "Alerts" (8 open, 0008 under "Cleared").
    - Fred (miner): "Device key: registered (ef52add3)" and the lost-phone line; Suspend
      ("Fred Temo is suspended."), Reset device key ("none registered", still
      suspended), Reactivate with "Their device key was reset: signing in on the new
      phone registers its key." ("active again"). Fred then signed in on the A57 (the
      phone Clement also uses: one key per account, Mobile (17)): "My account" showed
      "Registered ✓ 3056af24", and the administrator's page the same `3056af24`.
    - Rename to "Check Officer Two": "The name is now Check Officer Two." and the list;
      the officer's "My account" showed it only after logging out and in (fix 1 below).
    - The session ran out with "Edit full name" open: "Your session has expired. Please
      enter your password again." inside the dialog, with no way to enter it (fix 2).
    - Airplane mode: Suspend kept the dialog, the reason and "No internet connection".
    - Delete with "Account made for the phone check": "Sending…", "Check Officer Two's
      account is deleted.", final with no buttons, under "Deleted"; the A57's officer
      session ended at its next request ("Your session has ended. Please log in again.").
    - The activation code broke after its first dash ("3NMG-" / "QR7W-6HE7") (fix 3).
    - Not done: Fred recording and sending a step with the new key.
- ✅ **T6b Fixes from the phone check** (approved by the developer, 21 Nov).
  - Fix 1: `AuthController.refreshAccount()` (`GET /auth/me`); "My account" reads the
    account again when it first opens, from a refresh button ("Refresh my details") and on
    a pull down. Decision Admin accounts app (7).
  - Fix 2: an action whose session ran out asks for the password on top of the open
    dialog, then sends the same text again (`_withPassword` in `account_page_screen.dart`;
    the controller counts `TOKEN_EXPIRED` as "needs the password" at once). Cancelling
    keeps the dialog, its text and "Your session has expired". Decision (6).
  - Fix 3: the code on one line (`FittedBox`, `maxLines: 1`). Decision (4).
  - Tests: 15 new (4 `account_screen_test.dart`, 4 `auth_controller_test.dart`, 3 in
    `account_page_actions_test.dart`, 4 sizes in `create_account_screen_test.dart`);
    a mutation (no second send) failed the three session tests. Full run 2159 passed.
  - Re-check on the phones: open "My account" as an officer after renaming them on the
    emulator, tap the refresh button: the new name; a new activation code on one line.
- ✅ **T7 Docs and PR** (about 20 min). `decisions.md` Admin accounts app (1)–(8), three
  known limitations and two future improvements; `testing-log.md`, `progress.md`,
  `CLAUDE.md`, the PR description (in chat).

About 5 h of Claude Code time plus the developer's 40 minutes. Q1 (B) adds about 2.5 h,
with a production migration.

**Commits.** T1 touches its own files, `failure_text.dart` and the fake server, so it can be
its own commit. T2–T5 all add to `app_text.dart`, `routes.dart` and `app_router.dart`, so
they go in one code commit unless the developer commits between subtasks. Then one docs
commit after T6.

**Known limitations to record (T7):**

- The account page cannot be opened by its address alone (no read-one endpoint); an app
  restored after Android closed it opens the list.
- No search by name or username: the API has none, so a long list is paged 20 at a time.
- The app does not stop you before the last active administrator; the server does (409).

## 6. Questions

- **Q1 Password reset.** The day plan lists "reset … a password (Mutale)", but **the API
  has no password reset**: only the owner changes their own (`POST /auth/me/password`),
  and Accounts (1) chose that no administrator ever knows a person's password. The
  database only allows an activation code on an invited account, and only an invited
  account may have no password.
  - **(A, proposed)** Not in this feature. Record it as a known limitation and a future
    improvement ("a forgotten password needs a reset code, like the activation code").
    For the demo, Mutale signs in with the password the developer has; if it is truly
    lost, the developer tells me, and we choose then.
  - (B) Build it: a migration that lets a suspended account hold a code, `POST
    /admin/users/{id}/password-reset-code` (suspended only, a 72 h code, audited without
    the code), `/auth/activate` accepting it and making the account active, the app's
    button and the code page reused. Touches `backend/`, a migration and auth: about 2.5 h,
    a backup and the migration on production before the merge, and it delays GPS zones
    and Reports.
- **Q2 The status chips.** **(A, proposed)** Five chips, "Active" first, one status at a
  time (the API's filter). (B) Only "Active" and "Suspended", with invited, rejected and
  deleted under a "More" menu.
- **Q3 The activation code.** **(A, proposed)** Shown large, no copy button: the API says
  to hand it over in person or by phone, and on Android any app with focus can read the
  clipboard. `FLAG_SECURE` already blocks screenshots in release. (B) A "Copy" button,
  with the clipboard cleared after 60 seconds.
- **Q4 Delete confirmation.** **(A, proposed)** The reason dialog with the "cannot be
  undone" sentence and a "Delete for good" button in the error colour. (B) Also type the
  username to confirm (one more field, stronger for an action that is final).
- **Q5 Pending requests.** **(A, proposed)** Not in the Accounts list and no rename from
  "Account requests": a wrong name is fixed after approval. (B) A "Pending" chip that
  links to "Account requests", and "Edit name" on each request card (about 30 min more).
- **Q6 Fred's phone check.** The plan resets Fred's key with the real reset flow on
  production (suspend, reset, reactivate), which is exactly what the demo needs and leaves
  three audit entries with the reasons above. **(A, proposed)** As in T6. (B) Use a fresh
  test account for the reset, and leave Fred for the end-to-end test.
