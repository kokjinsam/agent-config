# Code Templates

Substitute `MyApp`, `Sales`, and `Order` with the detected app namespace and domain names. Mirror
the surrounding codebase's id type, timestamp type, formatter, migrations, and helper functions
where they differ.

## Contents

- Repo Flop helpers
- Public facade
- Public command handler
- Public query handler
- Public collection query with Flop
- Internal noun orchestration module
- Ecto schema with Gearbox, Flop derive, transitions, `build!/1`, and query fragments
- Child Ecto schema
- Cross-context reference
- Cross-context call inside a command or internal noun module
- Worker
- Async cross-context entry point through a facade
- Controller with boundary authorization
- Migration

## Repo Flop Helpers

Add these to the project Repo if absent. All public collection reads, filtering, ordering, and
pagination go through these helpers.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres

  def paginate(queryable, params, opts \\ []) do
    Flop.validate_and_run(queryable, params, opts)
  end

  def list(queryable, params, opts \\ []) do
    with {:ok, flop} <- Flop.validate(params, opts) do
      results =
        queryable
        |> Flop.filter(flop, opts)
        |> Flop.order_by(flop, opts)
        |> all()

      {:ok, results}
    end
  end
end
```

Use `paginate/3` when callers need metadata and `list/3` when callers need only the filtered and
ordered result list.

## Public Facade

Only expose operations that are necessary and important public boundary APIs. Do not scaffold
default CRUD-style functions just because an entity exists.

```elixir
defmodule MyApp.Sales do
  alias MyApp.Sales.Commands.CancelOrder
  alias MyApp.Sales.Commands.PlaceOrder
  alias MyApp.Sales.Queries.GetOrder
  alias MyApp.Sales.Queries.ListOrders

  defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
  defdelegate cancel_order(scope, attrs), to: CancelOrder, as: :handle
  defdelegate get_order(scope, attrs), to: GetOrder, as: :handle
  defdelegate list_orders(scope, params \\ %{}), to: ListOrders, as: :handle
end
```

No authorization and no orchestration live in the facade. Internal noun modules such as
`Sales.Orders` are not exposed unless their operation becomes a real public API and is wrapped in a
public command/query handler.

## Public Command Handler

The handler owns input validation, wraps work in `Repo.transact` when the operation needs an
atomicity boundary, checks business preconditions in the `with` chain, calls schema transition
functions, and persists through `Repo`.

It does not call authorization code.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order

  embedded_schema do
    field :customer_id, :binary_id
    field :currency, :string, default: "USD"

    embeds_many :line_items, LineItem do
      field :product_id, :binary_id
      field :sku, :string
      field :quantity, :integer
      field :unit_price_cents, :integer
    end
  end

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transact(fn ->
      with {:ok, command} <- validate(attrs),
           {:ok, order} <- build_order(scope, command),
           {:ok, placed} <- Repo.insert(Order.place(order)) do
        {:ok, placed}
      end
    end)
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
    |> validate_length(:line_items, min: 1)
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
  end

  defp build_order(%Scope{} = scope, %__MODULE__{} = command) do
    line_items =
      Enum.map(command.line_items, fn line_item ->
        %{
          product_id: line_item.product_id,
          sku: line_item.sku,
          quantity: line_item.quantity,
          unit_price_cents: line_item.unit_price_cents,
          subtotal_cents: line_item.quantity * line_item.unit_price_cents
        }
      end)

    attrs =
      %{
        customer_id: command.customer_id,
        currency: command.currency,
        total_cents: Enum.reduce(line_items, 0, &(&1.subtotal_cents + &2)),
        line_items: line_items
      }
      |> Map.merge(tenant_attrs_from_scope(scope))

    %Order{}
    |> Order.changeset(attrs)
    |> apply_action(:insert)
  end

  # Generate this helper only when Scope carries tenant/org fields.
  defp tenant_attrs_from_scope(%Scope{} = scope) do
    scope
    |> Map.from_struct()
    |> Map.take([:organization_id, :tenant_id])
  end
end
```

## Public Query Handler

