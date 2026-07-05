defmodule NOne.TelemetryHandler do
  @moduledoc false

  alias NOne.Collector

  def handle_event(event, measurements, metadata, %{collector: collector, owner_pid: owner_pid}) do
    if self() == owner_pid do
      Collector.record(collector, event, measurements, metadata)
    end
  end
end
