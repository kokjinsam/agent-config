defmodule NOne do
  @moduledoc """
  Detects repeated Ecto query fingerprints inside logical operation boundaries.
  """

  require Logger

  alias NOne.Collector
  alias NOne.Config
  alias NOne.Operation
  alias NOne.Report

  def watch(operation, opts \\ [], fun) when is_function(fun, 0) do
    config = Config.new(opts)

    if Config.off?(config) do
      fun.()
    else
      operation = start(operation, config)

      try do
        result = fun.()
        report = finish(operation)
        enforce!(report, config)
        result
      after
        cancel(operation)
      end
    end
  end

  def collect(operation, opts \\ [], fun) when is_function(fun, 0) do
    operation = start(operation, opts)

    try do
      result = fun.()
      report = finish(operation)
      {result, report}
    after
      cancel(operation)
    end
  end

  def start(operation, opts \\ [])

  def start(operation, %Config{} = config) do
    owner_pid = self()
    handler_id = {__MODULE__, owner_pid, make_ref()}
    {:ok, collector} = Collector.start(operation, config, handler_id, owner_pid)

    attach_query_handler(handler_id, collector, owner_pid, config.telemetry_events)

    %Operation{
      operation: operation,
      owner_pid: owner_pid,
      handler_id: handler_id,
      collector: collector,
      config: config
    }
  end

  def start(operation, opts) do
    start(operation, Config.new(opts))
  end

  def finish(%Operation{} = operation) do
    detach(operation.handler_id)
    Collector.finish(operation.collector)
  catch
    :exit, _reason ->
      %Report{operation: operation.operation}
  end

  def cancel(%Operation{} = operation) do
    detach(operation.handler_id)
    Collector.cancel(operation.collector)
  end

  def enforce!(report, opts_or_config \\ [])

  def enforce!(%Report{} = report, %Config{} = config) do
    if Report.violation?(report) do
      handle_violation(report, config)
    end

    :ok
  end

  def enforce!(%Report{} = report, opts) do
    enforce!(report, Config.new(opts))
  end

  defp attach_query_handler(_handler_id, _collector, _owner_pid, []), do: :ok

  defp attach_query_handler(handler_id, collector, owner_pid, telemetry_events) do
    :telemetry.attach_many(
      handler_id,
      telemetry_events,
      &NOne.TelemetryHandler.handle_event/4,
      %{collector: collector, owner_pid: owner_pid}
    )
  end

  defp handle_violation(report, %Config{mode: :log}) do
    Logger.warning(Report.message(report))
  end

  defp handle_violation(report, %Config{mode: :raise}) do
    raise NOne.Violation, report
  end

  defp handle_violation(report, %Config{mode: :telemetry}) do
    measurements = %{query_count: report.query_count, finding_count: length(report.findings)}
    metadata = %{operation: report.operation, report: report}

    :telemetry.execute([:n_one, :violation], measurements, metadata)
  end

  defp handle_violation(_report, %Config{mode: :off}), do: :ok

  defp detach(handler_id) do
    :telemetry.detach(handler_id)
  catch
    :error, _reason -> :ok
  end
end
