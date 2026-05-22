# Writing and running TLA+ for domain modeling

This is the deep guide for the TLA+ part of the `domain-modeling` skill. Read it before writing a
spec. The governing principle from the parent skill still holds: **model the correctness argument,
not the implementation.** A small spec people understand beats a large one nobody reads.

## Table of contents

- [The spec template](#the-spec-template)
- [Naming and readability](#naming-and-readability)
- [Bounding the model per property](#bounding-the-model-per-property)
- [Safety vs liveness](#safety-vs-liveness)
- [The .cfg file](#the-cfg-file)
- [Running TLC 1.8.0](#running-tlc-180)
- [Reading TLC output](#reading-tlc-output)
- [A worked example: order lifecycle](#a-worked-example-order-lifecycle)

## The spec template

Always use pure TLA+ (not PlusCal) for these design checks — the explicit action structure maps
directly onto domain transitions and stays readable. Structure every spec the same way so they're
easy to scan:

```
constants     -- the finite sets / parameters TLC will fill in
variables     -- the smallest state that lets you state the invariant
TypeOK        -- a typing invariant: each variable stays in its expected domain
Init          -- the initial state
actions       -- one operator per domain command/transition
Next          -- disjunction of all actions
Spec          -- Init /\ [][Next]_vars  (plus fairness only if checking liveness)
invariants    -- 2-4 named safety properties, the reason the spec exists
```

Keep it under ~100 lines excluding comments. Prefer few variables and coarse atomic steps; only split
a transition into finer interleavings when that interleaving is the exact risk you're studying (e.g.
modeling a crash *between* "mark shipped" and "emit event" because the gap is where the bug hides).

## Naming and readability

- Spell things out: `paymentAuthorized`, not `pa`. The spec is communication, not golf.
- One action operator per domain command, named after the command: `ShipOrder`, `CapturePayment`.
- Comment generously. Each action should say, in a line of prose, what business transition it is and
  what its precondition is. Each invariant should restate the domain rule in English above it.
- Open the module with a comment block stating what the model includes, what it ignores, and which
  properties it checks — the same list that goes in the architecture doc's "abstracted away" section.

## Bounding the model per property

TLC explores a finite state space, so every constant must be bounded. The discipline:

> Choose the smallest bound that can still exhibit the risky interleaving, and justify it.

For most order/payment/booking invariants, **1–2 of each entity is enough**. A double-capture bug
shows up with a single payment and two capture attempts; a ship-before-pay bug shows up with one
order. You rarely need 5 orders to find a state-machine flaw — extra entities just multiply states and
slow TLC without finding anything new. Where the domain is symmetric over a set of identical entities,
use a TLC `SYMMETRY` set to collapse equivalent states.

Write a one-line comment in the `.cfg` explaining why the chosen bound suffices for the property —
this is the bounding justification, and it's what a reviewer checks.

## Safety vs liveness

Default to **safety**: `Spec == Init /\ [][Next]_vars` with `INVARIANT`s in the `.cfg`. Safety
properties ("a bad state is never reachable") cover the vast majority of domain risks and need no
fairness reasoning.

Add a **liveness/temporal** property only when the domain has a genuine "eventually" obligation worth
guaranteeing — e.g. "an authorized payment is eventually captured or voided". Liveness requires:

- weak/strong fairness on the relevant actions in `Spec` (e.g. `/\ WF_vars(CapturePayment)`),
- a `PROPERTY` line in the `.cfg` pointing at the temporal formula (e.g.
  `Liveness == paymentAuthorized ~> (paymentCaptured \/ paymentVoided)`).

Don't add liveness reflexively — fairness conditions are subtle and a wrong one produces false
confidence. Let the risk justify it.

## The .cfg file

Each `<Name>.tla` needs a sibling `<Name>.cfg`. Minimal safety config:

```
\* Why this bound: one order + one payment is enough to reach every
\* shipped/cancelled/captured combination this invariant cares about.
CONSTANTS
    MaxCaptureAttempts = 2

SPECIFICATION Spec

INVARIANT TypeOK
INVARIANT ShipImpliesPaid
INVARIANT NeverShippedAndCancelled
INVARIANT CapturedAtMostOnce
```

For symmetric entity sets, declare model values in the `.cfg` but define the symmetry **as an
operator in the spec** — TLC does not accept `Permutations(...)` inline in the config, and there is
no `=` after `SYMMETRY`. In the `.tla`:

```tla
EXTENDS TLC                 \* Permutations comes from the TLC module
Symmetry == Permutations(Orders)
```

In the `.cfg`:

```
CONSTANT Orders = {o1, o2}
SYMMETRY Symmetry
```

(Writing `SYMMETRY = Permutations(Orders)` directly in the `.cfg` is a common mistake — TLC rejects
it with a config-file syntax error.)

## Running TLC 1.8.0

Use the bundled runner; don't hand-roll the java invocation each time:

```bash
scripts/run_tlc.sh path/to/Spec.tla            # uses sibling Spec.cfg
scripts/run_tlc.sh path/to/Spec.tla Other.cfg  # explicit config
```

The script locates `tla2tools.jar` (checking `TLA2TOOLS_JAR` first, then common install locations),
**surfaces the TLC version banner** (this skill targets the v1.8.0 release), and runs
`java -jar tla2tools.jar -config <cfg> -deadlock <spec>` from the spec's directory. If the jar can't
be found it prints how to set `TLA2TOOLS_JAR` and where to download 1.8.0, then exits.

Be aware: the TLC engine reports a **date-based** version (e.g. `TLC2 Version 2026.05.18.x`), not the
literal string `1.8.0` — so the runner prints the detected banner for you to eyeball rather than
matching a version string that never appears. As long as the jar comes from the v1.8.0 release, that
date banner is expected and not a problem.

Note on `-deadlock`: by default TLC reports a deadlock (no enabled next action) as an error. For a
domain lifecycle, reaching a terminal state (e.g. `Delivered`) is *not* a bug — it's the end of the
story. The runner passes a flag to disable deadlock-as-error by default so terminal states don't show
up as false violations. If you specifically want to check that the workflow can always make progress,
re-run without it and reason about each reported deadlock.

## Reading TLC output

- **No errors** → every reachable state satisfied every invariant within the bound. State the bound
  when you report this; it's "checked up to N", not "proven for all N".
- **"Invariant X is violated"** followed by a trace → TLC found a reachable state breaking X and prints
  the shortest sequence of states that reaches it. This is the counterexample. Walk it step by step:
  each state shows the variable values, and the action between states is the command that fired. Map
  that sequence back to the domain ("place, authorize, ship, then a duplicate ship") and apply the
  classification from the parent skill — real gap, over-strict invariant, or modeling artifact — before
  changing anything, and never silently weaken the invariant.
- **Parse/semantic errors** → the spec itself is malformed; fix syntax before drawing any conclusions.

## A worked example: order lifecycle

Rule under test: *an order is never shipped unless payment is authorized*, and *an order is never both
shipped and cancelled*. This is the canonical small model — note how little state it needs.

`Order.tla`:

```tla
-------------------------------- MODULE Order --------------------------------
(***************************************************************************)
(* Models the safety-relevant state of a single order's lifecycle.         *)
(*                                                                         *)
(* INCLUDES: whether the order is placed, payment authorized/captured,     *)
(*           shipped, cancelled.                                           *)
(* IGNORES:  HTTP, database schema, message broker, serialization, auth,   *)
(*           logging, metrics, deployment, retry timing. Capture retries   *)
(*           are modeled abstractly via MaxCaptureAttempts.                *)
(* CHECKS:   ShipImpliesPaid, NeverShippedAndCancelled, CapturedAtMostOnce.*)
(***************************************************************************)
EXTENDS Naturals

CONSTANT MaxCaptureAttempts   \* abstract bound on duplicate capture commands

VARIABLES
    placed,             \* TRUE once the order has been placed
    authorized,         \* TRUE once payment is authorized
    captureCount,       \* how many times capture has succeeded
    shipped,            \* TRUE once the order is shipped
    cancelled           \* TRUE once the order is cancelled

vars == <<placed, authorized, captureCount, shipped, cancelled>>

TypeOK ==
    /\ placed \in BOOLEAN
    /\ authorized \in BOOLEAN
    /\ captureCount \in 0..MaxCaptureAttempts
    /\ shipped \in BOOLEAN
    /\ cancelled \in BOOLEAN

Init ==
    /\ placed = FALSE
    /\ authorized = FALSE
    /\ captureCount = 0
    /\ shipped = FALSE
    /\ cancelled = FALSE

\* A customer places the order.
PlaceOrder ==
    /\ ~placed
    /\ placed' = TRUE
    /\ UNCHANGED <<authorized, captureCount, shipped, cancelled>>

\* Payment is authorized; only meaningful once placed and not cancelled.
AuthorizePayment ==
    /\ placed
    /\ ~cancelled
    /\ ~authorized
    /\ authorized' = TRUE
    /\ UNCHANGED <<placed, captureCount, shipped, cancelled>>

\* Capture funds. Guarded so it can never succeed more than once, even if the
\* command arrives repeatedly (duplicate/retry). The guard is the design rule.
CapturePayment ==
    /\ authorized
    /\ captureCount = 0
    /\ captureCount' = captureCount + 1
    /\ UNCHANGED <<placed, authorized, shipped, cancelled>>

\* Ship the order. Precondition encodes "never ship before payment authorized".
ShipOrder ==
    /\ authorized
    /\ ~cancelled
    /\ ~shipped
    /\ shipped' = TRUE
    /\ UNCHANGED <<placed, authorized, captureCount, cancelled>>

\* Cancel the order; only allowed before it ships.
CancelOrder ==
    /\ placed
    /\ ~shipped
    /\ ~cancelled
    /\ cancelled' = TRUE
    /\ UNCHANGED <<placed, authorized, captureCount, shipped>>

Next ==
    \/ PlaceOrder
    \/ AuthorizePayment
    \/ CapturePayment
    \/ ShipOrder
    \/ CancelOrder

Spec == Init /\ [][Next]_vars

\* ---- Invariants: the rules that must hold in every reachable state ----

\* An order is never shipped unless payment has been authorized.
ShipImpliesPaid == shipped => authorized

\* An order is never both shipped and cancelled.
NeverShippedAndCancelled == ~(shipped /\ cancelled)

\* A payment is never captured more than once.
CapturedAtMostOnce == captureCount <= 1
=============================================================================
```

`Order.cfg`:

```
\* Why this bound: a single order with at most 2 capture attempts is enough to
\* exercise every shipped/cancelled/captured combination these invariants test;
\* more attempts or more orders add states without reaching new rule violations.
CONSTANT MaxCaptureAttempts = 2

SPECIFICATION Spec

INVARIANT TypeOK
INVARIANT ShipImpliesPaid
INVARIANT NeverShippedAndCancelled
INVARIANT CapturedAtMostOnce
```

Run it:

```bash
scripts/run_tlc.sh Order.tla
```

To *demonstrate* the tool catching a real flaw, try removing the `~cancelled` guard from `ShipOrder`:
TLC then finds a trace `PlaceOrder → AuthorizePayment → CancelOrder → ShipOrder` that reaches
`shipped = TRUE /\ cancelled = TRUE`, violating `NeverShippedAndCancelled`. That trace is exactly the
kind of bug a happy-path diagram hides — and exactly why the model is worth writing for a risky flow.
