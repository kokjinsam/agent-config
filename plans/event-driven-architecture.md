# Event-Driven Application Architecture Guide

**Audience:** product engineers, frontend engineers, backend engineers, technical leads, architects, and coding agents.

**Scope:** practical event-driven application architecture across frontend state machines, backend bounded contexts, workflow orchestration, server synchronization, polling, domain events, transactional consistency, audit logging, PubSub/live updates, and async side effects.

**Applies to:** SaaS products, internal tools, marketplaces, collaboration platforms, workflow systems, admin consoles, document systems, commerce systems, data platforms, and other web applications.

**Position:** use event-driven structure where it improves clarity, testability, auditability, and workflow control. Do **not** assume this requires full event sourcing, a global frontend event bus, a backend event stream, or a major server rewrite.

---

## 1. Executive Summary

Use events as the **interface between intent and behavior**.

On the frontend, UI components should translate user interactions into semantic events sent to specific state-machine actors. Actors own workflow state, call APIs, react to server responses, and coordinate child actors. Avoid using a global event bus as the main control mechanism.

On the backend, bounded contexts should own domain rules. Workflow/application-service modules should orchestrate use cases across contexts. Command operations may produce domain events as facts. Mandatory consistency, such as audit logging, must be handled inside the database transaction. PubSub and after-commit dispatch should be used only for live UI/process notification or other non-critical reactions.

The core architecture is:

```txt
Frontend:
  UI event → specific actor/state machine → API call → server response → machine event → transition

Refresh:
  URL + session + server bootstrap/snapshot → reconstructed actor tree

Polling:
  server snapshot/job status → frontend machine event → explicit actor transition

Backend:
  Controller/LiveView → workflow module → bounded contexts → database transaction
                                               ↓
                                  transactional event consumers
                                               ↓
                               after-commit notifications/jobs
```

This architecture is useful because it answers:

```txt
Who owns this behavior?
Who is allowed to react to this event?
What must be transactionally consistent?
What can be eventually consistent?
What is only a UI convenience?
```

---

## 2. Shared Vocabulary

### Event

An event is a message describing either an **intent** or a **fact**.

Frontend user-intent events:

```txt
FORM_SUBMITTED
ITEM_SELECTED
MEMBER_INVITE_SUBMITTED
SETTINGS_FORM_SUBMITTED
IMPORT_FILE_SELECTED
APPROVAL_DECISION_SUBMITTED
CHECKOUT_STARTED
```

Frontend server-fact events:

```txt
SERVER_SNAPSHOT_RECEIVED
SAVE_CONFIRMED
JOB_STATUS_RECEIVED
BOOTSTRAP_RECEIVED
PERMISSIONS_REFRESHED
```

Backend domain-fact events:

```txt
MemberInvited
SettingsChanged
ApprovalDecisionRecorded
JobCreated
JobCompleted
OrderPlaced
PaymentCaptured
DocumentSubmitted
ConflictDetected
```

Backend domain events should usually be named in past tense because they describe facts that already happened.

Good:

```elixir
%MemberInvited{}
%SettingsChanged{}
%ApprovalDecisionRecorded{}
%OrderPlaced{}
%JobCreated{}
```

Avoid command-like event names:

```elixir
%SendInviteEmail{}
%CreateAuditLog{}
%CallExternalApi{}
%UpdateProgress{}
```

Those are instructions, not domain facts.

---

### Command

A command is a request to do something.

Examples:

```txt
Invite member
Submit approval decision
Start import
Change settings
Place order
Capture payment
Resolve conflict
Publish document
```

A command may fail due to authorization, validation, stale data, concurrency conflict, external constraint, or domain invariant.

---

### State Machine / Actor

A state machine instance is an actor with:

```txt
state
context
event inbox
side effects
child actors
```

An actor receives events and decides what happens next based on its current state.

Example:

```txt
current state + event = next state + actions
```

```txt
editing + FORM_SUBMITTED = saving
saving + SAVE_CONFIRMED = saved
saving + SAVE_FAILED = error
error + RETRY_CLICKED = saving
```

---

### Bounded Context

A bounded context is a backend module boundary that owns a set of domain rules and data operations.

Examples:

```txt
Accounts
Workspaces
Projects
Documents
Orders
Payments
Inventory
Approvals
Imports
Notifications
ActivityLog
Billing
```

A bounded context should expose public functions that enforce its own invariants. Other contexts should not reach into its private tables, schemas, or internal modules.

---

### Workflow / Application Service

A workflow module coordinates one use case across one or more bounded contexts.

Examples:

```elixir
MyApp.Workflows.InviteMember
MyApp.Workflows.SubmitApprovalDecision
MyApp.Workflows.StartImport
MyApp.Workflows.PlaceOrder
MyApp.Workflows.CapturePayment
MyApp.Workflows.PublishDocument
```

A workflow is the right place for cross-context orchestration.

---

## 3. Foundational Principles

### 3.1 UI Should Emit Events, Not Own Business Workflows

A UI handler should usually translate user interaction into a domain-relevant event.

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

Avoid putting the entire workflow inside the component:

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

The component should not own the business workflow. The actor should.

