---
name: phx-bounded-context
description: >
  Scaffold, change, or review rich Elixir/Phoenix bounded contexts from TLA+ specs first,
  with thin public facades, deliberately public command/query handlers, noun-named internal
  orchestration modules, Ecto schemas as Gearbox state-machine domain models, Flop-backed
  collection queries, boundary authorization outside the context, facade-only cross-context calls,
  and Repo-backed tests.
---

# Phoenix Bounded Context — Spec-First, Thin Facades, Ecto Domain Models

This skill implements Phoenix/Ecto bounded contexts without fighting the framework. Use TLA+
specs as the source of truth when they exist, architecture docs as explainers, and the codebase's
existing conventions as local style guidance. The bounded context contains the domain model and
domain API; HTTP/LiveView authorization is lifted above it.

The shape is intentionally conservative:

- a thin public context facade;
- public command/query handlers only when the operation is a necessary and important boundary API;
- internal orchestration modules named with precise domain nouns, not a `Workflows.*` convention;
- Ecto schemas as the domain model, including Gearbox state machines, changesets, transition
  functions, `build!/1`, and query fragments;
- collection reads, filtering, ordering, and pagination through Repo-level Flop helpers.

## Source-of-Truth Order

Before generating, changing, or reviewing bounded-context code:

1. Read relevant `docs/specs/*.tla` files first, if present. Treat them as the source of truth for
   entities, states, transitions, invariants, commands, allowed reads, and ownership boundaries.
2. Read architecture docs, ADRs, and `CONTEXT.md` as explainers. Use them to translate terminology,
   discover rationale, and identify drift, but do not let stale prose override the spec.
3. Inspect the current codebase for style: app namespace, Repo module, Scope struct, id type,
   timestamp type, JSON shaping, worker conventions, tests, and existing context layout.
4. Ask the user only for decisions the specs/docs/code do not settle. Do not ask obvious questions
   that the TLA+ model already answers.

When specs and architecture docs disagree, say that plainly and anchor the implementation or review
on the TLA+ model unless the user explicitly directs otherwise.

## When This Architecture Is Worth It

This structure earns its overhead only when the domain has meaningful behavior: real invariants,
state-machine lifecycles, money/totals, tenant boundaries, cross-context coordination, or
multi-step business rules that must stay consistent.

- **Rich domain**: apply the full structure below.
- **Simple CRUD**: recommend a lighter vanilla Phoenix context with plain Ecto schemas. Do not
  force commands, query handlers, orchestration modules, or Gearbox where they do not pay for
  themselves.

When in doubt, name the trade-off and let the user choose.

## What This Skill Does

Infer the mode from the request:

1. **Scaffold a new context**: generate the facade, necessary public command/query handlers,
   internal noun-named orchestration modules when needed, schemas, workers, migrations, and tests.
2. **Add an operation**: add one public command/query or one internal orchestration module, plus
   schema functions and tests.
3. **Review / refactor**: audit existing code against these rules and fix hard violations.
4. **Explain / guide**: answer how-to questions and point to the right layer.

For full code templates, read `references/templates.md`. For the test pyramid, read
`references/testing.md`.

## Before Generating: Detect The Project

Read the codebase first so generated code fits in:

- **App namespace** from `mix.exs` and `lib/` (for example `MyApp`, `MyApp.Repo`).
- **Scope module** and fields, often `MyApp.Accounts.Scope`. Scope fields drive tenancy and audit
  attribution.
- **Authorization style at the boundary**: plugs, controller helpers, LiveView hooks, or web-layer
  policy modules. Authorization is not part of the bounded context.
- **Repo conventions**, including whether helper functions such as `Repo.transact/1` already exist
  and whether Flop is installed.
- **JSON shaping**: Phoenix 1.7 JSON modules, custom serializers, JSONAPI, etc.
- **Conventions** from 2-3 existing contexts/schemas: test style, naming, id type, timestamp type,
  migrations, worker serialization.

Show the user the detected app prefix, Scope module, Repo, boundary authorization style, and
relevant source-of-truth files for confirmation before scaffolding substantial new code.

## The Layers And Where Things Live

```
lib/my_app/
  sales.ex                         # Thin public facade — defdelegate only
  sales/
    commands/place_order.ex        # Public write API, only when truly needed
    queries/get_order.ex           # Public read API, only when truly needed
    queries/list_orders.ex         # Public collection read, Flop-backed
    orders.ex                      # Internal orchestration around Order
    order_verification.ex          # Internal orchestration when plural noun is not precise
    workers/*.ex                   # Oban jobs; rebuild scope, call one public API or internal orchestrator
    order.ex                       # Ecto schema + Gearbox + changesets + transitions + query fragments
    order_line_item.ex             # Child Ecto schema
```

