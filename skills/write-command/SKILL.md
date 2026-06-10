---
name: write-command
description: Write or review a public bounded-context command handler for an already agreed operation in an Elixir/Phoenix codebase. Use when Codex needs to add, revise, or assess a `Context.command(scope, attrs)` facade delegate and its `Commands.Command.handle/2` implementation with TLA+/architecture vocabulary, input validation, domain transitions, persistence, rollback behavior, facade-only cross-context calls, and boundary authorization kept outside the context.
---

# Write Command

Use this skill for one focused public command operation inside an existing bounded context. Do not use it to design a whole context, add generic CRUD, create query surfaces, or expose private worker continuations.

## Source Order

Start from the agreed operation and current repo facts:

1. Read relevant `docs/specs/*.tla` first when present. Treat action names, state variables, invariants, and ownership boundaries as the authority.
2. Read architecture docs, ADRs, and `CONTEXT.md` as vocabulary/rationale explainers and drift detectors.
3. Inspect nearby commands, the context facade, schemas, tests, Repo helpers, Scope shape, and transaction convention.
4. Ask only if the operation name, public necessity, or command contract remains unsettled.

If specs and prose disagree, state the contradiction and follow the TLA+ model unless the user chooses otherwise.

## Public Command Gate

Before writing or preserving a public command, verify that it is necessary and important:

- It is a user-facing or boundary-facing domain intention, not an implementation step.
- A controller, LiveView, worker, or another context legitimately needs to call it.
- The name uses ubiquitous language from the spec/docs/code, not generic verbs like `run`, `process`, `sync`, or CRUD unless the domain really says that.
- Worker/private continuations are not being promoted into `Commands.*`; keep those in direct child noun modules such as `Orders` or `OrderVerification`.

If the operation fails this gate, recommend an internal noun module, schema transition, or private helper instead of a public command.

## Command Shape

Expose the operation through a thin facade only:

```elixir
defmodule MyApp.Sales do
  alias MyApp.Sales.Commands.PlaceOrder

  defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
end
```

Implement one command handler for one public write use case:

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order

  embedded_schema do
    field :customer_id, :binary_id
    embeds_many :items, Item, primary_key: false do
      field :sku, :string
      field :quantity, :integer
    end
  end

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, command} <- validate(attrs) do
      Repo.transact(fn ->
        %Order{}
        |> Order.place_changeset(scope, command)
        |> Repo.insert()
      end)
    end
  end

  defp validate(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:customer_id])
    |> cast_embed(:items, with: &item_changeset/2)
    |> validate_required([:customer_id])
    |> apply_action(:validate)
  end

  defp item_changeset(item, attrs) do
    item
    |> cast(attrs, [:sku, :quantity])
    |> validate_required([:sku, :quantity])
    |> validate_number(:quantity, greater_than: 0)
  end
end
```

Adapt names, Repo transaction helpers, schema APIs, and Scope modules to the local project. Do not cargo-cult this exact template.

## Handler Responsibilities

Keep these responsibilities in the command handler:

- Input shape validation. Use an internal `embedded_schema` for non-trivial attrs; small `%{id: id}` commands may use a private validation helper.
- Domain preconditions that belong to the public use case.
- Transaction boundary when the write spans multiple rows, side effects, or rollback-sensitive steps.
- Calls to schema transition/changeset functions that enforce legal state changes.
- Persistence through the repo convention already used by the project.
- Tagged result tuples such as `{:ok, %Schema{}}` or `{:error, changeset_or_reason}`.

Keep these out:

- Authorization checks. Boundary layers authorize before calling the facade.
- JSON-shaped maps, presentation wrappers, or controller response shaping.
- Direct calls to another context's internals.
- Generic orchestration that is not itself the public command.

## Cross-Context Calls

When the command needs another context, call the other context's public facade with the same `%Scope{}` and attrs maps:

```elixir
with {:ok, payment} <- Billing.authorize_payment(scope, %{order_id: order.id, payment: command.payment}),
     {:ok, order} <- persist_order(scope, command, payment) do
  {:ok, order}
end
```

Let downstream tagged errors bubble unless the public contract requires translation. If synchronous facade calls create cycles or awkward ownership, stop and identify the boundary issue instead of reaching into private modules.

## Review Checklist

When reviewing an existing command, report concrete findings first:

- Is the operation truly public and named in domain language?
- Is the facade only a delegate?
- Does validation reject malformed attrs before Ecto persistence paths fail ambiguously?
- Are state transitions and invariants enforced in the handler/schema path?
- Are multi-row writes atomic, and do partial failures roll back?
- Are auth checks absent from the bounded context and covered at the boundary?
- Are worker/private continuations kept out of `Commands.*`?
- Do cross-context calls use public facades with the same scope?
- Does the command return tagged tuples and schema structs rather than JSON-shaped maps?

## Testing

Test command handlers with repo-backed tests for:

- valid command input and returned schema struct;
- invalid attrs and changeset/error contract;
- precondition failures and no unintended persistence;
- legal state transitions and forbidden transitions;
- multi-row persistence and rollback behavior;
- cross-context error bubbling or documented error translation.

Do not test authorization in command tests. Put HTTP/LiveView/plug/resolver authorization coverage where authorization is enforced.