---

### 3.2 Prefer Specific Actors Over a Global Event Bus

Do not make every machine subscribe to a global stream by default.

Avoid:

```txt
globalEventBus.emit("MEMBER_INVITED")
  → unknown subscriber A
  → unknown subscriber B
  → unknown subscriber C
```

Prefer explicit routing:

```txt
membersActor
  → workspaceActor
  → notificationActor
  → live-update layer if needed
```

A global log can be useful for debugging, analytics, or audit. It should not become the primary control mechanism.

---

### 3.3 Server Is Source of Truth for Durable Domain State

The frontend state machine is not the database.

Server owns durable domain truth:

```txt
users
memberships
roles
permissions
orders
payments
documents
records
approval decisions
job state
billing state
canonical settings
```

Frontend machines own workflow/control state:

```txt
current step
loading/saving/error state
selected item
active tab
modal state
local form validation
local draft state
retry state
optimistic mutation state
```

On refresh, reconstruct machines from route, session, server data, and optional safe local UI snapshots.

---

### 3.4 Required Consistency Must Be Transactional

Do not rely on after-commit event dispatch for mandatory work.

If an audit log is mandatory, write it in the same transaction as the domain change.

```txt
Record domain change
Write audit log
Insert required job/outbox rows
Commit all together
```

After-commit dispatch is only for non-critical notification, such as PubSub broadcasts to connected clients.

---

### 3.5 External Side Effects Should Not Run Inside DB Transactions

Do not send emails, call external APIs, send webhooks, upload files, or broadcast PubSub messages inside a database transaction if correctness depends on rollback behavior.

Instead:

```txt
Inside transaction:
  insert domain row
  insert audit row
  insert job/outbox row

After commit:
  worker sends email/webhook/API call
  PubSub tells connected clients to refresh
```

---

### 3.6 Events Should Reduce Hidden Coupling, Not Create It

Events are helpful when they make facts explicit and consumers discoverable.

They are harmful when they become invisible control flow.

Good:

```txt
Workflow explicitly composes domain operation + audit + job insert.
Handler registry shows who reacts to each event.
PubSub is used only for live UI notification.
```

Bad:

```txt
A context secretly publishes an event.
Unknown subscribers perform critical business behavior.
No one can tell which code reacts to an event.
```

---

## 4. Frontend Architecture

### 4.1 Recommended Actor Hierarchy

A useful generic actor hierarchy is:

```txt
appActor
├── sessionActor
├── routeActor
├── serverSyncActor
├── notificationActor
└── domainAreaActor(areaId)
    ├── settingsActor
    ├── membersActor
    ├── listActor
    ├── detailActor(itemId)
    ├── workflowActor(workflowId)
    ├── importJobsActor
    └── integrationsActor
```

Examples of domain area actors:

```txt
workspaceActor
projectActor
organizationActor
accountActor
storeActor
teamActor
caseActor
orderActor
```

Start smaller if needed:

```txt
appActor
├── sessionActor
├── activeAreaActor
└── notificationActor
```

Split actors when a workflow has meaningful states, async work, retries, permissions, or child workflows.

---

### 4.2 Machine Boundary Rules

Create a separate machine when the thing has:

```txt
multiple states
async work
loading/error/retry behavior
permissions
domain rules
side effects
child workflows
long-running jobs
collaboration/conflict behavior
```

Do not create a separate machine merely because there is a component.

Usually yes:

```txt
auth/session
organization/workspace/project session
approval workflow
checkout workflow
import workflow
member invitation workflow
conflict resolution workflow
publishing workflow
long-running job workflow
```

Usually no:

```txt
plain button
static header
simple label
basic display component
presentational card
```

---

### 4.3 Frontend Event Naming

Use names that reflect domain intent rather than implementation detail.

Prefer:

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
  type: "SETTINGS_SUBMITTED";
}
{
  type: "IMPORT_FILE_SELECTED";
}
{
  type: "APPROVAL_DECISION_SUBMITTED";
}
{
  type: "CHECKOUT_SUBMITTED";
}
```

Avoid:

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

Frontend events can represent user intent. Server-originated machine events should be named as facts, acknowledgements, or snapshots:

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

---

### 4.4 Example: Generic Approval Workflow

User action:

```tsx
approvalActor.send({
  type: "APPROVAL_DECISION_SUBMITTED",
  itemId: "item_123",
  decision: "approved",
  note: "Looks good",
});
```

Machine flow:

```txt
reviewing
  → savingDecision
  → loadingNextItem
  → reviewing
```

API response becomes a machine event:

```ts
approvalActor.send({
  type: "APPROVAL_DECISION_SAVE_CONFIRMED",
  result: {
    itemId: "item_123",
    decision: "approved",
    revision: 43,
    nextItemId: "item_124",
    summary: {
      completedCount: 248,
      remainingCount: 552,
      conflictCount: 12,
    },
  },
});
```

The component does not manually update counts, pick the next item, or decide conflict behavior. It sends the event and renders the actor snapshot.

---

### 4.5 Example: Settings Workflow

User action:

```ts
settingsActor.send({
  type: "SETTINGS_SUBMITTED",
  patch: { displayName: "New Name" },
});
```

Flow:

```txt
settingsActor enters saving
  → PATCH /api/settings
  → server returns updated settings
  → settingsActor receives SETTINGS_SAVE_CONFIRMED
  → parent actor receives SETTINGS_UPDATED
  → header/sidebar/other views reflect new settings
