---
name: phx-bounded-context
description: >
  Implements bounded contexts in Elixir/Phoenix using state machines and a CQRS-style
  facade + handler + schema architecture: a thin public context facade that delegates to
  command and query handlers, handlers that own input validation and orchestration inside
  `Repo.transact`, Ecto schemas with Gearbox state machines as the domain model, and
  cross-context workflows expressed as direct command-to-command (or worker-to-command)
  calls through the other context's public facade. Use this skill whenever building or
  changing the internals of a Phoenix context that has real business rules.
---

# Phoenix Bounded Context — State Machines, CQRS-Style Handlers, Ecto Schemas

This skill implements bounded contexts on top of Phoenix and Ecto idioms with clear boundaries
without fighting the framework: a thin public facade, self-contained command/query handlers, and
Ecto schemas that ARE the domain model (Gearbox state machines, changesets, and intention-revealing
transition functions live on the schema itself — there's no separate in-memory aggregate alongside).

## When this architecture is worth it

This structure earns its overhead only when the domain has **meaningful business behavior**: real
invariants, state-machine lifecycles, money/totals, tenant or permission boundaries, or multi-step
business rules that must stay consistent. Decide heuristically per context:

- **Rich domain** (invariants, a state machine, multi-tenancy, things that must stay consistent) →
  apply the full structure below.
- **Simple CRUD** (admin panel, basic record management, reporting) → say so plainly and recommend a
  lighter vanilla Phoenix context with plain Ecto schemas. Don't force these patterns where they
  don't pay for themselves; flag the recommendation rather than silently scaffolding everything.

When in doubt, name the trade-off for the user and let them choose.

## What this skill does

Four modes — infer which from the request:

1. **Scaffold a new context** — generate the full tree (facade, commands, queries, schemas with
   Gearbox, policy, workers, migration, full test pyramid) from a domain description.
2. **Add an operation** — add a single command or query (plus the schema transition function and
   tests) to an existing context, following its established conventions.
3. **Review / refactor** — audit existing code against the rules here and fix violations: `Repo` in
   a schema module, a fat facade doing orchestration, cross-context calls inside a schema / policy /
   query (instead of a command or worker), cross-context calls bypassing the facade, child mutation
   bypassing parent functions, CRUD names where domain verbs belong, **a parallel in-memory
   "aggregate" module duplicating the Ecto schema**.
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
(handler/controller tests), read `references/testing.md`.

## The layers and where things live

```
lib/my_app/
  sales.ex                          # Thin public facade — defdelegate only
  sales/
    policy.ex                       # Authorization for the context
    commands/place_order.ex         # Write use case: authorize, validate, transact, persist
    queries/get_order.ex            # Read use case: validate, authorize/filter, fetch
    workers/*.ex                    # Oban jobs; call the public API
    order.ex                        # Ecto schema + Gearbox + changesets + transition functions
    order_line_item.ex              # Child Ecto schema
```

| Layer                  | Owns                                                                                                                                                                                                            | Never                                             |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `MyApp.Sales` (facade) | Public API shape, `defdelegate`                                                                                                                                                                                 | Transactions, orchestration, business rules       |
| `Commands.*`           | Authorize, validate input (own `embedded_schema`), `Repo.transact`, business preconditions in the `with` chain, call schema transition functions, persist, call other contexts via their facade                 | Reach into other context internals                |
| `Queries.*`            | Validate input, authorize/filter, compose schema query fragments, execute via `Repo`, return schema preloaded as needed                                                                                         | Mutations, calling other contexts                 |
| `Order` (Ecto schema)  | `schema "..."`, Gearbox state machine, changesets, transition functions that return changesets, query fragments                                                                                                 | Calling `Repo`, calling other contexts            |
| `Sales.Policy`         | Authorization decisions                                                                                                                                                                                         | Persistence, domain logic, calling other contexts |
| `Workers.*`            | Async entry points; may call own and other contexts via facades                                                                                                                                                 | Bypassing the facade                              |

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
policy), input validation, transaction boundary, **business preconditions in the `with` chain**,
calling schema transition functions, persisting through `Repo`, and returning a result. Handlers
own their **input schema** as an `embedded_schema` defined in the handler module itself — this
validates external/string-keyed params and expresses intent, separate from persistence validation.
If a handler seems to need several unrelated input schemas, split it into multiple handlers before
nesting input modules.

