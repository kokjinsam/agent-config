# Code Templates

Full code templates for each layer. Substitute `MyApp` / `Sales` / `Order` with the detected app
namespace and the context/aggregate names. Mirror the surrounding codebase's conventions (id type,
`timestamps` type, formatting) where they differ.

## Contents

- [Public facade](#public-facade)
- [Policy](#policy)
- [Command handler](#command-handler)
- [Query handler](#query-handler)
- [Aggregate root (with mapping)](#aggregate-root)
- [Updating an existing aggregate](#updating-an-existing-aggregate)
- [Persistence schema](#persistence-schema)
- [Persistence child schema](#persistence-child-schema)
- [Use case (cross-context)](#use-case)
- [Worker](#worker)
- [Controller](#controller)
- [Migration](#migration)

## Public facade

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

## Policy

Default home for authorization. Handlers call `Policy.authorize/2,3`.

```elixir
defmodule MyApp.Sales.Policy do
  alias MyApp.Accounts.Scope

  @spec authorize(Scope.t(), atom(), map()) :: :ok | {:error, :unauthorized}
  def authorize(scope, action, params \\ %{})

  def authorize(%Scope{roles: roles}, _action, _params) when :system in roles, do: :ok

  def authorize(%Scope{} = scope, :place_order, _params) do
    if :place_order in scope.permissions, do: :ok, else: {:error, :unauthorized}
  end

  def authorize(%Scope{} = scope, :cancel_order, _params) do
    if :cancel_order in scope.permissions, do: :ok, else: {:error, :unauthorized}
  end

  def authorize(%Scope{}, _action, _params), do: {:error, :unauthorized}
end
```

## Command handler

The handler owns its input `embedded_schema`, authorizes via the policy, wraps the work in
`Repo.transact`, calls the aggregate, and persists. Returns the domain aggregate via
`Order.from_schema/1`.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Policy
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
    Repo.transact(fn ->
      with :ok <- Policy.authorize(scope, :place_order),
           {:ok, command} <- validate(attrs),
           {:ok, order} <- build_order(command),
           {:ok, order} <- Order.place(order),
           {:ok, schema} <- insert_order_aggregate(scope, order) do
        {:ok, Order.from_schema(schema)}
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
    if Enum.empty?(get_field(changeset, :line_items) || []) do
      add_error(changeset, :line_items, "must contain at least one item")
    else
      changeset
    end
  end

  defp build_order(%__MODULE__{} = command) do
    base = %{customer_id: command.customer_id, currency: command.currency, status: :draft,
             total_cents: 0, line_items: []}

    with {:ok, order} <- Order.new(base) do
      Enum.reduce_while(command.line_items, {:ok, order}, fn attrs, {:ok, order} ->
        case Order.add_line_item(order, Map.from_struct(attrs)) do
          {:ok, order} -> {:cont, {:ok, order}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp insert_order_aggregate(%Scope{} = scope, %Order{} = order) do
    %OrderSchema{}
    |> OrderSchema.aggregate_changeset(Order.to_attrs(scope, order))
    |> Repo.insert()
  end
end
```

## Query handler

```elixir
defmodule MyApp.Sales.Queries.GetOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Repo.Sales.Order, as: OrderSchema

  @primary_key false
  embedded_schema do
    field :id, :binary_id
  end

  def handle(%Scope{} = scope, id) when not is_map(id), do: handle(scope, %{id: id})

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, input} <- validate(attrs),
         {:ok, schema} <- fetch_order(scope, input) do
      {:ok, Order.from_schema(schema)}
    end
  end

  defp validate(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id])
    |> validate_required([:id])
    |> apply_action(:validate)
  end

  defp fetch_order(%Scope{} = scope, %__MODULE__{} = input) do
    query =
      OrderSchema
      |> OrderSchema.by_id(input.id)
      |> OrderSchema.visible_to(scope)
      |> OrderSchema.preload_line_items()

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end
end
```

> Drop the `visible_to/2` call only if the project's `Scope` has no org/tenant fields.

## Aggregate root

`embedded_schema`, Gearbox state machine, inline children with private changesets, pure transitions,
and **mapping in both directions**. Never calls `Repo`.

```elixir
defmodule MyApp.Sales.Order do
  use Ecto.Schema
  import Ecto.Changeset

  use Gearbox,
    field: :status,
    states: [:draft, :placed, :cancelled],
    initial: :draft,
    transitions: %{draft: [:placed, :cancelled], placed: [:cancelled]}

  alias MyApp.Accounts.Scope
  alias MyApp.Repo.Sales.Order, as: OrderSchema

  embedded_schema do
    field :customer_id, :binary_id
    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled], default: :draft
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

  # --- construction -------------------------------------------------------

  def new(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [:id, :customer_id, :status, :placed_at, :total_cents, :currency])
    |> validate_required([:customer_id, :status, :total_cents, :currency])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> cast_embed(:line_items, with: &line_item_changeset/2)
  end

  # --- transitions (pure) -------------------------------------------------

  def add_line_item(%__MODULE__{status: :draft} = order, attrs) do
    with {:ok, line_item} <- new_line_item(attrs) do
      line_items = order.line_items ++ [line_item]
      {:ok, %{order | line_items: line_items, total_cents: calculate_total_cents(line_items)}}
    end
  end

  def add_line_item(%__MODULE__{}, _attrs), do: {:error, :order_not_editable}

  def place(%__MODULE__{status: :draft, line_items: [_ | _]} = order) do
    with {:ok, order} <- transition(order, :placed) do
      {:ok, %{order | placed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                      total_cents: calculate_total_cents(order.line_items)}}
    end
  end

  def place(%__MODULE__{status: :draft, line_items: []}), do: {:error, :empty_order}
  def place(%__MODULE__{}), do: {:error, :order_not_placeable}

  def cancel(%__MODULE__{status: :placed} = order), do: transition(order, :cancelled)
  def cancel(%__MODULE__{status: :draft} = order), do: transition(order, :cancelled)
  def cancel(%__MODULE__{}), do: {:error, :order_not_cancellable}

  # --- mapping (both directions, no Repo) ---------------------------------

  def from_schema(%OrderSchema{} = schema) do
    attrs = %{
      id: schema.id,
      customer_id: schema.customer_id,
      status: schema.status,
      placed_at: schema.placed_at,
      total_cents: schema.total_cents,
      currency: schema.currency,
      line_items: schema.line_items |> List.wrap() |> Enum.map(&line_item_from_schema/1)
    }

    {:ok, order} = new(attrs)
    order
  end

  def to_attrs(%Scope{} = scope, %__MODULE__{} = order) do
    %{
      customer_id: order.customer_id,
      # include only if Scope has these fields:
      organization_id: scope.organization && scope.organization.id,
      tenant_id: scope.tenant_id,
      status: order.status,
      placed_at: order.placed_at,
      total_cents: order.total_cents,
      currency: order.currency,
      line_items: Enum.map(order.line_items, &line_item_to_attrs/1)
    }
  end

  defp line_item_from_schema(li) do
    %{id: li.id, product_id: li.product_id, sku: li.sku, quantity: li.quantity,
      unit_price_cents: li.unit_price_cents, subtotal_cents: li.subtotal_cents}
  end

  defp line_item_to_attrs(li) do
    %{id: li.id, product_id: li.product_id, sku: li.sku, quantity: li.quantity,
      unit_price_cents: li.unit_price_cents, subtotal_cents: li.subtotal_cents}
  end

  # --- private helpers ----------------------------------------------------

  defp calculate_total_cents(line_items),
    do: Enum.reduce(line_items, 0, fn li, acc -> acc + (li.subtotal_cents || 0) end)

  defp new_line_item(attrs) do
    struct!(__MODULE__.LineItem)
    |> line_item_changeset(attrs)
    |> apply_action(:insert)
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:id, :product_id, :sku, :quantity, :unit_price_cents, :subtotal_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents])
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

> Mapping referencing `%OrderSchema{}` directly is intentional and acceptable — both modules belong
> to the same context. The only hard rule is that the aggregate never calls `Repo`.

## Updating an existing aggregate

Load through a scope-aware (and optionally locked) query, map to the aggregate, apply behavior,
persist back — all inside one `Repo.transact`.

```elixir
defmodule MyApp.Sales.Commands.PlaceExistingOrder do
  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Policy
  alias MyApp.Repo.Sales.Order, as: OrderSchema

  def handle(%Scope{} = scope, order_id) do
    Repo.transact(fn ->
      with :ok <- Policy.authorize(scope, :place_order),
           {:ok, schema} <- load_for_update(scope, order_id),
           {:ok, placed} <- Order.place(Order.from_schema(schema)),
           {:ok, saved} <- update_order_aggregate(scope, schema, placed) do
        {:ok, Order.from_schema(saved)}
      end
    end)
  end

  defp load_for_update(%Scope{} = scope, order_id) do
    OrderSchema
    |> OrderSchema.by_id(order_id)
    |> OrderSchema.visible_to(scope)
    |> OrderSchema.lock_for_update()
    |> OrderSchema.preload_line_items()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end

  defp update_order_aggregate(scope, schema, %Order{} = order) do
    schema
    |> OrderSchema.aggregate_changeset(Order.to_attrs(scope, order))
    |> Repo.update()
  end
end
```

## Persistence schema

```elixir
defmodule MyApp.Repo.Sales.Order do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias MyApp.Accounts.Scope
  alias MyApp.Repo.Sales.OrderLineItem

  schema "orders" do
    field :customer_id, :binary_id
    field :organization_id, :binary_id   # only if Scope has organization
    field :tenant_id, :binary_id         # only if Scope has tenant
    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled]
    field :placed_at, :utc_datetime
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    has_many :line_items, OrderLineItem, foreign_key: :order_id, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def by_id(query \\ __MODULE__, id), do: from(o in query, where: o.id == ^id)

  def for_customer(query \\ __MODULE__, customer_id),
    do: from(o in query, where: o.customer_id == ^customer_id)

  # only when Scope carries org/tenant:
  def visible_to(query \\ __MODULE__, %Scope{} = scope) do
    from o in query,
      where: o.organization_id == ^scope.organization.id,
      where: o.tenant_id == ^scope.tenant_id
  end

  def preload_line_items(query \\ __MODULE__), do: from(o in query, preload: [:line_items])
  def lock_for_update(query \\ __MODULE__), do: from(o in query, lock: "FOR UPDATE")

  def changeset(order, attrs) do
    order
    |> cast(attrs, [:customer_id, :organization_id, :tenant_id, :status, :placed_at,
                    :total_cents, :currency])
    |> validate_required([:customer_id, :status, :total_cents, :currency])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
  end

  def aggregate_changeset(order, attrs) do
    order
    |> changeset(attrs)
    |> cast_assoc(:line_items, with: &OrderLineItem.changeset/2)
  end
end
```

## Persistence child schema

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

  def changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:id, :product_id, :sku, :quantity, :unit_price_cents, :subtotal_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents, :subtotal_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:subtotal_cents, greater_than_or_equal_to: 0)
  end
end
```

## Use case

Cross-context orchestration, one shared `Repo.transact` for atomic rollback across contexts.

```elixir
defmodule MyApp.UseCases.Checkout do
  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Repo
  alias MyApp.Sales

  def run(%Scope{} = scope, attrs) do
    Repo.transact(fn ->
      with {:ok, order} <- Sales.place_order(scope, attrs.order),
           {:ok, _resv} <- Inventory.reserve_stock(scope, order.id),
           {:ok, _pay} <- Billing.authorize_payment(scope, order.id, attrs.payment) do
        {:ok, order}
      end
    end)
  end
end
```

## Worker

```elixir
defmodule MyApp.Sales.Workers.SendOrderConfirmation do
  use Oban.Worker, queue: :sales

  alias MyApp.Accounts.Scope
  alias MyApp.Sales

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id, "order_id" => order_id}}) do
    scope = %Scope{tenant_id: tenant_id, roles: [:system]}

    with {:ok, _order} <- Sales.get_order(scope, order_id) do
      # send confirmation, publish event, etc.
      :ok
    end
  end
end
```

## Controller

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  alias MyApp.Sales

  def create(conn, %{"order" => order_params}) do
    case Sales.place_order(conn.assigns.scope, order_params) do
      {:ok, order} ->
        conn |> put_status(:created) |> json(render_order(order))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: translate_errors(changeset)})

      {:error, :empty_order} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Order must contain at least one line item"})

      {:error, :unauthorized} ->
        send_resp(conn, 403, "")

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Sales.get_order(conn.assigns.scope, id) do
      {:ok, order} -> json(conn, render_order(order))
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end
end
```

## Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateSalesOrders do
  use Ecto.Migration

  def change do
    create table(:orders) do
      add :customer_id, :binary_id, null: false
      add :organization_id, :binary_id, null: false  # only if multi-tenant
      add :tenant_id, :binary_id, null: false         # only if multi-tenant
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
