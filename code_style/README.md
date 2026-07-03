# Code Style

Personal Elixir code-style checks.

## Credo Checks

Add `code_style` to a consuming Mix project:

```elixir
{:code_style, path: "../../../../agent-config/code_style", only: [:dev, :test], runtime: false}
```

Then enable the check in `.credo.exs`:

```elixir
{CodeStyle.Credo.NoDatabaseConstraints, []}
```

`CodeStyle.Credo.NoDatabaseConstraints` flags business-logic column options in
Ecto migration table blocks. The rule is intentionally copied from Remark
without behavior changes.
