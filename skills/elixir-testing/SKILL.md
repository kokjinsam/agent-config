---
name: elixir-testing
description: How to write good Elixir and Phoenix tests — which layer to test at, which libraries to reach for (ExMachina, Mimic, phoenix_test, StreamData, Faker), and the patterns that keep tests fast, deterministic, and honest. Use this skill whenever writing, reading, reviewing, or refactoring Elixir/Phoenix tests, test files, or test failures — even if the user doesn't say "test" explicitly (e.g. "verify this context function", "check the LiveView works", "why is this flaky"). This skill covers test *mechanics*; the TDD discipline (red/green/refactor, vertical slicing, behavior-over-implementation) lives in the separate tdd skill — defer there for *when* and *in what order* to write tests, and use this skill for *how* to express them in Elixir.
---

# Elixir Testing

How to write Elixir and Phoenix tests that are fast, deterministic, and actually catch bugs. This skill is about *mechanics and tooling*. The TDD discipline — the red/green/refactor loop, slicing work vertically, testing behavior over implementation — belongs to the **tdd skill**. Lean on that for *when* to write a test; use this for *how* to write it in Elixir.

## Start here: which layer am I testing?

Pick the layer first. Everything else — library, mocking stance, setup — follows from it. Most confusion in Elixir tests comes from testing at the wrong layer (mocking a context, or driving a feature through context calls).

```
What am I testing?
│
├─ A context / domain function (create_user, list_tasks, transition_order)?
│   → Call the real function. Real DB via Ecto sandbox. ExMachina for setup.
│     NEVER mock the Repo or your own contexts. → "Context/domain tests"
│
├─ A user-facing flow (a page, a form, a LiveView interaction)?
│   → phoenix_test. Drive actions through the rendered UI, not context calls.
│     → "Feature/page tests"
│
├─ Something I can't control inside the test process
│  (HTTP, payments, email, SMS, storage, PubSub, Oban)?
│   → Mimic at the boundary. → "External boundaries"
│
└─ A pure function (no DB, no process, no time)?
    → Plain assertions. Consider a property test (StreamData) and/or a doctest.
      → "Pure functions"
```

When a single feature spans layers, write a test at each layer rather than one test that reaches across all of them. A feature test proves the form works; a context test proves the business rule holds; a boundary test proves the email got sent. Each fails for one clear reason.

## Context/domain tests

The bulk of your suite. These exercise the real business logic against a real database.

- Call the real context functions. Do **not** mock them.
- Use ExMachina factories for setup, hitting a real DB through the Ecto sandbox. Factories + sandbox is fast, and mocking the Repo or your own contexts hides exactly the bugs these tests exist to catch.
- Modern Phoenix passes a `%Scope{}` (auth/tenancy) as the first argument. Build a scope in setup and pass it in.

```elixir
defmodule MyApp.TasksTest do
  use MyApp.DataCase, async: true

  alias MyApp.Tasks
  alias MyApp.Tasks.Task

  import MyApp.Factory

  describe "create_task/2" do
    setup do
      %{scope: user_scope(insert(:user))}
    end

    test "with valid attrs creates a task owned by the scope", %{scope: scope} do
      assert {:ok, %Task{} = task} = Tasks.create_task(scope, %{title: "Ship it"})
      assert task.title == "Ship it"
      assert task.user_id == scope.user.id
    end

    test "with a blank title returns an error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = changeset} = Tasks.create_task(scope, %{title: ""})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
```

`user_scope/1` is a small test helper that wraps a user in your app's `%Scope{}` struct — define it once in `DataCase`. If your app predates scopes and still threads a bare `current_user`/`user_id`, the same patterns apply with the user in that position; scopes are just the current default.

## Feature/page tests

