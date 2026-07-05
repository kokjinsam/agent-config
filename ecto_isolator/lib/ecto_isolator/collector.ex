defmodule EctoIsolator.Collector do
  @moduledoc false

  @table :ecto_isolator_offenses

  def start(id \\ make_ref()) do
    ensure_table!()
    :ets.insert(@table, {id, []})
    Process.put(:ecto_isolator_collector_id, id)
    Process.put(:ecto_isolator_mode, :collect)
    id
  end

  def stop do
    Process.delete(:ecto_isolator_collector_id)
    Process.delete(:ecto_isolator_mode)
    :ok
  end

  def collect(offense) do
    ensure_table!()

    case Process.get(:ecto_isolator_collector_id) do
      nil ->
        offenses = Process.get(:ecto_isolator_offenses, [])
        Process.put(:ecto_isolator_offenses, [offense | offenses])

      id ->
        offenses = offenses(id)
        :ets.insert(@table, {id, [offense | offenses]})
    end

    :ok
  end

  def offenses(id \\ Process.get(:ecto_isolator_collector_id))

  def offenses(nil) do
    Process.get(:ecto_isolator_offenses, [])
    |> Enum.reverse()
  end

  def offenses(id) do
    ensure_table!()

    case :ets.lookup(@table, id) do
      [{^id, offenses}] -> Enum.reverse(offenses)
      [] -> []
    end
  end

  def clear(id \\ Process.get(:ecto_isolator_collector_id))

  def clear(nil) do
    Process.delete(:ecto_isolator_offenses)
    :ok
  end

  def clear(id) do
    ensure_table!()
    :ets.insert(@table, {id, []})
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @table
        end

      _table ->
        @table
    end
  end
end
