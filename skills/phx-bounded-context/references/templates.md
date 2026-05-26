# Code Templates

Full code templates for each layer. Substitute `MyApp` / `Sales` / `Order` with the detected app
namespace and the context/entity names. Mirror the surrounding codebase's conventions (id type,
`timestamps` type, formatting) where they differ.

## Contents

- Public facade
- Policy (optional)
- Command handler
- Query handler
- Workflow
- Ecto schema (parent, with Gearbox + transitions + `build!/1` + queries)
- Child Ecto schema
- Cross-context reference (bare FK, no `belongs_to`)
- Cross-context call inside a command/workflow
- Worker (rebuilds scope, calls a workflow)
- Async cross-context entry point through a facade
- Controller (authorization at boundary)
- Migration

## Public facade

```elixir
defmodule MyApp.Sales do
  alias MyApp.Sales.Commands.CancelOrder
  alias MyApp.Sales.Commands.PlaceOrder
  alias MyApp.Sales.Queries.GetOrder
  alias MyApp.Sales.Queries.ListOrders

  defdelegate place_order(scope, attrs), to: PlaceOrder, as: :handle
  defdelegate cancel_order(scope, attrs), to: CancelOrder, as: :handle
  defdelegate get_order(scope, attrs), to: GetOrder, as: :handle
  defdelegate list_orders(scope, attrs \\ %{}), to: ListOrders, as: :handle
end
```

> Workflows are **not** exposed on the facade. They're internal — only commands and workers call
> them.

## Policy (optional)

Only scaffold a Policy module when the context has non-trivial action-specific authorization.
For simple contexts, a controller-level plug or check is enough.

The Policy is called **from controllers/LiveViews** (or from workers when they're the first
untrusted entry point), **not from inside handlers**.

```elixir
defmodule MyApp.Sales.Policy do
  alias MyApp.Accounts.Scope

  @spec authorize(Scope.t(), atom(), map()) :: :ok | {:error, :unauthorized}
  def authorize(scope, action, params \\ %{})

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

The handler owns input validation, wraps the work in `Repo.transact` when the operation needs an
atomicity boundary, checks business preconditions in the `with` chain, calls the schema's
transition function (which returns a changeset), and persists through `Repo`. Returns the
persisted schema struct.

It does **not** call `Policy.authorize` — the caller (controller / LiveView / worker) already did.

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
           {:ok, order}   <- build_order(scope, command),
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
    |> validate_length(:line_items, min: 1)
  end

  defp line_item_changeset(line_item, attrs) do
    line_item
    |> cast(attrs, [:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_required([:product_id, :sku, :quantity, :unit_price_cents])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
  end

  # Build an in-memory %Order{} (with line items) ready for the state transition.
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
    |> maybe_put_organization_id(scope)
  end

  defp maybe_put_organization_id(attrs, %{organization: %{id: organization_id}}),
    do: Map.put(attrs, :organization_id, organization_id)

  defp maybe_put_organization_id(attrs, _scope), do: attrs
end
```

## Query handler

Returns the schema directly. Preloads are explicit. No `Policy` call — the caller authorized.

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

## Workflow

Internal multi-step orchestration. **Not** exposed on the facade. Called by a command or a worker.
Trusts the caller to have validated AND authorized. Takes a **validated attrs map** with atom keys
and accesses required keys via `Map.fetch!`. Can call own schemas + `Repo`, own queries, and other
context facades. Owns its own outer `Repo.transact` when its orchestration needs atomicity.

```elixir
defmodule MyApp.Sales.Workflows.RunFulfillment do
  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Queries.GetOrder

  # Trusted, validated attrs map: %{order_id: binary_id, payment: map}
  def run(%Scope{} = scope, attrs) when is_map(attrs) do
    order_id = Map.fetch!(attrs, :order_id)
    payment  = Map.fetch!(attrs, :payment)

    Repo.transact(fn ->
      with {:ok, order} <- GetOrder.handle(scope, %{id: order_id}),
           {:ok, _resv} <- Inventory.reserve_stock(scope, %{order_id: order.id}),
           {:ok, _pay}  <- Billing.authorize_payment(scope, %{order_id: order.id, payment: payment}),
           {:ok, ship}  <- Repo.update(Order.mark_fulfilled(order)) do
        {:ok, ship}
      end
    end)
  end
end
```

