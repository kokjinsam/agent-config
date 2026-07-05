defmodule EctoIsolator.ExUnit do
  @moduledoc """
  ExUnit integration for collecting offenses during a test and failing after it.
  """

  import ExUnit.Assertions

  alias EctoIsolator.{Collector, Error}

  defmacro __using__(_opts) do
    quote do
      setup context do
        EctoIsolator.ExUnit.start(context)
      end
    end
  end

  def start(_context \\ %{}) do
    id = Collector.start()

    ExUnit.Callbacks.on_exit({__MODULE__, id}, fn ->
      assert_no_offenses!(id)
    end)

    :ok
  end

  def assert_no_offenses!(id) do
    case Collector.offenses(id) do
      [] ->
        :ok

      offenses ->
        message =
          offenses
          |> Enum.map_join("\n\n", fn offense ->
            offense
            |> Error.exception()
            |> Exception.message()
          end)

        flunk("EctoIsolator detected unsafe operations:\n\n" <> message)
    end
  end
end
