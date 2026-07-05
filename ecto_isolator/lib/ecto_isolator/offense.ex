defmodule EctoIsolator.Offense do
  @moduledoc """
  A detected non-atomic operation inside an Ecto transaction.
  """

  alias EctoIsolator.Config

  @enforce_keys [:adapter, :action, :details, :pid, :repos, :stacktrace]
  defstruct [:adapter, :action, :details, :pid, :repos, :stacktrace]

  def new(adapter, action, opts \\ []) when is_atom(adapter) and is_atom(action) do
    %__MODULE__{
      adapter: adapter,
      action: action,
      details: Keyword.get(opts, :details),
      pid: self(),
      repos: Keyword.get(opts, :repos, Config.repos()),
      stacktrace: Keyword.get_lazy(opts, :stacktrace, &current_stacktrace/0)
    }
  end

  def format(%__MODULE__{} = offense) do
    base =
      "Unsafe #{format_adapter_action(offense)} inside an Ecto transaction"

    case offense.details do
      nil -> base
      details -> base <> "\nDetails: " <> inspect(details)
    end
  end

  defp current_stacktrace do
    self()
    |> Process.info(:current_stacktrace)
    |> case do
      {:current_stacktrace, [_process_info | stacktrace]} -> stacktrace
      _other -> []
    end
  end

  defp format_adapter_action(%__MODULE__{adapter: adapter, action: action}) do
    "#{adapter}:#{action}"
  end
end
