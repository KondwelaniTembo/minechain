# Hardening plan

Status: **draft, waiting for approval** (19 Nov 2026).

Branch: `chore/hardening`, created by the developer from `main` after PR #11.

## 1. Goal

NFR-02 asks for "no Critical or High OWASP MSTG findings; private keys never leave the
device". This feature checks the app as it is built today (foundation, miner module,
Mapalo's design) against OWASP MASVS v2, with the MASTG tests as the method. It writes the
result down as a review the thesis can cite, fixes every Critical and High finding, and
decides each Medium one. It also clears the one skipped test and adds three device checks
that a unit test cannot do.

Out of scope: the backend (reviewed with the server work: rate limits, Argon2, CSV
injection, parameterised SQL) and the role modules not built yet. The last day keeps a
"Final OWASP review" for those (`docs/progress.md`, Sun 22 Nov).

## 2. First pass (done while writing this plan)

A read of the Android project, the Kotlin channel and the Dart code. **No Critical or High
finding so far.** T1 checks every control properly and may still find one.

| # | MASVS | What was seen | First rating |
|---|---|---|---|
| P1 | PLATFORM-3, STORAGE-2 | No `FLAG_SECURE`: the recent-apps screen keeps a picture of the last screen (an admin's account requests with names and licence numbers, a miner's consignments). Screenshots and screen recording also work | Medium |
| P2 | PLATFORM-3 | No tapjacking guard. Android 12+ blocks touches through untrusted overlays itself; Android 8–11 (still in NFR-09's range) does not | Low |
| P3 | CODE-1, RESILIENCE | A release build has never been run. R8 shrinking is on by default in Flutter release builds, but nobody has checked that the Keystore channel, sqlite3mc and ML Kit survive it. Dart code is not obfuscated (`--obfuscate --split-debug-info`) | Low (not a flaw yet, an untested path) |
| P4 | CODE-3 | The plugins' own manifest entries have not been read. Only the merged manifest of a release build shows whether any plugin adds an exported component | Unknown until T1 |
| P5 | CODE-3 | No check of the pinned package versions against security advisories | Unknown until T1 |
| P6 | RESILIENCE | Release signing uses the debug key (Flutter's template) | Info, a prototype limit |

Already in good shape (to be confirmed and written down in T1, with file references):
backup and device transfer off (Mobile (14)); no cleartext (`usesCleartextTraffic="false"`
plus the pinned TLS 1.3 client, no redirects, Mobile (21)); `taskAffinity=""` against task
hijacking; only the launcher activity is exported; no WebView, no deep links; token and
database key in flutter_secure_storage (Mobile (19)); SQLCipher-format database, WAL
included (Mobile (1), (28)); `Random.secure()` for the database key and step ids; the
private key made inside the Keystore with no export path (Mobile (4)); keyboards learn
nothing from password, licence, code and weight fields; release logs print rule names
only, and the sync debug line is compiled out (`kDebugMode`); location only in the
foreground, mock locations refused (Mobile (32)).

Known limits that stay limits (already in `docs/decisions.md`): an unlocked phone can sign
as its owner (Mobile (11)); no root or emulator detection; no key attestation; on a rooted
phone the database key can be read from secure storage.

## 3. Subtasks

- ⬜ **T1 The review** (about 60 min). New `docs/security-review.md`: the rating scale
  (§4), then MASVS v2 one group at a time (STORAGE, CRYPTO, AUTH, NETWORK, PLATFORM, CODE,
  RESILIENCE, PRIVACY). Each control gets what the app does, the evidence (file and line, or
  a test), the MASTG test it follows, and a rating. Includes P4 (merged manifest, needs a
  release build, Q3) and P5 (advisories, Q4). Output: the findings list. **STOP** so the
  developer can see the list before anything is fixed.
- ⬜ **T2 Fixes** (30–45 min). Every Critical and High from T1, plus the Mediums the
  developer approves. Expected now: P1 and P2 in `MainActivity.kt` (Q1, Q2). Kotlin cannot
  be reached by `flutter test`, so these are checked on the phone in T4. If T1 finds a
  Critical or High in Dart code, it gets a test that fails before the fix.
- ⬜ **T3 The skipped test** (about 30 min). Replace the skipped miner case in
  `homes_test.dart` (`skip: role == Role.miner`) with a real one: in the app harness with
  the router, each of the miner's three tiles opens its own screen, and "Coming soon" never
  appears. The other four roles keep their "Coming soon" case. Test count: 1 skipped → 0.
- ⬜ **T4 Three device checks on the A57** (the developer, about 30 min; exact commands in
  the T4 report):
  1. **Release build works:** `flutter run --release` with obfuscation; log in as the demo
     miner, register a consignment, send it. Proves R8 left the channel, sqlite3mc and the
     scanner working (P3).
  2. **Nothing sensitive in the log:** `adb logcat` captured during login, registration and
     sync, then searched for the token's start (`eyJ`), the QR code, the payload and the
     password. Expected: no hit.
  3. **Nothing readable outside the app:** the recent-apps screen shows a blank card (P1);
     the database file pulled from a debug install with `run-as` does not start with
     `SQLite format 3`; `adb backup` of the app is empty.
- ⬜ **T5 Docs** (about 30 min). `docs/decisions.md` "Hardening (1)…" for each choice and
  each accepted limit; `docs/security-review.md` marked with the T2 fixes and T4 results;
  `docs/testing-log.md`; `docs/progress.md`; the PR title and description.

About 3 h of Claude Code time plus the developer's 30 min on the phone. The schedule is
already about one day behind (`docs/progress.md`).

## 4. Rating scale (proposed, Q5)

OWASP Risk Rating, simplified to likelihood × impact for this app's setting (a prototype,
phones carried at mine sites, no app store):

- **Critical:** remote, no special access, exposes keys, tokens or lets someone sign as
  another user.
- **High:** needs the phone briefly or a common tool (adb on an unlocked phone, a backup),
  and exposes the token, the database or signed work.
- **Medium:** leaks personal data or work details without giving control (screenshots,
  recent-apps picture), or needs a rooted phone to do worse.
- **Low:** defence in depth, or only on old Android versions.
- **Info:** a prototype limit with no direct attack.

## 5. Questions

- **Q1 `FLAG_SECURE` (P1):** (A, proposed) release builds only, so debug builds still allow
  the thesis screenshots; (B) every build, which blocks the developer's own screenshots;
  (C) none, recorded as a Medium limit.
- **Q2 Tapjacking (P2):** set `filterTouchesWhenObscured` on the app's view in
  `MainActivity.kt` (proposed), or record it as a Low limit.
- **Q3 Release build in T1:** may Claude Code run `flutter build apk --release` (it is not on
  the allowed list) to read the merged manifest? It installs nothing. Otherwise the developer
  runs it and Claude Code reads the file.
- **Q4 Advisories in T1:** may Claude Code run `flutter pub outdated` (read-only, uses the
  network) and check each pinned package's advisories on pub.dev and GitHub? No package is
  changed without asking.
- **Q5 Rating scale:** §4 as written, or another scale?
