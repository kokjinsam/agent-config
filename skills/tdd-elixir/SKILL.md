---
name: tdd-elixir
description: Test-driven development enforcement for Elixir and Phoenix. Requires failing tests before implementation. Use when implementing features, fixing bugs, or when code quality discipline is needed.
---

# Elixir TDD Enforcement

Strict test-driven development practices for Elixir and Phoenix projects.

## The Golden Rule

**No Code Without a Failing Test First**

This is not optional. This is not negotiable. Every feature, every bug fix, every change starts with a test.

## The TDD Cycle

1. **Red**: Write a test that describes the behavior you want. Run it. It must fail.
2. **Green**: Write the minimum code to make the test pass. Nothing more.
3. **Refactor**: Clean up while keeping tests green.
4. **Repeat**

```elixir
# Step 1: Write the failing test
test "create_user/1 with valid attrs creates a user" do
  attrs = %{email: "test@example.com", name: "Test User"}
  assert {:ok, %User{} = user} = Accounts.create_user(attrs)
  assert user.email == "test@example.com"
end

# Step 2: Run it - it MUST fail
# $ mix test test/my_app/accounts_test.exs:10
# ** (UndefinedFunctionError) function Accounts.create_user/1 is undefined

# Step 3: Write minimum code to pass
def create_user(attrs) do
  %User{}
  |> User.changeset(attrs)
  |> Repo.insert()
end

# Step 4: Run test again - it passes
# Step 5: Refactor if needed, keeping tests green
```

## Preferred Test Style

Tests cluster into three layers. Each has a different default approach. Pick the layer first, then the approach follows.

### Context/domain tests

- Call real context functions. Do not mock them.
- Use ExMachina factories for database setup.
- Hit a real DB via the Ecto sandbox. Factories + sandbox is fast enough, and mocking the Repo or your own contexts hides exactly the bugs these tests exist to catch.

### Feature/page tests

