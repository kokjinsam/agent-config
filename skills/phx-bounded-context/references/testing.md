# Testing the Test Pyramid

Generate tests at three levels:

```
Handler tests        Repo + input validation + state transitions + persistence.
(commands/queries)   For cross-context commands: real downstream contexts (no mocks) + rollback
                     when the command owns an atomicity boundary.
                     Do NOT cover authorization here — that lives at the boundary.

Workflow tests       Repo + orchestration + partial-failure rollback + cross-context coordination.
                     Workflows are also exercised transitively through the commands/workers that
                     invoke them; per-workflow tests focus on orchestration concerns.

Boundary tests       HTTP / LiveView behavior, response shape, AND the authorization path
(controller/LV)      (which scopes are allowed/denied, what status codes come back, what plugs
                     reject).
```

Why the split? Authorization moved to the boundary (controllers/LiveViews/plugs), so handler tests
no longer assert "unauthorized scope rejects." That test still exists — it just lives where the
authz decision lives. This keeps handler tests focused on domain behavior and prevents the
duplicate-authz-check trap.

There's no fast pure-aggregate tier because there's no separate aggregate: the schema is the
domain model, and exercising its transitions meaningfully requires the Repo. If your domain is
genuinely rich enough to warrant property-style operation-sequence testing, do it at the handler
tier — see the optional aside at the bottom.

## Command/query handler test

Repo-backed. Exercise input validation failures, the happy path, the state transition, and
persistence. Assert on the returned schema struct directly. **No authorization tests here.**

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

    test "returns :empty_order from the precondition when line items become empty after validation" do
      # Set up a case that passes input validation but fails the with-chain precondition.
      # Often this isn't reachable when input validation already enforces non-empty; in that
      # case, delete this test.
    end
  end
end
```

## Cross-context tests live in the command's (or workflow's) test file

When a command or workflow calls into other contexts (e.g. `Sales.place_order` calls
`Inventory.reserve_stock` and `Billing.authorize_payment`), the cross-context paths are tested in
the same file as the single-context paths — no separate test tier, no mocks. Drive the downstream
contexts into the state you need (insufficient stock, payment that will fail) using their real
public API, then assert both the bubbled error and that the earlier Sales write rolled back
through the composing `Repo.transact`.

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
      # the order write must not survive the composing transaction's rollback
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
> HTTP API). The cross-context call itself stays real — what gets stubbed is the system at the
> very edge of the application.

## Workflow test

Repo-backed. The workflow trusts the caller has validated and authorized, so workflow tests
**start from a validated attrs map** and focus on:

- The orchestration sequence happens correctly.
- Persistence side-effects land.
- Partial failure rolls back (when the workflow owns a transaction).
- Cross-context error tuples bubble verbatim.

```elixir
defmodule MyApp.Sales.Workflows.RunFulfillmentTest do
  use MyApp.DataCase, async: true

  alias MyApp.Repo
  alias MyApp.Sales.Order
  alias MyApp.Sales.Workflows.RunFulfillment

  defp scope, do: build_scope()

  describe "run/2" do
    test "fulfills the order when Inventory and Billing both succeed" do
      order = insert_order(status: :placed)
      attrs = %{order_id: order.id, payment: valid_payment()}

      assert {:ok, fulfilled} = RunFulfillment.run(scope(), attrs)
      assert fulfilled.status == :fulfilled
    end

    test "rolls back the fulfillment when Billing declines" do
      order = insert_order(status: :placed)
      attrs = %{order_id: order.id, payment: invalid_payment()}

      assert {:error, :payment_declined} = RunFulfillment.run(scope(), attrs)
      assert Repo.reload!(order).status == :placed
    end

    test "raises when a required attrs key is missing (invariant violation)" do
      assert_raise KeyError, fn ->
        RunFulfillment.run(scope(), %{order_id: Ecto.UUID.generate()})  # missing :payment
      end
    end
  end
end
```

> A workflow's "missing required key" test is optional — it just documents that the workflow's
> input contract is enforced via `Map.fetch!`. Skip it if it's noise.

## Boundary test (controller / LiveView)

Verify status codes and response shape for success, validation error, not-found, **and
unauthorized**. This is where authz coverage now lives.

```elixir
defmodule MyAppWeb.OrderControllerTest do
  use MyAppWeb.ConnCase, async: true

  describe "POST /orders" do
    test "returns 201 with the created order for an authorized scope", %{conn: conn} do
      conn = post(authed(conn, perms: [:place_order]), ~p"/orders", order: valid_order_params())
      assert %{"status" => "placed"} = json_response(conn, 201)
    end

    test "returns 403 when the scope lacks :place_order permission", %{conn: conn} do
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

    test "returns 403 when the scope lacks :read_order permission", %{conn: conn} do
      conn = get(authed(conn, perms: []), ~p"/orders/#{Ecto.UUID.generate()}")
      assert response(conn, 403)
    end
  end
end
```

> If authorization is enforced by a plug (not the controller action), put the 403 tests against
> the pipeline rather than each action.

## Optional: property-style handler tests

When a domain is rich enough that you genuinely want "any sequence of valid operations preserves
the invariants" coverage, write that test at the handler tier — drive sequences through the public
context functions (`Sales.place_order`, `Sales.add_line_item`, `Sales.cancel_order`) and assert on
the persisted result. This is slower than pure in-memory property tests and isn't free, so reach
for it only when the domain interaction graph is genuinely complex (multi-step lifecycles, many
optional commands, intricate cross-field rules).

`{:stream_data, "~> 1.0", only: [:test]}` (or similar) needs to be in `mix.exs` if you go this
route — flag it if absent.