Single-record identity lookups do not need Flop. They still validate input and use scoped query
fragments.

```elixir
defmodule MyApp.Sales.Queries.GetOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order

  embedded_schema do
    field :id, :binary_id
  end

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, input} <- validate(attrs) do
      query =
        Order
        |> Order.by_id(input.id)
        |> Order.visible_to(scope)
        |> Order.preload_line_items()

      case Repo.one(query) do
        nil -> {:error, :not_found}
        order -> {:ok, order}
      end
    end
  end

  defp validate(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id])
    |> validate_required([:id])
    |> apply_action(:validate)
  end
end
```

## Public Collection Query With Flop

Use this pattern only when the list is a necessary public read. All list/search/filter/sort paths
go through `Repo.list/3` or `Repo.paginate/3`.

```elixir
defmodule MyApp.Sales.Queries.ListOrders do
  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order

  def handle(%Scope{} = scope, params) when is_map(params) do
    Order
    |> Order.visible_to(scope)
    |> Order.preload_line_items()
    |> Repo.paginate(params, for: Order)
  end
end
```

Use `Repo.list(query, params, for: Order)` when the public API should return `{:ok, results}`
without pagination metadata.

## Internal Noun Orchestration Module

No `Workflows.*` convention. Internal orchestration modules live directly under the context
namespace and are named from ubiquitous language.

```elixir
defmodule MyApp.Sales.OrderVerification do
  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Queries.GetOrder

  def verify_for_fulfillment(%Scope{} = scope, attrs) when is_map(attrs) do
    order_id = Map.fetch!(attrs, :order_id)
    payment = Map.fetch!(attrs, :payment)

    Repo.transact(fn ->
      with {:ok, order} <- GetOrder.handle(scope, %{id: order_id}),
           {:ok, _reservation} <- Inventory.reserve_stock(scope, %{order_id: order.id}),
           {:ok, _payment} <- Billing.authorize_payment(scope, %{order_id: order.id, payment: payment}),
           {:ok, fulfilled} <- Repo.update(Order.mark_fulfilled(order)) do
        {:ok, fulfilled}
      end
    end)
  end
end
```

Use a plural schema noun such as `Orders` when it precisely names the behavior. Use a more specific
noun such as `OrderVerification` when the plural noun is too broad. Do not use `Processor`,
`Manager`, `Runner`, `Workflow`, `Orchestrator`, or `Service`.

## Ecto Schema

One schema per entity. It owns the table, Gearbox state machine, changesets, transition functions,
`build!/1`, Flop derive for public collection reads, and query fragments. It does not call `Repo`.

