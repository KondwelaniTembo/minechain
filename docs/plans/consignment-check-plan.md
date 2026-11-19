# Consignment check plan

Status: **approved 19 Nov 2026, Q1–Q5 and Q7 as proposed; Q6 (demo accounts) asked again
before T6.** T1–T3 done.

Branch: `feature/consignment-check`, created by the developer from `main` after PR #14.

## 1. Goal

FR-04: "Verify a consignment by QR scan and signature check". A transporter, a buyer or a
regulatory officer scans the custody record's QR code on a bag and sees, in plain words:

- **whether the record can be trusted**: each step's signature and stored record checked by
  the server against the Sepolia blockchain (Scope (9), Verification (1)–(14));
- **its provenance**: who registered it, handed it off and bought it, when, where (zone),
  and how heavy it was at each step, as far as the viewer's role may see.

The server endpoint already exists and is deployed (`GET /consignments/by-qr/{qrCode}`,
PR #8, `docs/api.md`). This feature is **app only**: `mobile/` and `docs/`, so nothing
deploys to Render. The phone never talks to the blockchain (CLAUDE.md, design rules).

It is the first of the three role modules, and the next two reuse it: the transporter's
handoff starts from a check (the screen tells a transporter to weigh first), and the buyer's
purchase does the same.

## 2. What exists already

| Part | Where | Used for |
|---|---|---|
| The endpoint and its per-role disclosure table | `docs/api.md`, "GET /consignments/by-qr/{qrCode}" | the whole answer: consignment, steps, `check.result` |
| QR scanner behind a builder provider (fake in tests) | `registration/presentation/qr_scanner_view.dart` | the camera |
| Custody record ID rule `MC-<year>-<ABC>-<0000>` | `registration/domain/custody_record.dart` | refusing stray QR codes (links, other tags) |
| `ApiClient.get` with the token, pinned TLS 1.3, `AppFailure` types | `core/network/api_client.dart`, `core/errors/app_failure.dart` | the call and its failures |
| Weight shown per mineral unit (`weightInUnit`) | `registration/domain/weight.dart`, `my_consignments_screen.dart` | weights as text, never floats |
| "Check a consignment" tiles, now "Coming soon" | transporter, buyer and officer homes | the way in |
| A data/domain/presentation split for a server list | `admin/data`, `admin/domain`, `admin/presentation` | the pattern to copy |

## 3. How it fits

```
Home tile "Check a consignment"
  → /transporter/check | /buyer/check | /officer/check   (one screen, three paths)
      scan (camera) ─ custody record ID? ─ no → "This is not a MineChain custody record"
                                         └ yes → GET /consignments/by-qr/{code}  (token)
      → result page: verdict banner + steps in custody order
```

- **One screen, three paths** under each role's home, so the router's existing role rule
  ("every page of a role lives under its home's path") keeps miners and administrators out
  with no new rule. The server refuses them too (403).
- **New feature folder** `lib/features/verification/`:
  - `domain/consignment_view.dart`: the answer as Dart values, read strictly (a field the
    role may not see is absent, never `null`); weights and coordinates stay text;
  - `domain/verdict.dart`: one pure function from the answer to the banner (§4);
  - `data/consignment_check_api.dart`: the one GET, its errors mapped;
  - `presentation/`: the controller (Riverpod), the scan step and the result page.
- **Needs the network.** The answer is `Cache-Control: no-store`, and a stored copy of a
  live check would be stale, so nothing is cached in the local database. Offline, the screen
  says so and offers "Try again".

## 4. What the result page shows

**The banner (verdict), worst first:**

| When | Banner (plain words, final wording in `app_text.dart`) | Colour |
|---|---|---|
| any step `mismatch` | "This record does not match the blockchain. Officers have been told, and the consignment is held." | error |
| `held` (no mismatch) | "Under review: an officer is checking a problem with this consignment." | warning |
| any step `chain_unavailable` | "Could not reach the blockchain just now. Try again later." Never called tampering | neutral |
| any step `not_anchored_yet` | "Recorded, not on the blockchain yet. This usually takes a few minutes." | neutral |
| no step listed, nothing holding it (added in T1: every step flagged or rejected, and the viewer is not an officer) | "Nothing to check yet: no accepted step is recorded for this consignment." | neutral |
| every step `match` | "Verified: every step matches the blockchain." | success (patina) |

**Then the consignment:** QR code, mineral, stage in words ("Registered", "On its way",
"Bought"). For a blind transporter (`weightsHidden`): "Weigh it before you take custody: the
weight is hidden until you record yours."

**Then one card per step, in custody order:** what happened ("Registered by miner
mutale_banda", "Handed off", "Bought by buyer …"; "You" for `byYou`), weight, zone name or
"Outside every licensed zone", capture time in the phone's local time, and the step's own
check in words. Shown only when the answer has it:

- the transaction hash (`0x…`), selectable so it can be copied into Etherscan (Q4);
- latitude and longitude (officer, owning buyer);
- officer only: review status, the number of alerts, and on a mismatch the names of what
  differs (`check.fields`), never values.

**Errors**, each with "Scan again" or "Try again":

| Cause | Words |
|---|---|
| not a custody record ID | "This is not a MineChain custody record." (camera keeps scanning) |
| 404 `CONSIGNMENT_NOT_FOUND` | the server's message: "No consignment has this QR code." The same for an unknown code and one a buyer may not see; the app adds nothing that tells them apart |
| 429 | the server's message, plus `Retry-After` when sent |
| no network, timed out | the app's usual sentences (`NoConnection`, `TimedOut`) |
| 401 token errors | the existing session handling (back to login, or "Enter your password") |

## 5. Subtasks

- ✅ **T1 Domain** (about 45 min). `ConsignmentView`, `CheckedStep` and their strict
  `fromJson` (an unknown `type`, `stage`, `check.result` or a weight that is not whole digits
  makes the whole answer unreadable, `BadResponse`, as `AdminUsersApi` does); `verdictFor()`
  (§4 order). Unit tests: the api.md example; each role's field set from the disclosure
  table; absent vs `null` (`zoneName: null` is "outside every zone", `chainTxHash: null`
  is "not sent yet"); each verdict and the worst-first order.
- ✅ **T2 Data** (about 30 min). `ConsignmentCheckApi.byQr(code, token)` through
  `ApiClient.get(['consignments', 'by-qr', code])` (path segments, so any `/` is sent as
  `%2F`, as api.md requires); provider wiring. Tests with the fake HTTP client: 200, 404,
  429 with `Retry-After`, 403, a malformed body, and that the token is sent.
- ✅ **T3 Scan step and routes** (about 60 min). `/transporter/check`, `/buyer/check`,
  `/officer/check`; the three home tiles go there (no "Coming soon"); the scanner with the
  custody record ID rule, one request per scan (a second read of the same code while busy is
  ignored), busy state, the error sentences of §4, "Scan again"; Q1's typed entry if chosen.
  Widget tests with the fake scanner; router tests that a miner or admin cannot open the paths.
  As built: "Try again" only where the same code can get a different answer (no network,
  a timeout, a 5xx, an unreadable answer), never after a 4xx; a 429's `Retry-After` is shown
  in whole minutes, rounded up. Until T4, a finished check says only which record was
  checked.
- ⬜ **T4 Result page** (about 60 min). Banner, consignment block and step cards (§4) for
  the common view (any buyer in transit, a transporter who has handed off). Widget tests per
  verdict; text 2.0 in portrait and landscape; light and dark contrast of the banner colours.
- ⬜ **T5 Role differences** (about 45 min). Blind transporter (no weights, no hash, the
  "weigh first" line), officer extras (review status, alerts, mismatch fields, flagged and
  rejected steps listed), owning buyer (location). Widget tests from fixtures that follow the
  disclosure table exactly.
- ⬜ **T6 Phone check on the A57** (the developer, about 20 min). Exact commands in the T5
  report. Scan a real custody record (Clement's or Mutale's) as a transporter and as an
  officer (Q6), with and without the network; screenshots for the thesis.
- ⬜ **T7 Docs** (about 20 min). `decisions.md` "Verification app (1)…", `testing-log.md`,
  `progress.md`, `CLAUDE.md`, PR description.

About 4 h 30 of Claude Code time plus the developer's 20 minutes. The schedule is about one
day behind (`docs/progress.md`), and Transporter handoff is also planned for today.

## 6. Questions

- **Q1 Typed entry.** (A, proposed) Camera only, as for registration: a typed code is easy
  to mistype and the demo always has the printed tag. (B) Also a "Type the code" field, for a
  damaged tag or an emulator without a camera scene.
- **Q2 The phone's own signature re-check.** The officer and the owning buyer receive the
  signed payload, signature and public key so the phone could verify each signature itself.
  (A, proposed) Not in this feature: the server already re-verifies every signature on each
  scan and compares with the chain (Verification (5)), and the result is shown. Recorded as a
  known limitation and a future improvement. (B) Verify in Kotlin with
  `Signature.getInstance("SHA256withECDSA")` over the channel: no new package, but no
  automated test (as Hardening found) and about 1 h more. (C) A Dart package such as
  `pointycastle`: needs your OK for a new package and about 1 h 30 more.
- **Q3 Paths.** (A, proposed) Three paths, one per home, as §3. (B) One shared `/check` path
  with a new router rule for three roles.
- **Q4 Transaction hash.** (A, proposed) Shown in full and selectable, so it can be copied;
  no link, because opening a browser needs a new package (`url_launcher`). (B) A tappable
  Etherscan link with `url_launcher` (new package, your OK needed).
- **Q5 Folder name.** `features/verification/` (proposed, matching "Verification (1)–(14)"
  in the decisions), or `features/consignment_check/`.
- **Q6 Accounts for the phone check.** Which approved transporter, buyer and officer accounts
  exist on production for the demo? Claude Code never creates accounts; if one is missing,
  you create it (an officer needs an activation code from the admin).
- **Q7 A mismatch in the phone check.** A real `mismatch` needs a changed row on the server,
  which Claude Code will not do on production. (A, proposed) The mismatch and "under review"
  screens are proven by widget tests only, and the phone check covers the verified, not yet
  anchored and offline cases. (B) The developer edits a row in `minechain_dev` and points a
  debug build at a local server: about 45 min more.
