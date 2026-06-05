# Testing The Test Pyramid

Generate tests at three levels:

```
Public handler tests       Repo + input validation + state transitions + persistence.
(commands/queries)         Collection queries exercise Repo.list/Repo.paginate + Flop validation.
                           Cross-context commands use real downstream contexts when possible.
                           Do NOT cover authorization here.

Internal orchestration     Repo + multi-step orchestration + partial-failure rollback +
module tests               worker-driven behavior + cross-context coordination.
                           These are tests for noun modules such as Sales.OrderVerification.

Boundary tests             HTTP / LiveView / plug behavior, response shape, and authorization.
(controller/LV/plug)       This is where allowed/denied scopes and status codes are verified.
```

Authorization is outside the bounded context, so public handler tests no longer assert
"unauthorized scope rejects." That test still exists; it lives where authorization lives. This
keeps domain tests focused on domain behavior and avoids duplicate authorization checks.

There is no fast pure-aggregate tier because there is no separate aggregate: the Ecto schema is the
domain model, and exercising its transitions meaningfully usually requires Repo-backed tests. If
the domain warrants property-style operation-sequence testing, do it at the public handler tier.

## Public Command Handler Test

Repo-backed. Exercise input validation failures, the happy path, state transitions, persistence,
and returned schema structs. No authorization tests here.

```elixir
defmodule MyApp.Sales.Commands.PlaceOrderTest do
  use MyApp.DataCase, async: true

  alias MyApp.Sales

  defp scope, do: %MyApp.Accounts.Scope{tenant_id: Ecto.UUID.generate()}

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

      assert {:ok, order} = Sales.place_order(scope(), attrs)
      assert order.status == :placed
      assert order.total_cents == 1000
      assert is_struct(order, MyApp.Sales.Order)
      assert order.placed_at
    end

    test "rejects an empty order via input validation" do
      attrs = %{
        "customer_id" => Ecto.UUID.generate(),
        "currency" => "USD",
        "line_items" => []
      }

      assert {:error, %Ecto.Changeset{}} = Sales.place_order(scope(), attrs)
    end
  end
end
```

## Public Collection Query Test

Collection reads must exercise Flop validation, filtering, ordering, and pagination through the
Repo helpers.

```elixir
defmodule MyApp.Sales.Queries.ListOrdersTest do
  use MyApp.DataCase, async: true

  alias MyApp.Sales

  describe "list_orders/2" do
    test "filters and orders orders through Flop" do
      scope = build_scope()
      cancelled = insert_order(scope, status: :cancelled, inserted_at: ~U[2026-01-01 00:00:00Z])
      placed = insert_order(scope, status: :placed, inserted_at: ~U[2026-01-02 00:00:00Z])
      insert_order(build_scope(), status: :placed)

      params = %{
        "filters" => [%{"field" => "status", "op" => "==", "value" => "placed"}],
        "order_by" => ["inserted_at"],
        "order_directions" => ["desc"]
      }

      assert {:ok, {orders, _meta}} = Sales.list_orders(scope, params)
      assert Enum.map(orders, & &1.id) == [placed.id]
      refute Enum.any?(orders, &(&1.id == cancelled.id))
    end

    test "returns a Flop validation error for unsupported filters" do
      scope = build_scope()
      params = %{"filters" => [%{"field" => "internal_notes", "op" => "like", "value" => "x"}]}

      assert {:error, %Flop.Meta{}} = Sales.list_orders(scope, params)
    end
  end
end
```

If the public API uses `Repo.list/3` instead of `Repo.paginate/3`, assert `{:ok, results}` rather
than `{results, meta}`.

## Cross-Context Tests

When a public command or internal noun module calls other contexts, test those paths in the same
file as the behavior being composed. Use real downstream contexts where possible. Drive downstream
contexts into the needed state through their public APIs, then assert both the bubbled error and
rollback behavior.

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

Reach for mocks only when a downstream call hits a real external system. The cross-context call
itself stays real; the external edge is what gets stubbed.

## Internal Orchestration Module Test

Repo-backed. Internal noun modules trust their caller contract, so tests start from validated attrs
or fixtures and focus on:

- the orchestration sequence;
- persistence side effects;
- rollback on partial failure when the module owns a transaction;
- cross-context error tuples bubbling verbatim;
- worker-driven behavior when an Oban worker delegates to the module.

```elixir
defmodule MyApp.Sales.OrderVerificationTest do
  use MyApp.DataCase, async: true

  alias MyApp.Repo
  alias MyApp.Sales.OrderVerification

  describe "verify_for_fulfillment/2" do
    test "fulfills the order when Inventory and Billing both succeed" do
      scope = build_scope()
      order = insert_order(scope, status: :placed)
      attrs = %{order_id: order.id, payment: valid_payment()}

      assert {:ok, fulfilled} = OrderVerification.verify_for_fulfillment(scope, attrs)
      assert fulfilled.status == :fulfilled
    end

    test "rolls back fulfillment when Billing declines" do
      scope = build_scope()
      order = insert_order(scope, status: :placed)
      attrs = %{order_id: order.id, payment: invalid_payment()}

      assert {:error, :payment_declined} = OrderVerification.verify_for_fulfillment(scope, attrs)
      assert Repo.reload!(order).status == :placed
    end

    test "raises when a required attrs key is missing" do
      scope = build_scope()

      assert_raise KeyError, fn ->
        OrderVerification.verify_for_fulfillment(scope, %{order_id: Ecto.UUID.generate()})
      end
    end
  end
end
```

The missing-key test is optional. Use it when documenting the trusted internal contract helps more
than it clutters.

## Boundary Test

Verify status codes and response shape for success, validation error, not-found, and unauthorized
cases. This is where authorization coverage lives.

```elixir
defmodule MyAppWeb.OrderControllerTest do
  use MyAppWeb.ConnCase, async: true

  describe "POST /orders" do
    test "returns 201 with the created order for an authorized scope", %{conn: conn} do
      conn = post(authed(conn, perms: [:place_order]), ~p"/orders", order: valid_order_params())
      assert %{"status" => "placed"} = json_response(conn, 201)
    end

    test "returns 403 when the boundary authorization rejects the scope", %{conn: conn} do
      conn = post(authed(conn, perms: []), ~p"/orders", order: valid_order_params())
      assert response(conn, 403)
    end

    test "returns 422 for an empty order", %{conn: conn} do
      conn = post(authed(conn, perms: [:place_order]), ~p"/orders", order: empty_order_params())
      assert json_response(conn, 422)["error"]
    end
  end

  describe "GET /orders/:id" do
    test "returns 404 when the order does not exist", %{conn: conn} do
      conn = get(authed(conn, perms: [:read_order]), ~p"/orders/#{Ecto.UUID.generate()}")
      assert response(conn, 404)
    end

    test "returns 403 when boundary authorization rejects the scope", %{conn: conn} do
      conn = get(authed(conn, perms: []), ~p"/orders/#{Ecto.UUID.generate()}")
      assert response(conn, 403)
    end
  end
end
```

If authorization is enforced by a plug or pipeline, put the 403 tests against that boundary rather
than duplicating checks in every action.

## Optional: Property-Style Public Handler Tests

When a domain is rich enough that "any sequence of valid operations preserves the invariants"
coverage is valuable, write that at the public handler tier. Drive sequences through public context
functions and assert on persisted results.

`{:stream_data, "~> 1.0", only: [:test]}` or similar needs to be in `mix.exs` if you add these
tests. Flag it if absent.
