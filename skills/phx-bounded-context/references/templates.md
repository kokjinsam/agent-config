# Code Templates

Full code templates for each layer. Substitute `MyApp` / `Sales` / `Order` with the detected app
namespace and the context/entity names. Mirror the surrounding codebase's conventions (id type,
`timestamps` type, formatting) where they differ.

## Contents

- [Public facade](#public-facade)
- [Policy](#policy)
- [Command handler](#command-handler)
- [Query handler](#query-handler)
- [Ecto schema (parent, with Gearbox + transitions + queries)](#ecto-schema-parent)
- [Child Ecto schema](#child-ecto-schema)
- [Cross-context call in a command](#cross-context-call-in-a-command)
- [Worker](#worker)
- [Async cross-context entry point on a facade](#async-cross-context-entry-point-on-a-facade)
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
  defdelegate get_order(scope, attrs), to: GetOrder, as: :handle
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
`Repo.transact`, checks business preconditions in the `with` chain, calls the schema's transition
function (which returns a changeset), and persists through `Repo`. Returns the persisted schema
struct.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Policy

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
      with :ok            <- Policy.authorize(scope, :place_order),
           {:ok, command} <- validate(attrs),
           {:ok, order}   <- build_order(scope, command),
           :ok            <- ensure_has_line_items(order),
           {:ok, placed}  <- Repo.insert(Order.place(order)) do
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
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
  end

  # Cross-field business precondition lives in the handler, not the schema.
  defp ensure_has_line_items(%Order{line_items: [_ | _]}), do: :ok
  defp ensure_has_line_items(%Order{}), do: {:error, :empty_order}

  # Build an in-memory %Order{} (with line items) ready for the state transition.
  # We don't insert yet — the handler's transaction holds the transition + insert atomically.
  defp build_order(%Scope{} = scope, %__MODULE__{} = command) do
    line_items =
      Enum.map(command.line_items, fn li ->
        %{
          product_id: li.product_id,
          sku: li.sku,
          quantity: li.quantity,
          unit_price_cents: li.unit_price_cents,
          subtotal_cents: li.quantity * li.unit_price_cents
        }
      end)

    attrs = %{
      customer_id: command.customer_id,
      currency: command.currency,
      # include tenant fields only if Scope carries them:
      organization_id: scope.organization && scope.organization.id,
      tenant_id: scope.tenant_id,
      total_cents: Enum.reduce(line_items, 0, &(&1.subtotal_cents + &2)),
      line_items: line_items
    }

    %Order{}
    |> Order.changeset(attrs)
    |> apply_action(:insert)
  end
end
```

## Query handler

Returns the schema directly. Preloads are explicit.

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

> Drop the `visible_to/2` call only if the project's `Scope` has no org/tenant fields.

## Ecto schema (parent)

One schema per entity. It owns the table, the Gearbox state machine, changesets, transition
functions (which return changesets), and query fragments. It does **not** call `Repo`.

```elixir
defmodule MyApp.Sales.Order do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  use Gearbox,
    field: :status,
    states: [:draft, :placed, :cancelled],
    initial: :draft,
    transitions: %{draft: [:placed, :cancelled], placed: [:cancelled]}

  alias MyApp.Accounts.Scope
  alias MyApp.Sales.OrderLineItem

  schema "orders" do
    field :customer_id, :binary_id
    field :organization_id, :binary_id   # only if Scope has organization
    field :tenant_id, :binary_id         # only if Scope has tenant
    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled], default: :draft
    field :placed_at, :utc_datetime
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    has_many :line_items, OrderLineItem, foreign_key: :order_id, on_replace: :delete

    timestamps()
  end

  # --- changesets ---------------------------------------------------------

  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :customer_id, :organization_id, :tenant_id,
      :status, :placed_at, :total_cents, :currency
    ])
    |> validate_required([:customer_id, :status, :total_cents, :currency])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> cast_assoc(:line_items, with: &OrderLineItem.changeset/2)
  end

  # --- transition functions (return changesets) --------------------------

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

  # Child mutations route through the parent so the parent's invariants stay
  # in one place even though Ecto stores children in their own table.
  def add_line_item(order, attrs) do
    new_item = Map.put(attrs, :subtotal_cents, attrs.quantity * attrs.unit_price_cents)
    existing = Enum.map(order.line_items, &Map.from_struct/1)
    items = existing ++ [new_item]

    order
    |> changeset(%{
      line_items: items,
      total_cents: Enum.reduce(items, 0, &(&1.subtotal_cents + &2))
    })
  end

  # --- query fragments (return Ecto.Query, never execute) ----------------

  def by_id(query \\ __MODULE__, id), do: from(o in query, where: o.id == ^id)

  def for_customer(query \\ __MODULE__, customer_id),
    do: from(o in query, where: o.customer_id == ^customer_id)

  # only when Scope carries org/tenant:
  def visible_to(query \\ __MODULE__, %Scope{} = scope) do
    from o in query,
      where: o.organization_id == ^scope.organization.id,
      where: o.tenant_id == ^scope.tenant_id
  end

  def preload_line_items(query \\ __MODULE__),
    do: from(o in query, preload: [:line_items])

  def lock_for_update(query \\ __MODULE__),
    do: from(o in query, lock: "FOR UPDATE")
end
```

> The transition functions return changesets, not `{:ok, _}` / `{:error, _}`. The handler runs them
> through `Repo.insert` / `Repo.update`, which surfaces Gearbox transition errors as changeset
> errors — keeping the error shape consistent.

## Child Ecto schema

Lives alongside the parent under `sales/`, not under a separate `repo/` subtree.

```elixir
defmodule MyApp.Sales.OrderLineItem do
  use Ecto.Schema
  import Ecto.Changeset

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

## Cross-context call in a command

Cross-context orchestration lives inside the originating command handler. Call the other context's
public facade with the same `%Scope{}`, let errors bubble verbatim, and rely on nested
`Repo.transact` for atomic rollback — every context shares one `Repo`, so an inner `:error` rolls
back the outer transaction automatically.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Policy

  # ... embedded_schema and validation as in the basic Command handler template ...

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transact(fn ->
      with :ok            <- Policy.authorize(scope, :place_order),
           {:ok, command} <- validate(attrs),
           {:ok, order}   <- build_order(scope, command),
           :ok            <- ensure_has_line_items(order),
           {:ok, placed}  <- Repo.insert(Order.place(order)),
           {:ok, _resv}   <- Inventory.reserve_stock(scope, placed.id),
           {:ok, _pay}    <- Billing.authorize_payment(scope, placed.id, command.payment) do
        {:ok, placed}
      end
    end)
  end
end
```

> The same pattern applies inside a single context — sibling commands call each other through their
> own facade (`Sales.apply_discount/2`), never through `Sales.Commands.ApplyDiscount` directly.

## Worker

```elixir
defmodule MyApp.Sales.Workers.SendOrderConfirmation do
  use Oban.Worker, queue: :sales

  alias MyApp.Accounts.Scope
  alias MyApp.Sales

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id, "order_id" => order_id}}) do
    scope = %Scope{tenant_id: tenant_id, roles: [:system]}

    with {:ok, _order} <- Sales.get_order(scope, %{id: order_id}) do
      # send confirmation, publish event, etc.
      :ok
    end
  end
end
```

## Async cross-context entry point on a facade

When another context needs to trigger work in this one asynchronously, expose an enqueue function on
this context's facade — never let outsiders reach into `Workers.*` directly. The facade stays the
single surface for both sync and async cross-context calls.

```elixir
defmodule MyApp.Billing do
  alias MyApp.Billing.Commands.AuthorizePayment
  alias MyApp.Billing.Workers.AuthorizePaymentWorker

  defdelegate authorize_payment(scope, order_id, attrs), to: AuthorizePayment, as: :handle

  def enqueue_payment_authorization(scope, order_id, attrs) do
    %{tenant_id: scope.tenant_id, order_id: order_id, attrs: attrs}
    |> AuthorizePaymentWorker.new()
    |> Oban.insert()
  end
end
```

Callers in Sales then do `Billing.enqueue_payment_authorization(scope, order_id, payment_attrs)`;
they never know `AuthorizePaymentWorker` exists.

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
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Order must contain at least one line item"})

      {:error, :unauthorized} ->
        send_resp(conn, 403, "")

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Sales.get_order(conn.assigns.scope, %{id: id}) do
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
      add :customer_id, :binary_id
      add :organization_id, :binary_id  # only if multi-tenant
      add :tenant_id, :binary_id         # only if multi-tenant
      add :status, :string
      add :placed_at, :utc_datetime
      add :total_cents, :integer, default: 0
      add :currency, :string, default: "USD"
      timestamps()
    end

    create table(:order_line_items) do
      add :order_id, :binary_id
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
