---
name: event-driven-frontend
description: Apply event-driven frontend architecture using state-machine actors. Use this skill whenever the user is building or refactoring UI workflows, working with XState/state machines/actors, deciding where workflow logic should live, designing how UI components talk to APIs, structuring server synchronization (refresh bootstrapping, snapshot/job polling, revisions, idempotency keys), naming UI events, or asking questions like "where should this state go", "should this be in the component", "how do I handle loading/error/retry across this flow", "how do I survive a refresh", or "how do I poll a long-running job from the UI". Trigger even when the user does not explicitly say "state machine" — if they describe multi-step UI flows, async operations with loading/error/retry, long-running jobs, or coordination between components, this skill applies.
---

Use events as the **interface between intent and behavior**. UI components translate user interactions into semantic events sent to specific actors. Actors own workflow state, call APIs, and react to server responses as events.

## 1. The core mental model

```
UI event → specific actor → API call → server response → machine event → transition
```

Frontend machines own **workflow/control state** (current step, loading, selected item, modal, draft, retry). The server owns **durable domain truth** (users, permissions, orders, decisions, job state). Never confuse the two.

When in doubt, ask:

- Who owns this fact or workflow?
- Durable domain truth → server.
- Workflow/control state → actor.
- Crosses contexts → workflow module (backend) or parent actor (frontend).

## 2. UI components emit events; they do not own workflows

A UI handler should translate a user interaction into a domain-relevant event and stop there. The component should not orchestrate API calls, mutate counts, pick the next item, or run multi-step logic.

Prefer:

```tsx
<button
  onClick={() =>
    approvalActor.send({
      type: "APPROVAL_DECISION_SUBMITTED",
      itemId,
      decision: "approved",
      note,
    })
  }
>
  Approve
</button>
```

Avoid stuffing the workflow inside the component:

```tsx
<button onClick={async () => {
  setSaving(true)
  await api.saveDecision(...)
  updateCounts(...)
  loadNextItem(...)
  showToast(...)
  setSaving(false)
}}>
  Approve
</button>
```

The component sends an event and renders the actor's snapshot. The actor decides what happens next.

## 3. Prefer specific actors over a global event bus

Route events through explicit actor refs and parent/child relationships. A global event bus where "anyone can subscribe to anything" creates invisible control flow and makes consumers undiscoverable.

Avoid:

```
globalEventBus.emit("MEMBER_INVITED")
  → unknown subscriber A, B, C
```

Prefer:

```
membersActor → workspaceActor → notificationActor
```

A global log can still be useful for debugging or analytics — it just should not be the primary control mechanism.

## 4. Recommended actor hierarchy

Start with what the app actually needs. A useful generic shape:

```
appActor
├── sessionActor
├── routeActor
├── serverSyncActor
├── notificationActor
└── domainAreaActor(areaId)        // workspace, project, org, store, case…
    ├── settingsActor
    ├── membersActor
    ├── listActor
    ├── detailActor(itemId)
    ├── workflowActor(workflowId)  // approval, checkout, import, publish…
    └── jobsActor
```

Smaller starting point is fine:

```
appActor
├── sessionActor
├── activeAreaActor
└── notificationActor
```

Split actors when a workflow has meaningful states, async work, retries, permissions, or child workflows.

## 5. Machine boundary rules

Create a separate machine when the thing has any of:

- multiple meaningful states
- async work with loading / error / retry
- permissions or domain rules
- side effects
- child workflows
- long-running jobs
- collaboration / conflict behavior

Do **not** create a separate machine just because there is a component. Buttons, headers, labels, presentational cards do not need their own machines.

Usually yes: auth/session, organization/workspace/project session, approval workflow, checkout, import, member invitation, conflict resolution, publishing, long-running jobs.

Usually no: plain button, static header, simple label, presentational card.

## 6. Event naming

Use names that reflect **domain intent** for user actions, and **facts/acknowledgements** for server-originated events. Past-tense or "\_RECEIVED" / "\_CONFIRMED" suffixes signal facts.

User intent (good):

```ts
{
  type: "FORM_SUBMITTED";
}
{
  type: "ITEM_SELECTED";
}
{
  type: "MEMBER_INVITE_SUBMITTED";
}
{
  type: "APPROVAL_DECISION_SUBMITTED";
}
{
  type: "CHECKOUT_SUBMITTED";
}
{
  type: "IMPORT_FILE_SELECTED";
}
```

Implementation noise (avoid):

```ts
{
  type: "BUTTON_CLICKED";
}
{
  type: "CALL_API";
}
{
  type: "SET_LOADING_TRUE";
}
{
  type: "DO_SUBMIT";
}
```

Server facts (good):

```ts
{
  type: "SERVER_SNAPSHOT_RECEIVED";
}
{
  type: "SAVE_CONFIRMED";
}
{
  type: "JOB_STATUS_RECEIVED";
}
{
  type: "BOOTSTRAP_RECEIVED";
}
{
  type: "PERMISSIONS_REFRESHED";
}
```

Why this matters: domain-named events let you change the implementation (button → keyboard shortcut → drag) without renaming the event, and they make the state chart readable as a description of the workflow.

## 7. Treat server responses as machine events

