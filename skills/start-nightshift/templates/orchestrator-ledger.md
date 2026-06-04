```text
Nightshift Ledger

Branch: <branch>
Branch source: existing | auto-created
Repo: <owner/name>
Base branch: <base>
PR: <url or none>
Current state: NOT_STARTED | PREFLIGHT | WAITING_FOR_PRD_PROMPT | READY_TO_START_COORDINATOR | WAITING_FOR_COORDINATOR | WAITING_FOR_PR_REVIEWER | COMPLETE | BLOCKED_BY_RUN_FAILURE
Current PRD: <thread id or none>
Pending PRD prompt thread/message: <id or none>
Pending Coordinator thread: <id or none>
Pending PR Reviewer thread: <id or none>

Heartbeat:
- Next heartbeat: <duration>
- Heartbeat reason: <reason>
- Consecutive waiting checks: <n>

PRD Queue:
- Index: 1
  Thread: <id>
  PRD issue: <issue/url>
  Size: SMALL | MEDIUM | LARGE
  Size rationale: <short reason>
  State: READY | RUNNING | COMPLETE | BLOCKED_BY_PRD | BLOCKED_EXTERNAL
  Blocked by:
  - <reference or None>

Completed:
- PRD thread: <id>
  PRD issue: <issue/url>
  Coordinator thread: <id>
  Issues:
  - ISSUE: #123
    COMMIT: abc123
    SUMMARY: <summary>

Skipped / Blocked:
- PRD thread: <id>
  PRD issue: <issue/url>
  Class: <blocker class>
  Reason: <reason>

Failures To Report:
- Push failures: <items or none>
- PR creation failures: <items or none>
- PRD label failures: <items or none>
- Child closure failures: <items or none>
- Skill substitutions: <items or none>

Follow-up needed:
- <item or none>
```
