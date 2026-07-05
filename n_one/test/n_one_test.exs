defmodule NOneTest do
  use ExUnit.Case, async: true

  @event [:n_one_test, :repo, :query]

  test "collect/3 reports repeated query fingerprints" do
    {result, report} =
      NOne.collect("reviews.index", [telemetry_events: [@event], max_repeats: 1], fn ->
        emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [1])
        emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [2])
        :ok
      end)

    assert result == :ok
    assert report.operation == "reviews.index"
    assert report.query_count == 2

    assert [
             %NOne.Finding{
               count: 2,
               source: "users",
               command: "SELECT",
               unique_param_sets: 2
             }
           ] = report.findings
  end

  test "collect/3 ignores telemetry from other processes" do
    {_result, report} =
      NOne.collect("reviews.index", [telemetry_events: [@event], max_repeats: 1], fn ->
        task =
          Task.async(fn ->
            emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [1])
          end)

        Task.await(task)
        emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [2])
      end)

    assert report.query_count == 1
    assert report.findings == []
  end

  test "watch/3 raises in raise mode when repeated queries are found" do
    assert_raise NOne.Violation, ~r/NOne detected 1 repeated query/, fn ->
      NOne.watch(
        "reviews.index",
        [telemetry_events: [@event], max_repeats: 1, mode: :raise],
        fn ->
          emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [1])
          emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [2])
        end
      )
    end
  end

  test "watch/3 returns the wrapped result when no repeated queries are found" do
    assert {:ok, 42} =
             NOne.watch(
               "reviews.show",
               [telemetry_events: [@event], max_repeats: 1, mode: :raise],
               fn ->
                 emit_query("SELECT u0.* FROM users AS u0 WHERE u0.id = $1", [1])
                 {:ok, 42}
               end
             )
  end

  defp emit_query(query, params) do
    :telemetry.execute(@event, %{query_time: 1}, %{query: query, params: params, source: "users"})
  end
end
