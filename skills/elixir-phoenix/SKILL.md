---
name: elixir-phoenix
description: >
  Phoenix v1.8+ and Elixir conventions, gotchas, and patterns for writing
  code that compiles and behaves correctly. Use this skill whenever the user
  is working on Phoenix or Elixir — writing or editing LiveViews, HEEx
  templates, Ecto schemas, migrations, changesets, forms, contexts, tests,
  or mix tasks. Trigger even on small edits or single-line changes: Phoenix
  has many syntax footguns (HEEx `{...}` vs `<%= %>` interpolation, list
  index access, `if`-rebinding, struct vs map access, form access via
  changeset) where models regress to wrong patterns from training data
  without explicit guardrails. Also trigger on questions about Phoenix
  routing, LiveView streams, LiveView JS hooks, Ecto preloading, form
  handling, and Elixir standard-library use. For architectural decisions
  about context boundaries and DDD-style domain design, defer to the
  `ddd-phoenix` skill. For test-driven development discipline (failing
  test first), defer to the `tdd-elixir` skill — this skill covers the
  mechanical test rules (start_supervised!, no Process.sleep, etc.) but
  not the workflow.
---

# Elixir & Phoenix conventions

This skill targets **Phoenix v1.8+** (the generation with `<Layouts.app>`,
`current_scope`, and colocated JS hooks) and recent Elixir. If you're in a
codebase that predates v1.8, check `mix.exs` and adjust — most rules in the
Elixir/Ecto/HEEx sections still apply, but the layout and authentication
rules in the Phoenix v1.8 section do not.

## Before you touch code

**Detect the project state first.** Greenfield Phoenix work and existing
codebases have different defaults, and getting this wrong is the most
common way to produce out-of-character code.

- **Greenfield (new app, fresh `mix phx.new`):** prefer the generators
  (`mix phx.gen.live`, `mix phx.gen.schema`, `mix phx.gen.auth`). They
  produce idiomatic v1.8 scaffolds that already follow most rules below.
  Don't over-architect — start with what the generator gives you and grow
  from there.
- **Existing codebase:** read 2-3 similar modules before adding new ones.
  Mirror their patterns even when they disagree with these defaults. The
  defaults here are how to write *new* Phoenix code in 2026; an existing
  codebase has its own history, and consistency beats correctness-in-the-
  abstract. If you genuinely think a refactor is warranted, surface it to
  the user before doing it.

## Verify APIs before writing them

Hallucinating Elixir/Phoenix APIs is a top failure mode — modules and
functions get renamed, deprecated, or simply imagined. Before writing code
that calls an API you're not certain about:

- `mix help <task>` for any Mix task whose flags or behavior you're guessing
  at (e.g., `mix help ecto.gen.migration`).
- `mix hex.docs offline <package>` to open the local docs for a dep.
- Search the codebase first — if you're about to write `Repo.something/2`,
  grep for existing usages to confirm the arity and pattern.

When in doubt, read the docs rather than guess. A wrong API call wastes
more time than a 10-second lookup.

## End-of-task gate: `mix precommit`

When you've finished a coherent change set — a feature, fix, or refactor —
run `mix precommit` and address any failures before declaring the task
done. This is a *boundary* gate, not a per-edit tick: don't run it after
every micro-edit, and don't skip it before handing back to the user.
Phoenix's default `precommit` alias runs format, compile (with warnings
as errors), and tests, which catches the bulk of mechanical regressions.

## HTTP requests: use `Req`

Phoenix apps include `:req` (the `Req` library) by default. Use it for
all HTTP requests. Avoid `:httpoison`, `:tesla`, and `:httpc` — they're
either older, lower-level, or duplicate functionality `Req` already
covers cleanly.

# Elixir core gotchas

These are the rules where models most often write code that won't compile
or has subtle runtime issues. The "wrong" half of each pair is shown
deliberately — training data is full of these patterns, and seeing the
contrast immunizes against regression.

## Lists do not support index access

Elixir lists are linked lists, not arrays. `mylist[i]` does not work.

**Wrong (raises at runtime):**

    i = 0
    mylist = ["blue", "green"]
    mylist[i]

