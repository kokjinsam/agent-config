defmodule EctoIsolator do
  @moduledoc """
  Detects configured non-atomic operations while the current process is inside
  an Ecto transaction.
  """

  require Logger

  alias EctoIsolator.{Collector, Config, Error, Offense}

  @doc """
  Returns true when any configured repo reports an active transaction.
  """
  def within_transaction?(repos \\ Config.repos()) do
    repos
    |> List.wrap()
    |> Enum.any?(&repo_in_transaction?/1)
  end

  @doc """
  Checks whether an adapter action is allowed in the current process.

  When any configured repo is in a transaction, the offense is handled according
  to the active mode:

    * `:raise` - raise `EctoIsolator.Error`
    * `:log` - write a warning and continue
    * `:collect` - record the offense for later assertion
  """
  def check!(adapter, action, opts \\ []) when is_atom(adapter) and is_atom(action) do
    if should_report?(opts) do
      offense = Offense.new(adapter, action, opts)

      if ignored?(offense) do
        :ok
      else
        handle_offense(offense, Keyword.get(opts, :mode, Config.mode()))
      end
    else
      :ok
    end
  end

  def with_mode(mode, fun) when mode in [:raise, :log, :collect] and is_function(fun, 0) do
    with_process_value(:ecto_isolator_mode, mode, fun)
  end

  defp should_report?(opts) do
    within_transaction?(Keyword.get(opts, :repos, Config.repos()))
  end

  defp handle_offense(%Offense{} = offense, :raise) do
    raise Error, offense
  end

  defp handle_offense(%Offense{} = offense, :log) do
    Logger.warning(Offense.format(offense))
    :ok
  end

  defp handle_offense(%Offense{} = offense, :collect) do
    Collector.collect(offense)
  end

  defp ignored?(%Offense{} = offense) do
    Enum.any?(Config.ignore_rules(), &ignore_rule_matches?(&1, offense))
  end

  defp ignore_rule_matches?(fun, %Offense{} = offense) when is_function(fun, 1) do
    fun.(offense)
  end

  defp ignore_rule_matches?({adapter, fun}, %Offense{adapter: adapter} = offense)
       when is_function(fun, 1) do
    fun.(offense)
  end

  defp ignore_rule_matches?(
         {adapter, action, fun},
         %Offense{adapter: adapter, action: action} = offense
       )
       when is_function(fun, 1) do
    fun.(offense)
  end

  defp ignore_rule_matches?(_rule, _offense), do: false

  defp repo_in_transaction?(repo) when is_atom(repo) do
    Code.ensure_loaded?(repo) &&
      function_exported?(repo, :in_transaction?, 0) &&
      repo.in_transaction?()
  end

  defp repo_in_transaction?(_repo), do: false

  defp with_process_value(key, value, fun) do
    previous = Process.get(key)
    Process.put(key, value)

    try do
      fun.()
    after
      restore_process_value(key, previous)
    end
  end

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
