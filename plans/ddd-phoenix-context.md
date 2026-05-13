# Pragmatic DDD for Phoenix Contexts

## Purpose

Create a skill that helps users design Phoenix applications using a pragmatic Domain-Driven Design approach.

The skill should guide users to model Phoenix contexts as bounded contexts, define command/query APIs using domain language, and coordinate cross-context workflows through use cases and lightweight domain events.

This skill should avoid heavyweight enterprise DDD unless the user explicitly asks for it. The goal is practical architectural guidance for Elixir/Phoenix applications.

## Core Philosophy

The core idea is:

> Do not start with tables, schemas, or CRUD resources. Start with the business language and discover boundaries from that language.

Phoenix contexts should not simply mirror database tables. They should represent bounded contexts discovered from domain language.

A word like `Product`, `User`, `Call`, or `Order` may mean different things in different parts of the business. Therefore, there may be multiple models of the "same" concept across different bounded contexts.

Example:

- `Checkout.Product`
  - SKU
  - name
  - description

- `Billing.Product`
  - SKU
  - quantity
  - unit cost

- `Fulfillment.Product`
  - SKU
  - label
  - quantity on hand
  - warehouse location

The skill should help users identify these separate meanings rather than forcing one universal schema/model.

## DDD Concepts Mapped to Phoenix

Use this mapping:

| DDD concept     | Phoenix / Elixir interpretation                                          |
| --------------- | ------------------------------------------------------------------------ |
| Domain          | The overall business problem space                                       |
| Subdomain       | A meaningful business area with its own language                         |
| Bounded context | A Phoenix context or namespace representing a specific dialect           |
| Entity          | Struct/schema with identity and lifecycle                                |
| Value object    | Struct without identity, compared by attributes                          |
| Aggregate       | Cluster of entities/value objects enforcing business invariants          |
| Aggregate root  | The only public entry point for modifying an aggregate                   |
| Repository      | Persistence abstraction around Ecto/database access                      |
| Domain event    | Lightweight struct representing a meaningful business fact               |
| Command         | Function that performs domain behavior                                   |
| Query           | Function that returns domain data or read models                         |
| Use case        | Application-level workflow that coordinates one or more bounded contexts |

## Main Design Process

When helping a user design a Phoenix context, follow this process:

1. Identify the business workflow.
2. Listen for domain language.
3. Identify subdomains.
4. Map subdomains to bounded contexts.
5. Define each context's public API using commands and queries.
6. Keep CRUD only when the context is genuinely CRUD-like.
7. Use aggregates where business invariants must be protected.
8. Use events to decouple bounded contexts.
9. Use use cases to orchestrate cross-context workflows.

## Context Design Rules

### Prefer business language over database language

Avoid this as the starting point:

```elixir
Products.create_product(params)
Products.update_product(product, params)
Products.delete_product(product)
Products.list_products()
```

Prefer commands that express business behavior:

```elixir
Checkout.place_order(cart_id)
Billing.capture_payment(order_placed)
Fulfillment.reserve_stock(order_placed)
BackgroundCalls.assign_call_to_room(call_id)
BackgroundCalls.register_callee(call_id, callee_info)
```

### A Phoenix context can be a bounded context

Treat a context as a boundary around a specific domain language.

Good examples:

```elixir
Checkout
Billing
Fulfillment
Blogging
SocialGraph
Onboarding
BackgroundCalls
TaskManagement
```

Less helpful examples when used blindly:

```elixir
Products
Users
Posts
Comments
```

Those may be fine for CRUD, but they should not be automatic defaults.

## Commands and Queries

A bounded context exposes workflows as commands and queries.

### Commands

Commands change state or perform business behavior.

Examples:

```elixir
Checkout.place_order(cart_id)
Billing.capture_payment(order_placed_event)
Fulfillment.reserve_stock(order_placed_event)
Blogging.publish_post(author_id, attrs)
SocialGraph.notify_followers(post_published_event)
```

### Queries

Queries return data, usually without side effects.

Examples:

```elixir
Checkout.get_cart(cart_id)
Billing.get_invoice(invoice_id)
BackgroundCalls.get_dialer(agent_id)
Blogging.list_published_posts()
```

Complex queries may return a domain-specific read model rather than exposing internal schemas.

Example:

```elixir
%BackgroundCalls.Dialer{
  room: room,
  active_call: active_call
}
```

