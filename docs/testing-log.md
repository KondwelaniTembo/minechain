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