> When a command delegates to a workflow, it just calls `RunFulfillment.run(scope, validated_attrs)`
> after its own input validation. The workflow does not re-validate.

## Ecto schema (parent)

One schema per entity. It owns the table, the Gearbox state machine, changesets, transition
functions (which return changesets), `build!/1` for in-memory variants, and query fragments. It
does **not** call `Repo`. The template below shows a binary-id project; drop `@primary_key` /
`@foreign_key_type` and the binary-id migration fields when the existing project uses integer ids.

```elixir
defmodule MyApp.Sales.Order do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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
    field :organization_id, :binary_id   # only if Scope has organization
    field :tenant_id, :binary_id         # only if Scope has tenant
    field :status, Ecto.Enum, values: [:draft, :placed, :cancelled, :fulfilled], default: :draft
    field :placed_at, :utc_datetime
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    # Virtual fields used for command return shapes (Rule 16):
    field :payment_intent_url, :string, virtual: true

    has_many :line_items, OrderLineItem, foreign_key: :order_id, on_replace: :delete

    timestamps()
  end

  # --- changesets ---------------------------------------------------------

  def changeset(order, attrs) do
    order
    |> cast(attrs, [:customer_id, :organization_id, :tenant_id, :total_cents, :currency])
    |> validate_required([:customer_id, :status, :total_cents, :currency])
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> cast_assoc(:line_items, with: &OrderLineItem.changeset/2)
  end

  # --- build!/1 for in-memory (non-persisted) variants -------------------
  #
  # Use when you need a struct-shaped value for internal passing (event payloads,
  # value objects). `Map.fetch!` raises on missing required keys — the caller's
  # contract guarantees them. Do not use this to skip the changeset for persistence.

  def build!(attrs) do
    %__MODULE__{
      customer_id: Map.fetch!(attrs, :customer_id),
      currency: Map.fetch!(attrs, :currency),
      total_cents: Map.fetch!(attrs, :total_cents)
    }
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

  def mark_fulfilled(order) do
    order
    |> change()
    |> Gearbox.transition(:fulfilled)
  end

  # Child mutations route through the parent so the parent's invariants stay
  # in one place even though Ecto stores children in their own table.
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

  # --- query fragments (return Ecto.Query, never execute) ----------------

  def by_id(query \\ __MODULE__, id), do: from(o in query, where: o.id == ^id)

  def for_customer(query \\ __MODULE__, customer_id),
    do: from(o in query, where: o.customer_id == ^customer_id)

  # only when Scope carries org/tenant:
  def visible_to(query \\ __MODULE__, %Scope{} = scope) do
    scope_attrs = Map.from_struct(scope)
    organization_id = Map.get(scope_attrs, :organization_id) || get_in(scope_attrs, [:organization, :id])
    tenant_id = Map.fetch!(scope_attrs, :tenant_id)

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

> Transition functions return changesets, not `{:ok, _}` / `{:error, _}`. The handler runs them
> through `Repo.insert` / `Repo.update`, which surfaces Gearbox transition errors as changeset
> errors — keeping the error shape consistent.

## Child Ecto schema

Lives alongside the parent under `sales/`, not under a separate `repo/` subtree.

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

    belongs_to :order, Order   # OK — same context

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

## Cross-context reference (bare FK, no `belongs_to`)

Cross-context references use **bare FK columns**, not `belongs_to`. The owning context loads the
record through the foreign context's facade.

```elixir
defmodule MyApp.Reviews.Review do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reviews" do
    field :title, :string
    # Bare FK — DO NOT `belongs_to :author, MyApp.Accounts.User` across contexts.
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

Loading the author goes through the facade:

```elixir
# Inside a Reviews command/workflow that needs the author:
{:ok, review} <- Repo.insert(...),
{:ok, author} <- Accounts.get_user(scope, %{id: review.authored_by_id})
```

`belongs_to` between schemas in the **same** context (like `OrderLineItem` → `Order` above) stays
fine.

## Cross-context call inside a command/workflow

