# Bounded Context Architecture in Elixir/Phoenix

## 1. Purpose

This document describes a Phoenix-native architecture for structuring bounded contexts using aggregate-oriented Domain-Driven Design concepts.

The intended audience is software engineers working in an Elixir/Phoenix codebase who need to understand:

- How bounded contexts should be organized.
- How public context modules should expose APIs.
- How command and query handlers should be structured.
- How `%Scope{}` should be used for user-, organization-, tenant-, permission-, and visibility-sensitive operations.
- Where cross-context orchestration should live.
- Where business logic should live.
- How aggregates should protect business invariants.
- How Ecto `embedded_schema` differs from database-backed `schema`.
- How persistence should be handled.
- How property-based testing can validate aggregate invariants.

This approach is designed to be pragmatic. It uses Phoenix and Ecto idioms while preserving clear architectural boundaries.

## 2. High-Level Architecture

At a high level, each bounded context exposes a public context module, but that module should be thin.

The public context module is the external API for that bounded context. It should usually delegate to self-contained command and query handlers.

For example, a `Sales` bounded context may expose:

```elixir
MyApp.Sales.place_order(scope, attrs)
MyApp.Sales.get_order(scope, id)
MyApp.Sales.cancel_order(scope, id)
```

Internally, the bounded context is split into:

- Commands for write-side use cases.
- Queries for read-side use cases.
- Aggregates for business behavior, state transitions, and invariants.
- Persistence schemas for database interaction.
- Workers for asynchronous jobs.
- A thin public context module that delegates to commands and queries.

Cross-context workflows should not be hidden inside one bounded context. They belong in top-level use case modules under `lib/my_app/use_cases/`.

The key rules are:

- Public context modules expose APIs and delegate.
- Command and query handlers are self-contained for single-context operations.
- Cross-context orchestration belongs in top-level use cases.
- Domain behavior belongs in aggregates.
- Persistence belongs in repo schemas and handlers.
- External callers use the bounded context API.

## 3. Folder Structure

```bash
lib/my_app/
  sales.ex                         # Thin public bounded context facade

  sales/                           # Sales bounded context internals
    commands/                      # Self-contained write-side handlers
      place_order.ex
      cancel_order.ex

    queries/                       # Self-contained read-side handlers
      get_order.ex
      list_orders.ex

    workers/                       # Oban jobs or async process handlers
      send_order_confirmation.ex
      expire_unpaid_order.ex

    order.ex                       # Aggregate root with inline child schemas

  repo/
    sales/
      order.ex                     # Persistence schema, queries, changesets
      order_line_item.ex           # Persistence schema, changesets

  use_cases/                       # Cross-context orchestration
    checkout.ex
    cancel_order_and_release_stock.ex
    refund_order.ex
```

This example uses `Sales` as the bounded context, but the same pattern applies to other contexts such as `Billing`, `Accounts`, `Fulfillment`, `Inventory`, or `Subscriptions`.

## 4. Module Responsibilities

| Module                            | Responsibility                                                                                          |
| --------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `MyApp.Sales`                     | Thin public bounded context API. Delegates to command and query handlers.                               |
| `MyApp.Sales.Commands.PlaceOrder` | Validates input, authorizes, runs transactions, calls aggregates, persists results, and returns output. |
| `MyApp.Sales.Queries.GetOrder`    | Authorizes visibility, fetches data, and returns a domain object or read model.                         |
| `MyApp.Sales.Order`               | Aggregate root. Owns business behavior, state transitions, inline child schemas, and invariants.        |
| `MyApp.Repo.Sales.Order`          | Database-backed Ecto schema for orders. Owns persistence changesets and reusable query fragments.       |
| `MyApp.Repo.Sales.OrderLineItem`  | Database-backed Ecto schema for order line items.                                                       |
| `MyApp.Sales.Workers.*`           | Background jobs that typically call the public context API.                                             |
| `MyApp.UseCases.*`                | Cross-context workflows that orchestrate multiple bounded contexts.                                     |

## 5. Scope as the First Argument

Every public context function whose result or side effect depends on the current user, organization, tenant, permissions, request actor, or visibility must take a `%Scope{}` as its first argument.

This follows the Phoenix convention introduced around scoped context APIs.

Prefer:

```elixir
Sales.place_order(scope, attrs)
Sales.get_order(scope, id)
Sales.list_orders(scope, filters)
Sales.cancel_order(scope, order_id)
```

Avoid:

```elixir
Sales.place_order(attrs, current_user)
Sales.get_order(id)
Sales.list_orders(org_id)
Sales.cancel_order(order_id, user)
```

The scope should represent the request boundary, not merely the current user.

Example:

```elixir
defmodule MyApp.Accounts.Scope do
  defstruct [
    :user,
    :organization,
    :tenant_id,
    roles: [],
    permissions: []
  ]
end
```

A handler can then consistently authorize and filter using the same shape:

```elixir
def handle(%Scope{} = scope, attrs) do
  with :ok <- authorize(scope, :place_order),
       {:ok, command} <- validate(attrs),
       {:ok, order} <- build_order(command) do
    persist(order)
  end
end
```

If an operation is truly system-level, prefer making that explicit with a system scope rather than bypassing the pattern:

```elixir
%Scope{user: nil, organization: nil, tenant_id: tenant_id, roles: [:system]}
```

The architectural rule is:

```text
If the operation depends on actor, tenant, organization, permissions, or visibility, `%Scope{}` is the first argument.
```

## 6. Public Context Module

The public context module is the main entry point into a bounded context, but it should usually be a thin facade.

