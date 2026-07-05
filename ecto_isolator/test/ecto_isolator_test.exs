defmodule EctoIsolatorTest do
  use ExUnit.Case, async: false

  alias EctoIsolator.{Collector, Error, Offense}
  alias EctoIsolator.ExUnit, as: EctoIsolatorExUnit

  setup do
    Application.put_env(:ecto_isolator, :repos, [EctoIsolator.TestRepo])
    Application.put_env(:ecto_isolator, :mode, :raise)
    Application.delete_env(:ecto_isolator, :ignore)

    on_exit(fn ->
      Application.delete_env(:ecto_isolator, :repos)
      Application.delete_env(:ecto_isolator, :mode)
      Application.delete_env(:ecto_isolator, :ignore)
      Process.delete(:ecto_isolator_test_transaction)
      Collector.stop()
    end)

    :ok
  end

  test "does not report outside an explicit transaction" do
    assert :ok = EctoIsolator.check!(:req, :request, details: %{url: "https://example.com"})
  end

  test "raises inside an explicit transaction" do
    assert_raise Error, ~r/Unsafe req:request inside an Ecto transaction/, fn ->
      EctoIsolator.TestRepo.transact(fn ->
        EctoIsolator.check!(:req, :request, details: %{url: "https://example.com"})
      end)
    end
  end

  test "supports ignore rules" do
    Application.put_env(:ecto_isolator, :ignore, [
      {:req, fn %Offense{details: details} -> details.url == "https://example.com" end}
    ])

    EctoIsolator.TestRepo.transact(fn ->
      assert :ok = EctoIsolator.check!(:req, :request, details: %{url: "https://example.com"})
    end)
  end

  test "collect mode records offenses instead of raising" do
    id = Collector.start()

    EctoIsolator.TestRepo.transact(fn ->
      assert :ok = EctoIsolator.check!(:req, :request, details: %{url: "https://example.com"})
    end)

    assert [%Offense{adapter: :req, action: :request}] = Collector.offenses(id)
  end

  test "repo transaction errors are not hidden" do
    Application.put_env(:ecto_isolator, :repos, [EctoIsolator.RaisingRepo])

    assert_raise RuntimeError, "repo unavailable", fn ->
      EctoIsolator.check!(:req, :request)
    end
  end

  test "ExUnit assertion fails when offenses were collected" do
    id = Collector.start()

    EctoIsolator.TestRepo.transact(fn ->
      EctoIsolator.check!(:req, :request, details: %{url: "https://example.com"})
    end)

    assert_raise ExUnit.AssertionError, ~r/EctoIsolator detected unsafe operations/, fn ->
      EctoIsolatorExUnit.assert_no_offenses!(id)
    end
  end
end
