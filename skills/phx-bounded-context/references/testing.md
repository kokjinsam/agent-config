# Testing the Test Pyramid

Generate tests at two main levels:

```
Handler tests       Repo + transactions + scope + authorization + persistence + state transitions.
                    For cross-context commands: real downstream contexts (no mocks) + rollback.
Controller tests    HTTP behavior and response shape.
```

Cross-context behavior is not its own tier — it lives inside the originating command's handler
tests, using real downstream contexts.

There's no fast pure-aggregate tier any more because there's no separate aggregate: the schema is
the domain model, and exercising its transitions meaningfully requires the Repo. If your domain is
genuinely rich enough to warrant property-style operation-sequence testing, do it at the handler
tier — see the optional aside at the bottom.

## Command/query handler test

Repo-backed. Exercise authorization (allowed and denied scopes), validation failures, the happy
path, the state transition, and persistence. Assert on the returned schema struct directly.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrderTest do
  use MyApp.DataCase, async: true

  alias MyApp.Sales

  defp scope(perms),
    do: %MyApp.Accounts.Scope{permissions: perms, tenant_id: Ecto.UUID.generate()}

  describe "place_order/2" do
    test "places a valid order and returns the persisted schema" do
      attrs = %{
        "customer_id" => Ecto.UUID.generate(),
        "currency" => "USD",
        "line_items" => [
          %{
            "product_id" => Ecto.UUID.generate(),
            "sku" => "A1",
            "quantity" => 2,
            "unit_price_cents" => 500
          }
        ]
      }

      assert {:ok, order} = Sales.place_order(scope([:place_order]), attrs)
      assert order.status == :placed
      assert order.total_cents == 1000
      assert is_struct(order, MyApp.Sales.Order)
      assert order.placed_at
    end

    test "rejects an empty order via business precondition" do
      attrs = %{
        "customer_id" => Ecto.UUID.generate(),
        "currency" => "USD",
        "line_items" => []
      }

      # input validation flags missing line_items before the precondition fires, so this
      # surfaces as a changeset error from the handler's input embedded_schema
      assert {:error, %Ecto.Changeset{}} = Sales.place_order(scope([:place_order]), attrs)
    end

    test "denies a scope without permission" do
      attrs = %{
        "customer_id" => Ecto.UUID.generate(),
        "currency" => "USD",
        "line_items" => [
          %{
            "product_id" => Ecto.UUID.generate(),
            "sku" => "A1",
            "quantity" => 1,
            "unit_price_cents" => 100
          }
        ]
      }

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
  alias MyApp.Sales
  alias MyApp.Sales.Order

  describe "place_order/2 with cross-context calls" do
    test "rolls back the order when Billing rejects the payment" do
      scope = build_scope()
      attrs = order_attrs(payment: invalid_card_attrs())

      assert {:error, :payment_declined} = Sales.place_order(scope, attrs)
      # the order write must not survive the nested transaction's rollback
      assert Repo.aggregate(Order, :count) == 0
    end

    test "rolls back the order when Inventory cannot reserve stock" do
      scope = build_scope()
      out_of_stock_product = insert_product(stock: 0)
      attrs = order_attrs(product: out_of_stock_product)

      assert {:error, :insufficient_stock} = Sales.place_order(scope, attrs)
      assert Repo.aggregate(Order, :count) == 0
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

## Optional: property-style handler tests

When a domain is rich enough that you genuinely want "any sequence of valid operations preserves
the invariants" coverage, write that test at the handler tier — drive sequences through the public
context functions (`Sales.place_order`, `Sales.add_line_item`, `Sales.cancel_order`) and assert on
the persisted result. This is slower than pure in-memory property tests and isn't free, so reach
for it only when the domain interaction graph is genuinely complex (multi-step lifecycles, many
optional commands, intricate cross-field rules).

`{:stream_data, "~> 1.0", only: [:test]}` (or similar) needs to be in `mix.exs` if you go this
route — flag it if absent.
