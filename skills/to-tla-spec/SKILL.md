---
name: to-tla-spec
description: "Write and iteratively refine executable TLA+ specs (.tla) and TLC model configs (.cfg) from natural-language system designs; run TLC model checking."
---

# Write TLA+ Spec

## Outputs

- TLA+ spec(s): `*.tla`
- TLC config(s): `*.cfg`
- TLC run artifacts: `.tla-check/runs/<run-id>/...` (logs, json trace if any)

## Non-Negotiables (Honesty Rules)

- Never say "proved correct". Say "no counterexample found" and state the bounds/model used.
- Always surface modeling assumptions you introduced to remove ambiguity.
- If liveness is in scope, explicitly state fairness assumptions used in the run (`WF_`/`SF_`), or explicitly say "none (safety-only run)".
- Actively guard against vacuous success before calling a run "pass":
  - Show that at least one non-stuttering transition is reachable.
  - If using `CONSTRAINT` / `ACTION_CONSTRAINT`, list each one and the behavior it excludes.
  - Reject properties that are tautological or trivially weakened.
  - If any vacuity check is inconclusive, report "inconclusive coverage" instead of "pass".

## Workflow (NL -> Classify -> Spec+CFG -> TLC -> Iterate)

### 1) Classify Spec

Before writing files, classify the layer:

- **Bounded context system spec**: one canonical spec per small bounded context. It owns vocabulary,
  state variables, core transitions, and invariants.
- **Workflow spec**: a small projection of a context system spec for a risky workflow or
  transition family. It should say it is a slice of `<ContextSystem>.tla`, reuse names where possible,
  and avoid parallel vocabulary. If it needs semantics missing from the system spec, mark it
  exploratory or flag that the system spec needs an update.
- **Integration spec**: a cross-context coordination model for handoffs, bridges, accepted/rejected
  events, ownership transfer, eventual consistency, duplicate delivery, and similar contracts. It
  must not redefine each context's internals.

If a single system spec is growing into a giant executable architecture document, say so. Either the
bounded context is too broad, or the spec should be decomposed into TLA modules while preserving one
named context-level authority.

For integration spec names, use descriptive relationship names such as
`SalesOrderPaymentAcceptance.tla`, `SalesOrderShippingSchedule.tla`, or `ProtocolActivationHandoff.tla`.
Avoid vague names like `Integration.tla`, `CrossContext.tla`, `Workflow.tla`, or `Bridge.tla`.

### 2) Pin Down Scope and Bounds (Ask, Don't Guess)

Ask for (and record) answers:

- What are the state variables?
- What are the actions/steps?
- What safety properties must never break? (invariants)
- What liveness properties must eventually happen? (temporal properties)
- If liveness is in scope, what fairness model applies to which actions? (`WF_`/`SF_`)
- What environment/failure model is in-scope? (message loss, crashes, reordering, clock skew, retries)
- What bounds make the model finite? (small sets for nodes, messages, values, time, etc.)

If the user doesn't specify bounds, propose minimal ones (and label them as "proposed"):

- 2-3 nodes, 2-3 values, short message buffers, small time domain.

### 3) Write the Minimal Spec Skeleton (Then Grow It)

Use a consistent structure:

- `CONSTANTS` for bounded sets (e.g., `Nodes`, `Values`).
- `VARIABLES` for state.
- `Vars == <<...>>` as a single canonical variable tuple name. Use the same casing (`Vars`) everywhere.
- `TypeOK` (type invariant) to keep the model honest.
- `Init` and `Next` (with `UNCHANGED` for untouched vars).
- For safety checks: `Spec == Init /\\ [][Next]_Vars`.
- For liveness checks: extend `Spec` with explicit fairness assumptions, e.g. `/\\ WF_Vars(SomeAction)` or `/\\ SF_Vars(SomeAction)`.
- Named invariants as separate operators so they can be listed in the `.cfg`.

Prefer modeling the _design_ over implementation details. If the design is fuzzy, model the uncertainty explicitly with nondeterminism and constraints.

### Requirement Ledger (Prevent Hallucinated Coverage)

Maintain a compact checklist that maps each natural-language requirement to one of:

- A named invariant/operator in the spec (and listed in the `.cfg`)
- A temporal property (and listed in the `.cfg`)
- A precondition in one or more actions
- Explicitly "not modeled yet"

When reporting results, include this ledger (or a short version) so it's obvious what passed vs what was never encoded.

### 4) Write the TLC `.cfg` (Make the Model Check Run)

Baseline config (edit as needed):

```tla
SPECIFICATION Spec
\* Or:
\* INIT Init
\* NEXT Next

CONSTANTS
  \* Example:
  \* Nodes = {n1, n2, n3}
  \* Values = {v1, v2}

INVARIANT
  TypeOK
  \* Add safety invariants here

CHECK_DEADLOCK TRUE
```

Deadlock policy:

- Keep `CHECK_DEADLOCK TRUE` by default.
- If terminal states are intentional, define an explicit terminal condition in the spec and report deadlock outcomes as either "expected terminal completion" or "unexpected stall".

If you introduce `CONSTRAINT` / `ACTION_CONSTRAINT`, call it out as a _coverage tradeoff_ and report what behavior it removes.

### 5) Run TLC Deterministically (Via Bundled Script)

Prereqs:

- `java` on PATH
- `jq` on PATH
- `tla2tools.jar` available from a project-local `.tla/tla2tools.jar`, `TLA2TOOLS_JAR`, or `--jar`

Run (from the `to-tla-spec` skill directory):

```bash
scripts/tlc_check.sh --spec path/to/Foo.tla --cfg path/to/Foo.cfg
```

This writes a run directory under the spec folder:

- `.tla-check/runs/<run-id>/summary.json`
- `.tla-check/runs/<run-id>/tlc.stdout`
- `.tla-check/runs/<run-id>/tlc.stderr`
- `.tla-check/runs/<run-id>/counterexample.json` (only if TLC produced one)

### 6) Iterate (Tight Loop)

If TLC fails:

- Explain the failure using the dumped trace (focus on state deltas and the violated property).
- Patch the spec/config minimally.
- Re-run and compare.

If TLC passes:

- Report: bounds, invariants/properties checked, fairness assumptions used (or "none"), deadlock interpretation, and what's still unmodeled.
  - Confirm vacuity checks passed; otherwise report "inconclusive coverage."
  - Example: "Checked with 3 nodes, 2 values, bounded message buffer of size 2; no counterexample found."

## Resources

### scripts/

- `scripts/tlc_check.sh`: run TLC with `-dumpTrace json`, capture logs, emit `summary.json`
- `scripts/tlc_trace_summary.sh`: summarize a `counterexample.json` into step-by-step diffs (optional helper)

### references/

- `references/spec_skeleton.md`: minimal skeleton patterns and cfg snippets