The web layer should not have to traverse internal schemas to construct this.

## Command Return Rule

Use the following pragmatic rule from the discussion:

> Commands may return entities for local/UI-oriented workflows.
> Commands should return events when they participate in cross-context workflows and complete a meaningful domain action.

Do not force all commands into a universal return wrapper.

### Local or UI-oriented command

If the command is primarily used inside the same bounded context or directly by the UI, returning an entity/result is fine.

```elixir
Checkout.create_cart(params)
# => {:ok, cart}

Blogging.create_draft(author_id, attrs)
# => {:ok, draft}
```

### Cross-context workflow command

If the command completes a meaningful business action that another bounded context may react to, return a domain event.

```elixir
Checkout.place_order(cart_id)
# => {:ok, %Checkout.Events.OrderPlaced{}}

Billing.capture_payment(%Checkout.Events.OrderPlaced{} = event)
# => {:ok, %Billing.Events.PaymentCaptured{}}

Fulfillment.reserve_stock(%Checkout.Events.OrderPlaced{} = event)
# => {:ok, %Fulfillment.Events.StockReserved{}}
```

### Important nuance

The command should return based on the semantic role of the command, not random caller preference.

Avoid making the same command return different shapes depending on who calls it:

```elixir
# Avoid
Checkout.place_order(params)
# sometimes {:ok, order}
# sometimes {:ok, %OrderPlaced{}}
```

Instead, decide what the command means.

If `place_order` represents the domain milestone "an order was placed," returning `%OrderPlaced{}` is reasonable.

If `create_cart` represents local state creation for UI continuation, returning the cart is reasonable.

## Events

Events are lightweight data structures used to decouple bounded contexts.

They do not imply event sourcing, message brokers, or asynchronous systems.

In the simplest version, events are just Elixir structs passed between functions.

```elixir
defmodule Checkout.Events.OrderPlaced do
  defstruct [:order_id, :customer_id, :total]
end
```

### Events are facts, not instructions

Good event names:

```elixir
%OrderPlaced{}
%PaymentCaptured{}
%PaymentFailed{}
%StockReserved{}
%CallAssignedToRoom{}
%CalleeRegistered{}
%DialingSessionStarted{}
%PostPublished{}
%GuestCompletedOnboarding{}
```

Bad event names:

```elixir
%ChargeCustomer{}
%ReserveStock{}
%SendEmail{}
%UpdateTask{}
```

Those are commands disguised as events.

An event says:

> This happened.

A command says:

> Please do this.

### Event payloads

Events should contain the minimum information needed by another bounded context.

Do not pass internal schemas from one context into another.

Prefer:

```elixir
%OrderPlaced{
  order_id: order.id,
  customer_id: order.customer_id,
  total: order.total
}
```

Avoid:

```elixir
%OrderPlaced{
  order: %Checkout.Order{...}
}
```

The second version couples other contexts to `Checkout` internals.

## Use Cases

Use cases coordinate workflows that span multiple bounded contexts.

A use case is an orchestration layer. It is allowed to call public commands and queries on bounded contexts.

It should not call internal schemas, repositories, changesets, or aggregate internals.

Good:

```elixir
defmodule MyApp.UseCases.PlaceOrder do
  def run(cart_id) do
    with {:ok, %Checkout.Events.OrderPlaced{} = order_placed} <-
           Checkout.place_order(cart_id),
         {:ok, %Billing.Events.PaymentCaptured{} = payment_captured} <-
           Billing.capture_payment(order_placed),
         {:ok, %Fulfillment.Events.StockReserved{} = stock_reserved} <-
           Fulfillment.reserve_stock(order_placed) do
      {:ok, stock_reserved}
    end
  end
end
```

Avoid:

```elixir
Checkout.Order.changeset(...)
Billing.Payment.insert(...)
Fulfillment.Repo.update(...)
```

That leaks into context internals.

## Cross-Context Communication Rule

Use this rule:

> One bounded context should not directly manipulate another bounded context's internals.

Instead of this:

```elixir
defmodule BackgroundCalls do
  def start_dialing_session(agent_id) do
    # does background call work
    TaskManagement.update_task(...)
  end
end
```

Prefer:

```elixir
defmodule BackgroundCalls do
  def start_dialing_session(agent_id) do
    # does background call work
    {:ok, %BackgroundCalls.Events.DialingSessionStarted{
      agent_id: agent_id,
      room_id: room_id
    }}
  end
end
```

