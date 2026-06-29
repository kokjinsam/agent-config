module TenantResourceAccess

/*
Models:
  <structural design slice>

Assumptions:
  <modeling assumptions introduced>

Scope:
  <exact command scopes>

Command expectations:
  validWorld: SAT
  <forbiddenExample>: UNSAT
  <invariantCheck>: no counterexample
*/

-- signatures

sig Tenant {}

sig User {
  tenant: one Tenant
}

sig Resource {
  tenant: one Tenant
}

sig Grant {
  user: one User,
  resource: one Resource
}

-- derived predicates/functions

pred canAccess[u: User, r: Resource] {
  some g: Grant | g.user = u and g.resource = r
}

-- foundational facts

fact GrantsStayWithinTenant {
  all g: Grant | g.user.tenant = g.resource.tenant
}

-- valid examples

pred validWorldExample {
  some User
  some Resource
}

pred nonEmptyAccessExample {
  some u: User, r: Resource | canAccess[u, r]
}

-- forbidden examples

pred crossTenantAccessExample {
  some u: User, r: Resource |
    canAccess[u, r] and u.tenant != r.tenant
}

-- assertions

assert NoCrossTenantAccess {
  all u: User, r: Resource |
    canAccess[u, r] implies u.tenant = r.tenant
}

-- commands

validWorld: run validWorldExample for 2 Tenant, 3 User, 3 Resource, 3 Grant
nonEmptyAccess: run nonEmptyAccessExample for 2 Tenant, 3 User, 3 Resource, 3 Grant
crossTenantAccess: run crossTenantAccessExample for 2 Tenant, 3 User, 3 Resource, 3 Grant
noCrossTenantAccess: check NoCrossTenantAccess for 2 Tenant, 3 User, 3 Resource, 3 Grant
