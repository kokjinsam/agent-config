# Testing the Test Pyramid

Generate tests at three levels, each matched to what its layer actually owns. The split matters: the
aggregate is pure and in-memory, so it gets fast property-based tests with no database; everything
that touches `Repo`, scope, or HTTP gets conventional integration tests. Cross-context behavior is
not its own tier — it lives inside the originating command's handler tests, using real downstream
contexts.

```
Aggregate tests       Fast, property-based, no database. Invariants and transitions.
Handler tests         Repo + transactions + scope + authorization + persistence + mapping.
                      For cross-context commands: real downstream contexts (no mocks) + rollback.
Controller tests      HTTP behavior and response shape.
```

Property tests need `{:stream_data, "~> 1.0", only: [:test]}` (or similar) in `mix.exs`. If it's
absent, add it (or flag it for the user) before generating property tests.

## Why aggregates get property tests

Because aggregate functions are pure (`Order.add_line_item/2`, `Order.place/1`, `Order.cancel/1`
return `{:ok, order}` / `{:error, reason}` with no I/O), they need no fixtures, no `Repo.insert!`, no
SQL sandbox, no preloads. That makes it cheap to throw thousands of generated inputs and operation
sequences at them and assert invariants hold every time.

Cover **two kinds** of properties:

- **Data properties** — relationships that must always hold over generated data. E.g. order total
  equals the sum of line-item subtotals; each subtotal equals `quantity * unit_price_cents`.
- **Operation-sequence properties** — any sequence of public operations preserves invariants. Generate
  random sequences of `add_line_item` / `place` / `cancel`, apply them (ignoring `{:error, _}`
  results, which represent correctly-rejected operations), and assert invariants on the final state.

Useful `Order` properties: total = sum of subtotals; subtotal = qty × price; non-draft orders reject
edits; empty orders can't be placed; invalid transitions are rejected; cancelling doesn't change the
total; placed orders can't be placed again.

## Aggregate data property test

```elixir
defmodule MyApp.Sales.OrderPropertyTest do
  use ExUnit.Case, async: true
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
      %{product_id: product_id, sku: sku, quantity: quantity, unit_price_cents: unit_price_cents}
    end
  end

  property "order total equals the sum of line item subtotals" do
    check all customer_id <- uuid_generator(),
              line_items <- list_of(line_item_generator(), min_length: 1, max_length: 50) do
      {:ok, order} =
        Order.new(%{customer_id: customer_id, currency: "USD", status: :draft,
                    total_cents: 0, line_items: []})

      {:ok, order} =
        Enum.reduce_while(line_items, {:ok, order}, fn attrs, {:ok, order} ->
          case Order.add_line_item(order, attrs) do
            {:ok, order} -> {:cont, {:ok, order}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      expected = order.line_items |> Enum.map(& &1.subtotal_cents) |> Enum.sum()
      assert order.total_cents == expected
    end
  end
end
```

## Aggregate operation-sequence property test

```elixir
defmodule MyApp.Sales.OrderSequencePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MyApp.Sales.Order

  defp operation_generator do
    one_of([
      constant(:place),
      constant(:cancel),
      gen all quantity <- integer(1..10), unit_price_cents <- integer(0..10_000) do
        {:add_line_item,
         %{product_id: Ecto.UUID.generate(), sku: "SKU-#{System.unique_integer([:positive])}",
           quantity: quantity, unit_price_cents: unit_price_cents}}
      end
    ])
  end

  property "all operation sequences preserve order invariants" do
    check all operations <- list_of(operation_generator(), max_length: 100) do
      {:ok, order} =
        Order.new(%{customer_id: Ecto.UUID.generate(), currency: "USD", status: :draft,
                    total_cents: 0, line_items: []})

      final =
        Enum.reduce(operations, order, fn op, order ->
          case apply_operation(order, op) do
            {:ok, order} -> order
            {:error, _reason} -> order
          end
        end)

      assert_order_invariants(final)
    end
  end

  defp apply_operation(order, {:add_line_item, attrs}), do: Order.add_line_item(order, attrs)
  defp apply_operation(order, :place), do: Order.place(order)
  defp apply_operation(order, :cancel), do: Order.cancel(order)

  defp assert_order_invariants(order) do
    expected = order.line_items |> Enum.map(& &1.subtotal_cents) |> Enum.sum()
    assert order.total_cents == expected

    for li <- order.line_items do
      assert li.quantity > 0
      assert li.unit_price_cents >= 0
      assert li.subtotal_cents == li.quantity * li.unit_price_cents
    end
  end
end
```

