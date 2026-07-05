defmodule NOne.Collector do
  @moduledoc false

  use GenServer

  alias NOne.Finding
  alias NOne.Fingerprint
  alias NOne.Report

  def start(operation, config, handler_id, owner_pid) do
    GenServer.start(__MODULE__, {operation, config, handler_id, owner_pid})
  end

  def record(collector, _event, measurements, metadata) do
    GenServer.cast(collector, {:record, measurements, metadata})
  end

  def finish(collector) do
    GenServer.call(collector, :finish)
  end

  def cancel(collector) do
    GenServer.stop(collector, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({operation, config, handler_id, owner_pid}) do
    Process.monitor(owner_pid)

    state = %{
      operation: operation,
      config: config,
      handler_id: handler_id,
      started_at: System.monotonic_time(),
      query_count: 0,
      groups: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:record, _measurements, metadata}, state) do
    if ignored?(metadata, state.config) do
      {:noreply, state}
    else
      {:noreply, record_query(state, metadata)}
    end
  end

  @impl GenServer
  def handle_call(:finish, _from, state) do
    {:stop, :normal, build_report(state), state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    detach(state.handler_id)
    {:stop, :normal, state}
  end

  defp record_query(state, metadata) do
    query = metadata[:query] || ""
    fingerprint = Fingerprint.query(query)
    command = Fingerprint.command(query)
    source = metadata[:source]
    params_hash = Fingerprint.params_hash(metadata[:params])
    key = {source, command, fingerprint}

    group =
      state.groups
      |> Map.get(key, %{count: 0, param_sets: MapSet.new()})
      |> then(fn group ->
        %{
          count: group.count + 1,
          param_sets: MapSet.put(group.param_sets, params_hash)
        }
      end)

    %{
      state
      | query_count: state.query_count + 1,
        groups: Map.put(state.groups, key, group)
    }
  end

  defp build_report(state) do
    findings =
      state.groups
      |> Enum.flat_map(fn {{source, command, fingerprint}, group} ->
        if group.count > state.config.max_repeats do
          [
            %Finding{
              source: source,
              command: command,
              fingerprint: fingerprint,
              count: group.count,
              unique_param_sets: MapSet.size(group.param_sets)
            }
          ]
        else
          []
        end
      end)
      |> Enum.sort_by(& &1.count, :desc)

    %Report{
      operation: state.operation,
      query_count: state.query_count,
      findings: findings,
      started_at: state.started_at,
      finished_at: System.monotonic_time()
    }
  end

  defp ignored?(metadata, config) do
    ignored_source?(metadata, config.ignore) or ignored_query?(metadata, config.ignore) or
      not included?(metadata, config.include)
  end

  defp ignored_source?(metadata, ignore) do
    Enum.any?(List.wrap(ignore), fn
      {:source, source} -> metadata[:source] == source
      options when is_list(options) -> Keyword.get(options, :source) == metadata[:source]
      _other -> false
    end)
  end

  defp ignored_query?(metadata, ignore) do
    query = metadata[:query] || ""

    Enum.any?(List.wrap(ignore), fn
      {:query, %Regex{} = regex} -> Regex.match?(regex, query)
      options when is_list(options) -> query_ignored_by_options?(query, options)
      _other -> false
    end)
  end

  defp query_ignored_by_options?(query, options) do
    case Keyword.get(options, :query) do
      %Regex{} = regex -> Regex.match?(regex, query)
      expected when is_binary(expected) -> query == expected
      _other -> false
    end
  end

  defp included?(_metadata, :all), do: true

  defp included?(metadata, include) when is_list(include) do
    metadata[:query]
    |> Fingerprint.command()
    |> normalized_command()
    |> then(fn command -> Enum.any?(include, &command_matches?(&1, command)) end)
  end

  defp included?(_metadata, _include), do: true

  defp normalized_command(nil), do: nil

  defp normalized_command(command), do: String.downcase(command)

  defp command_matches?(command, normalized) when is_atom(command),
    do: Atom.to_string(command) == normalized

  defp command_matches?(command, normalized) when is_binary(command),
    do: String.downcase(command) == normalized

  defp command_matches?(_command, _normalized), do: false

  defp detach(handler_id) do
    :telemetry.detach(handler_id)
  catch
    :error, _reason -> :ok
  end
end