This is where business rules live. Schema-level transition functions (e.g. `Order.place/1`) handle
the state-machine transition and structural changeset; the handler is responsible for checking
cross-field preconditions like "must have at least one line item" or "payment must be authorized"
before calling the transition. This keeps the schema functions reusable and keeps use-case rules
visible at the handler level.

### 5. One schema per entity

Don't create a parallel in-memory representation of the schema. There is no separate "aggregate"
`embedded_schema` that mirrors the Ecto schema — the Ecto schema **is** the domain model. It owns
the state machine, the changesets, the transition functions, and the query fragments. Splitting
the in-memory model from the persistence schema makes mapping code grow, lets the two drift apart,
and confuses coding agents about which one to update. One schema per entity keeps the model honest
and the code small.

### 6. Schemas own domain behavior

The Ecto schema is where the domain lives. It owns:

- The `schema "..."` definition (fields, associations, timestamps).
- The Gearbox state machine.
- Changesets (structural validation, defaults, formatting).
- Transition functions that return changesets, e.g.:

  ```elixir
  def place(order) do
    order
    |> change(placed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Gearbox.transition(:placed)
  end
  ```

- Query fragments (`by_id/2`, `for_customer/2`, `visible_to/2`, `preload_line_items/1`,
  `lock_for_update/1`) — returning `Ecto.Query`, not executing.

The schema does **not** call `Repo`; the handler does. Construct with
`Order.changeset(%Order{}, attrs)` directly — no `new/1` wrapper, no separate aggregate struct.

Children are `has_many` associations (separate schemas). Child mutations route through the parent
schema via functions like `Order.add_line_item(order, attrs)` that build a changeset with
`cast_assoc`. The parent owns the consistency boundary for its children's lifecycle decisions even
though Ecto stores them in their own table.

### 7. State machines use Gearbox

Wire the state machine with `Gearbox` (`use Gearbox, field: :status, states: [...], transitions:
%{...}`) directly on the Ecto schema. Gearbox guards the **legal transition graph** — `draft ->
placed` allowed, `cancelled -> placed` rejected. Transition functions on the schema are thin: they
apply the Gearbox transition and any structural side effects (setting `placed_at`, etc.) and return
a changeset.

**Cross-field business preconditions** — "must have at least one line item to place", "must have
an authorized payment to ship" — live in the **handler's `with` chain**, not in the transition
function or changeset:

```elixir
with :ok            <- Policy.authorize(scope, :place_order),
     {:ok, command} <- validate(attrs),
     {:ok, order}   <- load_order(scope, command.order_id),
     :ok            <- ensure_has_line_items(order),       # ← business precondition
     {:ok, placed}  <- Repo.update(Order.place(order)) do
  {:ok, placed}
end
```

### 8. `embedded_schema` is for handler input only

`embedded_schema` is the right tool for one job: validating external/string-keyed input on a
handler. It is **not** for parallel in-memory representations of persistence schemas — that
re-introduces the duplication Rule 5 forbids.

### 9. Authorization lives in a policy module by default

Generate a `MyApp.Sales.Policy` with `authorize(scope, action, params \\ %{})` returning `:ok` /
`{:error, :unauthorized}`; handlers call it. Keep authz out of the schema and the facade. When a
single operation's authorization grows genuinely complex, it's fine to drop a private `authorize/2`
into that handler — but the policy module is the default home.

### 10. Errors: tagged atoms + changesets

Domain errors are tagged atoms (`{:error, :unauthorized}`, `{:error, :not_found}`,
`{:error, :empty_order}`); input/persistence validation failures are `{:error, %Ecto.Changeset{}}`.
Controllers pattern-match these to status codes. Keep this convention consistent across every layer.

### 11. Transactions use `Repo.transact`

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
    with :ok            <- Policy.authorize(scope, :place_order),
         {:ok, command} <- validate(attrs),
         {:ok, order}   <- build_order(scope, command),
         :ok            <- ensure_has_line_items(order),
         {:ok, placed}  <- Repo.insert(Order.place(order)) do
      {:ok, placed}
    end
  end)
