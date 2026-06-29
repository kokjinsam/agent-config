---
name: alloy-spec
description: "Write and iteratively refine executable Alloy specs (.als) from natural-language structural/domain designs; run Alloy Analyzer commands and report scopes, instances, counterexamples, and modeling assumptions."
disable-model-invocation: true
---

# Write Alloy Spec

Use Alloy for structural domain modeling.

Use it to model possible data relationships, ownership rules, tenancy boundaries, containment, permissions, reachability, cardinality, and invalid combinations of state.

Do not use this skill for temporal workflows, retries, concurrency, ordering, liveness, or execution traces. Use `/tla-spec` for those.

## Outputs

- Alloy spec(s): `*.als`
- Alloy run artifacts: `.alloy-check/runs/<run-id>/...`
  - command results
  - analyzer logs
  - instance/counterexample XML or JSON if available
  - summarized domain-language explanation

## Non-Negotiables

- Never say "proved correct".
- Say "no counterexample found" and state the exact scope used.
- Always surface modeling assumptions introduced to remove ambiguity.
- Always make command expectations explicit:
  - which `run` commands should find an instance
  - which `run` commands should find no instance
  - which `check` commands should find no counterexample
- Actively guard against overconstraint before calling a run "pass":
  - Show that at least one valid instance exists.
  - Show that important signatures can be populated.
  - Show that important relations can be non-empty when they should be possible.
  - If all interesting `run` commands are unsat, report "inconclusive model: possibly overconstrained".
- Do not hide business rules inside `fact` until they have been tested with examples or assertions.
- A model without checked commands is an unchecked draft.

## Workflow

### 1) Pin Down Scope and Structure

Ask for and record:

- What are the domain entities?
- What are the relationships between them?
- Which relationships are `one`, `lone`, `some`, or `set`?
- Which relationships imply ownership, containment, or permission?
- Which cycles are allowed or forbidden?
- Which combinations of entity states are allowed or forbidden?
- What must always be true?
- What invalid structure are we trying to find?
- What small scope is enough to expose the risk?

If the user does not specify scope, propose minimal scopes and label them as proposed:

```txt
Proposed scope:
  2 tenants
  3 users
  3 resources
  3 roles
  4 permissions
```

Do not rely on Alloy's default scope unless it is intentional and reported.

### 2) Write the Minimal Spec Skeleton

Use a consistent structure:

```alloy
module <name>

/*
Models:
  <what this model represents>

Checks:
  <bad structures this model is trying to find>

Assumptions:
  <modeling assumptions introduced>

Scope:
  <intended command scopes>

Command expectations:
  <command>: <SAT/UNSAT/no counterexample> - <why>

Implementation obligations:
  <database constraints, code guards, tests, runtime assertions>
*/

-- signatures

-- derived predicates/functions

-- facts

-- valid examples

-- forbidden examples

-- assertions

-- commands
```

Prefer domain names from `CONTEXT.md`.

Keep signatures small.

Use facts only for foundational truths.

Use predicates for named scenarios.

Use assertions for properties that must always hold.

Use commands to check the model.

### 3) Facts vs Assertions

Be careful with `fact`.

A `fact` removes all instances that violate it. Too many facts can make the model empty and make every `check` look successful.

Use this order when possible:

1. Model basic structure.
2. Add valid-example `run` commands.
3. Add forbidden-example `run` commands.
4. Add assertions and `check` commands.
5. Only then promote stable assumptions into facts.

Good:

```alloy
pred crossTenantAccessExists {
  some u: User, r: Resource |
    canAccess[u, r] and u.tenant != r.tenant
}

crossTenantAccessShouldBeImpossible: run crossTenantAccessExists for 3 Tenant, 4 User, 4 Resource
```

Good:

```alloy
assert NoCrossTenantAccess {
  all u: User, r: Resource |
    canAccess[u, r] implies u.tenant = r.tenant
}

noCrossTenantAccessCheck: check NoCrossTenantAccess for 3 Tenant, 4 User, 4 Resource
```

Bad:

```alloy
fact {
  all u: User, r: Resource |
    canAccess[u, r] implies u.tenant = r.tenant
}

check {}
```

### Requirement Ledger

Maintain a compact ledger mapping each natural-language requirement to one of:

- a signature
- a field
- a fact
- a predicate
- an assertion
- a command
- explicitly "not modeled yet"

Example:

```txt
Requirement ledger:
  "A resource belongs to exactly one tenant"
    -> Resource.tenant: one Tenant

  "Users cannot access resources in another tenant"
    -> assert NoCrossTenantAccess
    -> command noCrossTenantAccessCheck

  "A tenant may have multiple users"
    -> multiUserTenantExample run command

  "Billing limits are ignored"
    -> not modeled yet
```

When reporting results, include the ledger or a short version.

### 4) Write Commands That Actually Test the Model

Every Alloy spec must include commands.

Use `run` commands for examples.

Use `check` commands for invariants.

Every command should have an explicit expectation.

Include at least:

- one valid-world command expected to be SAT
- one command exercising an important non-empty relationship, if applicable
- one forbidden-structure command expected to be UNSAT, if applicable
- one `check` command per important invariant

Example:

```alloy
validWorld: run {
  some Tenant
  some User
  some Resource
} for 3 Tenant, 4 User, 4 Resource

nonEmptyAccessExample: run {
  some u: User, r: Resource | canAccess[u, r]
} for 3 Tenant, 4 User, 4 Resource

crossTenantAccessExample: run {
  some u: User, r: Resource |
    canAccess[u, r] and u.tenant != r.tenant
} for 3 Tenant, 4 User, 4 Resource

noCrossTenantAccessCheck: check NoCrossTenantAccess for 3 Tenant, 4 User, 4 Resource
```

Interpretation:

```txt
validWorld:
  Expected SAT.

nonEmptyAccessExample:
  Expected SAT if access is possible.

crossTenantAccessExample:
  Expected UNSAT.

noCrossTenantAccessCheck:
  Expected no counterexample.
```

If expectations are not met, explain the mismatch before changing the model.

### 5) Run Alloy Deterministically

Prefer an existing project command first:

- README instructions
- Makefile
- justfile
- package scripts
- mise tasks
- nix/devenv commands
- Docker commands
- CI formal-checking jobs

If no project command exists, use the bundled skill script.

Prereqs:

- `java` on PATH
- Alloy jar available from one of:
  - project-local `.alloy/org.alloytools.alloy.dist.jar`
  - `ALLOY_JAR`
  - `--jar path/to/org.alloytools.alloy.dist.jar`

Run from the `alloy-spec` skill directory:

```bash
scripts/alloy_check.sh --spec path/to/Foo.als
```

This writes a run directory near the spec:

```txt
.alloy-check/runs/<run-id>/summary.json
.alloy-check/runs/<run-id>/alloy.stdout
.alloy-check/runs/<run-id>/alloy.stderr
.alloy-check/runs/<run-id>/commands.json
.alloy-check/runs/<run-id>/instances/
.alloy-check/runs/<run-id>/counterexamples/
```

If the repository has no working Alloy runner and the bundled script is unavailable, do not claim the model was checked.

Report:

```txt
Status:
  unchecked draft

Reason:
  Alloy checker was not available in this environment.

Command to run:
  scripts/alloy_check.sh --spec path/to/Foo.als
```

### 6) Iterate

If a valid example is UNSAT:

- The model may be overconstrained.
- Explain which facts or multiplicities may be preventing an instance.
- Patch minimally.
- Re-run.

If a forbidden example is SAT:

- Alloy found a bad structure.
- Translate the instance into domain language.
- Decide whether the design is wrong, the model is missing a rule, or the requirement was ambiguous.
- Patch minimally.
- Re-run.

If a `check` command finds a counterexample:

- Explain the counterexample in domain language.
- Do not immediately patch the assertion to pass.
- First decide whether the counterexample is a real design flaw, a missing assumption, or an invalid model abstraction.
- Patch minimally.
- Re-run.

If all commands pass:

- Report the exact scopes.
- Report which commands were SAT/UNSAT.
- Report which assertions had no counterexample.
- Report assumptions and unmodeled requirements.
- Report implementation obligations.

Say:

```txt
No counterexample found within this scope.
```

Do not say:

```txt
The design is correct.
```

## Report Format

After writing or changing a spec, report:

```txt
Model:
  docs/formal/TenantResourceAccess.als

Checker:
  scripts/alloy_check.sh --spec docs/formal/TenantResourceAccess.als

Result:
  no counterexample found within checked scopes

Scope:
  3 Tenant
  4 User
  4 Resource
  4 Role
  6 Permission

Commands:
  validWorld
    expected: SAT
    actual: SAT

  nonEmptyAccessExample
    expected: SAT
    actual: SAT

  crossTenantAccessExample
    expected: UNSAT
    actual: UNSAT

  noCrossTenantAccessCheck
    expected: no counterexample
    actual: no counterexample found

Assumptions:
  Users belong to exactly one tenant.
  Resources belong to exactly one tenant.
  Cross-tenant sharing is not modeled.

Requirement ledger:
  <short mapping>

Counterexamples:
  none

Unmodeled:
  Billing limits.
  Time-based permission expiry.
  Invitation acceptance workflow.

Implementation obligations:
  Add tenant_id to protected resources.
  Add authorization tests for cross-tenant access attempts.
  Add a database constraint preventing membership rows across tenants.
```

If a counterexample is found:

```txt
Counterexample:
  A user in TenantA can access ResourceB because RoleAssignment is not constrained to the user's tenant.

Design implication:
  RoleAssignment must be tenant-scoped.

Implementation obligations:
  Add tenant_id to role_assignment.
  Enforce role_assignment.tenant_id = user.tenant_id.
  Enforce role_assignment.tenant_id = resource.tenant_id during access checks.
```

If unchecked:

```txt
Model:
  docs/formal/TenantResourceAccess.als

Result:
  unchecked draft

Reason:
  Alloy checker was not available.

Command to run:
  scripts/alloy_check.sh --spec docs/formal/TenantResourceAccess.als

Do not treat this model as authoritative until checked.
```

## Resources

### scripts/

- `scripts/alloy_check.sh`: run every Alloy command, capture logs, emit `summary.json`
- `scripts/alloy_instance_summary.sh`: summarize an instance or counterexample into domain-language facts

### references/

- `references/spec_skeleton.als`: minimal Alloy skeleton
- `references/command_patterns.md`: common `run` / `check` command patterns

The most important part is the **valid-world run**. Without it, an agent can accidentally write an Alloy model whose facts make the universe impossible, then all checks "pass" vacuously.