For example:

```elixir
defmodule MyApp.Sales do
  alias MyApp.Sales.Commands.CancelOrder
  alias MyApp.Sales.Commands.PlaceOrder
  alias MyApp.Sales.Queries.GetOrder
  alias MyApp.Sales.Queries.ListOrders

  defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
  defdelegate cancel_order(scope, order_id), to: CancelOrder, as: :handle
  defdelegate get_order(scope, id), to: GetOrder, as: :handle
  defdelegate list_orders(scope, filters \\ %{}), to: ListOrders, as: :handle
end
```

The public context module owns:

- The public API shape of the bounded context.
- Function names that controllers, LiveViews, workers, use cases, and other contexts call.
- A stable facade over internal implementation details.

The public context module should usually not own:

- Transaction bodies.
- Complex orchestration.
- Persistence mapping.
- Business rules.
- Authorization logic.
- Large procedural workflows.

Those responsibilities belong in command handlers, query handlers, aggregates, persistence schemas, or top-level use cases depending on the concern.

The context module should remain boring.

That is a feature.

## 7. Commands

Commands represent write-side use cases within one bounded context.

A command handler is self-contained. It should usually own:

- Authorization for the operation.
- Input validation and normalization.
- Transaction boundaries.
- Loading persistence schemas when needed.
- Mapping persistence schemas to aggregates.
- Calling aggregate behavior.
- Persisting aggregate results.
- Returning a domain object, read model, or explicit result.

If a command handler uses an input struct, the command handler module itself should own that struct with `embedded_schema`.