**Right — use `Enum.at`, pattern matching, or the `List` module:**

    Enum.at(mylist, 0)

## `if`/`case`/`cond` results must be rebound outside the block

Elixir variables are immutable but rebindable. Rebinding *inside* a block
expression doesn't escape — the outer scope keeps the old value.

**Wrong (the `assign` is thrown away):**

    if connected?(socket) do
      socket = assign(socket, :val, val)
    end

**Right (rebind the result of the expression):**

    socket =
      if connected?(socket) do
        assign(socket, :val, val)
      end

## Structs don't implement the `Access` behaviour

`changeset[:field]` and `user[:email]` do not work on plain structs. Use
direct field access or a higher-level API.

**Wrong:**

    changeset[:field]
    user[:email]

**Right:**

    user.email
    Ecto.Changeset.get_field(changeset, :field)

## Predicate naming: `?` suffix, no `is_` prefix

Reserve `is_thing` names for *guards* (macros that work in guard clauses).
Regular predicate functions end in `?`. So `admin?(user)`, not
`is_admin(user)`.

## `String.to_atom/1` on user input is a memory leak

Atoms are never garbage-collected. Converting arbitrary user input to
atoms lets an attacker fill the atom table. Use `String.to_existing_atom/1`
when you genuinely need an atom from input, and audit carefully.

## Date and time: standard library is enough

`Time`, `Date`, `DateTime`, and `Calendar` cover almost every need. Don't
install `timex` or similar unless asked. The one exception worth knowing:
`date_time_parser` is fine for parsing messy human-entered date strings.

## OTP primitives need names

`DynamicSupervisor`, `Registry`, and similar require a `:name` in their
child spec so you can address them later:

    children = [{DynamicSupervisor, name: MyApp.Sup, strategy: :one_for_one}]
    # then:
    DynamicSupervisor.start_child(MyApp.Sup, child_spec)

## Concurrent enumeration: `Task.async_stream` with `timeout: :infinity`

For back-pressured concurrent work over a collection,
`Task.async_stream(collection, fun, timeout: :infinity)` is almost always
what you want. The default 5s timeout bites at the wrong moments; pass
`:infinity` and let the inner work decide.

## Don't nest modules in one file

Defining `defmodule A.Inner do` inside `defmodule A do` in the same file
causes cyclic-dependency compilation errors. Put each module in its own
file.

# Mix

- `mix help <task>` before running any task you're guessing at.
- Test a specific file: `mix test test/my_test.exs`. Re-run last failures:
  `mix test --failed`.
- `mix deps.clean --all` is almost never needed. Avoid it unless you have
  a specific reason — it forces a full recompile of every dependency.
- `mix ecto.gen.migration migration_name_in_snake_case` to generate
  migrations. The task handles timestamps and conventions correctly.

# Phoenix routing

Router `scope` blocks take an optional alias prefix. **You don't need to
alias modules inside a scope** — the scope does it for you.

    scope "/admin", AppWeb.Admin do
      pipe_through :browser
      live "/users", UserLive, :index   # → AppWeb.Admin.UserLive
    end

If you write `live "/users", AppWeb.Admin.UserLive, :index` inside that
scope, you'll get `AppWeb.Admin.AppWeb.Admin.UserLive` — a duplicate
prefix and a compile error.

The default `:browser` scope in router.ex is already aliased with the
`AppWeb` module, so LiveView routes there can be written as
`live "/weather", WeatherLive` (not `AppWeb.WeatherLive`).

`Phoenix.View` no longer ships with Phoenix. Don't `use` it or reach for
it — HEEx components have replaced it.

# Phoenix v1.8 specifics

These rules apply to projects generated by `mix phx.new` in v1.8+. They
will not compile on older versions.

## Wrap LiveView templates in `<Layouts.app>`

Every LiveView template begins with `<Layouts.app flash={@flash} ...>`
which wraps the inner content. The `MyAppWeb.Layouts` module is aliased
in `my_app_web.ex`, so you don't need to alias it again in each LiveView.

