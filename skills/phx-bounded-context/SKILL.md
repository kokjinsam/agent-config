---
name: phx-bounded-context
description: >
  Implements bounded contexts in Elixir/Phoenix using state machines and a layered domain
  architecture: a thin public context facade, command and query handlers, internal workflows for
  multi-step orchestration (often driven by Oban workers), Ecto schemas with Gearbox state machines
  as the domain model, and cross-context coordination via other contexts' public facades.
  Authorization lives at the boundary (controllers / LiveViews) — commands and workflows trust the
  caller to have authorized. Use this skill whenever building or changing the internals of a Phoenix
  context that has real business rules.
---

# Phoenix Bounded Context — State Machines, CQRS-Style Handlers, Workflows, Ecto Schemas

This skill implements bounded contexts on top of Phoenix and Ecto idioms with clear boundaries
without fighting the framework: a thin public facade, self-contained command/query handlers,
**internal workflows** for orchestration driven by workers or commands, and Ecto schemas that ARE
the domain model (Gearbox state machines, changesets, and intention-revealing transition functions
live on the schema itself — there's no separate in-memory aggregate alongside).

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

1. **Scaffold a new context** — generate the full tree (facade, commands, queries, workflows when
   needed, schemas with Gearbox, workers, migration, full test pyramid) from a domain description.
2. **Add an operation** — add a single command, query, or workflow (plus the schema transition
   function and tests) to an existing context, following its established conventions.
3. **Review / refactor** — audit existing code against the rules here and fix violations. See the
   "Review mode" section below for what to auto-fix vs flag.
4. **Explain / guide** — answer how-to questions and point to the right layer without necessarily
   writing code.

## Before generating: detect the project

Read the codebase first so generated code fits in, then confirm once before scaffolding:

- **App namespace** — from `mix.exs` (`:app`) and the `lib/` tree (e.g. `MyApp`, `MyApp.Repo`).
- **Scope module** — find the existing `Scope` struct (often `MyApp.Accounts.Scope`). **Inspect its
  fields** — this drives multi-tenancy (below).
- **Authorization style** — does the codebase use a `Policy` module per context, plugs, LiveView
  checks, or some mix? Mirror what's there; Policy is opt-in (see Rule 9).
- **JSON shaping** — Phoenix 1.7 JSON view modules, custom serializers, JSONAPI? Mirror the
  existing pattern; do not impose one.
- **Conventions** — look at 2–3 existing contexts/schemas and mirror their patterns (test style,
  naming, `timestamps` type, id type) even where they differ from the templates here. Consistency
  with the codebase beats matching this skill verbatim.

Show the user the detected app prefix, Scope module, Repo, and authz style for a single
confirmation, then build.

For full code templates for every module, read `references/templates.md`. For the test pyramid
(handler/workflow/controller tests), read `references/testing.md`.

## The layers and where things live

```
lib/my_app/
  sales.ex                          # Thin public facade — defdelegate only
  sales/
    commands/place_order.ex         # Write use case (user/system intent): validate, transact, persist
    queries/get_order.ex            # Read use case: validate, filter, fetch
    workflows/run_fulfillment.ex    # Internal orchestration; called by commands or workers
    workers/*.ex                    # Oban jobs; rebuild scope, call ONE workflow (or command)
    order.ex                        # Ecto schema + Gearbox + changesets + transition functions
    order_line_item.ex              # Child Ecto schema
    policy.ex                       # OPTIONAL — only when the context has non-trivial authz
```

| Layer                  | Owns                                                                                                                                                       | Never                                                                                       |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `MyApp.Sales` (facade) | Public API shape, `defdelegate`                                                                                                                            | Transactions, orchestration, business rules                                                 |
| `Commands.*`           | Input validation (embedded_schema), atomicity boundaries, business preconditions in the `with` chain, call schema transition functions, persist            | Authorization (caller does it), reaching into other contexts' internals                     |
| `Queries.*`            | Input validation, compose schema query fragments, execute via `Repo`, return schema preloaded as needed                                                    | Mutations, calling other contexts                                                           |
| `Workflows.*`          | Internal multi-step orchestration: schema transitions, `Repo` writes, queries, cross-context calls. Atomicity when needed.                                 | Public exposure (not on facade), input validation, authorization (caller does both)         |
| `Order` (Ecto schema)  | `schema "..."`, Gearbox state machine, changesets, transition functions that return changesets, `build!/1` for in-memory structs, query fragments          | Calling `Repo`, calling other contexts, cross-context `belongs_to`                          |
| `Workers.*`            | Rebuild `%Scope{}` from serialized job args; call one workflow (preferred) or command; queue/retry/operational metadata                                    | Business logic, bypassing facade for cross-context, duplicating domain rules                |
| `Sales.Policy` (opt-in)| Authorization decisions, called from controllers/LiveViews (or workers when truly needed)                                                                  | Persistence, domain logic, being called from inside handlers (commands/workflows/queries)   |

## Core rules

### 1. Scope is the first argument

Every public function whose result or side effect depends on actor, workspace, organization,
tenant, permissions, visibility, audit attribution, or tenant scoping takes `%Scope{}` first and
an attrs map second. The scope represents the caller/execution boundary, not just the current user.
For genuinely system-level work, pass an explicit system scope rather than bypassing the pattern —
and never add a blanket "system can do everything" shortcut unless an ADR explicitly defines it.

```elixir
Sales.place_order(scope, attrs)   # not Sales.place_order(attrs, user)
Sales.get_order(scope, attrs)     # not Sales.get_order(id) — pass %{id: id}
```

Both scoped commands and queries take `(scope, attrs)`. Even single-id reads pass a map
(`Sales.get_order(scope, %{id: id})`) so every handler validates input and adding a field later
(filters, preloads, options) never changes the call shape. Pre-scope Auth operations that establish
identity before a trusted scope exists may omit `%Scope{}` but still use handler functions named
`handle` and should prefer attrs maps for external input.

Public handler attrs carry IDs and options by default, not caller-loaded Ecto structs. The handler
loads referenced records only when the operation needs the record for visibility, preconditions,
locking, derived data, or return shape; IDs that are just durable references may stay IDs.

### 2. The facade is thin

The public context module delegates and nothing more. A boring facade is a feature — it's the stable
surface controllers, LiveViews, workers, and use cases depend on. Workflows are NOT exposed on the
facade; they're internal.

```elixir
defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
defdelegate get_order(scope, attrs), to: GetOrder, as: :handle
```

### 3. Name public commands in ubiquitous language

Public **command** functions use the domain's verbs, not CRUD: `place_order`, `cancel_order`,
`ship_shipment` — never `create_order`/`update_order`/`delete_order`. Before naming, **ask the user
for the context's glossary / ubiquitous language** if it isn't already clear from the conversation
or codebase; the names are the API and should match how the business talks. **Queries may stay
`get_`/`list_`/`find_`** — reads are less domain-charged and the conventional names read clearly.

**Refuse generic names during scaffold.** If the user asks to scaffold a command/schema/workflow
named `run`, `process`, `record`, `item`, or similar, pause and ask for the domain-specific name
with examples from the ubiquitous language (`intake_run` over `run`, `evidence_item` over `item`).

**Keep the domain noun on operation modules.** `Sales.Commands.PlaceOrder`, not
`Sales.Commands.Place`; `Reviews.Workflows.RunIntake`, not `Reviews.Workflows.Run`. These names
appear in stack traces, telemetry, and logs where the parent namespace is lost. The "drop redundant
prefix" rule (see the "Naming: redundant prefixes" section below) applies to leaf schemas and enums only.

### 4. Handlers are self-contained (and authorization-trusted)

A command or query handler owns one use case end to end for one context: input validation, any
required transaction boundary, **business preconditions in the `with` chain**, calling schema
transition functions (or a workflow when orchestration is needed), persisting through `Repo`, and
returning a result.

Handlers **trust the caller to have authorized** (see Rule 9). They do not call `Policy.authorize`
themselves. They also do not load Scope-derived authz state; they assume the scope passed in is
allowed to execute this operation.

For complex or external/string-keyed input, handlers own an **input schema** as an
`embedded_schema` defined in the handler module itself; for tiny `%{id: id}`-style inputs, an
explicit private validation helper is fine. If a handler seems to need several unrelated input
schemas, split it into multiple handlers before nesting input modules.

Business rules live here. Schema-level transition functions (e.g. `Order.place/1`) handle the
state-machine transition and structural changeset; the handler is responsible for checking
cross-field preconditions like "must have at least one line item" or "payment must be authorized"
before calling the transition. This keeps the schema functions reusable and keeps use-case rules
visible at the handler level.

### 5. One schema per entity; `build!/1` is for in-memory structs only

Don't create a parallel in-memory representation of a persisted schema. There is no separate
"aggregate" `embedded_schema` that mirrors the Ecto schema — the Ecto schema **is** the domain
model. It owns the state machine, the changesets, the transition functions, and the query
fragments.

Two construction patterns coexist by role:

- **`Schema.changeset(struct, attrs)`** — for persisted entities. The handler casts external/
  trusted attrs through the changeset and lets `Repo.insert`/`Repo.update` execute it.
  Normalization (downcasing, trimming, defaults via `put_change`) for persisted fields lives in
  the changeset.

- **`Schema.build!(attrs)`** — for **non-persisted** in-memory structs (event payloads, value
  objects, internal attrs-shaped structs that get passed between modules). Uses `Map.fetch!` for
  required keys and raises on missing ones, because the caller's contract guarantees them. Don't
  use `build!/1` to skip the changeset for things that will be persisted.

```elixir
def build!(attrs) do
  %__MODULE__{
    workspace_id: Map.fetch!(attrs, :workspace_id),
    review_id: Map.fetch!(attrs, :review_id)
  }
end
```

Splitting in-memory and persistence schemas grows mapping code and lets the two drift; one schema
per entity keeps the model honest.

### 6. Schemas own domain behavior

The Ecto schema is where the domain lives. It owns:

- The `schema "..."` definition (fields, associations, timestamps).
- The Gearbox state machine.
- Changesets (structural validation, normalization, defaults, formatting).
- Transition functions that return changesets, e.g.:

  ```elixir
  def place(order) do
    order
    |> change(placed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Gearbox.transition(:placed)
  end
  ```

- `build!/1` for in-memory variants (Rule 5).
- Query fragments (`by_id/2`, `for_customer/2`, `visible_to/2`, `preload_line_items/1`,
  `lock_for_update/1`) — returning `Ecto.Query`, not executing.

The schema does **not** call `Repo`; the handler or workflow does. Construct persisted entities
with `Order.changeset(%Order{}, attrs)` directly — no `new/1` wrapper, no separate aggregate struct.

Children are `has_many` associations (separate schemas). Child mutations route through the parent
schema via functions like `Order.add_line_item(order, attrs)` that build a changeset with
`cast_assoc`. The parent owns the consistency boundary for its children's lifecycle decisions even
though Ecto stores them in their own table.

### 7. State machines use Gearbox when there's a status field

If an entity has a `status` field with multiple values, **use Gearbox**. A status field without an
FSM is a code smell — transitions become scattered guards. Wire it directly on the schema:

```elixir
use Gearbox,
  field: :status,
  states: [:draft, :placed, :cancelled],
  initial: :draft,
  transitions: %{draft: [:placed, :cancelled], placed: [:cancelled]}
```

Gearbox guards the **legal transition graph** — `draft -> placed` allowed, `cancelled -> placed`
rejected. Transition functions on the schema are thin: apply the Gearbox transition and any
structural side effects (setting `placed_at`, etc.) and return a changeset.

**Inverse:** don't *invent* a status field just to use Gearbox. If the entity doesn't naturally
have a lifecycle, plain functions and explicit field checks are clearer. FSM machinery should
clarify allowed transitions, not be ceremony.

**Cross-field business preconditions** — "must have at least one line item to place", "must have
an authorized payment to ship" — live in the **handler's `with` chain**, not in the transition
function or changeset:

```elixir
with {:ok, command} <- validate(attrs),
     {:ok, order}   <- load_order(scope, command.order_id),
     :ok            <- ensure_has_line_items(order),       # ← business precondition
     {:ok, placed}  <- Repo.update(Order.place(order)) do
  {:ok, placed}
end
```

### 8. `embedded_schema` is for handler input only

`embedded_schema` is the right tool for complex or external/string-keyed handler input. Use it on
every command unless the input is a tiny already-normalized shape (a single `%{id: id}` validated
inline is fine). It is **not** for parallel in-memory representations of persistence schemas — that
re-introduces the duplication Rule 5 forbids. Internal in-memory structs use `build!/1` (Rule 5).

### 9. Authorization lives at the boundary; `Policy` is opt-in

Authorization happens at the **calling boundary**, not inside handlers:

- **Controllers / LiveViews** authorize before dispatching to a command or query (a plug, a
  pipeline check, or an explicit call in the action/event handler).
- **Workers** authorize when they're entry points that don't come from an already-authorized
  context (rare — usually the work was authorized at enqueue time).

Commands, workflows, and queries **trust the caller has already authorized**. They do not call
`Policy.authorize`. This keeps domain handlers focused on domain logic and avoids the surprise of
the same authz decision running twice (once at the controller, once at the handler) with subtly
different inputs.

The `MyApp.Sales.Policy` module is **opt-in**, not scaffolded by default. Many contexts won't have
one — a plug or a controller-level check is enough. Add a Policy module when the context has
non-trivial authz (action-specific permission checks, resource-level rules) that the boundary needs
a domain-shaped place to call.

When you do generate a Policy:

```elixir
@spec authorize(Scope.t(), atom(), map()) :: :ok | {:error, :unauthorized}
def authorize(%Scope{} = scope, :place_order, _params) do
  if :place_order in scope.permissions, do: :ok, else: {:error, :unauthorized}
end
```

Policy lives in the context but is called *from* the boundary. Scoped queries still enforce
ordinary visibility through `visible_to/2` query construction — that's not authorization, that's
data scoping.

### 10. Errors: fail-fast for invariants, tagged tuples for recoverable

Fail-fast when the contract already guarantees the happy path; return tagged tuples only when the
caller is genuinely expected to branch.

- **Raise (invariant violation)** — missing required attrs after validation, lookups whose
  existence is assumed, programmer-bug states. Use bang functions: `Repo.get!`, `Map.fetch!`,
  internal `Sales.get_order!/2`, schema `build!/1`.
- **Return `{:error, atom}` (recoverable)** — `:unauthorized`, `:not_found` for a user-supplied
  id, `:invalid_transition`, `:insufficient_funds`, `:empty_order`. Domain decisions the caller
  must branch on.
- **Return `{:error, %Ecto.Changeset{}}`** — input/persistence validation failures.

Rules:

- Do **not** wrap bang results in `{:ok, value}` — they raise on failure and return the value on
  success.
- Do **not** manually throw `:not_found` tuples when a bang lookup is clearer.
- Bang functions are **internal** (used in handlers/workflows/schemas). The public **facade always
  returns tagged results** so HTTP/LiveView callers can pattern-match without `try`/`rescue`.
- Avoid broad `rescue _`/`catch` blocks around domain calls unless there's a documented recovery
  path.

The goal is not to ignore errors; it's to avoid defensive noise where invariants already define
valid input.

### 11. Use `Repo.transact` when atomicity is needed

Use `Repo.transact/1` when the operation has a real atomicity boundary: multiple dependent writes,
a domain write plus job/audit/projection enqueue, locks and state transitions that must be
consistent. A single independent insert/update doesn't need a transaction by convention alone.

Ownership is **per-need at each layer** — there is no global "outermost wraps everything" rule.
Each command/workflow decides for itself whether its own operations need atomicity. Nested
`Repo.transact` calls work via savepoints and are fine when each layer has its own atomic concern.

```elixir
def handle(%Scope{} = scope, attrs) do
  Repo.transact(fn ->
    with {:ok, command} <- validate(attrs),
         {:ok, order}   <- build_order(scope, command),
         :ok            <- ensure_has_line_items(order),
         {:ok, placed}  <- Repo.insert(Order.place(order)) do
      {:ok, placed}
    end
  end)
end
```

### 12. Cross-context calls — eligibility and rules

| Layer        | Can call other-context facades? |
| ------------ | -------------------------------- |
| Commands     | **Yes**                          |
| Workflows    | **Yes**                          |
| Workers      | Typically no — delegate to a workflow that does |
| Queries      | **No** — composition lives at controller/LiveView OR in a read workflow |
| Schemas      | **No** (hard restriction)        |
| Policies     | **No** (hard restriction)        |

Always call the other context's **public facade**, never its `Commands.*`, `Queries.*`,
`Workflows.*`, or `Workers.*` modules. The same applies inside a single context: sibling commands
call each other via `Sales.apply_discount/2`, not `Sales.Commands.ApplyDiscount`.

Rules of the boundary:

- **Scope flows verbatim.** Pass the same `%Scope{}` through. Authorization happened at the
  boundary, but downstream contexts may still use scope for `visible_to/2`, audit attribution, or
  derived data.
- **Errors bubble verbatim.** `{:error, :unauthorized}` from a downstream context flows up
  unchanged. Controllers pattern-match the same tagged atoms regardless of which context produced
  them; don't introduce a remap layer.
- **Returns may be the called schema.** `Billing.authorize_payment` returning `%Billing.Payment{}`
  is fine — accept the cross-context coupling rather than hiding behind opaque IDs.
- **Names stay in ubiquitous language.** `Sales.place_order` keeps that name even when it
  internally calls Inventory and Billing.
- **Workers are entry points, not bridges.** When a context needs an async cross-context trigger,
  the called context exposes a facade function that enqueues its own worker
  (`Billing.enqueue_payment_authorization(scope, ...)`). Never reach into another context's worker
  module directly.
- **Cycles are discouraged.** If a real cycle appears, treat it as a design signal — extract a
  shared lower context, or replace the back-edge with a `Phoenix.PubSub` event.

### 13. Workflows: internal multi-step orchestration

Workflows are an **internal** layer (not on the facade) for multi-step domain processes that:

- An **Oban worker** needs to drive (the common case — workers stay thin and delegate to a
  workflow that owns the multi-step work);
- A command needs to delegate to for non-trivial orchestration;
- A read needs to compose across contexts (a "read workflow").

**Location:** `lib/my_app/sales/workflows/*.ex`, parallel to `commands/` and `queries/`.

**Who calls a workflow:** commands and workers. Not the facade directly.

**What a workflow can call:**
- Own schemas + `Repo` (it can mutate state directly — workflows are not just orchestrators of
  commands).
- Own queries.
- Other context facades (cross-context coordination).
- (For now, not other workflows. That can come later if the pattern emerges.)

**Trust model:** workflows assume the caller (command or worker) has already validated AND
authorized. They take a **validated attrs map** (atom keys, required fields present) and use
`Map.fetch!` to access keys. No `embedded_schema`, no `Policy.authorize`.

**Atomicity:** a workflow owns its own outer `Repo.transact` when its orchestrated steps must be
atomic. Inner commands may have their own transactions — savepoints handle the nesting.

**When to extract a workflow (vs. inline in a command):** when the logic is not a public domain
action but is internally needed — most commonly, when an Oban worker has to drive a multi-step
process. If exactly one command would inline the same 3+ steps and no worker is involved, leaving
it in the command is fine.

### 14. Multi-tenancy is detected from Scope

Only scaffold `organization_id` / `tenant_id` columns, the `visible_to(query, scope)` filter, and
tenant fields on the schema **if those fields exist on the project's `Scope` struct**. If the Scope
has no org/tenant, omit them entirely rather than inventing tenancy the app doesn't have. When they
do exist, every persistence query for that context filters through `visible_to/2`.

### 15. Queries return schemas by default, preloaded as needed

A query handler returns the Ecto schema struct by default. Callers declare what they need preloaded
per call (a `preload` option on the handler, or a query-level preload fragment composed in). Don't
deep-preload everything by default — that pulls expensive data nobody asked for. Introduce a flat
read model only when the read is clearly display-only (lists, dashboards, reports, exports) or
performance-sensitive — and prefer doing so on explicit request rather than pre-emptively.

Queries do **not** call other context facades. Cross-context read composition lives at the
controller/LiveView level (call both `Sales.get_order` and `Billing.get_invoice` and assemble),
OR in a **read workflow** when the composition repeats or is intrinsic.

### 16. Return shapes — virtual fields over anonymous maps

Public APIs should return domain-shaped values:

- Return persisted schemas, domain structs, or explicit result structs.
- **Strongly prefer virtual fields on the schema** when a command result naturally extends the
  domain object (a presigned URL on an upload, a signed token on a session).
- Anonymous maps from public command APIs are a **violation** — flag during review.

```elixir
# Prefer:
{:ok, %FileUpload{presigned_url: url, presigned_headers: headers}}

# Over:
{:ok, %{file_upload_id: id, presigned_url: url, presigned_headers: headers}}
```

JSON shaping for API responses belongs in JSON view modules or serializers, not in command return
values and not directly in controllers.

### 17. Workers stay thin

Workers are operational entry points. Each worker:

- Carries scope in job args as a **serialized map** representation.
- **Reconstitutes `%Scope{}`** via `Accounts.build_scope/1` (or your project's equivalent) at the
  top of `perform/1`.
- Optionally calls `Policy.authorize` — only when the work wasn't authorized at enqueue time and
  this is the first untrusted entry point.
- **Calls one workflow (preferred) or one command** through the facade. Multi-step domain work is
  the workflow's job, not the worker's.
- Keeps retry behavior, queue concerns, and operational metadata in the worker.

If a worker starts accumulating domain branching, move that behavior into a workflow.

### 18. Cross-context Ecto associations are forbidden

Do **not** declare `belongs_to :user, Accounts.User` on a schema in a different context. Cross-
context association is a hidden coupling that drags one context's schema module into another's
loading path and undermines facade-only access.

Instead:

```elixir
# In Reviews.Review:
field :authored_by_id, :binary_id   # bare FK column, no belongs_to to Accounts.User
```

Loading the referenced record goes through the other context's facade at the handler/workflow
level (`Accounts.get_user(scope, %{id: review.authored_by_id})`). Within a single context,
ordinary `belongs_to` between sibling schemas is fine.

### 19. Migrations follow the owning context

- Put new tables in a migration that matches the **owning feature or context**.
- Don't mix unrelated context changes in the same migration (no Reviews tables and
  EvidenceIntake tables together).
- **Greenfield contexts** still in active build-out: it's acceptable to fold related migrations
  together when the user requests it.
- **Mature contexts**: each schema change gets its own dated migration.
- Use the project's generator convention (e.g. `mix ecto.gen.migration`) where it exists.

### 20. Other persistence conventions

- Money as integer cents + a `currency` string; don't mix representations.
- Atom statuses → `Ecto.Enum`, not integers.
- `has_many ..., on_replace: :delete` makes `cast_assoc` treat missing children as removed —
  correct when the parent owns the full collection, dangerous for partial updates. Note when used.
- Use row locks (`lock: "FOR UPDATE"`) when loading a parent for update under concurrency.

## Naming: redundant prefixes

Inside a leaf schema or enum where the parent module already disambiguates, drop redundant
prefixes:

```elixir
# Inside MyApp.Sales.FileUpload — prefer:
defmodule Kind do
  use Ecto.Type
  # ...
end

# Over MyApp.Sales.FileUpload.UploadKind — the "Upload" prefix is redundant.
```

This applies to **schemas and enums only**. Commands, queries, workflows, and workers should keep
the domain noun in their module name (`PlaceOrder`, `RunIntake`, `SendOrderConfirmation`) because
those names appear in stack traces, telemetry, and logs where the parent namespace is lost.

## Controllers and JSON

Controllers should be thin:

- Validate / shape the request at the boundary.
- Run authorization (Rule 9).
- Call the bounded-context public API with `(scope, attrs)`.
- Delegate response shaping to a JSON view module or serializer.

**Detect and match** the codebase's existing JSON shaping pattern (Phoenix 1.7 JSON view modules,
custom serializer modules, JSONAPI library). Don't impose one style.