```

Use explicit actor-to-actor routing rather than a global bus.

---

### 4.6 Example: Import or Long-Running Job Workflow

User action:

```ts
importActor.send({
  type: "IMPORT_FILE_SUBMITTED",
  fileId: "file_123",
});
```

Flow:

```txt
idle
  → creatingJob
  → running(jobId)
  → completed
```

Server response:

```ts
importActor.send({
  type: "IMPORT_JOB_CREATED",
  jobId: "job_123",
});
```

Polling response:

```ts
importActor.send({
  type: "IMPORT_JOB_STATUS_RECEIVED",
  job: {
    id: "job_123",
    status: "running",
    progress: 64,
  },
});
```

On refresh, the server bootstrap should include active jobs so the frontend can reconstruct job actors.

---

## 5. Frontend and Backend Synchronization

### 5.1 Page Refresh

A browser refresh destroys the frontend actor system. Rebuild it from stable inputs.

Inputs:

```txt
URL
session/auth
server bootstrap data
server snapshots
optional local UI snapshots
```

Generic boot flow:

```txt
appActor starts
  → routeActor parses route params and active view
  → sessionActor loads current user
  → domainAreaActor starts with route params
  → GET /api/.../bootstrap
  → child actors start from bootstrap/snapshot facts
  → active workflow actor starts in the correct state
```

Do not blindly restore durable domain state from local storage. Permissions, decisions, memberships, statuses, payments, job state, and canonical settings must come from the server.

Safe local persistence examples:

```txt
collapsed sidebar
selected tab
unsaved local draft
temporary filters
wizard step
```

Unsafe local persistence examples:

```txt
role/permission state
approval decisions
payment state
membership state
record completion status
server job status
billing state
```

---

### 5.2 Snapshot Polling

You do not need a server event feed to keep frontend machines updated.

Poll current state:

```http
GET /api/resources/:id/snapshot
```

Response:

```json
{
  "id": "resource_123",
  "revision": 42,
  "status": "active",
  "summary": {
    "completedCount": 247,
    "remainingCount": 553,
    "conflictCount": 12
  },
  "activeJobs": [
    {
      "id": "job_123",
      "type": "import",
      "status": "running",
      "progress": 64
    }
  ]
}
```

Frontend wraps the response as a machine event:

```ts
resourceActor.send({
  type: "SERVER_SNAPSHOT_RECEIVED",
  snapshot,
});
```

This keeps the frontend event-driven without requiring the backend to emit events.

---

### 5.3 Job Polling

Long-running jobs should be durable on the server.

Start job:

```txt
POST /api/jobs
  → returns jobId
```

Poll status:

```txt
GET /api/jobs/:job_id
```

Machine events:

```ts
{
  type: ("JOB_CREATED", jobId);
}
{
  type: ("JOB_STATUS_RECEIVED", job);
}
{
  type: ("JOB_COMPLETED", job);
}
{
  type: ("JOB_FAILED", job);
}
```

Refresh behavior:

```txt
bootstrap says job_123 is running
  → frontend spawns jobActor(job_123)
  → polling resumes
```

---

### 5.4 Use Revisions, Cursors, or Timestamps

Polling responses can arrive out of order. Include a stable ordering field.

Examples:

```txt
revision
updatedAt
serverCursor
lockVersion
etag
```

Frontend rule:

```txt
If incoming revision <= current revision:
  ignore as stale

If incoming revision > current revision:
  apply snapshot/event
```

For important mutations, include idempotency keys:

```ts
{
  type: "APPROVAL_DECISION_SUBMITTED",
  itemId: "item_123",
  decision: "approved",
  clientMutationId: "mut_abc123",
  expectedRevision: 17
}
```

Server can safely handle retries and conflicts.

---

### 5.5 Mutation Responses Should Return Server Facts

When a mutation succeeds, the server should return enough facts for the frontend machine to transition correctly.

Example:

```http
POST /api/items/item_123/approval-decision
```

Response:

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

Frontend event:

```ts
{
  type: ("APPROVAL_DECISION_SAVE_CONFIRMED", result);
}
```

Do not make the frontend guess server-side consequences.

---

### 5.6 Bootstrap Endpoints Should Reconstruct Workflow State

Bootstrap should include:

```txt
identity and permissions
current resource status
active jobs
current phase or workflow state
counts/summaries
selected/current item when applicable
revision/version
feature flags or capability flags
```

Example endpoints:

```txt
GET /api/session/bootstrap
GET /api/organizations/:id/bootstrap
GET /api/projects/:id/bootstrap
GET /api/resources/:id/snapshot
GET /api/jobs/:job_id
```

---

## 6. Backend Architecture in Phoenix/Elixir

The examples below use Phoenix/Elixir terminology because the backend stack in scope is Phoenix. The same architectural roles map to other stacks:

```txt
Phoenix controller/LiveView  → web adapter / UI adapter
Context                      → bounded context / domain service
Workflow module              → application service / use case
Ecto.Multi                   → transaction composition
Oban/outbox                  → durable async side effects
Phoenix.PubSub               → live process/UI notification
```

---

### 6.1 Recommended Structure

```txt
MyAppWeb
├── Controllers
└── LiveViews

