# Alloy Command Patterns

Use `run` to ask whether a structure can exist. Use `check` to ask whether an assertion has a counterexample.

## Valid World

```alloy
validWorld: run {
  some Tenant
  some User
  some Resource
} for 2 Tenant, 3 User, 3 Resource
```

Expected: SAT. If this is UNSAT, the model may be overconstrained.

## Non-Empty Relation

```alloy
nonEmptyAccess: run {
  some u: User, r: Resource | canAccess[u, r]
} for 2 Tenant, 3 User, 3 Resource, 3 Grant
```

Expected: SAT when the relation should be possible.

## Forbidden Structure

```alloy
crossTenantAccess: run {
  some u: User, r: Resource |
    canAccess[u, r] and u.tenant != r.tenant
} for 2 Tenant, 3 User, 3 Resource, 3 Grant
```

Expected: UNSAT when cross-tenant access is forbidden.

## Invariant Check

```alloy
assert NoCrossTenantAccess {
  all u: User, r: Resource |
    canAccess[u, r] implies u.tenant = r.tenant
}

noCrossTenantAccess: check NoCrossTenantAccess for 2 Tenant, 3 User, 3 Resource, 3 Grant
```

Expected: no counterexample.

## Fact Promotion

Start with examples and assertions. Promote a rule into `fact` only when violating it should remove the instance from the modeled universe.
