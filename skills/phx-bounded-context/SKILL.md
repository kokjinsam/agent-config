---
name: phx-bounded-context
description: >
  Implements bounded contexts in Elixir/Phoenix using aggregate-oriented DDD: a thin public
  context facade that delegates to command and query handlers, in-memory aggregate roots
  that own invariants and state machines, separate database-backed persistence schemas, and
  cross-context workflows expressed as direct command-to-command (or worker-to-command)
  calls through the other context's public facade. Use this skill whenever building or
  changing the internals of a Phoenix context that has real business rules.
---

# Phoenix Bounded Context Architecture

This skill implements bounded contexts using aggregate-oriented DDD on top of Phoenix and Ecto
idioms. The goal is clear boundaries without fighting the framework: a thin public facade,
self-contained command/query handlers, pure in-memory aggregates that protect invariants, and
separate persistence schemas for the database.

## When this architecture is worth it

This structure earns its overhead only when the domain has **meaningful business behavior**: real
invariants, state transitions, money/totals, tenant or permission boundaries, or aggregate
consistency requirements. Decide heuristically per context:

- **Rich domain** (invariants, a state machine, multi-tenancy, things that must stay consistent) →
  apply the full structure below.
- **Simple CRUD** (admin panel, basic record management, reporting) → say so plainly and recommend a
  lighter vanilla Phoenix context with plain Ecto schemas. Don't force these patterns where they
  don't pay for themselves; flag the recommendation rather than silently scaffolding everything.

When in doubt, name the trade-off for the user and let them choose.

## What this skill does

Four modes — infer which from the request:

1. **Scaffold a new context** — generate the full tree (facade, commands, queries, aggregate,
   persistence schemas, policy, workers, migration, full test pyramid) from a domain description.
2. **Add an operation** — add a single command or query (plus the aggregate transition and tests) to
   an existing context, following its established conventions.
3. **Review / refactor** — audit existing code against the rules here and fix violations: `Repo` in
   an aggregate, a fat facade doing orchestration, cross-context calls inside an aggregate / policy
   / query (instead of a command or worker), cross-context calls bypassing the facade, child
   mutation bypassing the aggregate root, CRUD names where domain verbs belong.
4. **Explain / guide** — answer how-to questions and point to the right layer without necessarily
   writing code.

## Before generating: detect the project

Read the codebase first so generated code fits in, then confirm once before scaffolding:

- **App namespace** — from `mix.exs` (`:app`) and the `lib/` tree (e.g. `MyApp`, `MyApp.Repo`).
- **Scope module** — find the existing `Scope` struct (often `MyApp.Accounts.Scope`). **Inspect its
  fields** — this drives multi-tenancy (below).
- **Conventions** — look at 2–3 existing contexts/schemas and mirror their patterns (test style,
  naming, `timestamps` type, id type) even where they differ from the templates here. Consistency
  with the codebase beats matching this skill verbatim.

Show the user the detected app prefix, Scope module, and Repo for a single confirmation, then build.

For full code templates for every module, read `references/templates.md`. For the test pyramid
(StreamData property tests, handler/use-case/controller tests), read `references/testing.md`.

## The layers and where things live

```
lib/my_app/
  sales.ex                      # Thin public facade — defdelegate only
  sales/
    policy.ex                   # Authorization for the context (default home for authz)
    commands/place_order.ex     # Write use case: authorize, validate, transact, persist
    queries/get_order.ex        # Read use case: validate, authorize/filter, fetch, map
    workers/*.ex                # Oban jobs; call the public API
    order.ex                    # Aggregate root: invariants, state machine, mapping (no Repo)
  repo/sales/
    order.ex                    # schema "orders": queries, changesets
    order_line_item.ex          # schema "order_line_items"
```

