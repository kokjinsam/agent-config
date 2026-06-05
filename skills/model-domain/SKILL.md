---
name: model-domain
description: >
  Model a business domain before implementation: discover existing semantic authorities, capture
  bounded-context vocabulary and ownership, separate commands from queries, state variables,
  transitions, invariants, and intentionally abstracted-away details. Treat TLA+ specs as source of
  truth when present and architecture docs as explainers or drift surfaces. Decide whether formal
  modeling is warranted and which TLA+ layer applies, but do not write executable .tla/.cfg files,
  run TLC, or create proofs. Use whenever the user wants to model a domain, design a workflow or
  state machine, reason about invariants, or structure a bounded context.
---

# Model Domain

This skill is the front door for domain design. It turns product or system intent into bounded
context shape: vocabulary, ownership boundary, commands, queries, state variables, transitions,
invariants, and what the model intentionally leaves out.

It owns semantic authority and modeling judgment. It does not own formal execution evidence.

## What this skill is not

- It does not write production code.
- It does not write executable `.tla` or `.cfg` files or run TLC. If the user explicitly asks for
  executable TLA+ work, use `to-tla-spec` when available.
- It does not create or debug `THEOREM`/`PROOF` obligations. If the user explicitly asks for TLAPS
  proof work, use `prove-tla-spec` when available.
- It does not proactively recommend another skill. It may classify a transition as formal-modeling
  worthy, then stop unless the user asks for handoff or executable formal work.

## Source Discovery

Before inventing a model, look for existing sources. Use explicit user-named files first, then search
the repo:

1. `docs/specs/**/*.tla`
2. `.tla/**/*.tla`
3. other `*.tla`
4. architecture docs such as `docs/architecture/**`, ADRs, and `CONTEXT.md`

Treat TLA+ specs as the semantic source of truth when present. Use architecture docs as explainers,
terminology support, or drift surfaces. If prose and TLA+ disagree, proceed from the TLA+ model and
call out the prose drift. If the relevant TLA+ spec is ambiguous, incomplete, or there are competing
specs for the same slice, ask before merging them into a synthetic model.

Architecture-only semantics are candidate semantics until they are mapped to a TLA+ construct or the
user confirms they are intended.

## TLA+ Authority Layers

When existing or proposed TLA+ specs are relevant, classify the layer:

- **Bounded context system spec**: one canonical spec per small bounded context. It owns vocabulary,
  state variables, core transitions, and invariants.
- **Workflow proof spec**: a small projection of a context system spec for a risky workflow or
  transition family. It should say it is a slice of `<ContextSystem>.tla`, reuse names where possible,
  and avoid parallel vocabulary. If it needs semantics missing from the system spec, mark it
  exploratory or flag that the system spec needs an update.
- **Integration spec**: a cross-context coordination model for handoffs, bridges, accepted/rejected
  events, ownership transfer, eventual consistency, duplicate delivery, and similar contracts. It
  must not redefine each context's internals.

If a single system spec is growing into a giant executable architecture document, say so. Either the
bounded context is too broad, or the spec should be decomposed into TLA modules while preserving one
named context-level authority.

For integration spec names, use descriptive relationship names such as
`SalesOrderPaymentAcceptance.tla`, `SalesOrderShippingSchedule.tla`, or `ProtocolActivationHandoff.tla`.
Avoid vague names like `Integration.tla`, `CrossContext.tla`, `Workflow.tla`, or `Bridge.tla`.

## Workflow

Do these in order, looping back as needed:

1. **Capture the domain language.** Use the business's nouns and verbs: "payment must be authorized
   before shipping", "a booking cannot be checked in before it is confirmed". These sentences become
   commands, events, state variables, and invariants.
2. **Scope the bounded context.** Name what the model covers and where it stops. If the slice mixes
   unrelated languages, recommend splitting. If several workflows share state, ask whether to model
   them together, separately with the shared variable called out, or one in scope and the other out.
3. **Separate commands from queries.** Commands express intent and change state
   (`AuthorizePayment`, `ShipOrder`); queries read state for display (`GetOrderSummary`). Commands
   protect invariants. Queries never change business state.
4. **Name state variables.** Prefer state-shaped names over storage-shaped names:
   `orderStatus`, `paymentAuthorized`, `acceptedFullTextAvailable`.
5. **Sketch transitions.** State which command or event moves which variable from which value to
   which value, and which preconditions guard it.
6. **State invariants.** Write flat rules that must hold in every reachable state, not code paths:
   "an order is never shipped unless payment is authorized", "a payment is never captured twice".
7. **Apply the formal-modeling risk gate.** Decide whether the transition is formal-modeling-worthy,
   and which TLA+ layer would own it. Do not write or run the spec here.
8. **List intentionally abstracted-away details.** Call out HTTP, schemas, workers, brokers, auth,
   retries' exact timing, UI, metrics, or anything else deliberately omitted.

## Formal-Modeling Risk Gate

Ask:

> Would a wrong state transition cause serious business, financial, operational, or user harm?

High-risk examples: payment capture, inventory reservation, entitlement grants, booking lifecycles,
ownership transfer, duplicate/retry handling, out-of-order events, worker crashes, partial failures,
and cross-context handoffs.

Low-risk examples: CRUD admin screens, reporting queries, basic settings pages, and workflows where a
wrong transition is easy to detect and undo.

When risk is high, state the call and why: "formal modeling is warranted because duplicate capture
could violate the money-movement invariant." Do not proactively recommend another skill or create
handoff material unless the user asks.

## Optional Handoff Material

Only when the user asks for handoff material, write a compact requirement ledger:

```markdown
| Natural-language rule           | State/action/invariant/property/not modeled |
| ------------------------------- | ------------------------------------------- |
| Payment is never captured twice | invariant: CapturedAtMostOnce               |
| Retry timing                    | not modeled                                 |
```

Include spec layer, authoritative source files, architecture drift notes, environment/failure model,
proposed finite bounds if known, and intentionally abstracted-away details. Do not make this a
required deliverable for normal domain modeling.

## The Architecture Document

The normal deliverable is a concise domain model or architecture note. Detect the repo's conventions
for where docs live and ask if placement is ambiguous. Include:

```markdown
# <Bounded Context> domain model

## Sources

Authoritative TLA+ specs, explanatory architecture docs, and any drift found.

## Bounded context

What this model covers and, importantly, where it stops.

## Ubiquitous language

The domain terms and the business sentences they came from.

## Commands

The intents that change state.

## Queries

The reads, kept separate from commands.

## State variables

The safety-relevant state named in domain language.

## State transitions

Which command or event moves which state from which value to which value.

## Invariants

The rules that must always hold, as flat statements about state.

## Formal-modeling assessment

Whether formal modeling is warranted, which TLA+ layer would own it, and why.

## Intentionally abstracted away

The explicit list of what the model and doc leave out.
```

Keep the model small, the language clear, and the architecture honest.