MyApp.Accounts
MyApp.Workspaces
MyApp.Projects
MyApp.Documents
MyApp.Orders
MyApp.Payments
MyApp.Approvals
MyApp.Imports
MyApp.Notifications
MyApp.ActivityLog
MyApp.Billing

MyApp.Workflows
├── InviteMember
├── SubmitApprovalDecision
├── StartImport
├── PlaceOrder
├── CapturePayment
├── PublishDocument
└── ChangeSettings

MyApp.DomainEvents
├── event structs
├── transactional consumers
├── after-commit notifications
└── handler registry, if useful
```

Controllers and LiveViews should stay thin.

They should:

```txt
parse input
identify actor/current user
call workflow/context function
render response or update assigns
```

They should not:

```txt
coordinate multiple contexts
write audit logs manually
send emails directly
broadcast domain events directly
implement business rules
perform external side effects
```

---

### 6.2 Contexts Own Domain Rules

A bounded context should own its own invariants.

Examples:

```txt
Accounts:
  identity, users, authentication constraints

Workspaces/Organizations:
  membership, roles, permissions, ownership transfer

Projects:
  project lifecycle, project settings, project membership

Documents:
  document status, publish rules, versioning

Orders:
  order placement, cancellation rules, order status

Payments:
  payment capture, refunds, payment state transitions

Approvals:
  assignment rules, decision validity, conflict detection

Imports:
  file import lifecycle, deduplication, job state
```

Do not let another context reach into private schemas or manipulate internal tables directly.

Prefer:

```elixir
Workspaces.authorize(actor, :invite_member, workspace_id)
Approvals.submit_decision_multi(...)
ActivityLog.append_from_events_multi(...)
```

Avoid:

```elixir
Repo.insert!(%MyApp.Workspaces.PrivateMembershipAuditRow{...})
```

from unrelated modules.

---

### 6.3 Workflows Orchestrate Use Cases

Use workflow modules when one operation crosses context boundaries.

Example operation:

```txt
Submit approval decision
```

May require:

```txt
authorization
record decision
detect conflict
update progress
write audit log
enqueue notification job
broadcast UI update
```

The workflow coordinates these steps.

```elixir
defmodule MyApp.Workflows.SubmitApprovalDecision do
  alias Ecto.Multi
  alias MyApp.{Repo, Workspaces, Approvals, ActivityLog, NotificationJobs, DomainEvents}

  def call(actor, item_id, attrs) do
    multi =
      Multi.new()
      |> Workspaces.authorize_multi(:permission, actor, :approve_item, item_id)
      |> Approvals.submit_decision_multi(actor, item_id, attrs)
      |> ActivityLog.append_from_events_multi(:approval_events)
      |> NotificationJobs.enqueue_from_events_multi(:approval_events)

    case Repo.transaction(multi) do
      {:ok, %{decision: decision, approval_events: events}} ->
        DomainEvents.after_commit(events)
        {:ok, decision}

      {:error, step, reason, _changes_so_far} ->
        {:error, {step, reason}}
    end
  end
end
```

---

## 7. Backend Domain Events

### 7.1 Why Use Domain Events Internally?

Domain events are useful because the context that performs a command is often the best place to know what meaningful facts occurred.

A single command may produce several facts:

```txt
ApprovalDecisionRecorded
ApprovalConflictDetected
ApprovalQueueCompleted
```

Without events, other code must infer facts from raw rows and flags. That spreads domain knowledge across the app.

Events help by making facts explicit:

```elixir
%ApprovalDecisionRecorded{
  organization_id: organization_id,
  item_id: item_id,
  decision_id: decision.id,
  actor_id: actor.id,
  decision: decision.value,
  occurred_at: DateTime.utc_now()
}
```

Benefits:

```txt
explicit domain language
testable command outcomes
clear audit mapping
clear notification mapping
less leakage of domain rules into controllers
less duplication of “what happened?” logic
```

---

### 7.2 When Should Context Functions Return Events?

Command functions may return events.

Good candidates:

```elixir
Approvals.submit_decision(...)
Workspaces.invite_member(...)
Documents.publish(...)
Orders.place_order(...)
Payments.capture_payment(...)
Imports.start_import(...)
```

Poor candidates:

```elixir
Projects.get_project!(id)
Documents.list_documents(project_id)
Workspaces.get_member!(id)
Orders.change_order(order, attrs)
```

Queries should not produce events.

Low-level changeset helpers should not produce events.

---

### 7.3 Simple vs Consistency-Sensitive Commands

For simple commands, this can be acceptable:

```elixir
{:ok, %{result: result, events: events}} =
  SomeContext.some_command(...)

