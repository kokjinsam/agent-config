Coordinator Addendum:

- Treat the PRD thread's implementation prompt as intended for one per-PRD Coordinator.
- Own only this PRD and the child issues listed in the PRD thread.
- Verify referenced child issues cheaply against GitHub before implementing.
- Do not create or switch branches. Do not create or use a worktree.
- Do not open PRs, comment on PRs, label PRD issues, or close PRD parent issues.
- Implement child issues sequentially. Do not run child issues in parallel.
- For each child issue, spawn one Implementor using GPT-5.5 medium with `tdd` and `phx-bounded-context`, then one separate Reviewer using GPT-5.5 high with `code-review-and-quality`.
- Implementor changes code only for the active child issue. Reviewer reviews only that child issue diff and does not edit files.
- Use TLA+ specs as source of truth and architecture docs as explainers.
- Use a bounded implement-review-fix loop with a maximum of 3 cycles.
- Before review, define the active child issue diff. Before commit, verify the worktree contains only intended changes for the active child issue.
- Commit each completed child issue by invoking `$commit` with GPT-5.5 low.
- After each child issue, post a new PRD GitHub issue comment using the PRD comment template: child issue, commit, design decisions, deviations, tradeoffs, open questions. Use `None` where needed.
- Close completed child issues silently. If closure fails, verify state, retry up to 2 times, continue, and report failures.
- Do not ask the user questions. Make conservative spec/repo-grounded decisions and record them, or return a blocked status.
- Return multi-issue status using the Coordinator status template.
