# Testing log

Real results of every test run, appended after each subtask: newest at the bottom. Numbers
are copied from the command output, never estimated. A suite that was not run says so and
why.

Totals before this log started: backend `npm test` 2300 and `npm run test:db` 914 (15 Nov,
after B2.5a, confirmed by the developer); contract 37 (12 Nov).

| Date | Branch | Feature / subtask | Command | Result |
|---|---|---|---|---|
| 18 Nov 2026 | `chore/claude-workflow` | Workflow setup T1 (baseline) | `flutter analyze --no-pub` (in `mobile/`) | No issues found (72.0 s) |
| 18 Nov 2026 | `chore/claude-workflow` | Workflow setup T1 (baseline) | `flutter test` (in `mobile/`) | 1248 passed, 1 skipped, 0 failed (1:04). The skip is the miner case in `test/features/homes_test.dart`, covered by `my_consignments_screen_test.dart` |
| 18 Nov 2026 | `chore/claude-workflow` | Workflow setup T1 | backend `npm test`, `npm run test:db`; contract tests | Not run: no backend or contract file changed |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T1 | `flutter analyze --no-pub` (in `mobile/`) | No issues found (5.6 s) |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T1 | `flutter test test/core/widgets/home_scaffold_test.dart` | 16 passed, 0 failed (7 new: 4 title cases at 360 x 640, 1 wide title case, 2 account button sizes) |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T1 | same file, title group, against the committed (old) `home_scaffold.dart` | 1 passed, 4 failed, as expected: the four 360 x 640 cases catch the cut role label. New code restored afterwards |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T1 | `flutter test` (in `mobile/`) | 1265 passed, 1 skipped, 0 failed (1:09). Up from 1248 on 18 Nov: 7 new here, the rest came with Mapalo's theme commit. The skip is still the miner case in `homes_test.dart` (Hardening) |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T1 | backend `npm test`, `npm run test:db`; contract tests | Not run: no backend or contract file changed |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T2 | `flutter analyze --no-pub` (in `mobile/`) | No issues found (5.6 s) |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T2 | `flutter test test/core/theme/app_theme_test.dart` | 18 passed, 0 failed (2 new: copper icon on `secondaryContainer`, light and dark, at least 3:1) |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T2 | `flutter test` (in `mobile/`) | 1267 passed, 1 skipped, 0 failed (0:57). The skip is the miner case in `homes_test.dart` (Hardening) |
| 19 Nov 2026 | `design/mapalo-theme` | Design integration T2 | backend `npm test`, `npm run test:db`; contract tests | Not run: no backend or contract file changed |
