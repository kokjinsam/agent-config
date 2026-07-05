defmodule NOne.ExUnitTest do
  use ExUnit.Case, async: true

  import NOne.ExUnit

  @event [:n_one_ex_unit_test, :repo, :query]

  test "assert_no_repeated_queries returns the block result" do
    result =
      assert_no_repeated_queries "reviews.show", telemetry_events: [@event], max_repeats: 1 do
        emit_query([1])
      end

    assert result == :ok
  end

  test "assert_no_repeated_queries fails when query fingerprints repeat" do
    assert_raise ExUnit.AssertionError, ~r/NOne detected 1 repeated query/, fn ->
      assert_no_repeated_queries "reviews.index", telemetry_events: [@event], max_repeats: 1 do
        emit_query([1])
        emit_query([2])
      end
    end
  end

  defp emit_query(params) do
    :telemetry.execute(
      @event,
      %{query_time: 1},
      %{
        query: "SELECT p0.* FROM posts AS p0 WHERE p0.user_id = $1",
        params: params,
        source: "posts"
      }
    )
  end
end
