# NOne

Detect repeated Ecto query fingerprints inside logical operation boundaries.

```elixir
NOne.watch("reviews.index", fn ->
  Reviews.list_reviews(workspace)
end)
```

Configure the Repo telemetry events to watch:

```elixir
config :n_one,
  repos: [MyApp.Repo],
  mode: :log,
  max_repeats: 3
```

Use the Phoenix plug to watch request boundaries without wrapping query
functions:

```elixir
plug NOne.Plug
```

Use the ExUnit helper for focused regression tests:

```elixir
import NOne.ExUnit

assert_no_repeated_queries "reviews.index", max_repeats: 1 do
  Reviews.list_reviews(workspace)
end
```