## Testing

Generate the pyramid (details and templates in `references/testing.md`):

- **Handler tests (commands/queries)** — Repo-backed integration tests exercising input validation
  failures, the happy path, state transitions, persistence, and cross-context happy/rollback paths
  (with real downstream contexts, no mocks). **Do not test authorization here** — that moved to the
  boundary (Rule 9).
- **Workflow tests** — Repo-backed tests for the orchestrated steps, partial-failure rollback, and
  any cross-context coordination. Workflows also get covered transitively through the
  commands/workers that invoke them; per-workflow tests focus on the orchestration concerns.
- **Controller / LiveView tests** — HTTP behavior, response shape, **and the authorization path**
  (which scopes are allowed/denied, what plugs reject, what status codes come back).

StreamData is only needed if you choose to do property-style handler tests; flag it if absent and
you're adding such tests.

## Review mode: what to auto-fix vs flag

**Auto-fix (hard violations):**

- `Repo.*` calls inside a schema module → move the call to the handler/workflow that owns
  persistence; have the schema return a changeset or query instead.
- Cross-context `belongs_to` (`belongs_to :user, Accounts.User` in a foreign context's schema) →
  rewrite as a bare FK column (`field :user_id, :binary_id`) and update loading sites to go through
  the owning context's facade.

**Flag, don't silently rewrite (judgment calls):**

- Anonymous map returns from public command APIs → suggest a schema + virtual field or an explicit
  result struct; let the user pick.
- Broad `rescue _` / `catch` around domain calls → request a documented recovery path; don't strip
  the block on assumption.
- `Policy.authorize` called inside a handler → suggest moving authz to the boundary, but explain
  the trade-off (some teams still want defense-in-depth).
- Status field without Gearbox → suggest adding the state machine; show the transitions you'd
  declare.

## Dependency direction

```
Controller / LiveView -> Policy.authorize (at boundary, opt-in)
  -> MyApp.Sales (facade)
      -> Commands.*  (user/system intent)
      -> Queries.*   (reads)

Worker -> rebuild Scope -> Policy (only if needed) -> Workflows.* (preferred) or Commands.*

Commands.* / Workflows.*
  -> Schema -> Repo
  -> Other context facade   (cross-context allowed)

Queries.*
  -> Schema -> Repo only    (no cross-context calls)
```

The schema holds the domain (Gearbox + changesets + transition functions + `build!/1`) but never
calls `Repo`. Handlers and workflows are the layers that call `Repo`. The facade orchestrates
nothing. Cross-context calls always enter through another context's facade, and only commands and
workflows make them. Authorization sits at the entry boundary, not inside the domain.
