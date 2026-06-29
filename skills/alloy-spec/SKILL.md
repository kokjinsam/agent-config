---
name: alloy-spec
description: "Write and iteratively refine executable Alloy specs (.als) from natural-language structural/domain designs; run Alloy Analyzer commands and report scopes, instances, counterexamples, expectations, and modeling assumptions."
---

# Write Alloy Spec

Use Alloy to turn natural-language structural designs into executable relational models.

Use it for allowed structures: ownership, containment, cardinality, reachability, permissions, tenancy boundaries, cycles, and invalid combinations of state.

Do not use it for workflows, ordering, concurrency, retries, liveness, fairness, or execution traces. Use `/tla-spec` for those.

## Non-Negotiables

- Never say "proved correct". Say "no counterexample found" and state the exact scope.
- Always surface modeling assumptions introduced to remove ambiguity.
- Always make command expectations explicit:
  - `run` commands expected to find an instance
  - `run` commands expected to find no instance
  - `check` commands expected to find no counterexample
- A model without checked commands is an unchecked draft.
- Guard against overconstraint before calling a result useful:
  - include at least one valid-world `run` expected SAT
  - show important signatures can be populated
  - show important relations can be non-empty when they should be possible
  - report "inconclusive model: possibly overconstrained" if interesting runs are UNSAT
- Do not hide business rules inside `fact` until they have been tested with examples or assertions.

## Workflow

### 1) Shape the Model

Read `CONTEXT.md` if it exists and use its domain names. Do not update glossary or ADR files unless the user explicitly asks.

Record only what the spec needs:

- entities
- relationships and multiplicities (`one`, `lone`, `some`, `set`)
- ownership, containment, permission, reachability, and cycle rules
- valid structures that must be possible
- invalid structures the model should find or rule out
- invariants that must always hold
- exact scopes; propose small scopes when missing
- assumptions and requirements not modeled

Do not rely on Alloy's default scope unless it is intentional and reported.

### 2) Write the Minimal Spec

Use this order:

```alloy
module <name>

-- signatures
-- derived predicates/functions
-- foundational facts
-- valid examples
-- forbidden examples
-- assertions
-- commands
```

Keep signatures small. Use:

- `fact` for foundational truths that define the universe
- `pred` for named scenarios and examples
- `assert` for properties that must always hold
- `run` for examples
- `check` for invariants

Prefer this progression:

1. Model basic structure.
2. Add valid-example `run` commands.
3. Add forbidden-example `run` commands.
4. Add assertions and `check` commands.
5. Promote stable constraints into facts only when they are part of the intended universe.

### 3) Maintain a Requirement Ledger

Map each natural-language requirement to one of:

- signature
- field
- fact
- predicate
- assertion
- command
- not modeled yet

Keep the ledger compact enough to include in the report.

### 4) Write Useful Commands

Every spec must include commands with expectations.

Include at least:

- one valid-world `run` expected SAT
- one non-empty relation/signature `run` expected SAT when the structure should be possible
- one forbidden-structure `run` expected UNSAT when relevant
- one `check` per important invariant

If a command result differs from expectation, explain the mismatch before changing the model.

For more patterns, read `references/command_patterns.md`.

### 5) Run Alloy

Prefer an existing project command first: README, Makefile, Justfile, package script, mise task, nix/devenv task, Docker command, or CI formal-checking job.

If no project command exists, use the bundled runner:

```bash
scripts/alloy_check.sh --spec path/to/Foo.als
```

The runner needs `java`, `jq`, and an Alloy dist jar from one of:

- `--jar path/to/org.alloytools.alloy.dist.jar`
- `$ALLOY_JAR`
- project-local `.alloy/org.alloytools.alloy.dist.jar`

It writes:

```txt
.alloy-check/runs/<run-id>/summary.json
.alloy-check/runs/<run-id>/alloy.stdout
.alloy-check/runs/<run-id>/alloy.stderr
.alloy-check/runs/<run-id>/commands.json
.alloy-check/runs/<run-id>/instances/
.alloy-check/runs/<run-id>/counterexamples/
```

If no checker is available, report an unchecked draft and the command needed to check it. Do not treat it as authoritative.

### 6) Iterate

If a valid example is UNSAT, suspect overconstraint. Explain the likely fact or multiplicity causing it, patch minimally, and rerun.

If a forbidden example is SAT, translate the instance into domain language. Decide whether the design is wrong, the model is missing a rule, or the requirement was ambiguous before patching.

If a `check` finds a counterexample, explain the counterexample in domain language. Do not weaken the assertion just to pass.

If all relevant commands match expectations, report exact scopes and say:

```txt
No counterexample found within this scope.
```

## Report Contract

After writing or changing a spec, report:

- model path
- checker command
- result: checked, counterexample found, inconclusive, or unchecked draft
- exact scopes
- command expectations vs actuals
- assumptions
- requirement ledger
- counterexamples or instances that matter
- unmodeled requirements
- implementation obligations

## Resources

- `scripts/alloy_check.sh`: run Alloy commands, capture logs, emit `summary.json`
- `scripts/alloy_instance_summary.sh`: summarize JSON instances/counterexamples
- `references/spec_skeleton.als`: minimal copy/patch skeleton
- `references/command_patterns.md`: compact command patterns