DomainEvents.after_commit(events)
```

But for consistency-sensitive commands, prefer transaction composition:

```elixir
multi =
  Multi.new()
  |> SomeContext.some_command_multi(...)
  |> ActivityLog.append_from_events_multi(:events)
  |> Jobs.enqueue_from_events_multi(:events)

Repo.transaction(multi)
```

Reason:

```txt
If audit/job/outbox is mandatory, it must be committed atomically with the domain change.
```

---

### 7.4 Why Return Events Instead of Publishing Them Inside the Context?

Returning events keeps the context explicit and testable.

Prefer:

```txt
Context performs domain operation.
Context returns result + domain facts.
Workflow decides which facts must be transactionally consumed.
```

Avoid:

```txt
Context performs domain operation.
Context secretly broadcasts/publishes events.
Unknown subscribers perform important behavior.
```

Returning events lets tests assert:

```elixir
assert {:ok, %{result: result, events: events}} =
         SomeContext.some_command(...)

assert [%SomeDomainFact{}] = events
```

It also allows workflows to compose mandatory consumers inside the same transaction.

---

## 8. Consistency Model

### 8.1 Classify Each Reaction

For every reaction to an event, classify it.

| Reaction type        | Examples                                                                        | Mechanism                              |
| -------------------- | ------------------------------------------------------------------------------- | -------------------------------------- |
| Required immediately | audit log, required status row, required conflict row, required progress update | same transaction                       |
| Required eventually  | email, webhook, integration sync, search indexing, file processing              | job/outbox row inserted in transaction |
| UI convenience       | LiveView refresh, browser update, cache invalidation, toast signal              | after-commit PubSub/notification       |
| Optional analytics   | product analytics, metrics                                                      | after-commit or async job              |

---

### 8.2 Mandatory Audit Log

If audit log is mandatory, it is a transaction participant.

```elixir
multi =
  Multi.new()
  |> Approvals.submit_decision_multi(actor, item_id, attrs)
  |> ActivityLog.append_from_events_multi(:approval_events)

Repo.transaction(multi)
```

Outcome:

```txt
Decision succeeds + audit log succeeds
or
both roll back
```

Do not make mandatory audit logging depend only on after-commit dispatch.

---

### 8.3 Required Async Work

For external side effects that must eventually happen, insert a job or outbox row inside the transaction.

Examples:

```txt
send invite email
call external API
send webhook
sync integration
index records into search
process import file
generate export
```

Pattern:

```txt
Domain write
Audit write
Job/outbox insert
Commit
Worker performs side effect later with retries
```

---

### 8.4 PubSub Is Not Durable

PubSub is useful for notifying connected processes and live clients, but it is not a durable business workflow mechanism.

Use PubSub for:

```txt
connected pages should refresh
member list should update live
job progress banner should update
summary counters should update live
```

Do not use PubSub as the only mechanism for:

```txt
mandatory audit logging
required email delivery
billing updates
external API synchronization
critical domain invariants
```

---

### 8.5 External Side Effects Must Be Idempotent

Any worker that performs an external side effect should be safe to run more than once.

Use one or more of:

```txt
idempotency keys
unique job constraints
external idempotency tokens
processed_at flags
deduplication keys
stable payload hashes
```

Reason:

```txt
Retries happen.
Workers crash.
External APIs timeout.
A side effect may have succeeded even if the caller did not receive a response.
```

---

## 9. Event Handler Categories

### 9.1 Transactional Handlers

Run inside the same transaction as the domain change.

Allowed:

```txt
database inserts
database updates
audit log writes
required projections
job inserts
outbox inserts
```

Avoid:

```txt
HTTP calls
email sending
PubSub broadcasts
file uploads
slow external operations
```

Example:

```elixir
ActivityLog.append_from_events_multi(:approval_events)
NotificationJobs.enqueue_from_events_multi(:approval_events)
Outbox.insert_from_events_multi(:approval_events)
```

---

### 9.2 After-Commit Handlers

Run only after transaction success.

Allowed:

```txt
PubSub broadcast
cache invalidation
Telemetry events
local process notification
non-critical analytics
```

Example:

```elixir
defmodule MyApp.DomainEvents.AfterCommit do
  alias Phoenix.PubSub
  alias MyApp.Approvals.Events.ApprovalDecisionRecorded

  def handle(%ApprovalDecisionRecorded{} = event) do
    PubSub.broadcast(
      MyApp.PubSub,
      "resource:#{event.item_id}",
      {:approval_decision_recorded, event}
    )
  end

  def handle(_event), do: :ok
end
```

---

### 9.3 Durable Async Handlers

Run in workers. Triggered by job/outbox rows inserted during the transaction.

Allowed:

```txt
send email
call external APIs
send webhooks
sync integrations
search indexing
file processing
large imports
exports
```

Workers should be:

```txt
idempotent
retryable
observable
safe to run more than once
```

---

## 10. Backend Workflow Examples

The examples below are intentionally generic. Replace the domain words with the language of the product being built.

---

### 10.1 Invite Member

Flow:

```txt
LiveView/controller receives invite request
  → workflow checks permission
  → context inserts invitation/member row
  → context emits MemberInvited event
  → audit log writes audit row in transaction
  → notification job is inserted in transaction
  → transaction commits
  → PubSub notifies connected clients
