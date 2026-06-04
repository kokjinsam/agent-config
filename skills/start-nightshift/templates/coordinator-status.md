Coordinator final status:

```text
STATUS: COMPLETE

COMPLETED_ISSUES:
- ISSUE: #123
  COMMIT: abc123
  SUMMARY: <one sentence>

SKIPPED_ISSUES:
- ISSUE: #124
  REASON: <already closed / already implemented / other>
  COMMIT: <sha or None>

CLOSURE_FAILURES:
- ISSUE: #125
  COMMIT: def456
  REASON: <why silent closure failed>

SKILL_SUBSTITUTIONS:
- REQUESTED: <skill>
  USED: <skill or approach>
  REASON: <why>

TESTS_CHECKS:
- <command and result>

RESIDUAL_RISKS:
- <risk or None>
```

Coordinator blocked status:

```text
STATUS: BLOCKED
BLOCKER_CLASS: BLOCKED_BY_PRD | BLOCKED_EXTERNAL | BLOCKED_BY_RUN_FAILURE
REASON: <short reason>
ACTIVE_ISSUE: <issue if applicable>
COMPLETED_ISSUES:
- ISSUE: #123
  COMMIT: abc123
  SUMMARY: <one sentence>
```
