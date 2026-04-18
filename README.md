# Agent Config

## Quick Start

### Installing Skills

```bash
npx skills add https://github.com/kokjinsam/agent-config/skills --skill spec-driven-development
```

### Full Lifecycle

For comprehensive coverage, load skills by phase:

```
Starting a project:  spec-driven-development → planning-and-task-breakdown
During development:  incremental-implementation + test-driven-development
Before merge:        code-review-and-quality + security-and-hardening
Before deploy:       shipping-and-launch
```

### Context-Aware Loading

Don't load all skills at once — it wastes context. Load skills relevant to the current task:

- Working on UI? Load `frontend-ui-engineering`
- Debugging? Load `debugging-and-error-recovery`
- Setting up CI? Load `ci-cd-and-automation`

## Skill Anatomy

Every skill follows the same structure:

```
YAML frontmatter (name, description)
├── Overview — What this skill does
├── When to Use — Triggers and conditions
├── Core Process — Step-by-step workflow
├── Examples — Code samples and patterns
├── Common Rationalizations — Excuses and rebuttals
├── Red Flags — Signs the skill is being violated
└── Verification — Exit criteria checklist
```

See [skill-anatomy.md](skill-anatomy.md) for the full specification.

## Using Agents

The `agents/` directory contains pre-configured agent personas:

| Agent                 | Purpose                   |
| --------------------- | ------------------------- |
| `code-reviewer.md`    | Five-axis code review     |
| `test-engineer.md`    | Test strategy and writing |
| `security-auditor.md` | Vulnerability detection   |

Load an agent definition when you need specialized review. For example, ask your coding agent to "review this change using the code-reviewer agent persona" and provide the agent definition.

## Using Commands

The `.claude/commands/` directory contains slash commands for Claude Code:

| Command   | Skill Invoked                                        |
| --------- | ---------------------------------------------------- |
| `/spec`   | spec-driven-development                              |
| `/plan`   | planning-and-task-breakdown                          |
| `/build`  | incremental-implementation + test-driven-development |
| `/test`   | test-driven-development                              |
| `/review` | code-review-and-quality                              |
| `/ship`   | shipping-and-launch                                  |

## Using References

The `references/` directory contains supplementary checklists:

| Reference                    | Use With                 |
| ---------------------------- | ------------------------ |
| `testing-patterns.md`        | test-driven-development  |
| `performance-checklist.md`   | performance-optimization |
| `security-checklist.md`      | security-and-hardening   |
| `accessibility-checklist.md` | frontend-ui-engineering  |

Load a reference when you need detailed patterns beyond what the skill covers.

## Spec and task artifacts

The `/spec` and `/plan` commands create working artifacts (`SPEC.md`, `tasks/plan.md`, `tasks/todo.md`). Treat them as **living documents** while the work is in progress:

- Keep them in version control during development so the human and the agent have a shared source of truth.
- Update them when scope or decisions change.
- If your repo doesn't want these files long‑term, delete them before merge or add the folder to `.gitignore` — the workflow doesn't require them to be permanent.

## Tips

1. **Start with spec-driven-development** for any non-trivial work
2. **Always load test-driven-development** when writing code
3. **Don't skip verification steps** — they're the whole point
4. **Load skills selectively** — more context isn't always better
5. **Use the agents for review** — different perspectives catch different issues

## Inspirations

- https://github.com/addyosmani/agent-skills/
- https://github.com/mitsuhiko/agent-stuff/
- https://github.com/surma/pi-config/
- https://github.com/badlogic/pi-skills/