If you see errors about a missing `current_scope` assign, the cause is
almost always one of:

- The route is in the wrong `live_session` (authentication boundaries
  matter — generated apps put authenticated routes in one session,
  public routes in another), or
- `current_scope` isn't being passed to `<Layouts.app>` in the template.

Fix by moving the route to the correct `live_session` and ensuring
`<Layouts.app current_scope={@current_scope} ...>` is set.

## `<.flash_group>` lives in Layouts only

v1.8 moved `<.flash_group>` to the `Layouts` module. Calling it from
outside `layouts.ex` will fail. If you want flashes somewhere, they
should already be rendered inside `<Layouts.app>`.

## Use the bundled `<.icon>` and `<.input>` components

`core_components.ex` ships an `<.icon name="hero-x-mark" class="w-5 h-5" />`
that resolves hero icons through Tailwind. Use it rather than reaching
for `Heroicons` modules or inlining SVGs.

Same for `<.input>`: it's imported, it handles labels/errors/types, and
using it saves you reimplementing form-field plumbing. If you override
`class` on `<.input>`, your classes *replace* the defaults — they don't
merge. So your custom class string needs to fully style the input.

# Ecto

## Preload associations you'll touch in templates

If a template will access `message.user.email`, the query that fetches the
message must preload `:user`. The alternative is an N+1 query at render
time or a `KeyError` from a `nil` association. `Repo.preload/2` after the
fact works, but preloading in the query is cleaner.

## `Ecto.Schema` field type for `:text` columns is `:string`

The DB-level column type is `:text`, but the schema type is `:string`:

    field :body, :string  # for a column declared as :text in the migration

There is no `:text` field type in `Ecto.Schema`.

## `validate_number/2` has no `:allow_nil` option

Ecto's validations only run when a change exists for the field and the
new value is non-nil, so an explicit `:allow_nil` is unnecessary (and
will raise — the option doesn't exist).

## Access changeset fields via `get_field/2`

`changeset[:field]` doesn't work (changesets are structs, see the Access
note above). Use `Ecto.Changeset.get_field(changeset, :field)`.

## Don't `cast` programmatic fields

Fields set by your code, not the user — `user_id`, `tenant_id`,
`created_by` — must not appear in `cast/3` calls. If they do, an attacker
can override them by submitting them in form params. Set them explicitly
when constructing the struct, before piping into `change/2`:

    %Message{user_id: current_user.id}
    |> Message.changeset(params)

## `seeds.exs` needs explicit imports

`seeds.exs` runs as a script and doesn't inherit module imports. Add
`import Ecto.Query` and aliases at the top if you use them.

# Phoenix HTML / HEEx

Phoenix templates use **HEEx** — `~H` sigils or `.html.heex` files. The
older `~E` sigil is gone.

## Building forms

Use `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1`, not
the older `Phoenix.HTML.form_for`. Build the form value in the LiveView
with `to_form/2` and access fields via `@form[:field]`:

**In the LiveView:**

    socket = assign(socket, form: to_form(changeset))

**In the template:**

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:title]} type="text" label="Title" />
    </.form>

Give every form an explicit, unique DOM id (`id="todo-form"`) so tests
can target it.

**Never pass a changeset directly to `<.form for=...>`.** It will produce
errors that look unrelated to the real cause:

**Wrong:**

    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:title]} type="text" />
    </.form>

**Right:**

    <.form for={@form} id="my-form">
      <.input field={@form[:title]} type="text" />
    </.form>

Avoid the older `<.form let={f} ...>` style — drive everything from the
`@form` assign.

For deeper form patterns (`to_form` from params vs changesets, naming
nested params, error display), see `references/forms.md`.

## Elixir has no `else if`

HEEx inherits Elixir control flow. There is no `else if` / `elsif`. For
multiple branches use `cond` or `case`.

**Wrong (syntax error):**

    <%= if condition do %>
      ...
    <% else if other_condition %>
      ...
    <% end %>

**Right:**

    <%= cond do %>
      <% condition1 -> %>
        ...
      <% condition2 -> %>
        ...
      <% true -> %>
        ...
    <% end %>

