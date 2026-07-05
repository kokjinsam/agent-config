defmodule NOne.Config do
  @moduledoc false

  @modes ~w(off log raise telemetry)a

  defstruct repos: [],
            telemetry_events: [],
            mode: :log,
            max_repeats: 3,
            include: :all,
            ignore: []

  def new(opts \\ []) do
    opts = Application.get_all_env(:n_one) |> Keyword.merge(opts)
    mode = Keyword.get(opts, :mode, :log)
    max_repeats = Keyword.get(opts, :max_repeats, 3)
    repos = Keyword.get(opts, :repos, [])
    telemetry_events = opts |> Keyword.get(:telemetry_events, []) |> telemetry_events(repos)

    validate_mode!(mode)
    validate_max_repeats!(max_repeats)

    %__MODULE__{
      repos: List.wrap(repos),
      telemetry_events: telemetry_events,
      mode: mode,
      max_repeats: max_repeats,
      include: Keyword.get(opts, :include, :all),
      ignore: Keyword.get(opts, :ignore, [])
    }
  end

  def off?(%__MODULE__{mode: :off}), do: true
  def off?(%__MODULE__{}), do: false

  defp telemetry_events(events, repos) do
    events
    |> List.wrap()
    |> Enum.concat(repo_events(repos))
    |> Enum.uniq()
  end

  defp repo_events(repos) do
    repos
    |> List.wrap()
    |> Enum.flat_map(fn repo ->
      case repo_telemetry_prefix(repo) do
        nil -> []
        prefix -> [prefix ++ [:query]]
      end
    end)
  end

  defp repo_telemetry_prefix(repo) when is_atom(repo) do
    if function_exported?(repo, :config, 0) do
      repo.config()[:telemetry_prefix]
    end
  end

  defp repo_telemetry_prefix(_other), do: nil

  defp validate_mode!(mode) when mode in @modes, do: :ok

  defp validate_mode!(mode) do
    raise ArgumentError, "expected :mode to be one of #{inspect(@modes)}, got: #{inspect(mode)}"
  end

  defp validate_max_repeats!(max_repeats) when is_integer(max_repeats) and max_repeats >= 0,
    do: :ok

  defp validate_max_repeats!(max_repeats) do
    raise ArgumentError,
          "expected :max_repeats to be a non-negative integer, got: #{inspect(max_repeats)}"
  end
end