Then the use case coordinates:

```elixir
defmodule MyApp.UseCases.AgentJoinedRoom do
  def run(agent_id) do
    with {:ok, event} <- BackgroundCalls.start_dialing_session(agent_id),
         :ok <- TaskManagement.handle_dialing_session_started(event) do
      :ok
    end
  end
end
```

This keeps bounded contexts independent.

## Aggregates

Use aggregates when business invariants must be protected transactionally.

An aggregate is not just an association tree. It is a consistency boundary.

Example:

A bank account has transactions. Outside code should not freely insert transactions and separately update balances. The account aggregate should enforce that.

Prefer:

```elixir
Account.withdraw(account, amount)
```

Avoid:

```elixir
Transactions.insert(...)
Accounts.update_balance(...)
```

The aggregate root protects consistency.

## Functional Implementation Style

Use functional pipelines to implement aggregate operations.

General shape:

```elixir
params
|> Factory.build()
|> Aggregate.perform_business_operation()
|> Repository.save()
```

Example:

```elixir
def create_product(params) do
  params
  |> Products.build()
  |> Product.validate_for_catalog()
  |> Products.insert()
end
```

The exact function names should follow the domain language, not generic pattern names.

For simple CRUD contexts, this can collapse into ordinary Phoenix/Ecto code.

```elixir
def create_product(attrs) do
  %Product{}
  |> Product.changeset(attrs)
  |> Repo.insert()
end
```

Do not add unnecessary layers when the context is truly simple.

## Repositories

A DDD repository is not the same thing as `Ecto.Repo`.

In this approach, a repository is a persistence boundary for domain objects.

For simple contexts, Phoenix-generated context functions may be enough.

For richer contexts, separate public business APIs from persistence-oriented modules.

Example:

```elixir
Billing.issue_invoice(...)
```

may call:

```elixir
Billing.Invoices.insert(...)
```

Where:

- `Billing.issue_invoice/1` is the business command.
- `Billing.Invoices.insert/1` handles persistence.

## CRUD Guidance

CRUD is acceptable when the domain is genuinely CRUD-like.

Do not over-engineer.

If a context has no meaningful business behavior beyond managing records, generated Phoenix context functions are fine.

Good CRUD use case:

```elixir
Catalog.create_category(attrs)
Catalog.update_category(category, attrs)
Catalog.delete_category(category)
```

But if business behavior emerges, evolve the API:

```elixir
Catalog.publish_product(product_id)
Catalog.retire_product(product_id)
Catalog.mark_product_out_of_stock(product_id)
```

## How to Decide If a Command Should Return an Entity or Event

Use this decision table:

| Situation                                            | Return                       |
| ---------------------------------------------------- | ---------------------------- |
| UI needs to render or edit the created thing         | `{:ok, entity}`              |
| Command is local to one bounded context              | `{:ok, entity}` or `:ok`     |
| Command completes a meaningful business milestone    | `{:ok, event}`               |
| Another bounded context should continue the workflow | `{:ok, event}`               |
| The result is only success/failure                   | `:ok` or `{:error, reason}`  |
| The operation is a query                             | entity/read model, not event |

Examples:

```elixir
Checkout.create_cart(params)
# => {:ok, cart}

Checkout.place_order(cart_id)
# => {:ok, %OrderPlaced{}}

Billing.capture_payment(%OrderPlaced{} = event)
# => {:ok, %PaymentCaptured{}}

Notifications.send_order_confirmation(%OrderPlaced{} = event)
# => :ok
```

## Skill Behavior

When the user asks for DDD/Phoenix design help, the skill should:

1. Ask what domain/workflow they are modeling if unclear.
2. Identify candidate bounded contexts.
3. Point out overloaded words that may mean different things in different contexts.
4. Suggest context names based on domain language.
5. Suggest public commands and queries.
6. Recommend where events are useful.
7. Recommend use cases for cross-context workflows.
8. Avoid forcing event sourcing, CQRS, or message brokers unless requested.
9. Keep advice pragmatic and Phoenix-friendly.
10. Prefer simple structures when complexity is not justified.

## Common Prompts This Skill Should Handle

### Prompt: "Where should this schema go?"

Response approach:

- Do not answer based only on the schema name.
- Ask what business workflow uses it.
- Identify what the concept means in each subdomain.
- Suggest one or more bounded contexts.

### Prompt: "Should I create a context called Users?"

Response approach:

- Explain that `User` is often overloaded.
- Ask whether the domain language says `Author`, `Customer`, `Agent`, `Guest`, `Member`, etc.
- Suggest splitting by role/subdomain if meanings differ.

### Prompt: "Should this command return an entity or event?"

Response approach:

- If local/UI-oriented, return entity/result.
- If cross-context milestone, return event.
- Keep return shape stable for that command.
- Do not force a universal wrapper.

### Prompt: "How do I coordinate multiple contexts?"

Response approach:

- Create a use case module.
- The use case calls public context APIs.
- Contexts communicate through events when one context's output becomes another context's input.
- Do not let one context reach into another context's internals.

### Prompt: "Do I need event sourcing?"

Response approach:

- No, not by default.
- In this approach, events can be plain structs passed between functions.
- Event sourcing is optional and separate.

## Example Full Design

Domain workflow:

> Customer checks out a cart. The system places the order, captures payment, reserves stock, and sends a confirmation.

Bounded contexts:

```elixir
Checkout
Billing
Fulfillment
Notifications
```

Use case:

```elixir
defmodule MyApp.UseCases.CheckOutCart do
  def run(cart_id) do
    with {:ok, %Checkout.Events.OrderPlaced{} = order_placed} <-
           Checkout.place_order(cart_id),
         {:ok, %Billing.Events.PaymentCaptured{} = payment_captured} <-
           Billing.capture_payment(order_placed),
         {:ok, %Fulfillment.Events.StockReserved{} = stock_reserved} <-
           Fulfillment.reserve_stock(order_placed),
         :ok <-
           Notifications.send_order_confirmation(order_placed) do
      {:ok, stock_reserved}
    end
  end
end
```

Checkout event:

```elixir
defmodule Checkout.Events.OrderPlaced do
  defstruct [:order_id, :customer_id, :total]
end
```

Billing command:

```elixir
defmodule Billing do
  def capture_payment(%Checkout.Events.OrderPlaced{} = event) do
    # Load billing-specific customer/payment data
    # Capture payment
    # Persist payment
    {:ok, %Billing.Events.PaymentCaptured{
      order_id: event.order_id,
      customer_id: event.customer_id,
      amount: event.total
    }}
  end
end
```

Fulfillment command:

```elixir
defmodule Fulfillment do
  def reserve_stock(%Checkout.Events.OrderPlaced{} = event) do
    # Load fulfillment-specific order/item data
    # Reserve stock
    {:ok, %Fulfillment.Events.StockReserved{
      order_id: event.order_id
    }}
  end
end
```

Notes:

- `Checkout` owns `OrderPlaced`.
- `Billing` should not receive a full `%Checkout.Order{}` schema.
- `Fulfillment` should not reach into `Checkout` tables directly.
- The use case coordinates the workflow.
- Events are plain structs, not event sourcing.

## Anti-Patterns to Warn Against

### 1. Database-driven contexts

```elixir
Products
Users
Posts
Comments
```

These may be fine for CRUD, but they often indicate schema-first design.

### 2. God contexts

```elixir
Accounts
Core
Management
Admin
```

These can become dumping grounds.

### 3. One universal model

Avoid assuming one `Product`, `User`, or `Call` must serve every part of the business.

### 4. Context-to-context internal coupling

Avoid one context calling another context's repositories, schemas, or changesets.

### 5. Events as commands

Avoid event names like:

```elixir
%SendEmail{}
%ChargeCard{}
%UpdateTask{}
```

Prefer fact names:

```elixir
%OrderPlaced{}
%PaymentCaptured{}
%TaskStarted{}
```

### 6. Overengineering simple CRUD

Do not introduce aggregates, events, factories, and repositories when simple Phoenix/Ecto code is enough.

## Tone and Style

The skill should be:

- Pragmatic
- Phoenix-aware
- Elixir-friendly
- DDD-informed but not dogmatic
- Clear about tradeoffs
- Willing to say "simple CRUD is fine here"
- Focused on business language and boundaries

Avoid:

- Heavy enterprise jargon
- Insisting on event sourcing
- Forcing CQRS
- Forcing event returns everywhere
- Turning every operation into an aggregate
- Treating DDD patterns as mandatory ceremony
