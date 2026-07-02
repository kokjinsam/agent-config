---
name: grill-with-docs
description: "Run a relentless cross-sectional design interview that produces verifiable design contracts: small TLA+ models for behavior, small Alloy models for structure, OpenAPI specs for HTTP contracts, and Markdown for rationale, glossary, ADRs, and operating guidance."
---

# Grill With Docs

Run a `/grilling` session. Treat the interview as cross-sectional. Do not choose one artifact type for the whole session. For each resolved decision, classify every affected contract lane.

## Authority

Prefer the strongest checkable artifact that can express the semantics:

- OpenAPI owns HTTP wire contracts: paths, methods, request bodies, response bodies, error envelopes, examples, authentication, authorization-visible errors, and stable `operationId`s.
- TLA+ owns allowed executions: workflows, state transitions, ordering, concurrency, retries, failures, liveness, fairness, and temporal behavior.
- Alloy owns allowed structures: ownership, containment, cardinality, reachability, permissions, tenancy boundaries, cycles, and invalid combinations of state.
- Markdown owns human context: terminology, rationale, trade-offs, examples, ADRs, operating guidance, and links between artifacts.

Markdown may index and explain semantics, but do not make prose the source of truth for a rule that OpenAPI, TLA+, or Alloy can express and validate.

## Contract Ledger

Maintain a live ledger during the interview. For each resolved question or decision, record:

- decision or question
- affected lanes: Markdown, Alloy, TLA+, OpenAPI
- named anchors: TLA+ action/invariant/property, Alloy signature/predicate/assertion, OpenAPI `operationId`, or Markdown section/ADR
- implementation obligations
- verification command
- open questions

Use machine-readable names in the ledger so coding agents can trace the design into implementation and tests.

## Lane Routing

Use `/alloy-spec` when a decision needs a structural model. Keep the model about relationships and constraints, not database implementation details unless persistence structure is the actual risk.

Use `/tla-spec` when a decision needs an execution model. Keep the model about behavior and temporal risk, not full application state.

Use the repository's existing OpenAPI source of truth when a decision affects an HTTP API contract. If no OpenAPI source exists yet, propose the smallest conventional OpenAPI artifact and validation command instead of creating broad new tooling.

Use `/domain-modeling` only for terminology, glossary updates, ADR-worthy rationale, and domain-language conflicts. Do not let glossary or ADR work drive the semantic contract when a checkable lane applies.

## Small Model Discipline

Prefer many small linked formal artifacts over one large model.

For TLA+ and Alloy:

- model only the risk being clarified
- use tiny finite scopes or sets for checking
- abstract values unless identity matters
- name the property, invariant, predicate, or assertion being checked
- record intentional omissions in Markdown
- include the command that checks the model

Avoid formal models that become alternate implementations. A useful model is small enough for an implementation agent to read, run, understand a counterexample from, and map back to code.

## Output Shape

End with a concise design package:

- Markdown index with rationale, vocabulary, operating notes, and traceability links
- focused TLA+ and/or Alloy artifacts when behavior or structure needs checking
- OpenAPI contract changes when the HTTP boundary is affected
- implementation obligations and validation commands tied to named anchors