## Interpolation: `{...}` in attributes, `<%= %>` in bodies for blocks

HEEx has two interpolation styles and they're not interchangeable:

- `{...}` works in **attribute values** and for **simple value interpolation
  in tag bodies**.
- `<%= ... %>` works only **inside tag bodies**, and is required for
  **block constructs** (`if`, `cond`, `case`, `for`).

**Right:**

    <div id={@id}>
      {@title}
      <%= if @show_footer do %>
        {@footer}
      <% end %>
    </div>

**Wrong (parser error):**

    <div id="<%= @id %>">           <%!-- can't use <%= %> in attrs --%>
      {if @show_footer do}          <%!-- can't use { } for block constructs --%>
        {@footer}
      {end}
    </div>

## Class lists: always `[...]` syntax when conditional

HEEx accepts a list of class fragments and concatenates them. Use the list
form whenever you have more than one class string or any conditional:

**Right:**

    <a class={[
      "px-2 text-white",
      @active && "py-5",
      if(@error, do: "border-red-500", else: "border-blue-100")
    ]}>Text</a>

Wrap `if` expressions in parens inside `{...}` (`if(@cond, do: "...", else: "...")`).

**Wrong (compile error — missing `[` `]`):**

    <a class={
      "px-2 text-white",
      @active && "py-5"
    }>

## Showing literal `{` and `}` in templates

HEEx treats `{...}` as interpolation. To render literal curly braces (in a
`<code>` or `<pre>` block, for example), annotate the parent tag with
`phx-no-curly-interpolation`:

    <code phx-no-curly-interpolation>
      let obj = {key: "val"}
    </code>

Inside that tag, `{` and `}` are literal, but `<%= ... %>` interpolation
still works if you need dynamic content.

## Iteration: `<%= for ... do %>`, never `Enum.each` in templates

Use comprehensions for generating template content, not `Enum.each`
(which returns `:ok` and produces no output):

    <%= for item <- @items do %>
      <li>{item.name}</li>
    <% end %>

## HEEx comments use `<%!-- ... --%>`

