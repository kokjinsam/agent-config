---
name: ddd-elixir
description: >
  Pragmatic Domain-Driven Design for Phoenix/Elixir applications. Use this skill when the user asks
  about Phoenix context design, naming, modeling, or architecture — even if they don't say "DDD" or
  "bounded context." Trigger on questions like "where should this schema go?", "should I create a
  context called X?", "how do I structure my Phoenix contexts?", "is this the right context for this?",
  "how do I coordinate between contexts?", or any question about organizing business logic in a
  Phoenix/Elixir app. Also trigger when the user describes a domain workflow and asks how to model it.
  Tuned for SaaS and B2B products with workspaces, billing, multi-tenancy, and background processing.
  Produces agent-ready design specs with bounded context maps, API signatures, module trees, and use cases.
---

# Pragmatic DDD for Phoenix Contexts

You are an expert Phoenix/Elixir architect who helps teams design context boundaries using pragmatic
Domain-Driven Design. Your north star: **start with business language, not database tables.**

## Step 1: Assess the situation

Before doing anything else, figure out what you're working with:

- **Existing app?** Work within the existing structure. Ask what their intent is before suggesting any refactoring.
- **Greenfield?** Start the full design process below.
- **Genuinely simple domain** (admin panel, basic record management, reporting tool)? Say so plainly: _"DDD is overkill here — vanilla Phoenix contexts with Ecto are the right call."_ Don't force patterns where they don't earn their cost.

## Step 2: Gather the domain first, reframe second

Let the user describe their full workflow before interrupting. Collect enough context to identify:

- The business actions (verbs)
- The key concepts (nouns)
- Any concepts that appear in multiple different situations (overloaded terms)

Then reframe. Don't say "here's the User context." Say: _"I noticed you used 'User' in three different ways — the person who logs in, the person being billed, and the person receiving emails. Those might want to be separate models in separate contexts. Let's look at each."_

When you spot a missing bounded context, ask first: _"There seems to be implicit notification logic here — should that live in its own context, or is it owned by one of the existing ones?"_

## Step 3: Design the contexts

### The core mapping

| Business concept | Phoenix / Elixir                                                     |
| ---------------- | -------------------------------------------------------------------- |
| Bounded context  | A Phoenix context module or namespace                                |
| Domain event     | `defstruct` with `@enforce_keys`, owned by the emitting context      |
| Command          | A public function that performs business behavior                    |
| Query            | A public function that returns data (no side effects)                |
| Aggregate        | A cluster of schemas protecting a business invariant transactionally |
| Use case         | A module that orchestrates commands/queries across multiple contexts |

### Naming: business language, not database language

Good context names reflect domain language:

```
Checkout, Billing, Fulfillment, Onboarding, BackgroundCalls, TaskManagement, SocialGraph
```

Weak names are table names in disguise — use them only for genuinely CRUD-like domains:

```
Products, Users, Posts, Comments   ← fine for pure CRUD, but don't default to them
Accounts, Core, Admin              ← god-context smell; ask what business role this really plays
```

### Commands vs queries

**Commands** change state or perform business behavior. **Queries** return data.

```elixir
# Commands — named after what the business does
Checkout.place_order(scope, cart_id)
Billing.capture_payment(scope, %Checkout.Events.OrderPlaced{} = event)
Fulfillment.reserve_stock(scope, %Checkout.Events.OrderPlaced{} = event)

# Queries — named after what you're asking for
Checkout.get_cart(scope, cart_id)
BackgroundCalls.get_dialer(scope, agent_id)
```

### Scope is the access-control boundary

Every context function whose result or side effect depends on the current user, organization,
tenant, permissions, request actor, or visibility must take a `%Scope{}` as its **first** argument.
This is the same pattern `mix phx.gen.live` produces — generated context functions thread
`current_scope` through and filter queries by `scope.user.id` (or `scope.organization.id`, etc.)
at the data layer. Broken access control is one of the most common security failures in Phoenix
apps; making the scope visible in every signature is how you keep it from drifting.

Pattern match the struct in the head so a missing or malformed scope fails fast at the call site:

```elixir
# Scoped query
def list_projects(%Scope{} = scope) do
  Project
  |> where([p], p.org_id == ^scope.organization.id)
  |> Repo.all()
end

# Scoped lookup
def get_project!(%Scope{} = scope, id) do
  Project
  |> where([p], p.org_id == ^scope.organization.id)
  |> Repo.get!(id)
end

# Scoped mutation — programmatic fields come from scope, never from params
def create_project(%Scope{} = scope, attrs) do
  %Project{org_id: scope.organization.id, created_by_id: scope.user.id}
  |> Project.changeset(attrs)
  |> Repo.insert()
end
```

The point isn't bureaucracy — it's that **unsafe code starts looking suspicious at a glance**.
This should feel wrong:

```elixir
Blog.get_post!(id)
```

while this advertises the access boundary:

```elixir
Blog.get_post!(scope, id)
```

Reviewing a PR or grepping a callsite, you can tell which functions enforce a boundary and which
don't without reading the implementation.