```elixir
defmodule MyApp.Sales.Order do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:status, :customer_id],
    sortable: [:inserted_at, :status],
    default_order: %{order_by: [:inserted_at], order_directions: [:desc]}
  }

  use Gearbox,
    field: :status,
    states: [:draft, :placed, :cancelled, :fulfilled],
    initial: :draft,
    transitions: %{
      draft: [:placed, :cancelled],
      placed: [:cancelled, :fulfilled]
    }

  alias MyApp.Accounts.Scope
  alias MyApp.Sales.OrderLineItem

  schema "orders" do
    field :customer_id, :binary_id
    field :organization_id, :binary_id
    field :tenant_id, :binary_id
    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled, :fulfilled], default: :draft
    field :placed_at, :utc_datetime
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"
    field :payment_intent_url, :string, virtual: true

    has_many :line_items, OrderLineItem, foreign_key: :order_id, on_replace: :delete

    timestamps()
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [:customer_id, :organization_id, :tenant_id, :total_cents, :currency])
    |> validate_required([:customer_id, :status, :total_cents, :currency])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> cast_assoc(:line_items, with: &OrderLineItem.changeset/2)
  end

  def build!(attrs) do
    %__MODULE__{
      customer_id: Map.fetch!(attrs, :customer_id),
      currency: Map.fetch!(attrs, :currency),
      total_cents: Map.fetch!(attrs, :total_cents)
    }
  end

  def place(order) do
    order
    |> change(placed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Gearbox.transition(:placed)
  end

  def cancel(order) do
    order
    |> change()
    |> Gearbox.transition(:cancelled)
  end

  def mark_fulfilled(order) do
    order
    |> change()
    |> Gearbox.transition(:fulfilled)
  end

  def add_line_item(order, attrs) do
    quantity = Map.fetch!(attrs, :quantity)
    unit_price_cents = Map.fetch!(attrs, :unit_price_cents)
    new_item = Map.put(attrs, :subtotal_cents, quantity * unit_price_cents)

    existing =
      Enum.map(order.line_items, fn item ->
        Map.take(item, [:id, :product_id, :sku, :quantity, :unit_price_cents, :subtotal_cents])
      end)

    items = existing ++ [new_item]

    order
    |> changeset(%{
      line_items: items,
      total_cents: Enum.reduce(items, 0, &(&1.subtotal_cents + &2))
    })
  end

  def by_id(query \\ __MODULE__, id), do: from(o in query, where: o.id == ^id)

  def for_customer(query \\ __MODULE__, customer_id),
    do: from(o in query, where: o.customer_id == ^customer_id)

  def visible_to(query \\ __MODULE__, %Scope{} = scope) do
    scope_attrs = Map.from_struct(scope)
    organization_id = Map.get(scope_attrs, :organization_id)
    tenant_id = Map.get(scope_attrs, :tenant_id)

    from o in query,
      where: o.organization_id == ^organization_id,
      where: o.tenant_id == ^tenant_id
  end

  def preload_line_items(query \\ __MODULE__),
    do: from(o in query, preload: [:line_items])

  def lock_for_update(query \\ __MODULE__),
    do: from(o in query, lock: "FOR UPDATE")
end
```

Only include tenant fields and `visible_to/2` clauses that match the actual `Scope` struct. Only
include `@derive Flop.Schema` when this schema participates in public collection reads.

## Child Ecto Schema

Sibling associations in the same context are fine.

```elixir
defmodule MyApp.Sales.OrderLineItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  alias MyApp.Sales.Order

  schema "order_line_items" do
    field :product_id, :binary_id
    field :sku, :string
    field :quantity, :integer
    field :unit_price_cents, :integer
    field :subtotal_cents, :integer

    belongs_to :order, Order

    timestamps()
  end

  def changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:product_id, :sku, :quantity, :unit_price_cents, :subtotal_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents, :subtotal_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:subtotal_cents, greater_than_or_equal_to: 0)
  end
end
```

## Cross-Context Reference

Cross-context references use bare FK columns, not `belongs_to`.

```elixir
defmodule MyApp.Reviews.Review do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reviews" do
    field :title, :string
    field :authored_by_id, :binary_id

    timestamps()
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [:title, :authored_by_id])
    |> validate_required([:title, :authored_by_id])
  end
end
```

Load the referenced record through the owning context's facade when needed:

```elixir
{:ok, author} <- Accounts.get_user(scope, %{id: review.authored_by_id})
```

## Cross-Context Call Inside A Command Or Internal Noun Module

Call the other context's public facade with the same `%Scope{}` and attrs maps. Let errors bubble
unless the public contract says otherwise.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Repo
  alias MyApp.Sales.Order

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transact(fn ->
      with {:ok, command} <- validate(attrs),
           {:ok, order} <- build_order(scope, command),
           {:ok, placed} <- Repo.insert(Order.place(order)),
           {:ok, _reservation} <- Inventory.reserve_stock(scope, %{order_id: placed.id}),
           {:ok, _payment} <- Billing.authorize_payment(scope, %{order_id: placed.id, payment: command.payment}) do
        {:ok, placed}
      end
    end)
  end
end
```

If the behavior is also driven by a worker or reused by multiple public operations, move the
sequence into a same-context internal noun module such as `Sales.OrderVerification`.

## Worker

Workers rebuild scope and call one public facade function or one same-context internal noun module.

```elixir
defmodule MyApp.Sales.Workers.FulfillOrderWorker do
  use Oban.Worker, queue: :sales

  alias MyApp.Accounts
  alias MyApp.Sales.OrderVerification

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => scope_attrs} = args}) do
    {:ok, scope} = Accounts.build_scope(scope_attrs)

    OrderVerification.verify_for_fulfillment(scope, %{
      order_id: Map.fetch!(args, "order_id"),
      payment: Map.fetch!(args, "payment")
    })
  end