Not `<!-- ... -->` (which is preserved in output) and not `<%# ... %>`
(EEx syntax, doesn't work cleanly in HEEx). Use `<%!-- ... --%>` for
template comments.

# Phoenix LiveView

## Naming & routes

LiveView modules are named `AppWeb.WeatherLive` with a `Live` suffix. The
default `:browser` scope is already aliased to `AppWeb`, so register them
as `live "/weather", WeatherLive`.

Use `<.link navigate={href}>` for full LiveView navigation and
`<.link patch={href}>` for in-place patches. The old `live_redirect` and
`live_patch` functions are deprecated.

On the server side, the equivalents are `push_navigate/2` and
`push_patch/2`.

## Avoid LiveComponents unless you have a real need

LiveComponents add a separate state machine, lifecycle, and message
routing. Most of what they're used for can be done with function
components plus assigns. Reach for a LiveComponent only when you have a
specific reason (isolating expensive state, encapsulating a sub-tree that
many parents share). Otherwise prefer plain `Phoenix.Component` functions.

## Streams for collections

Assigning large lists directly to socket state balloons memory — the
LiveView server holds every assigned value indefinitely. Use **streams**
for any collection that grows over time (messages, tasks, comments,
records). Streams are required reading; see
`references/liveview-streams.md` for the full pattern: stream setup,
template structure, filtering via `reset: true`, deletion, mutations,
empty states, and re-streaming on assign change.

## JS hooks (colocated and external)

Two flavors:

- **Inline colocated** — written next to the element in HEEx using
  `:type={Phoenix.LiveView.ColocatedHook}`. The hook name starts with a
  `.` (e.g. `phx-hook=".PhoneNumber"`). Auto-integrates into `app.js`.
- **External** — defined in `assets/js/` and passed to the `LiveSocket`
  constructor in `hooks: {...}`.

`phx-hook` always requires a unique DOM id on the element, or the
compiler will reject it. If the hook manages its own DOM, also set
`phx-update="ignore"` to prevent LiveView from clobbering it.

For the full patterns (colocated examples, push_event server→client,
pushEvent client→server with replies), see
`references/liveview-js-hooks.md`.

## Never write raw `<script>` tags in HEEx

Raw `<script>custom js</script>` tags inside HEEx are incompatible with
LiveView's DOM patching and will misbehave. Use colocated hooks
(`:type={Phoenix.LiveView.ColocatedHook}`) for inline scripts attached to
elements, or external hooks for shared logic.

## LiveView tests

The mechanics:

- Use `Phoenix.LiveViewTest` + `LazyHTML` for assertions.
- Drive forms with `render_change/2` and `render_submit/2`.
- Always reference the DOM ids you put on elements (`element/2`,
  `has_element/2`) — selectors against raw HTML are brittle.
- Test for the presence of key elements, not exact text content (text
  changes more often than structure).
- When a selector isn't matching, dump the rendered HTML with
  `LazyHTML.filter/2` to see what's actually there:

      html = render(view)
      doc = LazyHTML.from_fragment(html)
      LazyHTML.filter(doc, "your-selector") |> IO.inspect(label: "matches")

For *workflow* discipline (failing test first, red-green-refactor), see
the `tdd-elixir` skill.

# Test mechanics (general)

These apply to all Elixir test code, not just LiveView.

## Use `start_supervised!/1` for processes in tests

ExUnit registers the supervised process for automatic teardown between
tests. Manual `start_link` leaves processes alive across tests and causes
cross-test pollution that's painful to debug.

    {:ok, pid} = start_supervised!({MyServer, []})

## Don't `Process.sleep` to synchronize

Sleeping is a flaky-test factory. The two patterns that replace it:

- Waiting for a process to exit — monitor it and assert on `:DOWN`:

      ref = Process.monitor(pid)
      # ... trigger the thing that should kill pid ...
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

- Waiting for prior messages to be processed before the next assertion —
  call `:sys.get_state/1` on the process. The call is synchronous and
  serializes after any pending messages in the mailbox:

      _ = :sys.get_state(MyServer)

# JS & CSS

## Tailwind CSS v4

v4 dropped `tailwind.config.js`. Configuration lives in `app.css`:

    @import "tailwindcss" source(none);
    @source "../css";
    @source "../js";
    @source "../../lib/my_app_web";

Keep this import block intact. Don't try to reintroduce a config file.

Avoid `@apply` when writing raw CSS — it's largely deprecated philosophy
in v4 and the project prefers utility classes (or hand-written CSS rules
where utilities don't fit).

Don't pull in DaisyUI or other component libraries; the project prefers
hand-built Tailwind components for visual distinctness.

## Only `app.js` and `app.css` are bundled

You can't reference an external vendor script `src` or stylesheet `href`
in layouts. Import vendor dependencies into `app.js` and `app.css` so
they're bundled.

# UI/UX

When building UI:

- Produce polished, modern interfaces. Pay attention to typography,
  spacing, and layout balance — Phoenix apps are sometimes underdressed,
  but there's no reason for that.
- Add subtle micro-interactions: hover effects, focus transitions, loading
  states. Use Tailwind's `transition-*` utilities.
- Sweat the details that make UI feel premium: empty states, error
  states, loading skeletons, and smooth state transitions.

# Cross-references

- **Architectural decisions about Phoenix contexts** (where a schema
  belongs, naming, bounded contexts, coordinating between contexts) →
  `ddd-phoenix` skill.
- **Test-driven workflow** (failing test first, what to test, how to
  decompose) → `tdd-elixir` skill. This skill only covers the *mechanical*
  test rules above.

# Deep references

Load these when working on the specific topic:

- `references/liveview-streams.md` — stream setup, template structure,
  filtering with `reset: true`, deletion, mutation patterns, empty
  states, re-streaming when an assign changes the rendered item.
- `references/liveview-js-hooks.md` — colocated and external hooks in
  depth, `push_event` server→client, `pushEvent` client→server with
  server replies.
- `references/forms.md` — `to_form/2` from raw params vs changesets,
  named params (`as: :user`), error display, and the common pitfalls
  around form assigns.
