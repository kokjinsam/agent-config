---
name: start-nightshift
description: Run an unattended nightly PRD implementation workflow from ordered Codex PRD thread IDs, using a shared non-main branch, per-PRD Coordinators, issue-level Implementor/Reviewer loops, GitHub issue reporting, draft PR creation, heartbeat automation, and final PR autoreview. Use when the user invokes "$start-nightshift" or asks to run a nightshift PRD implementation batch.
---

# Start Nightshift

Run a no-human-intervention PRD implementation batch from ordered Codex PRD threads.

## Trigger

Expected prompt:

```text
$start-nightshift

Ordered PRD thread IDs:
1. <thread-id>
2. <thread-id>
```

## Required Capabilities

Execution requires thread-management tools, git shell access, heartbeat automation tools, and GitHub mutation access. Prefer `gh` CLI for GitHub operations and always pass `--repo <owner/name>`; fall back to GitHub connector tools only when `gh` is unavailable or insufficient.

If a required execution capability is unavailable, stop with `STATUS: BLOCKED_BY_RUN_FAILURE`. Do not silently switch to authoring mode unless the user explicitly asks for prompts/templates only.

## Startup Gates

1. Parse ordered PRD thread IDs, preserve order, de-duplicate exact repeats, and record ignored duplicates.
2. Detect repo from git remote and infer base branch from the remote default branch. Stop if ambiguous.
3. Require a clean worktree. Stop if dirty unless the user explicitly said the changes are part of the run.
4. Detect active branch:
   - if clean and not `main`, `master`, or `trunk`, use it;
   - if on `main`, `master`, `trunk`, or branch detection fails, create `nightshift/<YYYY-MM-DD>-prd-run` with a numeric suffix if needed.
5. Confirm active branch is not `main`, `master`, or `trunk`.
6. Create a heartbeat automation for this Orchestrator. If it cannot be created, stop.
7. Look for an existing matching ledger. If branch and PRD list match, resume safely. If they conflict, stop.

## Workflow

Use the Orchestrator/Coordinator/PR Reviewer model in [REFERENCE.md](REFERENCE.md).

High-level sequence:

1. Preflight all listed PRD threads: read each thread, extract PRD GitHub issue, child issue list, blockers, and PRD size estimate. Unreadable or non-GitHub-backed PRDs become `BLOCKED_EXTERNAL`.
2. Cheaply verify all referenced child issues exist/state/labels. Do not perform broad reverse discovery unless the PRD thread lacks a usable child list.
3. Preserve the listed PRD order as priority order, but run the earliest `READY` PRD whose blockers are satisfied. Revisit PRD blockers after each completion.
4. Ask the selected PRD thread for an implementation prompt using [templates/original-prd-ask.md](templates/original-prd-ask.md) plus [templates/coordinator-addendum.md](templates/coordinator-addendum.md).
5. Start one Coordinator thread for that PRD. Never run Coordinators in parallel.
6. After each Coordinator completes, push the branch with bounded retry, attempt draft PR creation if no PR exists, and label the PRD issue `ready-for-review` with bounded retry.
7. After all implementable PRDs complete, post an Orchestrator implementation summary on the PR if it exists.
8. If a PR exists and `autoreview` is available, start one PR Reviewer thread using [templates/pr-reviewer-prompt.md](templates/pr-reviewer-prompt.md). Otherwise mark the run `COMPLETE` with follow-up needed and leave any draft PR as draft.
9. Mark the draft PR ready for review only after the PR Reviewer returns clean `STATUS: COMPLETE`.

## Heartbeat

The Orchestrator never waits indefinitely in one turn. After starting or messaging a long-running child thread, update the ledger and end the turn.

Use PRD-size-aware dynamic intervals:

- `WAITING_FOR_PRD_PROMPT`: 15 minutes
- `WAITING_FOR_COORDINATOR`: small PRD 10 minutes, medium 20 minutes, large 40 minutes
- `WAITING_FOR_PR_REVIEWER`: 30 minutes
- retry states: 10 minutes

After 3 checks with the same child still running, increase by 10 minutes for small, 15 for medium, and 20 for large, capped at 60 minutes. Reset on state transition or new child thread.

## Ledgers And Status

Keep the Orchestrator response ledger canonical and optionally mirror it to an uncommitted scratch ledger outside the repo. Never commit orchestration ledgers.

Use [templates/orchestrator-ledger.md](templates/orchestrator-ledger.md), [templates/coordinator-status.md](templates/coordinator-status.md), and [templates/prd-comment.md](templates/prd-comment.md).

## Non-Intervention Rule

No Nightshift thread may ask the user questions during execution. Make a conservative spec/repo-grounded decision and record it, or return the appropriate blocked/failure status.