| Layer                       | Owns                                                                | Never                                            |
| --------------------------- | ------------------------------------------------------------------- | ------------------------------------------------ |
| `MyApp.Sales` (facade)      | Public API shape, `defdelegate`                                     | Transactions, business rules, mapping            |
| `Commands.*`                | Authorize, validate input, transaction, persist, return result; may call other contexts via their facade | Reaching into another context's internals       |
| `Queries.*`                 | Validate, authorize/filter, build query, map to result              | Mutations, calling other contexts                |
| `Order` (aggregate)         | Invariants, state transitions, child updates, **mapping both ways** | Calling `Repo`, calling other contexts           |
| `Repo.Sales.Order` (schema) | `schema "..."`, query fragments, persistence changesets             | Business decisions                               |
| `Sales.Policy`              | Authorization decisions                                             | Persistence, domain logic, calling other contexts |
| `Workers.*`                 | Async entry points; may call own and other contexts via facades     | Bypassing the facade                             |

## Core rules

### 1. Scope is the first argument

Every public function whose result or side effect depends on actor, organization, tenant,
permissions, or visibility takes `%Scope{}` first. The scope represents the request boundary, not
just the current user. For genuinely system-level work, pass an explicit system scope
(`%Scope{user: nil, roles: [:system], tenant_id: ...}`) rather than bypassing the pattern.

```elixir
Sales.place_order(scope, attrs)   # not Sales.place_order(attrs, user)
Sales.get_order(scope, id)        # not Sales.get_order(id)
```

### 2. The facade is thin

The public context module delegates and nothing more. A boring facade is a feature — it's the stable
surface controllers, LiveViews, workers, and use cases depend on.

```elixir
defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
defdelegate get_order(scope, id), to: GetOrder, as: :handle
```

### 3. Name public commands in ubiquitous language

Public **command** functions use the domain's verbs, not CRUD: `place_order`, `cancel_order`,
`ship_shipment` — never `create_order`/`update_order`/`delete_order`. Before naming, **ask the user
for the context's glossary / ubiquitous language** if it isn't already clear from the conversation or
codebase; the names are the API and should match how the business talks. **Queries may stay
`get_`/`list_`/`find_`** — reads are less domain-charged and the conventional names read clearly.

### 4. Handlers are self-contained

A command or query handler owns one use case end to end for one context: authorization (via the
policy), input validation, transaction boundary, loading/persisting schemas, calling the aggregate,
mapping, and returning a result. Handlers own their **input schema** as an `embedded_schema` defined
in the handler module itself — this validates external/string-keyed params and expresses intent,
separate from persistence validation. If a handler seems to need several unrelated input schemas,
split it into multiple handlers before nesting input modules.

### 5. Aggregates are pure and own everything domain

The aggregate root (`Order`) is an `embedded_schema`, **not** database-backed. It owns invariants,
the state machine, and all updates to its children. It never calls `Repo`. Transition functions are
pure and return `{:ok, aggregate}` or `{:error, reason}`.

- **Children are inlined** in the root's `embedded_schema` (`embeds_many :line_items, ... do ... end`)
  with **private** child changesets. They're internal to the aggregate, not standalone resources.
  Ecto generates a nested struct module (`Order.LineItem`) — treat it as an implementation detail,
  never call it from application code.
- **All child updates go through the root**: `Order.add_line_item(order, attrs)`, not
  `LineItem.change_quantity(...)`.
- **Mapping lives in the aggregate, both directions** — this is a deliberate choice for this
  codebase. The aggregate exposes `from_schema/1` (build the domain struct from a loaded persistence
  struct) and `to_attrs/2` (domain → attrs map for persistence, taking `scope` for tenant fields).
  The aggregate **may alias and pattern-match the `%Repo.Sales.Order{}` struct directly** — that
  same-context coupling is acceptable. The hard rule is only that the aggregate never touches `Repo`;
  it receives already-loaded structs from handlers.

### 6. State machines use Gearbox