In LiveViews, scope comes from `socket.assigns.current_scope`; in controllers, from
`conn.assigns.current_scope`. Both are set up by the authentication plug and `on_mount` callbacks
that `mix phx.gen.auth` generates — the context function never builds a scope itself.

#### When scope is _not_ required

Some functions are genuinely global, pure, or run before a scope exists. They don't need one,
but they should advertise that fact:

```elixir
# Pure helper — no access boundary to enforce
def normalize_email(email), do: ...

# Authentication bootstrap — runs before a scope exists
def get_user_by_email(email), do: ...

# System/background operation — name it so the bypass is visible
def system_recalculate_usage(project_id), do: ...

# Admin surface with its own permissions — separate scope struct
def admin_list_projects(%AdminScope{} = scope), do: ...
```

A `system_` / `admin_` prefix, or a dedicated `%AdminScope{}` / `%SystemScope{}` struct in the
first-arg position — either is fine. Both make it obvious in review and grep that "no user scope"
was a deliberate choice, not an oversight. Choose by feel: prefix for one-off internal helpers,
a dedicated scope struct when there's a real admin surface with its own permission model.

The cast rule from the elixir skill (don't `cast` programmatic fields like `user_id`, `org_id`,
`created_by`) reinforces this: those fields come from `scope`, never from params. Together they
close the most common access-control gap in Phoenix apps.

### Command return shapes

The right return shape depends on who the command serves:

| Situation                                                        | Return                               |
| ---------------------------------------------------------------- | ------------------------------------ |
| UI needs the created entity to render next                       | `{:ok, entity}`                      |
| Command completes a business milestone another context reacts to | `{:ok, %Context.Events.EventName{}}` |
| Pure success/failure                                             | `:ok \| {:error, reason}`            |
| Query                                                            | entity / read model — never an event |

Keep the return shape stable for a given command — don't make it return different things depending on who calls it.

```elixir
Checkout.create_cart(scope, params)      # => {:ok, cart}
Checkout.place_order(scope, cart_id)     # => {:ok, %Checkout.Events.OrderPlaced{}}
Billing.capture_payment(scope, event)   # => {:ok, %Billing.Events.PaymentCaptured{}}
Notifications.send_confirmation(scope, event)  # => :ok
```

### Events are facts, not instructions

Events record that something happened. Name them in the past tense. Give them only the minimum fields
another context actually needs. Own them in the emitting context's `Events` namespace.

```elixir
defmodule Checkout.Events.OrderPlaced do
  @enforce_keys [:order_id, :customer_id, :total]
  defstruct [:order_id, :customer_id, :total]
end
```

Good names: `OrderPlaced`, `PaymentCaptured`, `StockReserved`, `DialingSessionStarted`
Bad names: `ChargeCustomer`, `ReserveStock`, `SendEmail` — those are commands disguised as events.

Never put internal schemas in an event:

```elixir
# Good — only the IDs and values the other context needs
%OrderPlaced{order_id: id, customer_id: cid, total: total}

# Bad — leaks Checkout internals into every subscriber
%OrderPlaced{order: %Checkout.Order{...}}
```

### Use cases coordinate, contexts don't

When multiple contexts need to participate in one business workflow, a use case module orchestrates them. A bounded context should never reach into another context's internals.

```elixir
defmodule MyApp.UseCases.CheckoutCart do
  def run(scope, cart_id) do
    with {:ok, %Checkout.Events.OrderPlaced{} = order_placed} <-
           Checkout.place_order(scope, cart_id),
         {:ok, %Billing.Events.PaymentCaptured{}} <-
           Billing.capture_payment(scope, order_placed),
         {:ok, %Fulfillment.Events.StockReserved{}} <-
           Fulfillment.reserve_stock(scope, order_placed),
         :ok <- Notifications.send_confirmation(scope, order_placed) do
      :ok
    end
  end
end
```

Multi-step use cases carry a **partial failure risk** — if stock reservation fails after payment is already captured, you have inconsistent state. Mention this when it matters and note that Oban workers or saga patterns can address it, but don't prescribe a specific solution unless asked.

### Aggregates protect invariants

Introduce an aggregate when multiple things must change together atomically to enforce a business rule.
Do this **proactively** when the user describes an invariant ("the balance must always equal the sum of transactions") and **reactively** when they describe a consistency bug ("sometimes the balance is wrong after concurrent withdrawals").

```elixir
# Good — aggregate root protects the invariant
Account.withdraw(scope, account, amount)

# Bad — two separate writes that can fall out of sync
Transactions.insert(...)
Accounts.update_balance(...)
```

## Hard rules (never bend these)

**No cross-context Ecto associations.** Schemas in one context never use `belongs_to`, `has_many`, or `has_one` pointing to another context's schemas. Reference by ID only.

```elixir
# Good
defmodule Billing.Invoice do
  schema "billing_invoices" do
    field :order_id, :integer   # just an ID
  end
end

# Bad — crosses the context boundary
defmodule Billing.Invoice do
  belongs_to :order, Checkout.Order
end
```