Do not create `workflows/` or `Workflows.*` modules. Internal orchestration modules live directly
under the context namespace and are named with ubiquitous-language nouns.

| Layer | Owns | Never |
| --- | --- | --- |
| `MyApp.Sales` facade | Public API shape, `defdelegate` | Transactions, orchestration, business rules, authorization |
| `Commands.*` | Necessary public write use cases: input validation, atomicity, business preconditions, schema transitions, persistence | Authorization, generic internal steps, reaching into other contexts' internals |
| `Queries.*` | Necessary public read use cases: input validation, scoped query composition, Flop-backed collection reads, result preloads | Mutations, authorization, cross-context composition |
| Internal noun modules | Multi-step same-context or cross-context orchestration that is not itself a public command/query | Generic names, dedicated workflow folder, public exposure by default |
| Ecto schemas | Tables, Gearbox, changesets, transition functions returning changesets, `build!/1`, query fragments, `@derive Flop.Schema` for listed schemas | `Repo` calls, other-context calls, cross-context `belongs_to` |
| Workers | Operational entry points: rebuild `%Scope{}`, call one public API or internal noun module, queue/retry metadata | Business logic, authorization logic, bypassing another context's facade |
| Controllers/LiveViews/plugs | Request shaping, authorization, response shaping, calling the facade | Domain logic, direct Repo access for context records |

## Core Rules

### 1. Scope Is The First Argument

Every public function whose result or side effect depends on actor, workspace, organization,
tenant, visibility, audit attribution, or tenant scoping takes `%Scope{}` first and an attrs map
second. Scope represents the caller/execution boundary, not just the current user.

```elixir
Sales.place_order(scope, attrs)
Sales.get_order(scope, %{id: id})
Sales.list_orders(scope, params)
```

Use an explicit system scope for system-level work. Do not add a blanket "system can do
everything" shortcut unless an ADR or spec defines it.

Both scoped commands and queries take `(scope, attrs_or_params)`. Even single-id reads pass a map
so every handler validates input and adding fields later never changes the call shape.

Pre-scope Auth operations that establish identity before a trusted scope exists may omit `%Scope{}`
but still prefer attrs maps for external input.

### 2. The Facade Is Thin And Deliberate

The public context module delegates and nothing more. It exposes only commands and queries that are
necessary and important boundary APIs. Do not scaffold default CRUD functions just because an
entity exists.

```elixir
defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
defdelegate get_order(scope, attrs), to: GetOrder, as: :handle
```

Before adding a facade function, consult TLA+ specs and architecture docs:

- Is this operation modeled as an external/domain action or required read?
- Does a controller, LiveView, worker, or another context legitimately need it?
- Would exposing it leak an internal step or unstable implementation detail?

If the answer is no, keep the behavior internal as a schema function, query fragment, or
ubiquitous-language orchestration module.

### 3. Commands And Queries Are Public API Labels

`Commands.*` and `Queries.*` are for operations exposed through the context facade. Do not use
those folders as generic buckets for every write/read module.

Public command functions use the domain's verbs, not CRUD: `place_order`, `cancel_order`,
`submit_protocol_amendment`, `accept_retrieved_full_text`. Before naming, consult TLA+ action
names, architecture docs, and code vocabulary. Ask the user for a glossary only when the sources
do not settle the language.

Queries may use `get_`, `list_`, or `find_` when they are genuinely public reads. A public
`list_*` function must have a real boundary use case; do not scaffold it by default.

Refuse generic names during scaffold. If the user asks for `run`, `process`, `record`, `item`,
`sync`, or similar, pause and ask for the domain-specific name with examples from the ubiquitous
language.

Keep the domain noun on public operation modules: `Sales.Commands.PlaceOrder`, not
`Sales.Commands.Place`. These names appear in stack traces, telemetry, and logs where the parent
namespace is often lost.

### 4. Authorization Is Outside The Bounded Context

Authorization is not part of the bounded context. Controllers, LiveViews, plugs, pipelines,
GraphQL resolvers, or web-layer policy modules authorize before calling the context facade.

Bounded-context modules trust the caller has already authorized:

- Facades do not authorize.
- Commands do not call `Policy.authorize`.
- Queries do not call `Policy.authorize`.
- Internal orchestration modules do not call `Policy.authorize`.
- Schemas and workers do not own authorization rules.

