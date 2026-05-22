# Structuring Domain Architecture with DDD, CQRS, and a Small Amount of TLA+

Software systems are easier to build when the architecture reflects the business domain clearly.

That sounds obvious, but many systems slowly drift in the opposite direction. The code starts with a few simple entities and services. Then more use cases arrive. Then more edge cases. Then retries, background jobs, partial failures, duplicate messages, and inconsistent read models. Eventually, the domain rules are scattered across controllers, handlers, database triggers, scheduled jobs, and integration code.

At that point, the hard part is no longer writing code. The hard part is answering a simple question:

> What is this system actually allowed to do?

This is where Domain-Driven Design, CQRS, and TLA+ can work nicely together.

Not as a complicated methodology. Not as a way to make architecture look more academic. But as a practical combination:

- **Domain-Driven Design** helps us understand the business model.
- **CQRS** helps us separate decisions from views.
- **TLA+** helps us check the most important state transitions before we implement them.

The goal is not to overcomplicate the system. The goal is to make the important parts simple, explicit, and trustworthy.

## Every domain has state and behavior

Most business domains have state.

An order can be pending, paid, shipped, cancelled, or refunded. A booking can be requested, confirmed, checked in, checked out, or expired. A payment can be authorized, captured, failed, reversed, or settled.

State by itself is not enough. What matters is how that state changes.

For example:

- Can an order be shipped before payment is authorized?
- Can a booking be cancelled after check-in?
- Can a payment be captured twice?
- Can inventory be reserved by two customers at the same time?
- Can a retry create a duplicate business action?

These questions are about behavior. More specifically, they are about **state transitions**.

A domain model should not only describe the nouns in the system. It should also describe the allowed transitions between states.

This is one reason Domain-Driven Design is useful. DDD encourages us to speak in the language of the business and make important rules visible. Instead of starting with tables and endpoints, we start with concepts such as:

- bounded contexts
- aggregates
- entities
- value objects
- commands
- domain events
- invariants
- policies
- workflows

The point is not to use DDD vocabulary for its own sake. The point is to make the domain easier to reason about.

A good domain model should help us say:

> Given this command, in this state, what is allowed to happen next?

## Start with the domain language

Before thinking about CQRS or TLA+, start with the domain language.

For example, suppose we are designing an order system. We might hear business people say things like:

- A customer places an order.
- Payment must be authorized before shipping.
- An order can be cancelled before it ships.
- Once an order ships, it cannot be cancelled.
- A payment must not be captured more than once.

These sentences are extremely valuable. They are not just requirements. They are the beginning of the domain model.

From them, we can identify commands:

- `PlaceOrder`
- `AuthorizePayment`
- `ShipOrder`
- `CancelOrder`
- `CapturePayment`

We can identify domain events:

- `OrderPlaced`
- `PaymentAuthorized`
- `OrderShipped`
- `OrderCancelled`
- `PaymentCaptured`

We can identify invariants:

- An order cannot be shipped unless payment is authorized.
- An order cannot be cancelled after it has shipped.
- A payment cannot be captured more than once.

These invariants are especially important. They are the rules that should always hold true, no matter what happens in the system.

## Use CQRS to keep decisions and views separate

CQRS stands for Command Query Responsibility Segregation.

The idea is simple:

> Commands change state. Queries read state.

A command expresses intent. It asks the system to do something:

- place this order
- authorize this payment
- reserve this room
- cancel this booking
- ship this package

A query asks for information:

- show me the order summary
- list today's bookings
- show the payment history
- display the customer dashboard

Keeping commands and queries separate makes the architecture easier to understand.

Commands are where business decisions happen. They should protect invariants and produce domain events when something meaningful changes.

Queries are where we shape information for users, reports, dashboards, APIs, or other consumers. They should not secretly change business state.

This separation helps us avoid mixing two different concerns:

- **Is this action allowed?**
- **What should the user see?**

Those are different questions. They deserve different models.

The write side can focus on correctness. The read side can focus on usefulness.

## A simple CQRS flow

A typical CQRS flow might look like this:

```text
Command -> Aggregate -> Domain Event -> Projection -> Read Model -> Query
```

For example:

```text
ShipOrder -> Order aggregate -> OrderShipped -> OrderSummary projection -> Order details page
```

The command handler loads the aggregate, asks it to perform an operation, and saves the resulting domain event or new state. A projection then updates one or more read models.

This structure gives us a clean place for domain rules.

For example, the `Order` aggregate can reject `ShipOrder` if payment has not been authorized yet. The read model does not need to know how to enforce that rule. It only needs to display the current order status.

This keeps the domain behavior close to the domain model.

## Where TLA+ fits

DDD helps us model the domain.

CQRS helps us structure commands and queries.

TLA+ helps us check whether important state transitions are safe.

TLA+ is a formal specification language. That may sound intimidating, but the basic idea is approachable:

> Describe the possible states of a system, describe the allowed transitions, then check whether bad states are reachable.

This is very close to how we already think about domain workflows.

For example:

```text
Pending -> Paid -> Shipped
Pending -> Cancelled
Paid -> Cancelled
Shipped -> Delivered
```

That is a state machine. TLA+ lets us write a precise version of that state machine and check properties such as:

- An order is never shipped before payment is authorized.
- An order is never both shipped and cancelled.
- A payment is never captured twice.

This is useful because many bugs hide in unusual sequences of events:

- duplicate commands
- retries
- out-of-order messages
- worker crashes
- delayed events
- partial failures
- concurrent requests

A diagram may show the happy path. TLA+ helps us ask:

> Is there any possible path that breaks the rule?

## Do not model the whole system

The most important TLA+ advice is this:

> Model the correctness argument, not the implementation.

Do not model your whole architecture. Do not model every table, endpoint, queue, cache, framework, and deployment detail.

Instead, write the smallest model that captures only the safety-relevant state.

For an order workflow, this might be just:

- order status
- whether payment has been authorized
- whether payment has been captured
- whether the order has been shipped
- whether the order has been cancelled

That may be enough to check the important rules.

You probably do not need to model:

- HTTP requests
- database schemas
- ORM mappings
- message broker internals
- JSON payloads
- logging
- metrics
- Kubernetes
- exact retry backoff timing

Unless those details affect the property you are checking, leave them out.

A small useful model is better than a large impressive one that nobody understands.

## A practical TLA+ modeling style

For architecture work, keep TLA+ models small and readable.

A good starting structure is:

```text
constants
variables
TypeOK
Init
actions
Next
Spec
2-4 invariants
```

Use clear names. Avoid abbreviations. Add comments generously.

The model should explain what it includes, what it ignores, and what properties it checks.

A good rule of thumb:

> Keep the spec under 100 lines of code, excluding comments, unless there is a specific reason not to.

Prefer fewer variables. Prefer coarser atomic steps. Only introduce finer interleavings when those interleavings are essential to the risk you are studying.

For example, if you are checking whether `ShipOrder` can happen before payment authorization, you probably do not need to model every internal step of the shipping service. You only need to model the transition that marks the order as shipped.

## A small example

Suppose the domain rule is:

> An order must never be shipped unless payment has been authorized.

In DDD terms, this is an invariant.

In CQRS terms, `ShipOrder` is a command that changes state.

In TLA+ terms, this becomes a safety property that should always be true.

A simplified model might describe these states:

```text
orderPlaced
paymentAuthorized
orderShipped
orderCancelled
```

And these actions:

```text
PlaceOrder
AuthorizePayment
ShipOrder
CancelOrder
```

Then we can check invariants like:

```text
If orderShipped is true, paymentAuthorized must also be true.
An order cannot be both shipped and cancelled.
```

This is not a full implementation. It is a design check.

We are not asking, "Does the code compile?"

We are asking:

> Does our model allow an impossible business situation?

That is a powerful question to ask before implementation.

## How the three ideas work together

DDD, CQRS, and TLA+ each answer a different question.

| Question                                     | Helpful tool   |
| -------------------------------------------- | -------------- |
| What does the business mean?                 | DDD            |
| What actions can change state?               | DDD + CQRS     |
| What information do users need to read?      | CQRS           |
| What rules must always hold?                 | DDD invariants |
| Can those rules break under weird sequences? | TLA+           |

The combination works well because the ideas reinforce each other.

DDD gives us the language. CQRS makes state-changing operations explicit. TLA+ checks the riskiest transitions.

The result is a domain architecture that is easier to discuss, easier to test, and easier to evolve.

## Keep it simple

It is easy to overdo this.

Not every system needs event sourcing. Not every aggregate needs a formal model. Not every CRUD screen needs CQRS. Not every workflow needs TLA+.

Use these tools where they help.

For a simple admin screen, a straightforward CRUD design may be enough.

For a payment workflow, booking system, inventory reservation system, entitlement system, or distributed process manager, the extra modeling may be worth it.

A good test is this:

> Would a wrong state transition cause serious business, financial, operational, or user harm?

If yes, make the transition explicit. Consider modeling it. Check the invariants.

If no, keep the design simple.

Architecture should reduce confusion, not add ceremony.

## A practical workflow

Here is a lightweight way to apply the approach:

1. **Listen to the domain language**

   Capture the words business people use. Identify important states, actions, and rules.

2. **Define the bounded context**

   Decide where this model applies. Avoid mixing unrelated domains into one large model.

3. **Identify commands and queries**

   Commands change state. Queries read state. Keep them separate.

4. **Find the invariants**

   Write down the rules that must always be true.

5. **Sketch the state transitions**

   Draw the lifecycle or workflow in plain language first.

6. **Use TLA+ only for the risky part**

   Model the smallest safety-relevant state. Check the most important invariants.

7. **Document what was abstracted away**

   Be clear about what the model does not include.

8. **Implement with the model in mind**

   The code does not need to look like the TLA+ spec line by line, but the design should preserve the checked rules.

## What to put in the architecture document

An architecture document does not need to be long or formal to be useful.

For a domain-heavy system, consider including:

- the bounded context
- the core domain concepts
- the main commands
- the main queries
- the important domain events
- the aggregate boundaries
- the state transition diagram
- the invariants
- the consistency expectations
- the TLA+ model link, if one exists
- the list of things intentionally abstracted away

The TLA+ section can be short:

```text
We modeled the order lifecycle in TLA+ to check two safety properties:

1. An order is never shipped before payment authorization.
2. An order is never both shipped and cancelled.

The model abstracts away HTTP, database schema, message broker behavior,
serialization, authentication, logging, metrics, and deployment topology.
```

That is enough to tell readers why the model exists and what confidence it gives.

## Final thought

Good domain architecture is not about adding more patterns.

It is about making the business behavior clear.

DDD helps us name the domain. CQRS helps us separate decisions from views. TLA+ helps us check the state transitions that really matter.

Used carefully, they form a simple and practical approach:

> Understand the domain. Separate commands from queries. Make state transitions explicit. Check the rules that must never break.

That is the heart of it.

Keep the model small. Keep the language clear. Keep the architecture honest.
