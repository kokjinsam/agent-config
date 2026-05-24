---
name: domain-modeling
description: >
  Model a business domain before implementing: capture the ubiquitous language, scope the bounded
  context, separate commands from queries (CQRS), state the invariants, sketch state transitions,
  and — only for risky transitions — check them with a small TLA+ spec run through TLC. Produces
  an architecture document and, when warranted, .tla/.cfg files; does NOT write implementation.
  Use whenever the user wants to model a domain, design a workflow or state machine, reason about
  invariants, or decide whether a transition is safe under retries/concurrency/partial failure —
  even when they don't name DDD, CQRS, or TLA+ explicitly.
---

# Domain Modeling with State Machines, CQRS, and TLA+

This skill is a **thinking discipline for design time**, used before code exists or before changing
the rules of code that does. It answers one question well:

> Given this command, in this state, what is the system allowed to do next — and can any weird
> sequence of events break a rule that must never break?

It deliberately stops at the design check. It produces an **architecture document** and, for the
risky parts, a **TLA+ spec checked by TLC**. It does **not** generate any implementation code.

## What this skill is not

- It does not interview the user on its own. It is a guideline for _how to model_.
- It does not write production code. The TLA+ spec is a design artifact, not a blueprint to
  transliterate line by line.
- It does not model the whole system. See "Model the correctness argument, not the implementation".

## The workflow

These steps mirror how the domain reveals itself; do them in order but loop back freely.

1. **Capture the domain language.** Write down the exact sentences the business uses: "payment must
   be authorized before shipping", "an order can't be cancelled after it ships". These are not just
   requirements — they are the raw material for commands, events, and invariants. Use the business's
   nouns and verbs, not CRUD.

2. **Scope the bounded context.** Decide where this model applies and where it stops. One invocation
   models **whatever slice the user names** — a whole context, a single workflow lifecycle, or one
   risky transition. But if the user's slice quietly mixes unrelated domains (e.g. pricing rules
   tangled with shipment tracking) into one model, **say so and recommend splitting** — a model that
   spans two languages is a model nobody trusts. If the slice spans multiple workflows that share
   state (e.g. an order workflow and an inventory workflow both touching a reservation), **stop and
   ask the user which scope they want** — model them together, model them separately with the shared
   variable called out, or model one and treat the other as out of scope. Name the boundary
   explicitly in the doc.

3. **Separate commands from queries (CQRS).** Commands express intent and change state
   (`PlaceOrder`, `AuthorizePayment`, `ShipOrder`); queries read state for display
   (`GetOrderSummary`, `ListTodaysBookings`). Keep them apart because they answer different questions
   — _is this action allowed?_ vs _what should the user see?_ — and conflating them is how invariants
   end up enforced in a read path or skipped entirely. Commands protect invariants and change state;
   queries never change business state.

4. **State the invariants.** These are the rules that must hold in _every_ reachable state, e.g. "an
   order is never shipped unless payment is authorized", "a payment is never captured twice", "an
   order is never both shipped and cancelled". Write them as flat statements about state, not about
   code paths — they are the properties TLA+ will check.

5. **Sketch the state transitions.** Name the state variables first (e.g.
   `order_status: pending|paid|shipped|cancelled`, `payment_captured: bool`), then — in plain
   language or a small diagram — lay out the lifecycle: which states exist, which command moves
   which state to which. This is already a state machine; you are just making it explicit. Naming
   the variables up front is what lets the invariants and any TLA+ spec downstream stay precise
   instead of hand-wavy.

6. **Decide whether this needs TLA+ (risk gate).** See the next section. Most slices stop here with a
   good doc. Some earn a spec.

7. **If warranted, write and check a TLA+ spec.** Follow `references/tla-plus.md`. Keep it tiny, run
   it through TLC, and iterate on any violation.

