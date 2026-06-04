# Start Nightshift Reference

## Roles

**Orchestrator** coordinates the whole batch. It owns branch setup, heartbeat, global ledger, PRD dependency/blocker map, Coordinator creation, draft PR creation, PRD `ready-for-review` labeling, final implementation summary, and PR Reviewer creation. It does not inspect diffs, run tests, implement, review code, or commit.

**Coordinator** owns exactly one PRD. It discovers/verifies child issues from the PRD thread, runs one Implementor plus one Reviewer loop per child issue, invokes `$commit` with GPT-5.5 low after each completed child issue, comments on the PRD issue after each child issue, and closes child issues silently. It does not open PRs, comment on PRs, label PRD issues, close PRD issues, create/switch branches, or create worktrees.

**Implementor** implements only the active child issue. Use GPT-5.5 medium with `tdd` and `phx-bounded-context`. If a named skill is unavailable, use the closest clear equivalent and report the substitution; if no safe equivalent exists, block.

**Reviewer** reviews only the active child issue diff. Use GPT-5.5 high with `code-review-and-quality`. It is read-only and reports severity-ordered findings with file/line references.

**PR Reviewer** runs final `autoreview` on the PR/branch, verifies findings against real code, runs targeted fix loops for accepted actionable findings, commits one fix per accepted finding with `$commit` using GPT-5.5 low, reruns checks and autoreview up to 3 cycles, comments only on the PR, and never comments on PRD issues.

## Blocker Classes

`BLOCKED_BY_PRD`: a listed PRD or child issue must complete first. Revisit automatically after each completed PRD.

`BLOCKED_EXTERNAL`: something outside this run is required, such as missing spec decision, unreadable PRD thread, missing GitHub issue backing, unavailable dependency, missing credentials, or ambiguous user decision. Skip for this run and report.

`BLOCKED_BY_RUN_FAILURE`: workflow infrastructure failed, such as branch setup, heartbeat creation, unreconcilable ledger mismatch, thread creation, or other control-plane failure. Stop unless the agreed policy says continue/report.

Operation-specific continue/report failures:

- child issue closure failure: retry bounded times, continue, report in `CLOSURE_FAILURES`;
- PRD `ready-for-review` label failure: retry bounded times, continue, report in `LABEL_FAILURES`;
- push failure: retry bounded times, continue locally, retry after later Coordinator completions, report;
- draft PR creation failure: retry bounded times, continue implementation, retry after later Coordinator completions, report.

## Ordering

Preserve the user's PRD order as priority order. During preflight, classify PRDs as `READY`, `BLOCKED_BY_PRD`, or `BLOCKED_EXTERNAL`. Always run the earliest `READY` PRD whose blockers are satisfied. Never run a later PRD if it depends on an incomplete earlier PRD. Recompute readiness after each PRD completes.

## GitHub Rules

Prefer `gh` CLI and include `--repo <owner/name>` on every command. Use GitHub connector fallback only when `gh` is unavailable, unauthenticated, or lacks the needed operation.

For execution mode, every PRD thread must resolve to a PRD GitHub issue and child GitHub issues. PRD parent issues stay open. Orchestrator labels a PRD issue `ready-for-review` immediately after its Coordinator completes, with bounded retry. Coordinator closes child issues silently after completion, with bounded retry and reported closure failures.

Coordinator posts a new PRD issue comment after each child issue using [templates/prd-comment.md](templates/prd-comment.md). These comments are child-specific for design decisions, deviations, tradeoffs, and cumulative open questions. Always comment, using `None` where there is no notable content.

## Branch And PR Rules

Use the detected clean non-main branch when available. If on `main`, `master`, `trunk`, or branch detection fails, create `nightshift/<YYYY-MM-DD>-prd-run`.

After each Coordinator completes, push the branch with bounded retry. If no draft PR exists, attempt to create one with:

- title: `Nightshift PRD implementation - <YYYY-MM-DD>`
- body based on [templates/pr-body.md](templates/pr-body.md)

If PR creation never succeeds, the Orchestrator may still return `STATUS: COMPLETE`, but must report that the draft PR could not be created, PR Reviewer/autoreview was skipped, and follow-up is needed.

If a draft PR exists and PR Reviewer completes cleanly, mark it ready for review. If PR Reviewer is blocked or skipped, leave the PR draft.

## Commit Rules

Before invoking `$commit`, ensure the worktree contains only changes for the active child issue or active PR Reviewer finding. If unrelated or ambiguous files are present, return `STATUS: BLOCKED_BY_RUN_FAILURE` rather than asking the user.

Invoke `$commit` in GPT-5.5 low reasoning. Do not pass extra context by default. Do not impose Nightshift-specific commit message conventions.

## Review Rules

For each child issue, run a bounded implement-review-fix loop. Use a maximum of 3 cycles. If high/critical findings remain after the final cycle, block the Coordinator for that PRD.

For final PR review, run `autoreview` in branch/PR mode against the actual PR base when possible. Treat output as advisory, verify every finding, reject speculative or over-broad findings, and fix only verified actionable findings plus test/compile/format failures caused or revealed by those fixes. Use a maximum of 3 autoreview cycles.

If `autoreview` is unavailable, do not substitute a generic review. Leave the PR draft, mark the run complete with follow-up needed, and report that PR Reviewer was skipped.

## Already Closed Or Already Implemented Child Issues

If a child issue is already closed during preflight, record it as `PRE_CLOSED`; the Coordinator reconciles before skipping by checking whether behavior appears already present. If satisfied, record `SKIPPED_PRE_CLOSED`; if unclear, block externally.

If a child issue is open but the Coordinator verifies the behavior is already implemented on the current branch, post a PRD comment with `Commit: None - already implemented`, close the child silently with bounded retry, and report it in final status.
