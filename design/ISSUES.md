# Issue Log

Auto-captured system issues. Review periodically and close resolved items.

## 2026-04-06 13:17 UTC — Executor failed: DC-003
**Category:** operational
**Task:** DC-003
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:18 UTC — Reviewer changes_requested: DC-004
**Category:** quality
**Task:** DC-004
**Impact:** Task needs rework
**Details:** DC-004 has zero implementation — none of 7 acceptance criteria are met; the only change is an unrelated issue log entry for DC-002.

## 2026-04-06 13:18 UTC — Executor failed: DC-004
**Category:** operational
**Task:** DC-004
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:19 UTC — Reviewer changes_requested: DC-005
**Category:** quality
**Task:** DC-005
**Impact:** Task needs rework
**Details:** DC-005 was never implemented — executor self-reported "blocked" and produced no code; zero of 8 acceptance criteria are met.

## 2026-04-06 13:20 UTC — Reviewer changes_requested: DC-006
**Category:** quality
**Task:** DC-006
**Impact:** Task needs rework
**Details:** DC-006 was never implemented — executor self-reported "blocked" and no code was produced; zero of 6 acceptance criteria are met.

## 2026-04-06 13:20 UTC — Reviewer changes_requested: DC-008
**Category:** quality
**Task:** DC-008
**Impact:** Task needs rework
**Details:** Zero acceptance criteria met — no code was implemented; diff contains only design file bookkeeping (ISSUES.md and SIGNALS.md updates).

## 2026-04-06 13:33 UTC — Reviewer changes_requested: DC-008
**Category:** quality
**Task:** DC-008
**Impact:** Task needs rework
**Details:** Zero acceptance criteria met — executor self-reported "blocked" and produced no code; the only commit (1b62274) contains ISSUES.md and SIGNALS.md bookkeeping, not implementation.

## 2026-04-06 13:33 UTC — Executor failed: DC-008
**Category:** operational
**Task:** DC-008
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-002
**Category:** operational
**Task:** DC-002
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-003
**Category:** operational
**Task:** DC-003
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-004
**Category:** operational
**Task:** DC-004
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-008
**Category:** operational
**Task:** DC-008
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-002
**Category:** operational
**Task:** DC-002
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-003
**Category:** operational
**Task:** DC-003
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-004
**Category:** operational
**Task:** DC-004
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-008
**Category:** operational
**Task:** DC-008
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-002
**Category:** operational
**Task:** DC-002
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-003
**Category:** operational
**Task:** DC-003
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-004
**Category:** operational
**Task:** DC-004
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 13:41 UTC — Executor failed: DC-008
**Category:** operational
**Task:** DC-008
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

## 2026-04-06 14:08 UTC — Reviewer changes_requested: DC-008
**Category:** quality
**Task:** DC-008
**Impact:** Task needs rework
**Details:** Executor never found the task definition (wrong path lookup) and made zero code changes across 3 runs — all acceptance criteria unmet.

## 2026-04-06 14:13 UTC — Executor failed: DC-008
**Category:** operational
**Task:** DC-008
**Impact:** Task not completed (324s spent)
**Root cause:** Session crashed: Separator is found, but chunk is longer than limit

## 2026-04-06 14:18 UTC — Executor failed: DC-008
**Category:** operational
**Task:** DC-008
**Impact:** Task not completed (216s spent)
**Root cause:** Session crashed: Separator is found, but chunk is longer than limit

## 2026-04-06 14:42 UTC — Reviewer changes_requested: DC-009
**Category:** quality
**Task:** DC-009
**Impact:** Task needs rework
**Details:** All code is present and correct, but the migration overlay can never appear due to synchronous init_db blocking the lifespan before the server accepts connections.

## 2026-04-06 14:42 UTC — Executor failed: DC-009
**Category:** operational
**Task:** DC-009
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (3/3 runs)

## 2026-04-06 15:24 UTC — Executor failed: DC-009
**Category:** operational
**Task:** DC-009
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (3/3 runs)

## 2026-04-06 15:30 UTC — Reviewer changes_requested: DC-009
**Category:** quality
**Task:** DC-009
**Impact:** Task needs rework
**Details:** Executor self-reported all 12 criteria as PASS, but the majority of the rewritten DC-009 acceptance criteria are not implemented — no backup, no rollback, no direct file I/O, no schema version sync, no tests, no failure UI.

## 2026-04-06 15:57 UTC — Reviewer changes_requested: DC-011
**Category:** quality
**Task:** DC-011
**Impact:** Task needs rework
**Details:** Zero DC-011 acceptance criteria implemented — the diff contains only build-infrastructure changes (build stamping, Python embedding) unrelated to the structured error code system.

## 2026-04-06 16:09 UTC — Reviewer changes_requested: DC-011
**Category:** quality
**Task:** DC-011
**Impact:** Task needs rework
**Details:** All acceptance criteria structurally met; type mismatch bug between Python int context values and Swift [String: String] model will break error log display

## 2026-04-06 16:09 UTC — Executor failed: DC-011
**Category:** operational
**Task:** DC-011
**Impact:** Task not completed (0s spent)
**Root cause:** Retry cap exhausted (4/3 runs)