```

Workflow:

```elixir
defmodule MyApp.Workflows.InviteMember do
  alias Ecto.Multi
  alias MyApp.{Repo, Workspaces, ActivityLog, NotificationJobs, DomainEvents}

  def call(actor, workspace_id, attrs) do
    multi =
      Multi.new()
      |> Workspaces.invite_member_multi(actor, workspace_id, attrs)
      |> ActivityLog.append_from_events_multi(:workspace_events)
      |> NotificationJobs.enqueue_from_events_multi(:workspace_events)

    case Repo.transaction(multi) do
      {:ok, %{member: member, workspace_events: events}} ->
        DomainEvents.after_commit(events)
        {:ok, member}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end
end
```

---

### 10.2 Submit Approval Decision

Flow:

```txt
User submits decision
  → authorize actor
  → record decision
  → detect conflict if applicable
  → update progress/status
  → emit domain events
  → write audit log transactionally
  → enqueue notification jobs transactionally
  → commit
  → broadcast live update after commit
```

Possible events:

```elixir
%ApprovalDecisionRecorded{}
%ApprovalConflictDetected{}
%ApprovalQueueCompleted{}
```

Rules:

```txt
Conflict row is core domain state → same transaction.
Progress/status update required for correctness → same transaction.
Audit log mandatory → same transaction.
Email/notification → job inserted in same transaction, delivered later.
PubSub → after commit only.
```

---

### 10.3 Start Import or Processing Job

Flow:

```txt
User uploads file or requests processing
  → workflow validates permission and metadata
  → context creates job row
  → audit log written transactionally
  → background job enqueued transactionally
  → commit
  → PubSub broadcasts job started
  → worker processes file/task
  → frontend polls job status or receives live updates
```

Frontend refresh:

```txt
bootstrap includes active job
  → jobActor(job_id) starts
  → polling resumes
```

---

### 10.4 Place Order / Capture Payment

Flow:

```txt
User places order
  → workflow validates cart, inventory, pricing, permissions
  → order context creates order
  → inventory context reserves stock if required
  → payment job or payment intent is created
  → audit log is written transactionally
  → commit
  → worker/external API handles payment capture if async
  → frontend receives order status or polls snapshot
```

Rules:

```txt
Order creation and required reservation should be transactionally consistent when possible.
External payment calls should not run inside DB transaction unless explicitly designed and safe.
Payment capture workers must be idempotent.
Frontend should treat payment/order state returned by the server as source of truth.
```

---

### 10.5 Publish Document / Resource

Flow:

```txt
User clicks publish
  → workflow checks permission
  → context validates publishability
  → status changes to published
  → audit row written transactionally
  → indexing/webhook jobs inserted transactionally
  → commit
  → PubSub notifies connected clients
```

Possible events:

```elixir
%DocumentPublished{}
%ResourcePublished{}
%SearchIndexingRequested{}
```

---

## 11. Controller and LiveView Guidance

### 11.1 Controllers

Controllers should call workflows or simple context functions.

Good:

```elixir
def create(conn, params) do
  actor = conn.assigns.current_user

  case MyApp.Workflows.SubmitApprovalDecision.call(actor, params["item_id"], params) do
    {:ok, decision} ->
      json(conn, %{id: decision.id})

    {:error, {_step, reason}} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: inspect(reason)})
  end
end
```

Avoid:

```elixir
def create(conn, params) do
  # permission check
  # domain insert
  # conflict detection
  # progress update
  # audit insert
  # email send
  # PubSub broadcast
  # response rendering
end
```

---

### 11.2 LiveViews

LiveViews should translate browser events into workflow calls and render updated state.

Good:

```elixir
def handle_event("submit_decision", params, socket) do
  actor = socket.assigns.current_user

  case MyApp.Workflows.SubmitApprovalDecision.call(actor, socket.assigns.item_id, params) do
    {:ok, decision} ->
      {:noreply, assign(socket, last_decision: decision)}

    {:error, {_step, reason}} ->
      {:noreply, assign(socket, error: reason)}
  end
end
```

Use PubSub subscription for live updates:

```elixir
def mount(%{"resource_id" => resource_id}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "resource:#{resource_id}")
  end

  {:ok, assign(socket, resource_id: resource_id)}
end


def handle_info({:resource_updated, event}, socket) do
  {:noreply, assign(socket, last_event: event)}