end
```

Authorization happens before enqueue or at the external boundary that schedules the work. The
worker does not own authorization rules.

## Async Cross-Context Entry Point Through A Facade

When another context needs to enqueue work in this context, expose a public enqueue command on the
facade. Outsiders never reach into `Workers.*`.

```elixir
defmodule MyApp.Sales do
  alias MyApp.Sales.Commands.EnqueueFulfillment

  defdelegate enqueue_fulfillment(scope, attrs), to: EnqueueFulfillment, as: :handle
end
```

```elixir
defmodule MyApp.Sales.Commands.EnqueueFulfillment do
  alias MyApp.Accounts
  alias MyApp.Accounts.Scope
  alias MyApp.Sales.Workers.FulfillOrderWorker

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, input} <- validate(attrs) do
      %{
        "scope" => Accounts.serialize_scope(scope),
        "order_id" => input.order_id,
        "payment" => input.payment
      }
      |> FulfillOrderWorker.new()
      |> Oban.insert()
    end
  end

  defp validate(attrs) do
    order_id = Map.get(attrs, :order_id) || Map.get(attrs, "order_id")
    payment = Map.get(attrs, :payment) || Map.get(attrs, "payment")

    cond do
      not is_binary(order_id) -> {:error, :invalid_order_id}
      not is_map(payment) -> {:error, :invalid_payment}
      true -> {:ok, %{order_id: order_id, payment: payment}}
    end
  end
end
```

## Controller With Boundary Authorization

Controllers authorize at the boundary, call the facade, and delegate JSON shaping to the project's
view/serializer convention. The authorization module/helper shown here is deliberately web-layer,
not part of `MyApp.Sales`.

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  alias MyApp.Sales
  alias MyAppWeb.SalesPolicy

  def create(conn, %{"order" => order_params}) do
    scope = conn.assigns.scope

    with :ok <- SalesPolicy.authorize(scope, :place_order, order_params) do
      case Sales.place_order(scope, order_params) do
        {:ok, order} ->
          conn |> put_status(:created) |> render(:show, order: order)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(:unprocessable_entity) |> render(:errors, changeset: changeset)

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> render(:error, message: inspect(reason))
      end
    else
      {:error, :unauthorized} -> send_resp(conn, 403, "")
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.scope

    with :ok <- SalesPolicy.authorize(scope, :read_order, %{id: id}) do
      case Sales.get_order(scope, %{id: id}) do
        {:ok, order} -> render(conn, :show, order: order)
        {:error, :not_found} -> send_resp(conn, 404, "")
      end
    else
      {:error, :unauthorized} -> send_resp(conn, 403, "")
    end
  end
end
```

If authorization is handled by plugs, pipelines, or LiveView hooks, use those instead. Do not add a
policy module under the bounded context.

## Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateSalesOrders do
  use Ecto.Migration

  def change do
    create table(:orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :customer_id, :binary_id
      add :organization_id, :binary_id
      add :tenant_id, :binary_id
      add :status, :string
      add :placed_at, :utc_datetime
      add :total_cents, :integer, default: 0
      add :currency, :string, default: "USD"
      timestamps()
    end

    create table(:order_line_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :order_id, references(:orders, type: :binary_id, on_delete: :delete_all), null: false
      add :product_id, :binary_id
      add :sku, :string
      add :quantity, :integer
      add :unit_price_cents, :integer
      add :subtotal_cents, :integer
      timestamps()
    end

    create index(:orders, [:customer_id])
    create index(:orders, [:organization_id])
    create index(:orders, [:tenant_id])
    create index(:order_line_items, [:order_id])
    create index(:order_line_items, [:product_id])
  end
end
```

Only include tenant fields/indexes when the project Scope and spec require them. If the project
uses integer ids, use the existing generator convention instead of copying the binary-id fields.