Example:

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Repo.Sales.Order, as: OrderSchema

  @primary_key false

  embedded_schema do
    field :customer_id, :binary_id
    field :currency, :string, default: "USD"

    embeds_many :line_items, LineItem, primary_key: false do
      field :product_id, :binary_id
      field :sku, :string
      field :quantity, :integer
      field :unit_price_cents, :integer
    end
  end

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with :ok <- authorize(scope, :place_order),
           {:ok, command} <- validate(attrs),
           {:ok, order} <- build_order(command),
           {:ok, order} <- Order.place(order),
           {:ok, order_schema} <- insert_order_aggregate(scope, order) do
        to_domain_order(order_schema)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp authorize(%Scope{} = scope, :place_order) do
    if :place_order in scope.permissions do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp validate(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  defp changeset(command, attrs) do
    command
    |> cast(attrs, [:customer_id, :currency])
    |> validate_required([:customer_id, :currency])
    |> cast_embed(:line_items, with: &line_item_changeset/2, required: true)
    |> validate_has_line_items()
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
  end

  defp validate_has_line_items(changeset) do
    line_items = get_field(changeset, :line_items) || []

    if Enum.empty?(line_items) do
      add_error(changeset, :line_items, "must contain at least one item")
    else
      changeset
    end
  end

  defp build_order(%__MODULE__{} = command) do
    attrs = %{
      customer_id: command.customer_id,
      currency: command.currency,
      status: :draft,
      total_cents: 0,
      line_items: []
    }

    with {:ok, order} <- Order.new(attrs) do
      Enum.reduce_while(command.line_items, {:ok, order}, fn line_item_attrs, {:ok, order} ->
        case Order.add_line_item(order, line_item_attrs) do
          {:ok, order} -> {:cont, {:ok, order}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp insert_order_aggregate(%Scope{} = scope, %Order{} = order) do
    %OrderSchema{}
    |> OrderSchema.aggregate_changeset(order_to_attrs(scope, order))
    |> Repo.insert()
  end
end
```

The exact helper functions may vary by project, but the responsibility boundary should remain clear:

```text
Command handler executes one write-side use case inside one bounded context.
```

## 8. Handler Input Validation

Command and query handlers own their input schemas.

If a handler uses Ecto validation, the handler module itself should usually define the `embedded_schema`.

This is useful for:

- Validating external input.
- Normalizing string-keyed params from controllers or APIs.
- Expressing the intent of an operation.
- Keeping input validation separate from persistence validation.

Example:

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :customer_id, :binary_id
    field :currency, :string, default: "USD"

    embeds_many :line_items, LineItem, primary_key: false do
      field :product_id, :binary_id
      field :sku, :string
      field :quantity, :integer
      field :unit_price_cents, :integer
    end
  end

  defp validate(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  defp changeset(command, attrs) do
    command
    |> cast(attrs, [:customer_id, :currency])
    |> validate_required([:customer_id, :currency])
    |> cast_embed(:line_items, with: &line_item_changeset/2, required: true)
    |> validate_has_line_items()
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
  end

  defp validate_has_line_items(changeset) do
    line_items = get_field(changeset, :line_items) || []

    if Enum.empty?(line_items) do
      add_error(changeset, :line_items, "must contain at least one item")
    else
      changeset
    end
  end
end
```

Handler input validation answers:

```text
Is this input acceptable for this use case?
```

Persistence validation answers:

```text
Can this data be safely stored in this table?
```

They often overlap, but they are not the same thing.

If a handler appears to need multiple unrelated input schemas, prefer splitting the operation into separate command or query handlers before introducing nested input modules.

## 9. Queries

Queries represent read-side use cases within one bounded context.

A query handler is self-contained. It should usually own:

- Input validation and normalization.
- Authorization and visibility filtering.
- Building the query.
- Calling `Repo`.
- Mapping persistence schemas to domain objects or read models.
- Returning `{:ok, result}` or `{:error, reason}`.

Example:

```elixir
defmodule MyApp.Sales.Queries.GetOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Repo.Sales.Order, as: OrderSchema

  @primary_key false

  embedded_schema do
    field :id, :binary_id
  end

  def handle(%Scope{} = scope, id) when not is_map(id) do
    handle(scope, %{id: id})
  end

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, input} <- validate(attrs),
         {:ok, order_schema} <- fetch_order(scope, input) do
      {:ok, to_domain_order(order_schema)}
    end
  end

  defp validate(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:validate)
  end

  defp changeset(input, attrs) do
    input
    |> cast(attrs, [:id])
    |> validate_required([:id])
  end

  defp fetch_order(%Scope{} = scope, %__MODULE__{} = input) do
    query =
      OrderSchema
      |> OrderSchema.by_id(input.id)
      |> OrderSchema.visible_to(scope)
      |> OrderSchema.preload_line_items()

    case Repo.one(query) do
      nil -> {:error, :not_found}
      order_schema -> {:ok, order_schema}
    end
  end
end
```

Query handlers can return:

- Domain aggregates, for simple domain-oriented reads.
- Read models, for screens, reports, dashboards, exports, or performance-sensitive queries.

For complex reads, prefer dedicated read models instead of forcing all read paths through aggregates.

## 10. Aggregates

Aggregates are the core business objects inside the bounded context.

An aggregate root protects invariants and controls updates to its child objects.

For example, `Order` is an aggregate root and `line_items` are child objects defined inline inside the root schema.

External code should not directly mutate line items. All updates should go through `Order`.

Prefer:

```elixir
Order.add_line_item(order, attrs)
Order.change_line_item_quantity(order, line_item_id, quantity)
Order.remove_line_item(order, line_item_id)
Order.place(order)
Order.cancel(order)
```

Avoid exposing child mutation as a public application API:

```elixir
LineItem.change_quantity(line_item, quantity)
LineItem.apply_discount(line_item, discount)
```

The aggregate root should enforce rules such as:

- Only draft orders can be edited.
- Empty orders cannot be placed.
- Placed orders cannot have line items added or removed.
- Totals are recalculated after line item changes.
- Invalid state transitions are rejected.
- Child objects cannot violate aggregate invariants.

Aggregates should not call `Repo`.

Prefer pure or mostly pure transition functions:

```elixir
Order.add_line_item(order, attrs)
Order.place(order)
Order.cancel(order)
```

Returning:

```elixir
{:ok, updated_order}
{:error, reason}
```

## 11. Aggregate Children Are Inlined in the Aggregate Root

Aggregate child objects should be defined inline inside the aggregate root's `embedded_schema`.

This reinforces that child objects are internal to the aggregate boundary and are not independently meaningful application resources.

Prefer:

```elixir
defmodule MyApp.Sales.Order do
  use Ecto.Schema

  embedded_schema do
    # Aggregate root
    field :customer_id, :binary_id
    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled]

    embeds_many :line_items, LineItem, primary_key: false do
      # Aggregate child
      field :product_id, :binary_id
      field :sku, :string
      field :quantity, :integer
      field :unit_price_cents, :integer
      field :subtotal_cents, :integer
    end
  end
end
```

Avoid hand-authoring aggregate child modules:

```elixir
defmodule MyApp.Sales.Order.LineItem do
  # Avoid making aggregate children look like standalone domain modules.
end
```

Ecto's inline embed syntax still generates a nested struct module such as `MyApp.Sales.Order.LineItem`.
Treat that as an implementation detail of the root schema, not as a module for application code to call directly.

This is a convention, not a language-enforced boundary. The boundary is maintained through:

- Inline schema definition.
- Private child changeset functions.
- Documentation.
- Code review.
- Tests.
- Public API discipline.

If an aggregate child becomes large enough that inline definition obscures the aggregate root, reconsider whether the aggregate boundary is too large before extracting a hand-authored child module.

## 12. Aggregate Root Example

```elixir
defmodule MyApp.Sales.Order do
  use Ecto.Schema
  import Ecto.Changeset

  use Gearbox,
    field: :status,
    states: [:draft, :placed, :cancelled],
    initial: :draft,
    transitions: %{
      draft: [:placed, :cancelled],
      placed: [:cancelled]
    }

  embedded_schema do
    field :customer_id, :binary_id

    field :status, Ecto.Enum,
      values: [:draft, :placed, :cancelled],
      default: :draft

    field :placed_at, :utc_datetime
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    embeds_many :line_items, LineItem, primary_key: false do
      field :id, :integer
      field :product_id, :binary_id
      field :sku, :string
      field :quantity, :integer
      field :unit_price_cents, :integer
      field :subtotal_cents, :integer
    end
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :id,
      :customer_id,
      :status,
      :placed_at,
      :total_cents,
      :currency
    ])
    |> validate_required([
      :customer_id,
      :status,
      :total_cents,
      :currency
    ])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> cast_embed(:line_items, with: &line_item_changeset/2)
  end

  def new(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  def add_line_item(%__MODULE__{status: :draft} = order, attrs) do
    with {:ok, line_item} <- new_line_item(attrs) do
      line_items = order.line_items ++ [line_item]

      {:ok,
       %{
         order
         | line_items: line_items,
           total_cents: calculate_total_cents(line_items)
       }}
    end
  end

  def add_line_item(%__MODULE__{}, _attrs) do
    {:error, :order_not_editable}
  end

  def place(%__MODULE__{status: :draft, line_items: [_ | _]} = order) do
    with {:ok, order} <- transition(order, :placed) do
      {:ok,
       %{
         order
         | placed_at: DateTime.utc_now() |> DateTime.truncate(:second),
           total_cents: calculate_total_cents(order.line_items)
       }}
    end
  end

  def place(%__MODULE__{status: :draft, line_items: []}) do
    {:error, :empty_order}
  end

  def place(%__MODULE__{}) do
    {:error, :order_not_placeable}
  end

  def cancel(%__MODULE__{status: :placed} = order) do
    transition(order, :cancelled)
  end

  def cancel(%__MODULE__{}) do
    {:error, :order_not_cancellable}
  end

  defp calculate_total_cents(line_items) do
    Enum.reduce(line_items, 0, fn line_item, acc ->
      acc + line_item.subtotal_cents
    end)
  end

  defp new_line_item(attrs) do
    struct!(__MODULE__.LineItem)
    |> line_item_changeset(attrs)
    |> apply_action(:insert)
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [
      :id,
      :product_id,
      :sku,
      :quantity,
      :unit_price_cents,
      :subtotal_cents
    ])
    |> validate_required([
      :product_id,
      :sku,
      :quantity,
      :unit_price_cents
    ])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> put_calculated_subtotal()
  end

  defp put_calculated_subtotal(changeset) do
    quantity = get_field(changeset, :quantity)
    unit_price_cents = get_field(changeset, :unit_price_cents)

    if is_integer(quantity) and is_integer(unit_price_cents) do
      put_change(changeset, :subtotal_cents, quantity * unit_price_cents)
    else
      changeset
    end
  end
end
```

Notes:

- `Order` uses `embedded_schema` to reuse Ecto validation.
- `Order` is not database-backed.
- `Order` owns the state machine.
- `Order` owns all updates to `line_items`.
- `line_items` are defined inline inside `Order`'s `embedded_schema`.
- Child changesets are private functions on `Order`.
- `Order` does not call `Repo`.

## 13. Gearbox and State Machines

State transitions should be maintained by the aggregate root.

For example, `Order` owns the `status` field and controls valid transitions:

```elixir
use Gearbox,
  field: :status,
  states: [:draft, :placed, :cancelled],
  initial: :draft,
  transitions: %{
    draft: [:placed, :cancelled],
    placed: [:cancelled]
  }
```

This keeps state transition rules close to the business behavior they protect.

The aggregate should expose intention-revealing functions:

```elixir
Order.place(order)
Order.cancel(order)
```

Instead of arbitrary state updates:

```elixir
%{order | status: :placed}
```

The state machine should be used to prevent invalid transitions, while aggregate functions should enforce additional business rules.

For example:

```text
State machine rule:
  draft -> placed is allowed

Business rule:
  draft -> placed is only allowed if the order has at least one line item
```

Both belong in the aggregate root.

## 14. `embedded_schema` vs Database-Backed `schema`

This distinction is central to the architecture.

### `embedded_schema`

Use `embedded_schema` for:

- Domain aggregates.
- Inline aggregate child definitions.
- Command and query handler input validation.
- In-memory data structures.
- Reusing Ecto changesets without database persistence.

`embedded_schema` modules are not database-backed.

Do not do this:

```elixir
Repo.get(MyApp.Sales.Order, id)
```

### Database-backed `schema`

Use `schema "table_name"` for:

- Database persistence.
- Ecto queries.
- Repo-backed changesets.
- Associations.
- Table mapping.

Do this:

```elixir
Repo.get(MyApp.Repo.Sales.Order, id)
```

Then map the persistence schema into the domain aggregate when domain behavior is needed.

### Rule of Thumb

```text
MyApp.Sales.Order
  embedded_schema
  domain validation
  state machine
  business transitions
  no Repo

MyApp.Repo.Sales.Order
  schema "orders"
  database queries
  persistence changesets
  Repo-backed
```

## 15. Persistence Schema Example

```elixir
defmodule MyApp.Repo.Sales.Order do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias MyApp.Accounts.Scope
  alias MyApp.Repo.Sales.OrderLineItem

  schema "orders" do
    field :customer_id, :binary_id
    field :organization_id, :binary_id
    field :tenant_id, :binary_id

    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled]
    field :placed_at, :utc_datetime
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    has_many :line_items, OrderLineItem,
      foreign_key: :order_id,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def by_id(query \\ __MODULE__, id) do
    from order in query,
      where: order.id == ^id
  end

  def for_customer(query \\ __MODULE__, customer_id) do
    from order in query,
      where: order.customer_id == ^customer_id
  end

  def visible_to(query \\ __MODULE__, %Scope{} = scope) do
    from order in query,
      where: order.organization_id == ^scope.organization.id,
      where: order.tenant_id == ^scope.tenant_id
  end

  def preload_line_items(query \\ __MODULE__) do
    from order in query,
      preload: [:line_items]
  end

  def lock_for_update(query \\ __MODULE__) do
    from order in query,
      lock: "FOR UPDATE"
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :customer_id,
      :organization_id,
      :tenant_id,
      :status,
      :placed_at,
      :total_cents,
      :currency
    ])
    |> validate_required([
      :customer_id,
      :organization_id,
      :tenant_id,
      :status,
      :total_cents,
      :currency
    ])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
  end

  def aggregate_changeset(order, attrs) do
    order
    |> changeset(attrs)
    |> cast_assoc(:line_items, with: &OrderLineItem.changeset/2)
  end
end
```

## 16. Persistence Child Schema Example

```elixir
defmodule MyApp.Repo.Sales.OrderLineItem do
  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Repo.Sales.Order

  schema "order_line_items" do
    field :product_id, :binary_id
    field :sku, :string
    field :quantity, :integer
    field :unit_price_cents, :integer
    field :subtotal_cents, :integer

    belongs_to :order, Order

    timestamps(type: :utc_datetime)
  end

  def changeset(order_line_item, attrs) do
    order_line_item
    |> cast(attrs, [
      :id,
      :product_id,
      :sku,
      :quantity,
      :unit_price_cents,
      :subtotal_cents
    ])
    |> validate_required([
      :product_id,
      :sku,
      :quantity,
      :unit_price_cents,
      :subtotal_cents
    ])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:subtotal_cents, greater_than_or_equal_to: 0)
  end
end
```

## 17. Persistence Mapping

Mapping between persistence schemas and domain aggregates should be explicit.

Mapping can live in command/query handlers, private helper modules, or dedicated mapper modules depending on project size.

The important rule is that mapping should not leak persistence concerns into aggregate behavior.

Example:

```elixir
defp to_domain_order(%OrderSchema{} = order_schema) do
  attrs = %{
    id: order_schema.id,
    customer_id: order_schema.customer_id,
    status: order_schema.status,
    placed_at: order_schema.placed_at,
    total_cents: order_schema.total_cents,
    currency: order_schema.currency,
    line_items:
      order_schema.line_items
      |> List.wrap()
      |> Enum.map(&order_line_item_to_domain_attrs/1)
  }

  {:ok, order} = Order.new(attrs)
  order
end

defp order_line_item_to_domain_attrs(%OrderLineItemSchema{} = line_item_schema) do
  %{
    id: line_item_schema.id,
    product_id: line_item_schema.product_id,
    sku: line_item_schema.sku,
    quantity: line_item_schema.quantity,
    unit_price_cents: line_item_schema.unit_price_cents,
    subtotal_cents: line_item_schema.subtotal_cents
  }
end

defp order_to_attrs(%Scope{} = scope, %Order{} = order) do
  %{
    customer_id: order.customer_id,
    organization_id: scope.organization.id,
    tenant_id: scope.tenant_id,
    status: order.status,
    placed_at: order.placed_at,
    total_cents: order.total_cents,
    currency: order.currency,
    line_items: Enum.map(order.line_items, &order_line_item_to_attrs/1)
  }
end

defp order_line_item_to_attrs(line_item) do
  %{
    id: line_item.id,
    product_id: line_item.product_id,
    sku: line_item.sku,
    quantity: line_item.quantity,
    unit_price_cents: line_item.unit_price_cents,
    subtotal_cents: line_item.subtotal_cents
  }
end
```

Mapping may look repetitive, but it keeps the boundary explicit.

This prevents database concerns from leaking into domain logic.

## 18. Updating an Existing Aggregate

When updating an existing aggregate inside a command handler:

1. Authorize the operation with `%Scope{}`.
2. Load the persistence schema through a scope-aware query.
3. Lock it if strong consistency is required.
4. Preload aggregate children.
5. Map to the domain aggregate.
6. Apply aggregate behavior.
7. Persist the aggregate back through persistence schemas.

Example:

```elixir
defmodule MyApp.Sales.Commands.PlaceExistingOrder do
  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Repo.Sales.Order, as: OrderSchema

  def handle(%Scope{} = scope, order_id) do
    Repo.transaction(fn ->
      with :ok <- authorize(scope, :place_order),
           {:ok, order_schema} <- get_order_schema_for_update(scope, order_id),
           order <- to_domain_order(order_schema),
           {:ok, placed_order} <- Order.place(order),
           {:ok, saved_order_schema} <- update_order_aggregate(order_schema, placed_order) do
        to_domain_order(saved_order_schema)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp get_order_schema_for_update(%Scope{} = scope, order_id) do
    OrderSchema
    |> OrderSchema.by_id(order_id)
    |> OrderSchema.visible_to(scope)
    |> OrderSchema.lock_for_update()
    |> OrderSchema.preload_line_items()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      order_schema -> {:ok, order_schema}
    end
  end
end
```

This keeps aggregate updates consistent while still relying on Ecto for persistence.

## 19. Cross-Context Communication and Top-Level Use Cases

A bounded context should not secretly orchestrate another bounded context's business process from inside its own command handler.

Cross-context workflows should live in top-level use case modules under:

```bash
lib/my_app/use_cases/
```

Use command and query handlers for operations inside one bounded context.

Use top-level use cases for workflows that coordinate multiple bounded contexts.

Example:

```text
Single bounded context operation:
  MyApp.Sales.Commands.PlaceOrder

Cross-context workflow:
  MyApp.UseCases.Checkout
```

A checkout workflow may involve:

- Sales placing an order.
- Inventory reserving stock.
- Billing authorizing payment.
- Notifications sending confirmation.

That should not all live inside `MyApp.Sales.Commands.PlaceOrder`.

Example:

```elixir
defmodule MyApp.UseCases.Checkout do
  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Sales

  def run(%Scope{} = scope, attrs) do
    with {:ok, order} <- Sales.place_order(scope, attrs.order),
         {:ok, _reservation} <- Inventory.reserve_stock(scope, order.id),
         {:ok, _payment} <- Billing.authorize_payment(scope, order.id, attrs.payment) do
      {:ok, order}
    end
  end
end
```

The rule is:

```text
If the workflow coordinates multiple bounded contexts, put it in `MyApp.UseCases.*`.
```

### Context-to-context calls

Contexts may expose public APIs that other contexts or use cases can call.

However, avoid hidden cross-context orchestration inside bounded context internals.

Prefer:

```elixir
MyApp.UseCases.Checkout.run(scope, attrs)
```

Calling:

```elixir
Sales.place_order(scope, attrs.order)
Inventory.reserve_stock(scope, order.id)
Billing.authorize_payment(scope, order.id, attrs.payment)
```

Avoid:

```elixir
Sales.place_order(scope, attrs)
# secretly reserves inventory and authorizes payment inside Sales
```

The top-level use case makes the workflow visible.

## 20. Database Migration Example

```elixir
defmodule MyApp.Repo.Migrations.CreateSalesOrders do
  use Ecto.Migration

  def change do
    create table(:orders) do
      add :customer_id, :binary_id, null: false
      add :organization_id, :binary_id, null: false
      add :tenant_id, :binary_id, null: false
      add :status, :string, null: false
      add :placed_at, :utc_datetime
      add :total_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "USD"

      timestamps(type: :utc_datetime)
    end

    create table(:order_line_items) do
      add :order_id, references(:orders, on_delete: :delete_all), null: false
      add :product_id, :binary_id, null: false
      add :sku, :string, null: false
      add :quantity, :integer, null: false
      add :unit_price_cents, :integer, null: false
      add :subtotal_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:orders, [:customer_id])
    create index(:orders, [:organization_id])
    create index(:orders, [:tenant_id])
    create index(:order_line_items, [:order_id])
    create index(:order_line_items, [:product_id])
  end
end
```

## 21. Controller Example

Controllers and LiveViews should call the public context API or top-level use cases.

For a single-context operation:

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  alias MyApp.Sales

  def create(conn, %{"order" => order_params}) do
    scope = conn.assigns.scope

    case Sales.place_order(scope, order_params) do
      {:ok, order} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: order.id,
          status: order.status,
          total_cents: order.total_cents,
          currency: order.currency
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})

      {:error, :empty_order} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Order must contain at least one line item"})

      {:error, :unauthorized} ->
        send_resp(conn, 403, "")

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.scope

    case Sales.get_order(scope, id) do
      {:ok, order} ->
        json(conn, %{
          id: order.id,
          customer_id: order.customer_id,
          status: order.status,
          total_cents: order.total_cents,
          currency: order.currency,
          line_items:
            Enum.map(order.line_items, fn line_item ->
              %{
                id: line_item.id,
                product_id: line_item.product_id,
                sku: line_item.sku,
                quantity: line_item.quantity,
                unit_price_cents: line_item.unit_price_cents,
                subtotal_cents: line_item.subtotal_cents
              }
            end)
        })

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end
end
```

For a cross-context workflow:

```elixir
defmodule MyAppWeb.CheckoutController do
  use MyAppWeb, :controller

  alias MyApp.UseCases.Checkout

  def create(conn, params) do
    scope = conn.assigns.scope

    case Checkout.run(scope, params) do
      {:ok, order} ->
        json(conn, %{order_id: order.id})

      {:error, :unauthorized} ->
        send_resp(conn, 403, "")

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end
end
```

Controllers should not:

- Call `Repo` directly for domain use cases.
- Modify aggregate children directly.
- Implement business rules.
- Bypass the public context API.
- Hide cross-context orchestration in controller code.

## 22. Worker Example

Workers belong inside the bounded context when they represent domain-specific background work.

Example:

```elixir
defmodule MyApp.Sales.Workers.SendOrderConfirmation do
  use Oban.Worker, queue: :sales

  alias MyApp.Accounts.Scope
  alias MyApp.Sales

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id, "order_id" => order_id}}) do
    scope = %Scope{tenant_id: tenant_id, roles: [:system]}

    with {:ok, order} <- Sales.get_order(scope, order_id) do
      # Send confirmation email, publish event, or call notification service.
      :ok
    end
  end