end
```

The LiveView should not be the business orchestrator.

---

## 12. Frontend–Backend Contract

### 12.1 Commands

Commands should include enough information for safe server-side processing.

Recommended fields for risky commands:

```txt
actor identity from session, not from client payload
resource id
command-specific payload
clientMutationId
expectedRevision or lockVersion
```

Example:

```json
{
  "decision": "approved",
  "note": "Looks good",
  "clientMutationId": "mut_abc123",
  "expectedRevision": 17
}
```

---

### 12.2 Mutation Responses

Responses should contain server facts, not just `ok: true`.

Prefer:

```json
{
  "itemId": "item_123",
  "status": "approved",
  "revision": 18,
  "summary": {
    "completedCount": 11,
    "remainingCount": 3
  },
  "nextItemId": "item_456"
}
```

Avoid:

```json
{ "ok": true }
```

unless the frontend truly does not need to transition based on the result.

---

### 12.3 Bootstrap and Snapshot APIs

Bootstrap APIs should answer:

```txt
Who is the user?
What can the user do?
What resource is active?
What is the resource status?
What workflow phase is active?
What jobs are running?
What revision/version is current?
What summary data is needed for initial render?
```

Snapshot APIs should answer:

```txt
What is the current server state of this resource or workflow?
```

The frontend can convert the response into a machine event.

---

### 12.4 Polling APIs

Polling APIs should be simple and stable.

Examples:

```txt
GET /api/resources/:id/snapshot
GET /api/jobs/:id
GET /api/notifications/unread-count
GET /api/projects/:id/summary
```

Use snapshot polling before building a server event feed.

---

## 13. Tradeoffs and Architecture Decisions

### Decision 1: Multiple Frontend Machines, Not One Giant Machine

Use multiple actors for independently meaningful workflows.

Benefits:

```txt
clear ownership
better testability
smaller state charts
localized events
explicit actor boundaries
```

Tradeoff:

```txt
requires actor routing and lifecycle management
```

---

### Decision 2: No Global Frontend Event Bus as Primary Control Plane

Use explicit actor refs and parent-child routing.

Benefits:

```txt
traceable event flow
less hidden coupling
clear event consumers
```

Tradeoff:

```txt
some cross-feature communication requires routing code
```

---

### Decision 3: Use Snapshot Polling Before Server Event Feeds

Use ordinary API endpoints and convert responses into frontend events.

Benefits:

```txt
no backend overhaul
simple to implement
works with REST/GraphQL
sufficient for many applications
```

Tradeoff:

```txt
less precise than server event feeds
may miss exact history of changes
requires careful revision handling
```

---

### Decision 4: Backend Domain Events Are Internal Facts, Not Event Sourcing

Use events to express what happened, not as the source of truth.

Benefits:

```txt
clear domain language
easier audit mapping
better testability
less controller orchestration
```

Tradeoff:

```txt
requires event structs and mapping code
can add indirection if overused
```

---

### Decision 5: Mandatory Consistency Uses Transactions, Not After-Commit Dispatch

Audit logs, required projections, required job inserts, and domain invariants must be inside the database transaction.

Benefits:

```txt
correctness
atomicity
predictable failures
```

Tradeoff:

```txt
more explicit transaction composition
workflow modules become important
```

---

### Decision 6: PubSub Is for Live Updates, Not Business Reliability

Use PubSub after commit to notify connected processes.

Benefits:

```txt
fast UI updates
simple LiveView integration
```

Tradeoff:

```txt
messages are not durable
clients must be able to refetch current state
```

---

### Decision 7: External Effects Use Jobs or Outbox

Emails, webhooks, external APIs, search indexing, imports, and exports should be handled by retryable workers.

Benefits:

```txt
reliability
retry behavior
no slow external calls in DB transaction
observability
```

Tradeoff:

```txt
eventual consistency
need idempotent worker design
```

---

### Decision 8: Controllers and LiveViews Are Adapters, Not Orchestrators

Use controllers and LiveViews to translate protocol/UI concerns into application calls.

Benefits:

```txt
business logic is reusable
HTTP and LiveView paths stay consistent
easier testing
less duplication
```

Tradeoff:

```txt
requires workflow modules or clear context APIs
```

---

## 14. Coding Agent Implementation Instructions

When implementing or modifying code in this architecture, follow these rules.

---

### 14.1 Frontend Agent Rules

1. Do not put multi-step business workflows inside UI components.
2. Convert UI interactions into semantic events sent to a specific actor.
3. Prefer actor hierarchy and explicit routing over a global event bus.
4. Do not store large durable server datasets in machine context unless necessary.
5. Use machines for workflow/control state.
6. Use a server-state cache/query layer for large server data when appropriate.
7. Treat server responses as machine events.
8. On refresh, reconstruct actors from URL, session, and server bootstrap.
9. Include revision/idempotency metadata for important commands.
10. Do not trust local storage for permissions, roles, decisions, payments, billing, or canonical server state.
11. Use server snapshots to reconcile stale or uncertain local state.
12. Prefer domain event names over UI implementation event names.

---

### 14.2 Backend Agent Rules

1. Keep controllers and LiveViews thin.
2. Put domain rules inside contexts.
3. Put cross-context orchestration inside workflow/application-service modules.
4. Use transaction composition for operations requiring atomic consistency.
5. Command functions may produce domain events as facts.
6. Query functions should not produce events.
7. Mandatory audit logs must be written in the same transaction as the domain change.
8. Required async work must be represented by job/outbox rows inserted in the transaction.
9. PubSub broadcasts should happen after commit.
10. Event handlers that run inside transactions should perform database operations only.
11. External API calls, email, webhooks, imports, exports, and search indexing should run in workers.
12. Workers must be idempotent and retry-safe.
13. Avoid hidden PubSub subscribers for core business behavior.
14. Prefer explicit handler maps or workflow composition so event consumers are discoverable.
15. Do not let contexts manipulate other contexts’ private tables directly.
16. Return enough server facts from mutations for frontend machines to transition correctly.

---

## 15. Implementation Checklist

### 15.1 Frontend Checklist

- [ ] Define the actor hierarchy.
- [ ] Identify workflows that deserve state machines.
- [ ] Define semantic UI events.
- [ ] Define server response events.
- [ ] Define page refresh bootstrapping flow.
- [ ] Add bootstrap/snapshot endpoints to reconstruct state.
- [ ] Add polling for active jobs and summaries.
- [ ] Add revision handling for stale polling responses.
- [ ] Add idempotency keys for risky mutations.
- [ ] Ensure UI renders actor snapshots rather than owning workflows.
- [ ] Ensure local storage is used only for safe UI state.
- [ ] Ensure server facts override stale local assumptions.

---

### 15.2 Backend Checklist

- [ ] Identify bounded contexts and their invariants.
- [ ] Identify use cases that need workflow modules.
- [ ] Define domain event structs for meaningful facts.
- [ ] Add `*_multi` helpers for consistency-sensitive context operations.
- [ ] Compose workflows with a transaction.
- [ ] Write mandatory audit log rows inside transactions.
- [ ] Insert job/outbox rows inside transactions for required async work.
- [ ] Broadcast PubSub only after commit.
- [ ] Keep controllers/LiveViews thin.
- [ ] Make workers idempotent and retryable.
- [ ] Ensure mutation responses include useful server facts.
- [ ] Ensure bootstrap/snapshot endpoints include revision metadata.
- [ ] Make event consumers discoverable.
- [ ] Avoid hidden side effects in contexts.

---

## 16. Anti-Patterns to Avoid

### 16.1 Frontend Anti-Patterns

```txt
Global event bus controls everything.
UI components contain long imperative workflows.
Every component gets its own machine.
Frontend machine is treated as canonical server state.
Local storage restores permissions or durable domain data.
Polling directly mutates machine context instead of sending events.
Server mutation response is too small, forcing frontend to guess consequences.
Machine context becomes a giant database cache.
```

---

### 16.2 Backend Anti-Patterns

```txt
Controllers orchestrate many contexts.
LiveViews implement business rules.
Contexts secretly publish events with important side effects.
Mandatory audit logs happen after commit.
PubSub is used as a durable event bus.
External HTTP calls happen inside DB transactions.
Email sending happens inside DB transactions.
Event handlers modify other contexts' private schemas directly.
Workers are not idempotent.
Domain events are used for trivial CRUD noise.
Every tiny state change becomes an event.
```

---

## 17. Practical Architecture in One Page

```txt
Frontend
========
UI components are event senders.
State-machine actors own workflows.
Actors call APIs and receive server facts as events.
Page refresh reconstructs actors from URL/session/server bootstrap.
Polling retrieves snapshots or job status and sends machine events.
No global event bus as primary control plane.