- Use [`phoenix_test`](https://github.com/germsvel/phoenix_test) for user-facing flows. It works for both LiveView and dead views with one API.
- Test behavior the user can see, not implementation details (assigns, socket state, internal messages).
- Set up **preconditions** (existing users, existing records) with factories — that's fine.
- Drive **user actions** (logging in, submitting forms, clicking buttons) through the UI, never by calling a context directly. Calling `Accounts.create_session/1` to "log in" inside a feature test defeats the point of the layer.
- Escape hatch: when you genuinely need to assert on LiveView internals, drop down to `Phoenix.LiveViewTest` deliberately for that one test and note why in a short comment.

### External boundaries (mock with Mimic)

The boundary is roughly "anything you can't fully control inside the BEAM process the test runs in":

- HTTP clients, payment processors, email, SMS, object storage, analytics — the usual outbound integrations.
- **Oban** — assert jobs are enqueued (`Oban.Testing.assert_enqueued`); don't actually run them in unit tests.
- **Phoenix.PubSub** — stub broadcasts; don't depend on real subscribers receiving messages.
- **File system I/O** — stub `File.read`/`File.write`/etc. rather than touching real paths.
- **Do not** mock the Repo, Ecto, or your own contexts.

Prefer [Mimic](https://github.com/edgurgel/mimic) for new code. Older codebases will have Mox-based mocks — leave them, but don't add more.

### Time

Don't mock the system clock. Functions that care about time accept it as a parameter:

```elixir
def expire_token(token, now \\ DateTime.utc_now()) do
  DateTime.compare(token.expires_at, now) == :lt
end
```

Tests pass a fixed `DateTime`. The dependency is visible at the call site, the test is deterministic, and there's no stub to remember to clean up.

### Factories

- Use [ExMachina](https://github.com/beam-community/ex_machina). One factory per schema.
- Keep factories minimal — stable, readable defaults that produce a valid record.
- Pass overrides at the call site, not by creating factory variants. A reader of the test should see the attribute that matters right there.

### Fake data

Use [Faker](https://github.com/elixirs/faker) only when the value doesn't matter (filler emails, lorem ipsum bodies). When the test asserts on the value, hardcode it — a readable failure (`expected "Ada Lovelace", got nil`) is worth more than a realistic-looking one (`expected "Quincy Wuckert MD", got nil`).

## Test File Structure

Match your source structure:

```
lib/my_app/accounts/user.ex      → test/my_app/accounts/user_test.exs
lib/my_app/accounts.ex           → test/my_app/accounts_test.exs
lib/my_app_web/live/task_live.ex → test/my_app_web/live/task_live_test.exs
lib/my_app_web/controllers/      → test/my_app_web/controllers/
```

## Mandatory Test Cases

For every function, test:

### 1. Happy Path

Valid input produces expected output.

```elixir
test "create_task/1 with valid attrs creates task" do
  attrs = %{title: "Test Task", status: :todo}
  assert {:ok, %Task{} = task} = Tasks.create_task(attrs)
  assert task.title == "Test Task"
  assert task.status == :todo
end
```

### 2. Validation Failures

Invalid input returns error changeset.

```elixir
test "create_task/1 with missing title returns error" do
  assert {:error, %Ecto.Changeset{} = changeset} = Tasks.create_task(%{})
  assert %{title: ["can't be blank"]} = errors_on(changeset)
end

test "create_task/1 with invalid status returns error" do
  attrs = %{title: "Test", status: :invalid_status}
  assert {:error, changeset} = Tasks.create_task(attrs)
  assert %{status: ["is invalid"]} = errors_on(changeset)
end
```

### 3. Edge Cases

Boundary conditions and unusual inputs.

```elixir
test "create_task/1 with empty string title returns error" do
  assert {:error, changeset} = Tasks.create_task(%{title: ""})
  assert %{title: ["can't be blank"]} = errors_on(changeset)
end

test "create_task/1 with whitespace-only title returns error" do
  assert {:error, changeset} = Tasks.create_task(%{title: "   "})
  assert %{title: ["can't be blank"]} = errors_on(changeset)
end

test "list_tasks/0 returns empty list when no tasks exist" do
  assert [] = Tasks.list_tasks()
end
```

### 4. Authorization

Users can only access their own resources.

```elixir
test "get_task/2 returns error when task belongs to another user" do
  other_user = user_fixture()
  task = task_fixture(user_id: other_user.id)
  user = user_fixture()

  assert {:error, :not_found} = Tasks.get_task(user, task.id)
end

test "update_task/3 returns error when user doesn't own task" do
  owner = user_fixture()
  other_user = user_fixture()
  task = task_fixture(user_id: owner.id)

  assert {:error, :unauthorized} = Tasks.update_task(other_user, task, %{title: "Hacked"})
end
```

### 5. State Transitions (if applicable)

Valid and invalid state changes.

```elixir
describe "transition_task/2" do
  test "allows todo -> in_progress" do
    task = task_fixture(status: :todo)
    assert {:ok, task} = Tasks.transition_task(task, :in_progress)
    assert task.status == :in_progress
  end

  test "allows in_progress -> done" do
    task = task_fixture(status: :in_progress)
    assert {:ok, task} = Tasks.transition_task(task, :done)
    assert task.status == :done
  end

  test "rejects todo -> done (must go through in_progress)" do
    task = task_fixture(status: :todo)
    assert {:error, :invalid_transition} = Tasks.transition_task(task, :done)
  end

  test "rejects done -> todo" do
    task = task_fixture(status: :done)
    assert {:error, :invalid_transition} = Tasks.transition_task(task, :todo)
  end
end
```

## Testing Feature/Page Flows with phoenix_test

`phoenix_test` drives both LiveView and dead views through one API. Set up state with factories, drive actions through the rendered page.

```elixir
import PhoenixTest

describe "managing tasks" do
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

  test "user deletes a task", %{conn: conn} do
    user = insert(:user)
    task = insert(:task, user: user, title: "Delete Me")

    conn
    |> log_in_user(user)
    |> visit(~p"/tasks")
    |> within("#task-#{task.id}", fn session ->
      click_button(session, "Delete")
    end)
    |> refute_has("#task-#{task.id}")
  end
end
```

### Escape hatch: when you really need internals

`phoenix_test` deliberately hides assigns, sockets, and `handle_info` — those are implementation detail, and tests coupled to them break for the wrong reasons. If you genuinely need to assert on a LiveView's internal state (e.g., a complex `handle_info` pipeline with no UI manifestation), import `Phoenix.LiveViewTest` for that single test and leave a one-line comment about why. Don't mix the two libraries' helpers in the same test.

## Test Data with ExMachina

One factory per schema. Stable, readable defaults. Overrides at the call site.

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
| `build/2` | The function doesn't touch the DB (changeset shape, struct manipulation, pure transformation). Avoids a needless write. |
| `params_for/2` | Testing a changeset function directly: `User.changeset(%User{}, params_for(:user, email: "bad"))`. |

### Override at the call site, don't grow factory variants

```elixir
# Good: the attribute that matters is right where the test reads
test "rejects too-short titles" do
  task = insert(:task, title: "x")
  assert {:error, _} = Tasks.update_task(task, %{title: ""})
end

# Bad: hides the relevant value in a far-away factory definition
def too_short_task_factory, do: %Task{title: "x", ...}
```

If a test needs a specific shape, pass it. Reserve factory definitions for "what does a valid one look like."

## What NOT to Do

### ❌ Don't write tests after the code

```elixir
# WRONG: Code first, then tests
def create_task(attrs), do: ...  # Written first
test "create_task works" do ...  # Added later to "cover" it
```

### ❌ Don't skip tests for "simple" functions

```elixir
# WRONG: "It's too simple to test"
def full_name(user), do: "#{user.first_name} #{user.last_name}"
# Still needs tests! What if first_name is nil?
```

### ❌ Don't test private functions directly

```elixir
# WRONG: Testing private implementation
test "parse_date/1 parses ISO format" do
  assert MyModule.parse_date("2024-01-01") == ~D[2024-01-01]
end

# RIGHT: Test through the public API
test "create_event/1 accepts ISO date strings" do
  assert {:ok, event} = Events.create_event(%{date: "2024-01-01"})
  assert event.date == ~D[2024-01-01]
end
```

### ❌ Don't mock Ecto or database in context tests

```elixir
# WRONG: Mocking the repo
expect(Repo, :insert, fn _ -> {:ok, %User{}} end)

# RIGHT: Use the sandbox, test real behavior
assert {:ok, %User{}} = Accounts.create_user(valid_attrs)
assert Repo.get(User, user.id)  # Actually in database
```

### ❌ Don't mock your own contexts

```elixir
# WRONG: stubbing internal code
stub(MyApp.Accounts, :get_user, fn _ -> %User{id: 1} end)

# RIGHT: call the real function with real (factory) data
user = insert(:user)
assert {:ok, _} = MyApp.Tasks.create_task(user, valid_attrs)
```

Mocking contexts means tests pass when your own code is broken. Mimic is for external boundaries — HTTP, payments, email, Oban, PubSub, file I/O — not for code you wrote.

### ❌ Don't drive user actions through context calls in feature tests

```elixir
# WRONG: skipping the UI for the action under test
test "user posts a comment", %{conn: conn} do
  user = insert(:user)
  post = insert(:post)
  {:ok, _comment} = Comments.create_comment(user, post, %{body: "Hello"})

  conn |> visit(~p"/posts/#{post}") |> assert_has(".comment", text: "Hello")
end

# RIGHT: drive the action through the rendered form
test "user posts a comment", %{conn: conn} do
  user = insert(:user)
  post = insert(:post)

  conn
  |> log_in_user(user)
  |> visit(~p"/posts/#{post}")
  |> fill_in("Comment", with: "Hello")
  |> click_button("Post")
  |> assert_has(".comment", text: "Hello")
end
```

Setting up *preconditions* (the user, the post) via factories is fine — those aren't user actions. The *action under test* is "user posts a comment," and that has to go through the form, or the test isn't testing what its name claims.

### ❌ Don't use Faker for values you'll assert on

```elixir
# WRONG: the failure message won't tell you what the value was
name = Faker.Person.name()
{:ok, user} = Accounts.create_user(%{name: name})
assert user.name == name

# RIGHT: stable, readable
{:ok, user} = Accounts.create_user(%{name: "Ada Lovelace"})
assert user.name == "Ada Lovelace"
```

Faker is for values that don't matter. Asserted values matter.

### ❌ Don't reach into LiveView internals from phoenix_test

If you find yourself wanting `:sys.get_state` or `assigns` access inside a `phoenix_test` file, stop and switch that one test to `Phoenix.LiveViewTest` deliberately. Don't smuggle one library's helpers into the other — a reader can't tell which contract a mixed test is honoring, and the layering rule that motivates `phoenix_test` quietly erodes.

### ❌ Don't write tests that pass regardless of implementation

```elixir
# WRONG: Test always passes
test "does something" do
  result = MyModule.do_thing()
  assert result  # What if result is {:error, ...}? Still truthy!
end

# RIGHT: Assert specific expectations
test "returns ok tuple with user" do
  assert {:ok, %User{email: "test@example.com"}} = MyModule.do_thing()
end
```

## Pre-Implementation Checklist

Before writing ANY code, ask yourself:

1. ☐ Have I written a failing test?
2. ☐ Does the test describe the behavior I want?
3. ☐ Have I run the test and confirmed it fails?
4. ☐ Does it fail for the RIGHT reason?

Only after checking all boxes: write the implementation.

## Test Organization

```elixir
defmodule MyApp.TasksTest do
  use MyApp.DataCase

  alias MyApp.Tasks
  alias MyApp.Tasks.Task

  import MyApp.AccountsFixtures
  import MyApp.TasksFixtures

  describe "create_task/1" do
    test "with valid attrs creates task" do
      # ...
    end

    test "with invalid attrs returns error changeset" do
      # ...
    end

    test "with empty title returns error" do
      # ...
    end
  end

  describe "update_task/2" do
    setup do
      task = task_fixture()
      %{task: task}
    end

    test "with valid attrs updates the task", %{task: task} do
      # ...
    end
  end

  describe "delete_task/1" do
    # ...
  end
end
```

## Mocking External Boundaries with Mimic

Use [Mimic](https://github.com/edgurgel/mimic) to stub modules at the external boundary — HTTP, payments, email, SMS, storage, analytics, Oban, PubSub, file I/O. Mimic copies the real module so you can replace functions on it in tests; there's no behaviour to define upfront, which is the main reason to prefer it over Mox for new code.

### Setup

```elixir
# test/test_helper.exs
Mimic.copy(MyApp.Stripe)
Mimic.copy(MyApp.Mailer)
Mimic.copy(File)
ExUnit.start()
```

Note: Mimic stubs are global by default and will leak across parallel tests. Put `setup :set_mimic_private` in any test module that uses `async: true`.

### Three operations, three intents

Pick the operation that matches what the test is actually saying.

| Operation | Means |
|---|---|
| `stub/3` | "Whatever happens, return this." No assertion that the call happened. Use for incidental dependencies the test needs to step past. |
| `expect/3` | "This must be called, with these args, this many times." Use when the test's purpose *is* "this thing got called correctly." |
| `reject/1` | "This must NOT be called." Use when not calling something is the point (e.g., short-circuit logic, idempotency). |

Don't reach for `expect` when you mean `stub` — failed expectation messages get noisy when every dependency carries a "must be called" demand, and the signal gets lost.

### Example

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

### Mox (legacy)

Older codebases use Mox with explicit behaviours and `Mox.defmock`. That pattern still works — leave existing Mox tests in place — but reach for Mimic for new code. It doesn't require a behaviour, and it works against modules you don't own (third-party libraries, `File`, etc.) where defining a behaviour would be awkward or impossible.

## Property-Based Testing with StreamData

Test properties that hold for all inputs, not just specific examples:

```elixir
use ExUnitProperties

# ✅ Good: Test a property that always holds
property "User.full_name/1 always returns a string" do
  check all first <- string(:alphanumeric, min_length: 1),
            last <- string(:alphanumeric, min_length: 1) do
    user = %User{first_name: first, last_name: last}
    result = User.full_name(user)
    assert is_binary(result)
    assert String.contains?(result, first)
    assert String.contains?(result, last)
  end
end

# ✅ Good: Roundtrip property
property "encoding then decoding returns the original" do
  check all data <- map_of(string(:alphanumeric), integer()) do
    assert data == data |> MyApp.Encoder.encode() |> MyApp.Encoder.decode()
  end
end

# ✅ Good: Invariant property
property "sorting is idempotent" do
  check all list <- list_of(integer()) do
    sorted = Enum.sort(list)
    assert sorted == Enum.sort(sorted)
  end
end

# ✅ Good: Custom generators for domain types
property "valid emails are accepted, invalid rejected" do
  valid_email = gen all name <- string(:alphanumeric, min_length: 1),
                        domain <- string(:alphanumeric, min_length: 1) do
    "#{name}@#{domain}.com"
  end

  check all email <- valid_email do
    assert {:ok, _} = Accounts.validate_email(email)
  end
end
```

## Running Tests

```bash
# Run all tests
mix test

# Run specific file
mix test test/my_app/tasks_test.exs

# Run specific test by line number
mix test test/my_app/tasks_test.exs:42

# Run with coverage
mix test --cover

# Run failed tests only
mix test --failed

# Run tests matching a pattern
mix test --only integration
```