end
```

Workers should usually call the public context API rather than directly modifying persistence schemas.

If a worker coordinates multiple bounded contexts, consider placing the workflow in `MyApp.UseCases.*` and having the worker call the use case.

## 23. Property-Based Testing

This architecture makes property-based testing practical because aggregate behavior is mostly pure and in-memory.

Aggregate functions should generally look like this:

```elixir
Order.add_line_item(order, attrs)
Order.place(order)
Order.cancel(order)
```

They return data:

```elixir
{:ok, updated_order}
{:error, reason}
```

They do not require:

- Database setup.
- Fixtures.
- `Repo.insert!`.
- SQL sandboxing.
- Preloads.
- Controllers.

This allows property-based testing to validate business invariants across many generated inputs and many generated operation sequences.

Useful properties for an `Order` aggregate include:

- `total_cents` always equals the sum of line item subtotals.
- Line item subtotal always equals `quantity * unit_price_cents`.
- Non-draft orders cannot be edited.
- Empty orders cannot be placed.
- Invalid state transitions are rejected.
- Cancelling an order does not change its total.
- Placed orders cannot be placed again.
- Cancelled orders cannot be edited.
- All valid sequences of public aggregate operations preserve aggregate invariants.

Property tests should cover both data properties and operation-sequence properties.

```text
Data properties:
  Generated line items produce correct totals.

