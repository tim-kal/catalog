# Issue Log

Auto-captured system issues. Review periodically and close resolved items.

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

## 2026-04-11 12:27 UTC — Reviewer changes_requested: DC-014
**Category:** quality
**Task:** DC-014
**Impact:** Task needs rework
**Details:** Executor failed to locate the task definition (exists at migration/TASKS/DC-014/ticket.md) and produced no code. Zero acceptance criteria were attempted.

## 2026-04-11 12:28 UTC — Reviewer blocked: DC-015
**Category:** quality
**Task:** DC-015
**Impact:** Task blocked — needs human input
**Details:** DC-015 has no task file at DriveSnapshots/TASKS/DC-015*.md. There are no acceptance criteria, goal, or scope defined. A task definition must be created before this can be executed or reviewed.

## 2026-04-11 12:28 UTC — Reviewer blocked: DC-015
**Category:** quality
**Task:** DC-015
**Impact:** Task blocked — needs human input
**Details:** No task file found at DriveSnapshots/TASKS/DC-015*.md. Without a goal and acceptance criteria, there is nothing to implement or review. A task definition must be created before this can proceed.

## 2026-04-11 12:28 UTC — Reviewer auto_redesign: DC-015
**Category:** quality
**Task:** DC-015
**Impact:** Task blocked — needs human input
**Details:** auto-promoted after 2 blocked verdicts: No task file found at DriveSnapshots/TASKS/DC-015*.md. No goal, acceptance criteria, or relevant files are defined. A task definition must be created before this can be executed or reviewed.

## 2026-04-11 12:29 UTC — Reviewer changes_requested: DC-016
**Category:** quality
**Task:** DC-016
**Impact:** Task needs rework
**Details:** Executor searched wrong path (DriveSnapshots/TASKS/) — task exists at migration/TASKS/DC-016/ticket.md with 6 acceptance-criteria groups; zero were attempted.