Cross-context orchestration lives inside a command or a workflow. Call the other context's public
facade with the same `%Scope{}` and attrs maps, let errors bubble verbatim, and wrap the
composition in `Repo.transact` when the work needs all-or-nothing behavior.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrder do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.Scope
  alias MyApp.Billing
  alias MyApp.Inventory
  alias MyApp.Repo
  alias MyApp.Sales.Order

  # ... embedded_schema and validation as in the basic Command handler template ...

  def handle(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transact(fn ->
      with {:ok, command} <- validate(attrs),
           {:ok, order}   <- build_order(scope, command),
           {:ok, placed}  <- Repo.insert(Order.place(order)),
           {:ok, _resv}   <- Inventory.reserve_stock(scope, %{order_id: placed.id}),
           {:ok, _pay}    <- Billing.authorize_payment(scope, %{order_id: placed.id, payment: command.payment}) do
        {:ok, placed}
      end
    end)
  end
end
```

> The same pattern applies inside a single context — sibling commands call each other through
> their own facade (`Sales.apply_discount/2`), never through `Sales.Commands.ApplyDiscount` directly.
> When this kind of orchestration spans 3+ cross-context calls or is also driven by a worker,
> extract it to a workflow (see the Workflow section above) so the worker can call the workflow directly.

## Worker (rebuilds scope, calls a workflow)

Workers stay thin. Each worker:

1. Carries scope in job args as a serialized map.
2. Calls `Accounts.build_scope/1` (your project's equivalent) to reconstitute `%Scope{}`.
3. Calls **one workflow** (preferred) or one command. No business logic.

```elixir
defmodule MyApp.Sales.Workers.FulfillOrderWorker do
  use Oban.Worker, queue: :sales

  alias MyApp.Accounts
  alias MyApp.Sales.Workflows.RunFulfillment

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => scope_attrs} = args}) do
    {:ok, scope} = Accounts.build_scope(scope_attrs)

    RunFulfillment.run(scope, %{
      order_id: Map.fetch!(args, "order_id"),
      payment: Map.fetch!(args, "payment")
    })
  end
end
```

> The worker doesn't call `Policy.authorize` — authorization happened at the enqueue site (the
> controller or command that scheduled this job). Add a Policy call here only when the worker is
> the first untrusted entry point.

## Async cross-context entry point through a facade

When another context needs to trigger work in this one asynchronously, expose an enqueue function
on this context's facade — never let outsiders reach into `Workers.*` directly. Keep the facade
thin by delegating to a command handler that validates attrs and builds the job.

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

Callers do `Sales.enqueue_fulfillment(scope, attrs)`; they never know `FulfillOrderWorker` exists.

## Controller (authorization at boundary)

Controllers stay thin: validate request shape, **authorize**, call the facade, delegate response
shaping to the JSON view module / serializer the codebase uses.

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  alias MyApp.Sales
  alias MyApp.Sales.Policy  # only if a Policy module exists

  def create(conn, %{"order" => order_params}) do
    scope = conn.assigns.scope

    with :ok <- Policy.authorize(scope, :place_order) do
      case Sales.place_order(scope, order_params) do
        {:ok, order} ->
          conn |> put_status(:created) |> render(:show, order: order)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(:unprocessable_entity) |> render(:errors, changeset: changeset)

        {:error, :empty_order} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, message: "Order must contain at least one line item")

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> render(:error, message: inspect(reason))
      end
    else
      {:error, :unauthorized} -> send_resp(conn, 403, "")
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.scope

    with :ok <- Policy.authorize(scope, :read_order, %{id: id}) do
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

> When the codebase has **no** Policy module, authorize at the plug or pipeline level instead, and
> drop the `Policy.authorize` step here. Match the existing pattern.
>
> The `render(:show, order: order)` call assumes a Phoenix 1.7 `MyAppWeb.OrderJSON` view module.
> Detect and match the codebase's JSON shaping (view modules, custom serializers, JSONAPI).

## Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateSalesOrders do
  use Ecto.Migration

  def change do
    create table(:orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :customer_id, :binary_id
      add :organization_id, :binary_id  # only if multi-tenant
      add :tenant_id, :binary_id         # only if multi-tenant
      add :status, :string
      add :placed_at, :utc_datetime
      add :total_cents, :integer, default: 0
      add :currency, :string, default: "USD"
      timestamps()
    end

    create table(:order_line_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
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

> One context per migration file. In greenfield contexts still in active build-out, it's acceptable
> to fold related migrations together when the user requests it. In mature contexts, each schema
> change gets its own dated migration.
>
> This migration matches the binary-id schema template. If the project uses integer ids, use the
> existing generator convention instead of copying the binary-id primary key fields.