8. **Document what was abstracted away.** Whatever the model leaves out (HTTP, schemas, brokers,
   auth, retries' exact timing) gets listed explicitly, so a reader knows what confidence the model
   does and doesn't give.

## The risk gate: when to reach for TLA+

Judge this yourself using the article's test, and **tell the user the call you made and why** — don't
silently skip it or silently spend a day on a spec.

> Would a wrong state transition cause serious business, financial, operational, or user harm?

- **Yes** → the transition is worth modeling. Payment capture, inventory reservation, entitlement
  grants, booking lifecycles, distributed process managers, anything where a duplicate/retry/crash
  could double-charge, double-book, or strand state.
- **No** → stop at the architecture doc. A CRUD admin screen, a reporting query, a settings page does
  not need a formal model, and adding one is just ceremony.

The signal that pushes toward TLA+ is **non-obvious sequences**: retries, duplicate commands,
out-of-order or delayed events, concurrent requests, worker crashes, partial failures. A diagram
shows the happy path; TLA+ answers "is there _any_ path that breaks the rule?". If the only risk is
the happy path, you don't need it.

When you do model, default to **safety properties** (a bad state is never reachable) — that is where
most of the value is. Add a **liveness/temporal** property only when the domain has a real "eventually"
obligation worth guaranteeing (e.g. "an authorized payment is eventually captured or voided"), since
liveness needs fairness conditions and adds real complexity. Let the risk decide, not reflex.

## Model the correctness argument, not the implementation

This is the single most important constraint on the TLA+ part. Model the **smallest** state that lets
you state and check the invariant — typically a handful of booleans/enums like `orderShipped`,
`paymentAuthorized`. Leave out HTTP, database schemas, ORM mappings, broker internals, serialization,
auth, logging, metrics, deployment, and exact retry backoff — unless one of those _directly_ affects
the property you're checking.

Strong default: keep the spec **under ~100 lines** (excluding comments), few variables, coarse atomic
steps. Introduce finer interleavings only when that interleaving is the very risk you're studying. You
_may_ exceed 100 lines, but only with a stated reason — a small model people understand beats a large
one nobody reads. Always end the doc with the explicit list of what you abstracted away.

## Writing and running TLA+

Full guidance — the spec template, naming, the TLC runner, bounding strategy, and a worked example —
lives in **`references/tla-plus.md`**. Read it before writing a spec. The essentials:

- **Pure TLA+**, structured as `constants / variables / TypeOK / Init / actions / Next / Spec` plus
  2–4 named invariants. Clear names, no abbreviations, comments explaining intent.
- **Run with TLC 1.8.0** via `scripts/run_tlc.sh <spec.tla>`, which finds `tla2tools.jar` (via the
  `TLA2TOOLS_JAR` env var, then common locations), **verifies the version and warns** if it isn't
  1.8.0, and invokes `java -jar`. Each spec needs a sibling `.cfg` naming the constants, the
  `SPECIFICATION`, and the `INVARIANT`s.
- **Bound the model per property.** TLC needs finite constants. Choose the _smallest_ bound that can
  still exhibit the risky interleaving you care about (often 1–2 of each entity is enough to surface a
  double-capture or a ship-before-pay), and write a one-line justification in the `.cfg` for why that
  bound suffices. Bigger isn't safer; it's just slower.

## When TLC reports a violation

A counterexample is a gift — TLC just handed you a concrete sequence that reaches a forbidden state.
Treat it as **a likely real design flaw first**: surface the trace prominently and walk the user
through the exact steps that break the rule, because that is usually a genuine bug the implementation
would have inherited.

Then **classify it explicitly** before changing anything:

- **(a) a real domain-rule gap** — the design genuinely allows a bad transition; fix the _design_ (add
  a guard, reorder a transition) and re-check.
- **(b) an over-strict invariant** — the rule as written forbids something the business actually
  allows; correct the _invariant_, but flag it loudly so the user agrees the rule was wrong.
- **(c) a modeling artifact** — the spec mis-models reality (a missing precondition on an action, a
  bad initial state); fix the _model_.

**Never silently weaken or delete an invariant to make a check pass.** Relaxing a rule is a design
decision the user must see and approve — quietly turning a red check green destroys the only thing the
spec was for.

## The architecture document

The deliverable for every invocation (TLA+ or not). It need not be long or formal. Detect the repo's
conventions for where docs live and **ask if it's ambiguous** rather than guessing — alongside the
code, a `docs/` tree, or a dedicated specs directory; mirror what the project already does. Include:

```markdown
# <Bounded Context> domain model

## Bounded context

What this model covers and, importantly, where it stops.

## Ubiquitous language

The domain terms and the business sentences they came from.

## Commands

The intents that change state.

## Queries

The reads, kept separate from commands.

## State transitions

The state variables, and the lifecycle — plain language or a small diagram —
showing which command moves which state to which.

## Invariants

The rules that must always hold, as flat statements about state.

## TLA+ model

Link to the .tla/.cfg if one exists, plus a short note: which properties
were checked and what the model abstracts away. (Omit if no spec was warranted.)

## Intentionally abstracted away

The explicit list of what the model and doc leave out.
```

Keep the model small, the language clear, and the architecture honest.