Backend
=======
Controllers and LiveViews are adapters.
Contexts own domain rules and data operations.
Workflow modules orchestrate cross-context use cases.
Command operations may produce domain events.
Transactions provide mandatory consistency.
Mandatory audit/projections/jobs are transaction participants.
PubSub runs after commit for live UI updates.
External side effects run in durable, retryable workers.
No full event sourcing required.
No server event feed required initially.
```

---

## 18. Guiding Question for Every Design Choice

Ask:

```txt
Who owns this fact or workflow?
```

If it is durable domain truth:

```txt
server/database/context owns it
```

If it is frontend workflow/control state:

```txt
state machine actor owns it
```

If it crosses contexts:

```txt
workflow module orchestrates it
```

If it is required for correctness:

```txt
transaction owns it
```

If it must happen eventually but can be async:

```txt
job/outbox owns it
```

If it is only for live UI convenience:

```txt
PubSub after commit owns it
```

That ownership model is the heart of the architecture.

---

## 19. Minimal Adoption Path

This architecture can be adopted incrementally.

### Stage 1: Frontend event discipline

```txt
Move multi-step workflows out of components.
Send semantic events to specific actors or reducers.
Keep API calls inside workflow actors/services.
```

### Stage 2: Backend workflow discipline

```txt
Keep controllers and LiveViews thin.
Move cross-context orchestration into workflow modules.
Keep domain rules in contexts.
```

### Stage 3: Transactional consistency

```txt
Use transaction composition for commands that need audit/projections/jobs.
Write mandatory audit logs inside the transaction.
Insert required jobs/outbox rows inside the transaction.
```

### Stage 4: Sync and refresh reliability

```txt
Add bootstrap/snapshot endpoints.
Add revision or lockVersion fields.
Add idempotency keys for risky commands.
```

### Stage 5: Live updates and async durability

```txt
Use PubSub after commit for live UI updates.
Use workers for external side effects.
Introduce a lightweight outbox only where job insertion is not enough.
```

Do not start by building event sourcing. Start by making ownership, workflows, and consistency explicit.