Always wire the state machine with `Gearbox` (`use Gearbox, field: :status, states: [...],
transitions: %{...}`), owned by the aggregate root. The state machine prevents invalid transitions;
aggregate functions enforce the extra business rules (e.g. `draft -> placed` is allowed by Gearbox,
but `place/1` also requires at least one line item). Expose intention-revealing functions
(`Order.place/1`, `Order.cancel/1`), never raw `%{order | status: :placed}`.

### 7. embedded_schema vs database-backed schema

- `embedded_schema` → aggregates, inline children, handler input schemas, in-memory validation. Not
  Repo-backed; never `Repo.get(MyApp.Sales.Order, id)`.
- `schema "table"` → persistence, queries, associations, `cast_assoc`. Lives under `MyApp.Repo.*`.

Map between them via the aggregate's `from_schema/to_attrs` so persistence concerns never leak into
domain behavior.

### 8. Authorization lives in a policy module by default

Generate a `MyApp.Sales.Policy` with `authorize(scope, action, params \\ %{})` returning `:ok` /
`{:error, :unauthorized}`; handlers call it. Keep authz out of the aggregate and the facade. When a
single operation's authorization grows genuinely complex, it's fine to drop a private `authorize/2`
into that handler — but the policy module is the default home.

### 9. Errors: tagged atoms + changesets

Domain errors are tagged atoms (`{:error, :unauthorized}`, `{:error, :not_found}`,
`{:error, :empty_order}`); input/persistence validation failures are `{:error, %Ecto.Changeset{}}`.
Controllers pattern-match these to status codes. Keep this convention consistent across every layer.

### 10. Transactions use Repo.transact

Standardize on `Repo.transact/1` everywhere — it returns the `{:ok, _}` / `{:error, _}` from the
function and rolls back automatically on `:error`, so there's no manual `Repo.rollback`. Every
command wraps its own work in `Repo.transact`. When one command calls another — in the same context
or across contexts — the nested `Repo.transact` calls compose safely: every context shares one
`Repo`, and Ecto rolls back the outer transaction when any inner `:error` bubbles up. You don't need
to coordinate which command "owns" the outer transaction; wrap each handler the same way and let it
nest.

```elixir
def handle(%Scope{} = scope, attrs) do
  Repo.transact(fn ->
    with :ok <- Policy.authorize(scope, :place_order),
         {:ok, command} <- validate(attrs),
         {:ok, order} <- build_order(command),
         {:ok, order} <- Order.place(order),
         {:ok, schema} <- insert_order_aggregate(scope, order) do
      {:ok, Order.from_schema(schema)}
    end
  end)
end
```

### 11. Cross-context calls go through the public facade

Command handlers and Oban workers may call other contexts directly — through the other context's
public facade, never into its `Commands.*` or `Workers.*` modules. The same applies inside a single
context: sibling commands call each other via `Sales.apply_discount/2`, not
`Sales.Commands.ApplyDiscount`. The facade is the only stable surface; everything else is internal.

Aggregates, policies, and queries do **not** call other contexts — that's a hard restriction.
Cross-context orchestration lives in commands and workers, where transactions, authorization, and
input validation already live. A query that needs data from a sister context is composed at the
controller / LiveView level (call both `Sales.get_order` and `Billing.get_invoice` and assemble the
view); promote that to a dedicated read-model context only when the composition repeats or becomes
performance-sensitive.

```elixir
# Inside Sales.Commands.PlaceOrder:
def handle(%Scope{} = scope, attrs) do
  Repo.transact(fn ->
    with :ok           <- Policy.authorize(scope, :place_order),
         {:ok, command} <- validate(attrs),
         {:ok, order}   <- build_order(command),
         {:ok, order}   <- Order.place(order),
         {:ok, schema}  <- insert_order_aggregate(scope, order),
         {:ok, _resv}   <- Inventory.reserve_stock(scope, schema.id),
         {:ok, _pay}    <- Billing.authorize_payment(scope, schema.id, attrs[:payment]) do
      {:ok, Order.from_schema(schema)}
    end
  end)
end
```

