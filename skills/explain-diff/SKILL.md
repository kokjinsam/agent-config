---
name: explain-diff
description: "Use when the user asks for a rich explanation of a code change, diff, branch, commit, or PR. Produces a single self-contained interactive HTML walkthrough with background, intuition, code tour, diagrams, and quiz questions."
---

# Explain Diff

Create a rich, interactive explanation of a specified code change as one self-contained HTML file.

## Workflow

### 1) Resolve the Change

Use the user's target when provided: PR, branch, commit range, patch file, local diff, or current worktree. If no target is specified, use the current branch/worktree only when that is the obvious subject; otherwise ask for the target.

Work from the concrete repository root, read local agent instructions, and preserve unrelated local changes.

### 2) Build the Mental Model

Read the diff first, then explore enough surrounding code to explain why the change exists:

- call sites, callees, schemas, routes, components, tests, specs, migrations, docs, and configuration touched by the change
- the pre-change behavior and user-visible workflow
- the new behavior, invariants, edge cases, and failure modes
- toy data or a small scenario that makes the change easy to reason about

Prefer source-grounded explanation over guesswork. If an inference is necessary, label it.

### 3) Write the Explanation

Write in clear, narrative, systems-oriented prose with smooth transitions, concrete examples, and carefully introduced terminology.

The page must contain these top-level sections in this order:

- **Background**: Start with a skippable beginner-friendly background on the relevant system, then narrow to the exact subsystem affected by the change.
- **Intuition**: Explain the essence of the change before the details. Use toy data and small diagrams to make the idea feel obvious.
- **Code**: Walk through the implementation at a high level. Group changes by concept or execution flow, not mechanically by file order unless file order is clearer.
- **Quiz**: Provide exactly five medium-difficulty multiple-choice questions. Each question must require understanding the substance of the change. Clicking an answer must show whether it is correct and give explanatory feedback.

Use callouts for definitions, key concepts, important edge cases, and surprising trade-offs.

## HTML Contract

Create a single self-contained HTML file with inline CSS and JavaScript. Do not depend on external CDNs, images, fonts, or scripts unless they are embedded into the file.

Default output path:

- `/tmp/YYYY-MM-DD-explanation-<slug>.html`
- Get the date from the local system with `date +%F`.
- Build `<slug>` from the branch, PR, commit, or change topic.
- Always write outside the code repository so the artifact stays out of version control.

The HTML must be one long page with section headers and a table of contents. Do not use tabs for the top-level structure. Make the layout responsive enough to read on a phone.

Use simple HTML/CSS diagrams, not ASCII diagrams. Reuse a small number of diagram families when possible:

- simplified UI mockups for UI changes
- system or data-flow diagrams for component interactions, including example payloads or records
- state/status-flow diagrams for lifecycle changes

Code snippets must use `<pre>` tags. If any custom styled code container is used instead, its CSS must include `white-space: pre` or `white-space: pre-wrap` so newlines are preserved.

## Verification

Before responding:

- Scan the HTML source and confirm every code block is a `<pre>` tag, or the custom code-block CSS contains `white-space: pre` or `white-space: pre-wrap`.
- Confirm the output file path starts with today's `YYYY-MM-DD-` date prefix and is outside the repository.
- Confirm the table of contents links work, the quiz responds to clicks, and the page has no top-level tabs.
- If browser tooling is available, open the file and visually check the layout at desktop and mobile widths.

Final response: give the absolute path to the HTML file and summarize the verification performed.