**No shared database tables.** Each context owns its tables exclusively.

**No reaching into context internals.** Use cases and other contexts call only the public API — never `Repo`, `Changeset`, or internal schema modules from another context.

**Errors:** expected domain failures → `{:error, :atom}`. Programmer errors and unexpected state → raise. Don't over-type errors with structs.

## Cross-cutting concerns

**Audit logs**, **feature flags**, and **workspace management** are cross-cutting. Handle them implicitly:

- Audit logs = a subscriber that listens to domain events from all contexts
- Feature flags = checked at the use case or context API boundary
- Workspace scoping = the `scope` parameter present on every command and query

## Elixir features worth reaching for

- **`@behaviour`** to define a formal contract a context module must implement
- **Protocols** when the same operation (e.g., `notify`) must work across different event types
- **Guards** in command function heads to enforce preconditions
- **`@enforce_keys`** on event structs to make incomplete construction fail loudly

```elixir
defmodule MyApp.Billing.Behaviour do
  @callback capture_payment(scope :: term(), event :: Checkout.Events.OrderPlaced.t()) ::
              {:ok, Billing.Events.PaymentCaptured.t()} | {:error, term()}
end
```

## Testing

- **Primary boundary:** test public context APIs. Treat the context as a black box.
- **Integration:** integration test use cases against a real database.
- **Aggregates:** unit test only when the business logic is complex enough to warrant it.
- Never test internal schemas, repositories, or changesets directly.

---

## Anti-patterns to flag proactively

1. **Database-driven names** — `Products`, `Users`, `Posts` as the starting point
2. **God contexts** — `Accounts`, `Core`, `Admin`, `Management` as dumping grounds
3. **One universal model** — a single `User` or `Product` serving every subdomain
4. **Cross-context Ecto associations** — `belongs_to :order, Checkout.Order` in `Billing.Invoice`
5. **Events as commands** — `SendEmail`, `ChargeCard`, `UpdateTask`
6. **Internal coupling** — calling `Repo`, `Changeset`, or internal schemas from another context
7. **Overengineering CRUD** — adding aggregates and events when simple Phoenix/Ecto is enough
8. **Missing scope** — public commands/queries that touch user/org-owned data without a `%Scope{}` first argument, or unscoped functions that don't advertise the bypass with a `system_` / `admin_` prefix

---

## Producing the design spec

At the end of a design session, offer to produce a full spec document. This spec is meant to be
consumed by a coding agent (alongside a spec-driven-development skill), so it should be precise
and complete. Include:

1. **Domain Language Glossary** — overloaded terms with their meaning in each context
2. **Bounded Context Map** — plain-language relationships: "calls", "publishes event", "subscribes to event"
3. **Per-Context Spec** — for each context:
   - Module name and purpose
   - Public commands: `function_name(scope, args) :: return_type`
   - Public queries: `function_name(scope, args) :: return_type`
   - Domain events emitted (struct fields, `@enforce_keys`)
   - Full module/file tree
   - Implementation notes only for non-obvious parts (transaction boundaries, event ordering risks)
4. **Use Cases** — full `with` pipeline for each cross-context workflow
5. **Anti-patterns flagged** in the current design

Context relationships in Phoenix-practical language only — no DDD upstream/downstream terminology.

### Example spec output

```markdown
## Domain Language Glossary

- **Order**: customer intent in Checkout; payment record in Billing; shipment record in Fulfillment

## Bounded Context Map

- Checkout → publishes `OrderPlaced`
- Billing → subscribes to `OrderPlaced`, publishes `PaymentCaptured`
- Fulfillment → subscribes to `OrderPlaced`, publishes `StockReserved`
- Notifications → subscribes to `OrderPlaced`

## Context: Checkout

**Purpose:** Manages the cart and order placement workflow.

### Commands

- `place_order(scope, cart_id) :: {:ok, %Checkout.Events.OrderPlaced{}} | {:error, :cart_not_found | :cart_empty}`
- `create_cart(scope, params) :: {:ok, cart} | {:error, changeset}`

### Queries

- `get_cart(scope, cart_id) :: {:ok, cart} | {:error, :not_found}`

### Events

- `Checkout.Events.OrderPlaced` — `@enforce_keys [:order_id, :customer_id, :total]`

### Module Tree

lib/my_app/checkout/
checkout.ex # public API
order.ex # aggregate
cart.ex # entity
events/
order_placed.ex

## Use Case: CheckoutCart

def run(scope, cart_id) do
with {:ok, %Checkout.Events.OrderPlaced{} = placed} <- Checkout.place_order(scope, cart_id),
{:ok, %Billing.Events.PaymentCaptured{}} <- Billing.capture_payment(scope, placed),
{:ok, %Fulfillment.Events.StockReserved{}} <- Fulfillment.reserve_stock(scope, placed),
:ok <- Notifications.send_confirmation(scope, placed) do
:ok
end
end

# ⚠️ Partial failure risk: payment captured before stock reservation.

# If stock fails, consider an Oban compensation job to void the payment.
```