Operation-sequence properties:
  Generated command sequences preserve aggregate invariants.
```

### Data property example

```elixir
defmodule MyApp.Sales.OrderPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias MyApp.Sales.Order

  defp uuid_generator do
    gen all bytes <- binary(length: 16) do
      Ecto.UUID.load!(bytes)
    end
  end

  defp line_item_generator do
    gen all product_id <- uuid_generator(),
            sku <- string(:alphanumeric, min_length: 1),
            quantity <- integer(1..100),
            unit_price_cents <- integer(0..100_000) do
      %{
        product_id: product_id,
        sku: sku,
        quantity: quantity,
        unit_price_cents: unit_price_cents
      }
    end
  end

  property "order total equals the sum of line item subtotals" do
    check all customer_id <- uuid_generator(),
              line_items <- list_of(line_item_generator(), min_length: 1, max_length: 50) do
      {:ok, order} =
        Order.new(%{
          customer_id: customer_id,
          currency: "USD",
          status: :draft,
          total_cents: 0,
          line_items: []
        })

      {:ok, order} =
        Enum.reduce_while(line_items, {:ok, order}, fn attrs, {:ok, order} ->
          case Order.add_line_item(order, attrs) do
            {:ok, order} -> {:cont, {:ok, order}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      expected_total =
        order.line_items
        |> Enum.map(& &1.subtotal_cents)
        |> Enum.sum()

      assert order.total_cents == expected_total
    end
  end
end
```

### Operation-sequence property example

```elixir
defmodule MyApp.Sales.OrderSequencePropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias MyApp.Sales.Order

  defp operation_generator do
    one_of([
      constant(:place),
      constant(:cancel),
      gen all quantity <- integer(1..10),
              unit_price_cents <- integer(0..10_000) do
        {:add_line_item,
         %{
           product_id: Ecto.UUID.generate(),
           sku: "SKU-#{System.unique_integer([:positive])}",
           quantity: quantity,
           unit_price_cents: unit_price_cents
         }}
      end
    ])
  end

  property "all operation sequences preserve order invariants" do
    check all operations <- list_of(operation_generator(), max_length: 100) do
      {:ok, order} =
        Order.new(%{
          customer_id: Ecto.UUID.generate(),
          currency: "USD",
          status: :draft,
          total_cents: 0,
          line_items: []
        })

      final_order =
        Enum.reduce(operations, order, fn operation, order ->
          case apply_operation(order, operation) do
            {:ok, order} -> order
            {:error, _reason} -> order
          end
        end)

      assert_order_invariants(final_order)
    end
  end

  defp apply_operation(order, {:add_line_item, attrs}), do: Order.add_line_item(order, attrs)
  defp apply_operation(order, :place), do: Order.place(order)
  defp apply_operation(order, :cancel), do: Order.cancel(order)

  defp assert_order_invariants(order) do
    expected_total =
      order.line_items
      |> Enum.map(& &1.subtotal_cents)
      |> Enum.sum()

    assert order.total_cents == expected_total

    for line_item <- order.line_items do
      assert line_item.quantity > 0
      assert line_item.unit_price_cents >= 0
      assert line_item.subtotal_cents == line_item.quantity * line_item.unit_price_cents
    end

    if order.status in [:placed, :cancelled] do
      assert order.total_cents == expected_total
    end
  end
end
```

Persistence and mapping should still be tested with integration tests.

The testing split should be:

```text
Aggregate tests:
  Fast, property-based, no database.

Command/query handler tests:
  Use Repo, transactions, scope, authorization, persistence schemas, and mapping.

Use case tests:
  Verify cross-context orchestration and failure behavior.

Controller tests:
  Verify HTTP behavior and response shape.
```

## 24. Architecture Rules and Guidelines

### 24.1 Public contexts are thin facades

The public context module should usually expose functions through `defdelegate`.

Prefer:

```elixir
defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
```

Avoid turning the public context into a large procedural service module.

### 24.2 Scope comes first

Every public context function whose result or side effect depends on actor, organization, tenant, permissions, request actor, or visibility must take `%Scope{}` as the first argument.

Prefer:

```elixir
Sales.get_order(scope, id)
```

Avoid:

```elixir
Sales.get_order(id)
```

unless the operation is truly public and visibility-independent.

### 24.3 Command and query handlers are self-contained

Command and query handlers should own the application logic for one bounded context operation.

They may call:

- Authorization helpers.
- Private input changesets.
- Aggregates.
- Persistence schemas.
- `Repo`.
- Mapping helpers.

They should not orchestrate unrelated bounded contexts.

### 24.4 Cross-context workflows live in use cases

If a workflow coordinates multiple bounded contexts, place it under:

```bash
lib/my_app/use_cases/
```

Prefer:

```elixir
MyApp.UseCases.Checkout.run(scope, attrs)
```

Avoid hiding checkout orchestration inside `MyApp.Sales.Commands.PlaceOrder`.

### 24.5 Aggregate children are inlined in the aggregate root

Child objects should be defined inline inside the aggregate root's `embedded_schema`.

Prefer:

```elixir
defmodule MyApp.Sales.Order do
  embedded_schema do
    embeds_many :line_items, LineItem, primary_key: false do
      field :product_id, :binary_id
      field :quantity, :integer
      field :unit_price_cents, :integer
    end
  end
end
```

Avoid hand-authoring aggregate child modules:

```elixir
defmodule MyApp.Sales.Order.LineItem do
end
```

### 24.6 All child updates go through the aggregate root

Do not let arbitrary code update aggregate children directly.

Prefer:

```elixir
Order.change_line_item_quantity(order, line_item_id, quantity)
```

Avoid:

```elixir
LineItem.change_quantity(line_item, quantity)
```

Child changesets should usually be private functions on the aggregate root.

### 24.7 Aggregates do not call `Repo`

Avoid:

```elixir
def place(order) do
  order
  |> change(status: :placed)
  |> Repo.update()
end
```

Prefer:

```elixir
def place(order) do
  {:ok, %{order | status: :placed}}
end
```

Then persist from the command handler.

### 24.8 Keep command validation separate from persistence validation

Command validation answers:

```text
Is this input acceptable for this use case?
```

Persistence validation answers:

```text
Can this data be safely stored in this table?
```

They often overlap, but they are not the same thing.

### 24.9 Use consistent names

Choose one term and use it everywhere.

Prefer:

```text
line_items
cancelled
```

Avoid mixing:

```text
line_items / lines
cancelled / canceled
```

### 24.10 Use `embeds_many` for collections

If an order has multiple line items, use:

```elixir
embeds_many :line_items, LineItem, primary_key: false do
  field :product_id, :binary_id
  field :quantity, :integer
end
```

not:

```elixir
embeds_one :line_items, LineItem
```

### 24.11 Store money consistently

Prefer storing money as integer cents plus currency:

```elixir
field :total_cents, :integer
field :currency, :string
```

Avoid mixing money representations unless there is explicit mapping between them.

### 24.12 Use `Ecto.Enum` for atom statuses

If the domain uses atom statuses:

```elixir
:draft
:placed
:cancelled
```

then persistence can use:

```elixir
field :status, Ecto.Enum, values: [:draft, :placed, :cancelled]
```

Avoid using `:integer` for status unless there is an explicit reason and conversion layer.

### 24.13 Be careful with `cast_assoc` replacement behavior

This is common for aggregate persistence:

```elixir
has_many :line_items, OrderLineItem, on_replace: :delete
```

That means if a line item is missing from the submitted association data, Ecto treats it as removed.

This can be correct when the aggregate owns the full child collection.

It can be dangerous for partial updates.

### 24.14 Use locks when consistency matters

For workflows that update existing aggregates, use row locking when concurrent updates would violate invariants.

Example:

```elixir
OrderSchema
|> OrderSchema.by_id(order_id)
|> OrderSchema.visible_to(scope)
|> OrderSchema.lock_for_update()
|> OrderSchema.preload_line_items()
|> Repo.one()
```

### 24.15 Query handlers may return read models

Not every read must return an aggregate.

Use aggregates when behavior or invariants matter.

Use read models when building screens, dashboards, reports, exports, or optimized queries.

### 24.16 Property-based testing should focus on aggregate invariants

Because aggregates are modeled as in-memory structures with pure transition functions, property-based testing is especially useful for:

- Totals.
- State transitions.
- Aggregate consistency.
- Valid operation sequences.
- Invalid operation rejection.

## 25. Dependency Direction

Preferred dependency direction for a single-context operation:

```text
Controller / LiveView / Worker
  -> MyApp.Sales
      -> MyApp.Sales.Commands.* / MyApp.Sales.Queries.*
          -> Aggregate
          -> Persistence Schema
          -> Repo
```

Preferred dependency direction for a cross-context workflow:

```text
Controller / LiveView / Worker
  -> MyApp.UseCases.*
      -> MyApp.Sales
      -> MyApp.Inventory
      -> MyApp.Billing
```

The aggregate should not depend on persistence.

The persistence schema should not contain business decisions.

The public context should not become a large orchestration module.

Single-context orchestration belongs in command and query handlers.

Cross-context orchestration belongs in top-level use cases.

## 26. What This Architecture Optimizes For

This structure optimizes for:

- Clear bounded context ownership.
- Thin and stable public context APIs.
- Explicit scope-aware authorization and visibility.
- Self-contained command and query handlers.
- Visible cross-context workflows.
- Explicit business invariants.
- Testable aggregate behavior.
- Property-based testing of generated inputs and operation sequences.
- Controlled persistence boundaries.
- Reduced controller and LiveView complexity.
- Safe state transitions.
- Better separation between input validation, domain behavior, and database validation.

It does introduce some overhead:

- Mapping between domain and persistence structs.
- More modules.
- More explicit boundaries.
- Some duplicated validations between command/domain/persistence layers.
- More deliberate decisions about where orchestration belongs.

That overhead is worthwhile when the domain has meaningful business rules, state transitions, tenant or permission boundaries, or aggregate consistency requirements.

For simple CRUD resources, a lighter Phoenix context with Ecto schemas may be sufficient.

## 27. Summary

The recommended structure is:

```text
Public bounded context facade:
  MyApp.Sales

Single-context write operations:
  MyApp.Sales.Commands.*

Single-context read operations:
  MyApp.Sales.Queries.*

Cross-context workflows:
  MyApp.UseCases.*

Business invariants:
  MyApp.Sales.Order

Aggregate children:
  line_items
  Defined inline inside MyApp.Sales.Order.

Database persistence:
  MyApp.Repo.Sales.*

Background work:
  MyApp.Sales.Workers.*
```

The most important rules are:

```text
Public contexts are thin facades.
Use `%Scope{}` as the first argument for actor-, tenant-, organization-, permission-, or visibility-sensitive operations.
Command and query handlers are self-contained for single-context operations.
Command and query handlers own their input schemas.
Cross-context orchestration belongs in `lib/my_app/use_cases/`.
All aggregate updates go through the aggregate root.
Aggregate children are defined inline inside the aggregate root by default.
The aggregate root owns the state machine.
Use `embedded_schema` for in-memory validation, domain aggregates, and handler input schemas.
Use database-backed `schema` for persistence.
Do not call `Repo` from aggregates.
Use property-based testing to validate aggregate invariants across generated inputs and generated operation sequences.
```

This gives the team a Phoenix-native, scope-aware, testable, and maintainable structure for implementing bounded contexts with meaningful domain behavior.