Mutations should return enough server facts for the actor to transition correctly. The frontend wraps the response into an event rather than mutating context piecemeal.

Good response (lets the actor transition without guessing):

```json
{
  "itemId": "item_123",
  "decision": "approved",
  "revision": 43,
  "nextItemId": "item_124",
  "summary": {
    "completedCount": 248,
    "remainingCount": 552,
    "conflictCount": 12
  }
}
```

Frontend:

```ts
approvalActor.send({
  type: "APPROVAL_DECISION_SAVE_CONFIRMED",
  result,
});
```

Avoid responses like `{ "ok": true }` for anything where the UI must transition based on the server's view. Do not make the frontend recompute counts, infer the next item, or guess at conflicts — ask the server to say what happened.

## 8. Surviving a page refresh

A refresh destroys the actor system. Rebuild it from stable inputs:

```
URL → routeActor parses params and view
session → sessionActor loads current user
GET /api/.../bootstrap → child actors start from facts
active workflow actor enters the correct state
```

Bootstrap endpoints should answer: who is the user, what can they do, what resource is active, what is its status, what workflow phase is active, what jobs are running, what revision is current, what summary data is needed for first paint.

Local persistence rules:

- **Safe locally:** collapsed sidebar, selected tab, unsaved draft, temporary filters, wizard step.
- **Never locally:** roles/permissions, decisions, payments, membership, completion status, job status, billing, canonical settings.

Anything the server is authoritative about must come from the server on refresh. Do not "restore" durable domain state from local storage — it will drift and you will ship a bug.

## 9. Polling: snapshots and jobs

You do not need a server event feed to keep the UI fresh. Snapshot polling plus revision handling is usually enough.

Snapshot polling:

```
GET /api/resources/:id/snapshot
  → resourceActor.send({ type: "SERVER_SNAPSHOT_RECEIVED", snapshot })
```

Long-running jobs are durable on the server. The actor reflects status:

```
POST /api/jobs                        → JOB_CREATED
GET  /api/jobs/:job_id (poll)         → JOB_STATUS_RECEIVED / JOB_COMPLETED / JOB_FAILED
bootstrap includes active jobs        → spawn jobActor(job_id), polling resumes
```

## 10. Revisions and idempotency

Polling responses can arrive out of order. Mutations can be retried. Both need stable ordering and de-duplication.

Include a stable ordering field on every snapshot/response: `revision`, `updatedAt`, `serverCursor`, `lockVersion`, or `etag`. Frontend rule:

```
incoming revision <= current → ignore as stale
incoming revision >  current → apply
```

For risky mutations, include `clientMutationId` and `expectedRevision`:

```ts
{
  type: "APPROVAL_DECISION_SUBMITTED",
  itemId: "item_123",
  decision: "approved",
  clientMutationId: "mut_abc123",
  expectedRevision: 17
}
```

This lets the server safely handle retries and surface conflicts as a real result instead of a silent overwrite.

## 11. Worked example: approval workflow

User action:

```ts
approvalActor.send({
  type: "APPROVAL_DECISION_SUBMITTED",
  itemId: "item_123",
  decision: "approved",
  note: "Looks good",
});
```

Machine flow:

```
reviewing → savingDecision → loadingNextItem → reviewing
```

Server response becomes an event:

```ts
approvalActor.send({
  type: "APPROVAL_DECISION_SAVE_CONFIRMED",
  result: { itemId, decision, revision, nextItemId, summary },
});
```

The component sends one event and renders the snapshot. It does not update counts, pick the next item, or decide conflict UI — the actor reads the server fact and transitions.

## 12. Worked example: long-running import

```ts
importActor.send({ type: "IMPORT_FILE_SUBMITTED", fileId });
```

Flow:

```
idle → creatingJob → running(jobId) → completed
```

Polling response:

```ts
importActor.send({
  type: "IMPORT_JOB_STATUS_RECEIVED",
  job: { id: "job_123", status: "running", progress: 64 },
});
```

On refresh, bootstrap returns the active job and the parent actor spawns `jobActor(job_id)` so polling resumes seamlessly.

## 13. Anti-patterns (do not do these)

- Global event bus controls everything.
- UI components contain long imperative workflows.
- Every component gets its own machine.
- Frontend machine is treated as canonical server state.
- Local storage restores permissions or durable domain data.
- Polling directly mutates machine context instead of sending an event.
- Mutation response is too small, forcing the frontend to guess server consequences.
- Machine context becomes a giant database cache.
- Event names describe widgets (`BUTTON_CLICKED`) instead of intent.

## 14. Quick checklist before shipping a workflow

- [ ] Component sends one semantic event; no business logic in the handler.
- [ ] Workflow lives in an actor with explicit states.
- [ ] Server response is wrapped as a single event with enough facts to transition.
- [ ] Bootstrap reconstructs the workflow's state on refresh.
- [ ] Active jobs survive refresh via bootstrap + polling.
- [ ] Snapshot/poll responses carry a revision; stale responses are dropped.
- [ ] Risky mutations include `clientMutationId` and `expectedRevision`.
- [ ] Local storage holds only safe UI state, never durable domain truth.
- [ ] Event names describe domain intent or server facts, not widgets or implementation.