Do not scaffold `MyApp.Sales.Policy` or any policy module under the context. If the project has a
policy convention, keep it in the boundary layer and match its existing location, such as
`MyAppWeb.SalesPolicy`, controller helpers, plugs, or LiveView hooks.

Scoped queries still enforce data scoping through query construction such as `visible_to/2`. That
is tenancy/visibility filtering, not authorization.

### 5. Handlers Are Self-Contained

A public command or query handler owns one boundary use case end to end for one context:
input validation, any transaction boundary, business preconditions in the `with` chain, schema
transition functions, persistence/query execution, and return shape.

For complex or external/string-keyed input, handlers own an `embedded_schema` input schema inside
the handler module. For tiny `%{id: id}` input, an explicit private validation helper is fine. If a
handler seems to need several unrelated input schemas, split it into multiple public operations or
move internal steps to noun-named modules.

Business rules live in handlers or internal orchestration modules. Schema transition functions
handle the legal state transition and structural changeset. Cross-field/domain preconditions like
"must have at least one line item" or "payment must be authorized" stay visible in the use-case
flow before the transition is persisted.

### 6. Internal Orchestration Uses Ubiquitous-Language Noun Modules

There is no `Workflows.*` convention. Internal orchestration modules are direct children of the
context namespace and are named after the domain concept they coordinate:

```elixir
defmodule MyApp.Sales.Orders do
  # orchestration around Order
end

defmodule MyApp.Sales.OrderVerification do
  # orchestration where "Orders" is too broad
end
```

Use the plural schema noun when it accurately names the coordinated behavior: `Orders`,
`Subscriptions`, `RetrievalAttempts`. If the plural noun is vague, choose a descriptive domain noun
from the TLA+ spec and architecture docs: `OrderVerification`, `FullTextCapture`,
`ProtocolActivation`, `ScreeningRecordAudit`.

Do not use generic nouns such as `Processor`, `Manager`, `Runner`, `Workflow`, `Orchestrator`, or
`Service`. Do not nest orchestration under the schema namespace unless the existing codebase
already has that convention.

Use an internal noun module when:

- an Oban worker needs to drive multi-step domain behavior;
- more than one public command needs the same domain sequence;
- the sequence coordinates multiple schemas or contexts;
- the operation is an internal domain step that should not be exposed on the facade.

Internal orchestration modules may call own schemas, own public query handlers when appropriate,
own schema query fragments, `Repo`, and other contexts' facades. They take `%Scope{}` first when
scope matters, then a validated attrs map or a small explicit argument set. They may use
`Map.fetch!` for required keys when the caller contract has already validated the input.

### 7. One Schema Per Entity; `build!/1` Is For In-Memory Structs Only

Do not create a parallel in-memory representation of a persisted schema. The Ecto schema is the
domain model: it owns the state machine, changesets, transition functions, and query fragments.

Two construction patterns coexist by role:

- `Schema.changeset(struct, attrs)` for persisted entities. Handlers cast external/trusted attrs
  through the changeset and let `Repo.insert` / `Repo.update` execute it.
- `Schema.build!(attrs)` for non-persisted in-memory structs such as event payloads and value
  objects. Use `Map.fetch!` for required keys because the caller contract guarantees them.

Do not use `build!/1` to skip the changeset for data that will be persisted.

### 8. Schemas Own Domain Behavior

The Ecto schema owns:

- `schema "..."`;
- Gearbox state machine when there is a lifecycle/status field;
- changesets, structural validation, normalization, defaults;
- transition functions that return changesets;
- `build!/1` for non-persisted variants;
- query fragments returning `Ecto.Query`;
- `@derive Flop.Schema` when the schema participates in public collection reads.

The schema does not call `Repo`, other contexts, workers, or authorization code.

Child entities are separate schemas in the same context. Child mutations route through the parent
schema when the parent owns the consistency boundary, usually via `cast_assoc`.

### 9. State Machines Use Gearbox When There Is A Status Field

If an entity has a `status` field with multiple values, use Gearbox. A status field without an FSM
is a smell because transitions become scattered guards.

```elixir
use Gearbox,
  field: :status,
  states: [:draft, :placed, :cancelled],
  initial: :draft,
  transitions: %{draft: [:placed, :cancelled], placed: [:cancelled]}
```

Do not invent a status field just to use Gearbox. Use it when it clarifies a real lifecycle.

### 10. Collection Queries And Pagination Use Flop

