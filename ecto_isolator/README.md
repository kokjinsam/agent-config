# Ecto Isolator

Detect non-atomic side effects while the current process is inside an Ecto
transaction.

## Install

```elixir
{:ecto_isolator, github: "kokjinsam/agent-config", sparse: "ecto_isolator", only: [:dev, :test], runtime: false}
```

## Configure

```elixir
config :ecto_isolator,
  repos: [MyApp.Repo],
  mode: :raise
```

Modes:

- `:raise` raises `EctoIsolator.Error`.
- `:log` logs a warning and continues.
- `:collect` records offenses for later assertion.

Use the ExUnit helper to collect offenses during each test and fail at teardown:

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use EctoIsolator.ExUnit
    end
  end
end
```

## Adapters

Req is the only built-in adapter:

```elixir
Req.new()
|> EctoIsolator.Adapters.Req.attach()
|> Req.get!(url: "https://example.com")
```

For other libraries, keep the package-specific wrapper or adapter in the
consuming application and call `EctoIsolator.check!/3` before the side effect:

```elixir
EctoIsolator.check!(:swoosh, :deliver, details: %{mailer: MyApp.Mailer})
MyApp.Mailer.deliver(email)
```

## Ignores

Ignore rules receive an `EctoIsolator.Offense`:

```elixir
config :ecto_isolator,
  ignore: [
    {:req, fn offense -> offense.details.url =~ "localhost" end}
  ]
```
