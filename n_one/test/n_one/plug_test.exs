defmodule NOne.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  @event [:n_one_plug_test, :repo, :query]

  test "treats one HTTP request as an operation boundary" do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, make_ref()}

    :telemetry.attach(
      handler_id,
      [:n_one, :violation],
      &__MODULE__.handle_violation/4,
      test_pid
    )

    try do
      conn =
        :get
        |> conn("/reviews")
        |> NOne.Plug.call(telemetry_events: [@event], mode: :telemetry, max_repeats: 1)

      emit_query([1])
      emit_query([2])

      send_resp(conn, 200, "ok")

      assert_receive {:n_one_violation, %{finding_count: 1, query_count: 2},
                      %{operation: "GET /reviews", report: %NOne.Report{}}}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp emit_query(params) do
    :telemetry.execute(
      @event,
      %{query_time: 1},
      %{
        query: "SELECT r0.* FROM reviews AS r0 WHERE r0.workspace_id = $1",
        params: params,
        source: "reviews"
      }
    )
  end

  def handle_violation(_event, measurements, metadata, test_pid) do
    send(test_pid, {:n_one_violation, measurements, metadata})
  end
end