All public list/search/filter/sort/pagination reads use Repo-level Flop helpers. Add them to the
project Repo if absent:

```elixir
def paginate(queryable, params, opts \\ []) do
  Flop.validate_and_run(queryable, params, opts)
end

def list(queryable, params, opts \\ []) do
  with {:ok, flop} <- Flop.validate(params, opts) do
    results =
      queryable
      |> Flop.filter(flop, opts)
      |> Flop.order_by(flop, opts)
      |> all()

    {:ok, results}
  end
end
```

Every schema used by public collection reads must define a proper `@derive Flop.Schema`, including
only fields the boundary should allow filtering/sorting on. Keep private, sensitive, or unstable
fields out of the derive.

```elixir
@derive {
  Flop.Schema,
  filterable: [:status, :customer_id],
  sortable: [:inserted_at, :status],
  default_order: %{order_by: [:inserted_at], order_directions: [:desc]}
}
schema "orders" do
  # ...
end
```

This rule applies to collection reads, not single-record identity lookups. A `get_order(scope,
%{id: id})` query may use `Repo.one` / `Repo.get_by` against a scoped query. Do not force Flop
onto single-id reads unless the project already does.

### 11. Queries Return Schemas By Default

A query handler returns Ecto schema structs by default. Preloads are explicit per call. Do not
deep-preload everything by default.

Queries do not call other context facades. Cross-context read composition lives at the
controller/LiveView boundary, in an explicit read model/projection, or in a separate reporting
context with its own public API.

Introduce flat read models when the read is clearly display-only, repeated, or
performance-sensitive. Do not hide cross-context read composition inside a query or internal
orchestration module.

### 12. Return Shapes Use Domain-Shaped Values

Public APIs should return persisted schemas, domain structs, or explicit result structs. Prefer
virtual fields on the schema when a command result naturally extends the domain object, such as a
presigned URL on an upload.

Anonymous maps from public command APIs are a violation. JSON shaping belongs in web JSON modules
or serializers, not command return values and not directly in controllers.

### 13. Repo Transactions Live Where Atomicity Is Needed

Use `Repo.transact/1` or the project's equivalent when the operation has a real atomicity boundary:
multiple dependent writes, a domain write plus job/audit/projection enqueue, locks and state
transitions, or cross-context coordination that must be all-or-nothing.

Do not wrap a single independent insert/update in a transaction by convention alone. Each public
command or internal orchestration module owns its own atomicity decision. Nested transactions via
savepoints are acceptable when each layer has its own atomic concern.

### 14. Cross-Context Calls Go Through Facades

Always call another context's public facade. Never call another context's `Commands.*`,
`Queries.*`, internal noun modules, `Workers.*`, or schemas.

| Layer | Can call other-context facades? |
| --- | --- |
| Public commands | Yes |
| Internal noun orchestration modules | Yes |
| Workers | Prefer no; call one public API or internal noun module in their own context |
| Public queries | No |
| Schemas | No |
| Boundary auth modules | No domain composition |

Rules:

- Pass the same `%Scope{}` through.
- Let downstream error tuples bubble unless the TLA+ spec or public API contract requires a
  translation.
- Returning the called schema is acceptable when that is the natural domain result.
- Use Phoenix.PubSub/events or extract a lower context if synchronous facade calls form a cycle.

### 15. Multi-Tenancy Is Detected From Scope

Only scaffold `organization_id`, `tenant_id`, `visible_to/2`, and tenant fields if those fields
exist on the project's `Scope` struct or are clearly modeled in the TLA+ spec. Do not invent
tenancy the app does not have.

When tenant fields exist, every persistence query for that context filters through a scoped query
fragment such as `visible_to/2`.

### 16. Workers Stay Thin

Workers are operational entry points. Each worker:

- carries scope in job args as a serialized map representation;
- reconstitutes `%Scope{}` with the project helper;
- calls one public facade function or one same-context internal noun module;
- keeps retry behavior, queue concerns, and operational metadata in the worker.

If a worker starts accumulating domain branching, move that behavior into an internal noun module.

Authorization still happens before enqueue or at the external boundary that schedules the work; it
does not become worker-owned bounded-context behavior.

### 17. Cross-Context Ecto Associations Are Forbidden

Do not declare `belongs_to :user, Accounts.User` on a schema in a different context. Use a bare FK
field and load the referenced record through the owning context's facade when needed.

```elixir
field :authored_by_id, :binary_id
```

`belongs_to` between sibling schemas in the same context is fine.