## Command/query handler test

Repo-backed. Exercise authorization (allowed and denied scopes), validation failures, the happy
path, persistence, and that `from_schema` mapping round-trips.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrderTest do
  use MyApp.DataCase, async: true

  alias MyApp.Sales

  defp scope(perms), do: %MyApp.Accounts.Scope{permissions: perms, tenant_id: Ecto.UUID.generate()}

  describe "place_order/2" do
    test "places a valid order and returns the domain aggregate" do
      attrs = %{
        "customer_id" => Ecto.UUID.generate(),
        "currency" => "USD",
        "line_items" => [
          %{"product_id" => Ecto.UUID.generate(), "sku" => "A1", "quantity" => 2, "unit_price_cents" => 500}
        ]
      }

      assert {:ok, order} = Sales.place_order(scope([:place_order]), attrs)
      assert order.status == :placed
      assert order.total_cents == 1000
    end

    test "rejects an empty order" do
      attrs = %{"customer_id" => Ecto.UUID.generate(), "currency" => "USD", "line_items" => []}
      assert {:error, %Ecto.Changeset{}} = Sales.place_order(scope([:place_order]), attrs)
    end

    test "denies a scope without permission" do
      attrs = %{"customer_id" => Ecto.UUID.generate(), "currency" => "USD",
                "line_items" => [%{"product_id" => Ecto.UUID.generate(), "sku" => "A1",
                                   "quantity" => 1, "unit_price_cents" => 100}]}
      assert {:error, :unauthorized} = Sales.place_order(scope([]), attrs)
    end
  end
end
```

## Cross-context tests live in the command's test file

When a command calls into other contexts (e.g. `Sales.place_order` calls `Inventory.reserve_stock`
and `Billing.authorize_payment`), the cross-context paths are tested in the same
`place_order_test.exs` file as the single-context paths — no separate test tier, no mocks. Drive
the downstream contexts into the state you need (insufficient stock, payment that will fail) using
their real public API, then assert both the bubbled error and that the earlier Sales write rolled
back via the nested `Repo.transact`.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrderTest do
  use MyApp.DataCase, async: true

  alias MyApp.Repo
  alias MyApp.Repo.Sales.Order, as: OrderSchema
  alias MyApp.Sales

  describe "place_order/2 with cross-context calls" do
    test "rolls back the order when Billing rejects the payment" do
      scope = build_scope()
      attrs = order_attrs(payment: invalid_card_attrs())

      assert {:error, :payment_declined} = Sales.place_order(scope, attrs)
      # the order write must not survive the nested transaction's rollback
      assert Repo.aggregate(OrderSchema, :count) == 0
    end

    test "rolls back the order when Inventory cannot reserve stock" do
      scope = build_scope()
      out_of_stock_product = insert_product(stock: 0)
      attrs = order_attrs(product: out_of_stock_product)

      assert {:error, :insufficient_stock} = Sales.place_order(scope, attrs)
      assert Repo.aggregate(OrderSchema, :count) == 0
    end
  end
end
```

> Reach for mocks only when a downstream call hits a real external system (e.g. a payment gateway
> HTTP API). The cross-context call itself stays real — what gets stubbed is the system at the very
> edge of the application.

## Controller test

Verify status codes and response shape for success, validation error, not-found, and unauthorized.

```elixir
defmodule MyAppWeb.OrderControllerTest do
  use MyAppWeb.ConnCase, async: true

  test "POST /orders returns 201 with the created order", %{conn: conn} do
    conn = post(authed(conn), ~p"/orders", order: valid_order_params())
    assert %{"status" => "placed"} = json_response(conn, 201)
  end

  test "POST /orders returns 422 for an empty order", %{conn: conn} do
    conn = post(authed(conn), ~p"/orders", order: empty_order_params())
    assert json_response(conn, 422)["error"]
  end
end
```