Rules of the boundary:

- **Scope flows verbatim.** Pass the same `%Scope{}` through — every context re-authorizes the
  caller as it sees fit. No scope rewriting, no escalation to a system scope at the boundary.
- **Errors bubble verbatim.** `{:error, :unauthorized}` from `Billing` flows up unchanged.
  Controllers pattern-match the same tagged atoms regardless of which context produced them; don't
  introduce a remap layer.
- **Returns may be the called aggregate.** `Billing.authorize_payment` returning `%Billing.Payment{}`
  is fine — accept the cross-context coupling rather than hiding behind opaque IDs. If Billing
  refactors its aggregate, callers update; that's a normal cost.
- **Names stay in ubiquitous language.** `Sales.place_order` keeps that name even when it
  internally calls Inventory and Billing. The cross-context calls are an implementation detail of
  the command, not part of its public identity.
- **Workers are first-class entry points.** Like commands, workers may call across contexts via
  facades. When a context needs an async cross-context entry point (e.g. Sales wants Billing to
  authorize payment asynchronously), the called context exposes a facade function that enqueues its
  own worker (`Billing.enqueue_payment_authorization(scope, ...)`). Never reach into another
  context's worker module directly.
- **Cycles are discouraged, not enforced.** Watch for them in code review. If a real cycle appears,
  treat it as a design signal — usually a shared lower context should be extracted, or the
  back-edge should become a `Phoenix.PubSub` event rather than a direct call. No compile-time
  enforcement library is mandated.

### 12. Multi-tenancy is detected from Scope

Only scaffold `organization_id` / `tenant_id` columns, the `visible_to(query, scope)` filter, and
tenant fields in `to_attrs` **if those fields exist on the project's `Scope` struct**. If the Scope
has no org/tenant, omit them entirely rather than inventing tenancy the app doesn't have. When they
do exist, every persistence query for that context filters through `visible_to/2`.

### 13. Queries return aggregates by default

A query handler returns the domain aggregate by default. Introduce a flat read model only when the
read is clearly display-only (lists, dashboards, reports, exports) or performance-sensitive — and
prefer doing so on explicit request rather than pre-emptively.

### 14. Other persistence conventions

- Use `embeds_many` for child collections, never `embeds_one` for a list.
- Money as integer cents + a `currency` string; don't mix representations.
- Atom statuses → `Ecto.Enum`, not integers.
- `has_many ..., on_replace: :delete` makes `cast_assoc` treat missing children as removed — correct
  when the aggregate owns the full collection, dangerous for partial updates. Note it when used.
- Use row locks (`lock: "FOR UPDATE"`) when loading an aggregate for update under concurrency.

## Testing

Generate the full pyramid (details and templates in `references/testing.md`):

- **Aggregate** — fast StreamData property tests, no database. Cover data properties (totals = sum of
  subtotals, subtotal = qty × unit_price) and operation-sequence properties (any sequence of public
  ops preserves invariants; invalid transitions are rejected).
- **Command/query handlers** — Repo-backed integration tests exercising scope, authorization,
  transactions, persistence, and mapping. For commands that call other contexts, the same test file
  covers cross-context paths with the real downstream contexts (no mocks) — including
  partial-failure rollback through the nested `Repo.transact`.
- **Controllers** — HTTP behavior and response shape.

StreamData must be in `mix.exs` for property tests; flag it if absent.

## Dependency direction

```
Controller / LiveView / Worker
  -> MyApp.Sales (facade)
      -> Commands.* / Queries.*
          -> Order (aggregate)        # pure, owns mapping, no Repo
          -> Repo.Sales.* (schema) -> Repo
          -> MyApp.Billing (facade)   # cross-context: only from Commands.* or Workers.*
```

The aggregate never depends on persistence behavior (only maps to/from its struct); the persistence
schema holds no business decisions; the facade never orchestrates. Cross-context calls always enter
through another context's facade, and only command handlers and workers may make them.
