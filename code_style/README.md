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
{CodeStyle.Check.Warning.RepoInsideLoop, []}
```

`CodeStyle.Credo.NoDatabaseConstraints` flags business-logic column options in
Ecto migration table blocks. The rule is intentionally copied from Remark
without behavior changes.

`CodeStyle.Check.Warning.RepoInsideLoop` flags direct `Repo.*` calls inside
`Enum`, `Stream`, and `for` loop bodies where the code is likely to create N+1
query behavior.
