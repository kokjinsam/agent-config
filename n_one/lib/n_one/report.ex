defmodule NOne.Report do
  @moduledoc """
  Query collection results for one logical operation.
  """

  defstruct operation: nil,
            query_count: 0,
            findings: [],
            started_at: nil,
            finished_at: nil

  def violation?(%__MODULE__{findings: findings}), do: findings != []

  def message(%__MODULE__{} = report) do
    header =
      "NOne detected #{length(report.findings)} repeated query finding(s) during " <>
        "#{inspect(report.operation)} across #{report.query_count} total querie(s)."

    details =
      report.findings
      |> Enum.map(fn finding ->
        source = finding.source || "unknown source"
        command = finding.command || "unknown"

        "* #{finding.count}x #{command} on #{source} " <>
          "(#{finding.unique_param_sets} unique param set(s)): #{finding.fingerprint}"
      end)
      |> Enum.join("\n")

    [header, details]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