### 18. Errors: Fail Fast For Invariants, Tagged Tuples For Recoverable Cases

Raise when the contract already guarantees the happy path: required attrs after validation,
invariant lookups, programmer-bug states. Use bang functions such as `Map.fetch!`, `Repo.get!`, and
internal facade bang functions.

Return tagged tuples for recoverable domain decisions and external/user input:
`:not_found`, `:invalid_transition`, `:insufficient_funds`, `:empty_order`, or
`{:error, %Ecto.Changeset{}}`.

Rules:

- Do not wrap bang results in `{:ok, value}`.
- Do not manually remap invariant lookup failures into new tagged tuples.
- Public facade functions return tagged results; bang functions are internal unless the project
  already exposes an explicit bang API.
- Avoid broad `rescue _` / `catch` blocks unless a documented recovery path exists.

### 19. Migrations Follow The Owning Context

- Put new tables in a migration matching the owning feature/context.
- Do not mix unrelated context changes in one migration.
- Greenfield contexts still in active build-out may fold related migrations together when the user
  requests it.
- Mature contexts get one dated migration per schema change.
- Match the project's generator convention.

### 20. Persistence Conventions

- Money uses integer cents plus a `currency` string.
- Atom statuses use `Ecto.Enum`, not integers.
- Use `has_many ..., on_replace: :delete` only when the parent owns the full collection.
- Use row locks (`lock: "FOR UPDATE"`) when loading a parent for concurrent update.

## Naming: Redundant Prefixes

Inside a leaf schema or enum where the parent module already disambiguates, drop redundant
prefixes:

```elixir
# Inside MyApp.Sales.FileUpload — prefer:
defmodule Kind do
  use Ecto.Type
end
```

This applies to schemas and enums only. Public commands, public queries, workers, and internal
noun orchestration modules keep precise domain nouns because their module names appear in logs,
stack traces, and telemetry.

## Controllers And JSON

Controllers and LiveViews stay thin:

- validate or shape request parameters at the boundary;
- authorize using the web/boundary convention;
- call the bounded-context public API with `(scope, attrs)`;
- delegate response shaping to JSON view modules or serializers.

Do not call Repo directly from controllers for bounded-context records. Detect and match the
codebase's existing JSON pattern.

## Testing

Generate the pyramid from `references/testing.md`:

- **Public handler tests**: Repo-backed tests for commands/queries covering input validation,
  state transitions, persistence, Flop-backed collection reads where applicable, and
  cross-context happy/rollback paths with real downstream contexts. Do not test authorization here.
- **Internal orchestration tests**: Repo-backed tests for noun modules covering orchestration,
  partial-failure rollback, worker-driven behavior, and cross-context coordination.
- **Boundary tests**: controller/LiveView/plug tests for HTTP behavior, response shape, and
  authorization.

StreamData is optional for rich property-style operation-sequence testing at the public handler
tier.

## Review Mode: Auto-Fix Vs Flag

**Auto-fix hard violations:**

- `Repo.*` calls inside schema modules: move persistence to the public handler or internal noun
  module.
- Cross-context `belongs_to`: replace with a bare FK and update loading sites to use the owning
  context's facade.
- Public collection reads bypassing Flop when Flop is available/required: route through
  `Repo.list/3` or `Repo.paginate/3` and add `@derive Flop.Schema`.
- New `Workflows.*` modules or `workflows/` folders: rename/move to direct child noun modules,
  preserving behavior.

**Flag for user judgment:**

- A command/query exposed publicly without a clear TLA+/architecture/boundary need.
- Anonymous map returns from public command APIs.
- Broad rescue/catch around domain calls.
- Status fields without Gearbox.
- Authorization inside bounded-context modules. Recommend moving it to the boundary; do not
  silently rewrite web/auth structure unless the project pattern is clear.

## Dependency Direction

```
Controller / LiveView / Plug / Resolver
  -> boundary authorization
  -> MyApp.Sales facade
      -> Commands.*  (necessary public write APIs)
      -> Queries.*   (necessary public read APIs)

Worker
  -> rebuild Scope
  -> one facade function OR one same-context internal noun module

Commands.* / internal noun modules
  -> Schema -> Repo
  -> Other context facade when needed

Queries.*
  -> Schema query fragments -> Repo
  -> Repo.list / Repo.paginate for collection reads
```

The schema holds the domain and never calls `Repo`. The facade orchestrates nothing. Cross-context
calls always enter through another context's facade. Authorization sits above the bounded context,
not inside it.
