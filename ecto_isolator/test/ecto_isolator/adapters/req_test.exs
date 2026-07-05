defmodule EctoIsolator.Adapters.ReqTest do
  use ExUnit.Case, async: false

  alias EctoIsolator.Adapters.Req
  alias EctoIsolator.Error

  setup do
    Application.put_env(:ecto_isolator, :repos, [EctoIsolator.TestRepo])
    Application.put_env(:ecto_isolator, :mode, :raise)

    on_exit(fn ->
      Application.delete_env(:ecto_isolator, :repos)
      Application.delete_env(:ecto_isolator, :mode)
      Process.delete(:ecto_isolator_test_transaction)
    end)

    :ok
  end

  test "request step reports inside a transaction" do
    request = %{method: :get, url: URI.parse("https://example.com/path"), options: %{}}

    assert_raise Error, ~r/req:request/, fn ->
      EctoIsolator.TestRepo.transact(fn ->
        Req.request_step(request)
      end)
    end
  end

  test "request step can be disabled per request" do
    request = %{
      method: :get,
      url: URI.parse("https://example.com/path"),
      options: %{ecto_isolator: false}
    }

    EctoIsolator.TestRepo.transact(fn ->
      assert ^request = Req.request_step(request)
    end)
  end
end