end
```

### 12. Cross-context calls go through the public facade

Command handlers and Oban workers may call other contexts directly — through the other context's
public facade, never into its `Commands.*` or `Workers.*` modules. The same applies inside a single
context: sibling commands call each other via `Sales.apply_discount/2`, not
`Sales.Commands.ApplyDiscount`. The facade is the only stable surface; everything else is internal.

**Schemas, policies, and queries do not call other contexts** — that's a hard restriction.
Cross-context orchestration lives in commands and workers, where transactions, authorization, and
input validation already live. A query that needs data from a sister context is composed at the
controller / LiveView level (call both `Sales.get_order` and `Billing.get_invoice` and assemble the
view); promote that to a dedicated read-model context only when the composition repeats or becomes
performance-sensitive.

```elixir
# Inside Sales.Commands.PlaceOrder:
def handle(%Scope{} = scope, attrs) do
  Repo.transact(fn ->
    with :ok            <- Policy.authorize(scope, :place_order),
         {:ok, command} <- validate(attrs),
         {:ok, order}   <- build_order(scope, command),
         :ok            <- ensure_has_line_items(order),
         {:ok, placed}  <- Repo.insert(Order.place(order)),
         {:ok, _resv}   <- Inventory.reserve_stock(scope, placed.id),
         {:ok, _pay}    <- Billing.authorize_payment(scope, placed.id, command.payment) do
      {:ok, placed}
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
- **Returns may be the called schema.** `Billing.authorize_payment` returning `%Billing.Payment{}`
  is fine — accept the cross-context coupling rather than hiding behind opaque IDs. If Billing
  refactors its schema, callers update; that's a normal cost.
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

### 13. Multi-tenancy is detected from Scope

Only scaffold `organization_id` / `tenant_id` columns, the `visible_to(query, scope)` filter, and
tenant fields on the schema **if those fields exist on the project's `Scope` struct**. If the Scope
has no org/tenant, omit them entirely rather than inventing tenancy the app doesn't have. When they
do exist, every persistence query for that context filters through `visible_to/2`.

### 14. Queries return schemas by default, preloaded as needed

A query handler returns the Ecto schema struct by default. Callers declare what they need preloaded
per call (a `preload` option on the handler, or a query-level preload fragment composed in). Don't
deep-preload everything by default — that pulls expensive data nobody asked for. Introduce a flat
read model only when the read is clearly display-only (lists, dashboards, reports, exports) or
performance-sensitive — and prefer doing so on explicit request rather than pre-emptively.

### 15. Other persistence conventions

- Money as integer cents + a `currency` string; don't mix representations.
- Atom statuses → `Ecto.Enum`, not integers.
- `has_many ..., on_replace: :delete` makes `cast_assoc` treat missing children as removed —
  correct when the parent owns the full collection, dangerous for partial updates. Note it when
  used.
- Use row locks (`lock: "FOR UPDATE"`) when loading a parent for update under concurrency.

## Testing

Generate the pyramid (details and templates in `references/testing.md`):

- **Handler tests** — Repo-backed integration tests exercising scope, authorization (allowed and
  denied), input validation failures, the happy path, state transitions, and persistence. For
  commands that call other contexts, the same test file covers cross-context paths with the real
  downstream contexts (no mocks) — including partial-failure rollback through the nested
  `Repo.transact`. Property-style tests (operation sequences preserve invariants) MAY be added
  here when the domain is rich enough to justify the setup cost, but they're not the default tier.
- **Controller tests** — HTTP behavior and response shape.

StreamData is only needed if you choose to do property-style handler tests; flag it if absent and
you're adding such tests.

## Dependency direction

```
Controller / LiveView / Worker
  -> MyApp.Sales (facade)
      -> Commands.* / Queries.*
          -> Order (Ecto schema) -> Repo   # schema is the model; handler calls Repo
          -> MyApp.Billing (facade)         # cross-context: only from Commands.* or Workers.*
```

The schema holds the domain (Gearbox + changesets + transition functions) but never calls `Repo`;
the handler is the only layer that calls `Repo`; the facade orchestrates nothing. Cross-context
calls always enter through another context's facade, and only command handlers and workers may
make them.