[`phoenix_test`](https://github.com/germsvel/phoenix_test) drives both LiveView and dead views through **one API**. It's the default for anything a user can see.

- Test behavior the user can observe (text on the page, redirects, validation messages), not implementation details (assigns, socket state, `handle_info`).
- Set up **preconditions** (existing users, existing records) with factories — that's fine, they aren't user actions.
- Drive the **action under test** (logging in, filling forms, clicking) through the UI. Calling `Accounts.create_session/1` to "log in" or `Comments.create_comment/2` to "post a comment" defeats the layer — the test stops testing what its name claims.

```elixir
defmodule MyAppWeb.TaskLiveTest do
  use MyAppWeb.ConnCase, async: true

  import PhoenixTest
  import MyApp.Factory

  test "user creates a task from the index page", %{conn: conn} do
    user = insert(:user)

    conn
    |> log_in_user(user)
    |> visit(~p"/tasks")
    |> click_link("New Task")
    |> fill_in("Title", with: "Ship the thing")
    |> click_button("Create")
    |> assert_has("#tasks", text: "Ship the thing")
    |> assert_path(~p"/tasks")
  end

  test "blank title renders inline validation", %{conn: conn} do
    conn
    |> log_in_user(insert(:user))
    |> visit(~p"/tasks/new")
    |> fill_in("Title", with: "")
    |> click_button("Create")
    |> assert_has(".error", text: "can't be blank")
  end
end
```

`log_in_user/2` establishes the scope through the session — that *is* a user action expressed at the right layer, so it's fine in setup.

### Escape hatch: `Phoenix.LiveViewTest`

`phoenix_test` deliberately hides assigns, sockets, and `handle_info` because tests coupled to them break for the wrong reasons. If you genuinely need to assert on a LiveView's internal state — e.g. a `handle_info` pipeline with no visible UI manifestation — drop into `Phoenix.LiveViewTest` for that **one** test and leave a one-line comment saying why. Don't smuggle its helpers into a `phoenix_test` file; a reader can't tell which contract a mixed test is honoring, and the layering rule quietly erodes.

## External boundaries

The boundary is roughly "anything you can't fully control inside the BEAM process the test runs in." Mock these with [Mimic](https://github.com/edgurgel/mimic), which copies the real module so you can replace functions on it — no behaviour to define upfront.

- HTTP clients, payment processors, email, SMS, object storage, analytics.
- **Oban** — assert jobs are enqueued (`Oban.Testing.assert_enqueued`); don't run them in unit tests. Test the worker's `perform/1` as its own unit elsewhere.
- **Phoenix.PubSub** — stub broadcasts; don't depend on real subscribers receiving messages in a unit test.
- **File system I/O** — stub `File.read`/`File.write`/etc. rather than touching real paths.
- **Do not** mock the Repo, Ecto, or your own contexts. Mimic is for the outside world, not code you wrote.

### Setup

```elixir
# test/test_helper.exs
Mimic.copy(MyApp.Stripe)
Mimic.copy(MyApp.Mailer)
Mimic.copy(File)
ExUnit.start()
```

### Three operations, three intents

Pick the one that matches what the test is actually saying. Reaching for `expect` when you mean `stub` makes failure messages noisy — every incidental dependency starts demanding "must be called" and the real signal gets lost.

| Operation | Means |
|---|---|
| `stub/3` | "Whatever happens, return this." No assertion the call happened. For incidental dependencies the test needs to step past. |
| `expect/3` | "This must be called, with these args, this many times." When the test's *purpose* is "this thing got called correctly." |
| `reject/1` | "This must NOT be called." When *not* calling something is the point (short-circuit logic, idempotency). |

```elixir
import Mimic

setup :set_mimic_private

test "complete_purchase/1 charges the card and emails a receipt" do
  stub(MyApp.Stripe, :charge, fn _ -> {:ok, %{id: "ch_123"}} end)

  expect(MyApp.Mailer, :deliver, fn email ->
    assert email.to == "buyer@example.com"
    assert email.subject =~ "Receipt"
    {:ok, email}
  end)

  assert :ok = Orders.complete_purchase(order_attrs())
end

test "complete_purchase/1 does not email when the charge fails" do
  stub(MyApp.Stripe, :charge, fn _ -> {:error, :card_declined} end)
  reject(&MyApp.Mailer.deliver/1)

  assert {:error, :card_declined} = Orders.complete_purchase(order_attrs())
end
```

## Pure functions

No DB, no process, no time — just plain assertions. These are the cheapest tests you have, and the only place doctests earn their keep. Property tests are happiest here too — cheap setup means you can crank thousands of generated inputs through — but they can also pay off at higher tiers when the domain has rich invariants and a complex interaction graph; you just accept the higher per-iteration cost. See the property-based testing section below.

### Time is a parameter, not a mock

Don't mock the system clock. A function that cares about time takes it as an argument with a default:

```elixir
def expired?(token, now \\ DateTime.utc_now()) do
  DateTime.compare(token.expires_at, now) == :lt
end
```

The test passes a fixed `DateTime`. The dependency is visible at the call site, the test is deterministic, and there's no global stub to remember to reset.

### Doctests (pure functions only)

Doctests double as documentation and tests — but only for pure functions. Never doctest anything that touches the DB, processes, or wall-clock time: the output isn't stable and the doc becomes a lie.

```elixir
defmodule MyApp.Money do
  @doc """
  Formats cents as a dollar string.

      iex> MyApp.Money.format(1050)
      "$10.50"

      iex> MyApp.Money.format(0)
      "$0.00"
  """
  def format(cents), do: ...
end
```

Wire them into ExUnit with one line per module:

```elixir
defmodule MyApp.MoneyTest do
  use ExUnit.Case, async: true
  doctest MyApp.Money
end
```

## Property-based testing with StreamData

Example-based tests check the cases you thought of. Property tests check a rule across hundreds of generated inputs — they shine on parsers, encoders, and anything with an invariant. Use [StreamData](https://github.com/whatyouhide/stream_data) (`use ExUnitProperties`).

```elixir
use ExUnitProperties

# Invariant: a property that always holds
property "full_name/1 always contains both names" do
  check all first <- string(:alphanumeric, min_length: 1),
            last <- string(:alphanumeric, min_length: 1) do
    name = User.full_name(%User{first_name: first, last_name: last})
    assert String.contains?(name, first)
    assert String.contains?(name, last)
  end
end

# Roundtrip: encode then decode returns the original
property "encoding then decoding is the identity" do
  check all data <- map_of(string(:alphanumeric), integer()) do
    assert data == data |> MyApp.Encoder.encode() |> MyApp.Encoder.decode()
  end
end

# Idempotence: applying twice equals applying once
property "sorting is idempotent" do
  check all list <- list_of(integer()) do
    assert Enum.sort(list) == list |> Enum.sort() |> Enum.sort()
  end
end

# Custom generator for a domain type
property "valid emails are accepted" do
  email_gen =
    gen all name <- string(:alphanumeric, min_length: 1),
            domain <- string(:alphanumeric, min_length: 1) do
      "#{name}@#{domain}.com"
    end

  check all email <- email_gen do
    assert {:ok, _} = Accounts.validate_email(email)
  end
end
```

When a property fails, StreamData shrinks the input to the smallest case that still breaks — read the shrunk value, it usually names the bug.

### Beyond pure functions

Property tests aren't strictly pure-only. When a domain has a rich interaction graph — many commands, intricate cross-field rules, multi-step lifecycles — a property test that drives random *sequences* of public context calls through the real Repo can surface ordering bugs that example-based tests miss. The cost is real (each iteration runs through transactions, factories, and DB writes, so iteration counts shrink), so reach for it only when the domain genuinely justifies it. Most apps don't need it; some absolutely do.

## Test data with ExMachina

[ExMachina](https://github.com/beam-community/ex_machina). **One factory per schema**, holding stable, readable defaults that produce a *valid* record. Don't grow factory variants — pass overrides at the call site so the reader sees the attribute that matters right there.

```elixir
# test/support/factory.ex
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  def user_factory do
    %MyApp.Accounts.User{
      email: sequence(:email, &"user-#{&1}@example.com"),
      name: "Test User"
    }
  end

  def task_factory do
    %MyApp.Tasks.Task{
      title: "Test Task",
      status: :todo,
      user: build(:user)
    }
  end
end
```

### Pick the operation by intent

| Operation | Use when |
|---|---|
| `insert/2` | Default for context tests. The function under test queries, updates, or associates — it needs a real row. |
| `build/2` | The function doesn't touch the DB (changeset shape, struct manipulation, pure transform). Avoids a needless write. |
| `params_for/2` | Testing a changeset directly: `User.changeset(%User{}, params_for(:user, email: "bad"))`. |

```elixir
# Good — the value that matters is right where the test reads
test "rejects too-short titles" do
  task = insert(:task, title: "x")
  assert {:error, _} = Tasks.update_task(task, %{title: ""})
end

# Bad — hides the relevant value in a far-away factory definition
def too_short_task_factory, do: %Task{title: "x"}
```

### Faker only for values you don't assert on

[Faker](https://github.com/elixirs/faker) is for filler — emails, lorem-ipsum bodies — where the value is irrelevant. When the test asserts on the value, **hardcode it**. A readable failure (`expected "Ada Lovelace", got nil`) beats a realistic-looking one (`expected "Quincy Wuckert MD", got nil`) that tells you nothing.

## Async and the Ecto SQL Sandbox

This is where most real Elixir test flakiness lives. Get it right once and it stops biting.

### Default to `async: true`

Tests in a module run concurrently with tests in *other* async modules. This is most of the speed win in an Elixir suite, so make modules async by default. A module is **safe to be async** when it touches only the database through the sandbox and process-local state. A module is **unsafe** (leave it synchronous) when it:

- mutates global state (application env, named ETS tables, a global GenServer),
- uses `Mimic` in **global** mode, or
- depends on real wall-clock timing.

### How the sandbox isolates DB state

Each test checks out a connection wrapped in a transaction that's rolled back at the end, so tests never see each other's rows. Two checkout modes:

- **`:manual` / private (default for async):** each test gets its own connection. This is what makes async DB tests safe. `DataCase`/`ConnCase` set this up via `Ecto.Adapters.SQL.Sandbox.start_owner!` per test.
- **`:shared`:** one connection shared across processes. Only for `async: false` modules where you can't (or don't want to) thread allowances. Setting shared mode in an async test corrupts other tests — don't.

### Spawned processes need an allowance

A spawned process (a `Task`, a GenServer, the LiveView process) runs under a *different* pid, so it doesn't automatically see the test's checked-out connection. Grant it explicitly:

```elixir
:ok = Ecto.Adapters.SQL.Sandbox.allow(MyApp.Repo, self(), spawned_pid)
```

`phoenix_test` and the generated `ConnCase` already wire allowances for the LiveView/request process, so feature tests usually just work async. You hit this manually when your code under test spawns its own process that queries the DB. If a row mysteriously isn't visible (or you get an ownership error) in an async test, a missing allowance is the first suspect.

### Mimic + async: use private mode

Mimic stubs are **global by default and leak across parallel tests**. Any module that is `async: true` and uses Mimic must opt into private mode:

```elixir
use MyApp.DataCase, async: true
import Mimic

setup :set_mimic_private
```

`set_mimic_private` scopes stubs to the calling process (and processes it allows). Reach for `set_mimic_global` only in `async: false` modules where the stub must be visible to a process you don't control — and accept that it serializes that module.

## Elixir gotchas worth a test

Not a checklist to apply blindly (the tdd skill governs *what* behaviors to test) — just three things the type system won't catch and that are easy to forget in Elixir/Phoenix specifically.

**Changeset error shape.** Assert on the actual message via `errors_on/1`, not just that it errored — a typo'd validation still "returns an error."

```elixir
assert {:error, changeset} = Tasks.create_task(scope, %{title: "", status: :nope})
assert %{title: ["can't be blank"], status: ["is invalid"]} = errors_on(changeset)
```

**Scope-based authorization.** A function that takes a `%Scope{}` must refuse another scope's data. This is load-bearing security, and it's trivial to forget the negative case.

```elixir
test "get_task/2 can't read another user's task" do
  owner_scope = user_scope(insert(:user))
  task = insert(:task, user: owner_scope.user)
  other_scope = user_scope(insert(:user))

  assert {:error, :not_found} = Tasks.get_task(other_scope, task.id)
end
```

**Ecto state transitions.** When a schema has a status machine, assert both the allowed and the rejected transitions — the rejected ones are where bugs hide. The error shape depends on how the transition function is written: a function that returns `{:ok, _}` / `{:error, _}` surfaces a tagged atom; a function that returns a changeset (e.g. Gearbox applied to a changeset, then `Repo.update`) surfaces an `%Ecto.Changeset{}` with the transition error attached. Pin whichever shape your code actually returns.

```elixir
# Tagged-atom shape:
test "rejects todo -> done (must pass through in_progress)" do
  task = insert(:task, status: :todo)
  assert {:error, :invalid_transition} = Tasks.transition_task(task, :done)
end

# Changeset shape (transition function returns a changeset, handler runs Repo.update):
test "rejects todo -> done (must pass through in_progress)" do
  task = insert(:task, status: :todo)
  assert {:error, %Ecto.Changeset{} = changeset} = Tasks.transition_task(task, :done)
  assert %{status: [_ | _]} = errors_on(changeset)
end
```

## Organizing tests

### File structure mirrors source

```
lib/my_app/accounts/user.ex       → test/my_app/accounts/user_test.exs
lib/my_app/accounts.ex            → test/my_app/accounts_test.exs
lib/my_app_web/live/task_live.ex  → test/my_app_web/live/task_live_test.exs
```

### `describe` per function, `setup` for shared preconditions

Group by the function under test; put shared setup in a `setup` block scoped to that `describe`. Keep what's *common* in setup and what *varies* in the test body.

```elixir
describe "update_task/3" do
  setup %{} do
    scope = user_scope(insert(:user))
    %{scope: scope, task: insert(:task, user: scope.user)}
  end

  test "with valid attrs updates the task", %{scope: scope, task: task} do
    assert {:ok, task} = Tasks.update_task(scope, task, %{title: "New"})
    assert task.title == "New"
  end
end
```

### What lives in `DataCase`/`ConnCase` vs a test's `setup`

- **In the case template** (`DataCase`, `ConnCase`): things *every* test in that category needs — the sandbox checkout, `import`s (`Factory`, `errors_on`), shared helpers like `user_scope/1` and `log_in_user/2`.
- **In a test's `setup`**: the specific records and scope *this* describe block needs.
- **Prefer per-test factories over global seed data.** A shared seed file makes tests depend on rows they didn't create and can't see in the test body — when the seed changes, unrelated tests break. Build what each test needs, in that test.

### Tags separate fast from slow

Tag the genuinely slow or externally-dependent tests so the default run stays fast:

```elixir
@tag :integration
test "talks to the real payment sandbox", do: ...
```

```elixir
# test/test_helper.exs — excluded by default, opt in with --include
ExUnit.configure(exclude: [:integration])
```

Run everything in CI, or `mix test --include integration` locally when you need it.

## Running tests

```bash
mix test                              # all (fast) tests
mix test test/my_app/tasks_test.exs   # one file
mix test test/my_app/tasks_test.exs:42 # one test by line
mix test --failed                     # only what failed last run
mix test --include integration        # add the slow/external tagged tests
mix test --warnings-as-errors         # CI: a warning fails the build
mix test.watch                        # local red/green loop, reruns on save
```

`--warnings-as-errors` in CI keeps unused variables and deprecations from rotting the suite. `mix test.watch` (the [`mix_test_watch`](https://github.com/randycoulman/mix_test_watch) dep) is the local companion to the TDD loop.

## Anti-patterns

### ❌ Don't mock the Repo or Ecto

```elixir
# WRONG — now the test passes even when your query is broken
expect(Repo, :insert, fn _ -> {:ok, %User{}} end)

# RIGHT — sandbox + real insert; assert it actually landed
assert {:ok, user} = Accounts.create_user(scope, valid_attrs)
assert Repo.get(User, user.id)
```

### ❌ Don't mock your own contexts

```elixir
# WRONG — green when your own code is broken
stub(MyApp.Accounts, :get_user, fn _ -> %User{id: 1} end)

# RIGHT — real function, real factory data
user = insert(:user)
assert {:ok, _} = MyApp.Tasks.create_task(user_scope(user), valid_attrs)
```

Mimic is for the external boundary — HTTP, payments, email, Oban, PubSub, file I/O — not code you wrote.

### ❌ Don't drive feature actions through context calls

```elixir
# WRONG — the action under test skips the UI entirely
{:ok, _} = Comments.create_comment(scope, post, %{body: "Hello"})
conn |> visit(~p"/posts/#{post}") |> assert_has(".comment", text: "Hello")

# RIGHT — the action goes through the form, which is what the test claims to check
conn
|> log_in_user(user)
|> visit(~p"/posts/#{post}")
|> fill_in("Comment", with: "Hello")
|> click_button("Post")
|> assert_has(".comment", text: "Hello")
```

Setting up *preconditions* (the user, the post) via factories is fine. The *action under test* must go through the UI.

### ❌ Don't use Faker for values you assert on

```elixir
# WRONG — the failure message can't tell you what the value was
name = Faker.Person.name()
{:ok, user} = Accounts.create_user(%{name: name})
assert user.name == name

# RIGHT — stable and readable
{:ok, user} = Accounts.create_user(%{name: "Ada Lovelace"})
assert user.name == "Ada Lovelace"
```

### ❌ Don't reach into LiveView internals from phoenix_test

If you find yourself wanting `:sys.get_state` or `assigns` inside a `phoenix_test` file, stop — switch that one test to `Phoenix.LiveViewTest` deliberately and note why. Don't mix the two libraries' helpers in one test.

### ❌ Don't write assertions that pass regardless of behavior

```elixir
# WRONG — {:error, ...} is still truthy; this never fails
result = MyModule.do_thing()
assert result

# RIGHT — pin the exact shape you expect
assert {:ok, %User{email: "test@example.com"}} = MyModule.do_thing()
```

Prefer a pattern-match assertion (`assert {:ok, %User{} = u} = ...`) over a bare truthiness check — it documents the contract and fails loudly when the shape drifts.
