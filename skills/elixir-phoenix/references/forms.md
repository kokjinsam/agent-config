# Phoenix forms

Phoenix v1.8 forms are built around `Phoenix.Component.form/1`, the
`<.input>` component, and a `@form` assign produced by `to_form/2`. Get
those three right and most form bugs disappear.

The rule that prevents the most pain: **always pass `@form` (a form
struct) to `<.form for=...>`, never a changeset.** Passing a changeset
"works" superficially but breaks error display, nested forms, and
validation flow in confusing ways.

## Creating a form from raw params

When you have a `handle_event` callback with submitted params and just
need a form to re-render with those values (e.g., after a validation
round-trip), wrap them with `to_form/1`:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

`to_form/1` over a plain map assumes the map *is* the form params and
expects **string keys** (as they arrive from the wire).

Nest the params under a name with `:as`:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

After this, the form's fields appear in template assigns as
`@form[:email]`, `@form[:name]`, etc.

## Creating a form from a changeset

When backed by an Ecto schema, build a changeset and pass it to
`to_form/1`. The form name is derived automatically from the schema
module (so a `MyApp.Users.User` changeset produces params under
`%{"user" => ...}` on submit).

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

In the LiveView:

    socket = assign(socket, form: to_form(changeset))

In the template:

    <.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:email]} type="email" label="Email" />
      <.input field={@form[:name]} type="text" label="Name" />
      <button>Save</button>
    </.form>

The two event handlers usually look like:

    def handle_event("validate", %{"user" => user_params}, socket) do
      changeset =
        %User{}
        |> User.changeset(user_params)
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, form: to_form(changeset))}
    end

    def handle_event("save", %{"user" => user_params}, socket) do
      case Users.create_user(user_params) do
        {:ok, user} ->
          {:noreply, socket |> put_flash(:info, "Saved") |> push_navigate(to: ~p"/users/#{user}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end

`Map.put(:action, :validate)` on the validation changeset is how you get
errors to render during the first `phx-change` round-trip. Without it,
the changeset is "unsubmitted" and errors are suppressed.

## DOM ids

Give every form an explicit, unique `id` (`id="user-form"`). It's needed
for:

- `Phoenix.LiveViewTest.element/2` selectors in tests.
- LiveView's own diff tracking — multiple forms on a page with no ids
  can collide.
- CSS/JS hooks that target the form.

## What to avoid

**Passing the changeset directly:**

    <%!-- BROKEN --%>
    <.form for={@changeset} id="user-form">
      <.input field={@changeset[:email]} type="email" />
    </.form>

The `@changeset[:email]` access doesn't work (changesets don't implement
`Access`), and `<.form for={@changeset}>` mis-renders error state. Always
go through `@form = to_form(changeset)` and `@form[:email]`.

**Using `<.form let={f} ...>`:**

    <%!-- OLD STYLE --%>
    <.form let={f} for={@form}>
      <%= text_input f, :email %>
    </.form>

This is the pre-component API. Use the new style — drive everything from
`@form[:field]` with `<.input>`:

    <.form for={@form} id="user-form">
      <.input field={@form[:email]} type="email" />
    </.form>

## Overriding `<.input>` styles

`<.input>` comes with default Tailwind classes. If you pass a custom
`class`, your classes **replace** the defaults — they don't merge:

    <.input field={@form[:email]} class="my-custom px-2 py-1 rounded-lg" />

The custom class string must fully style the input (typography, padding,
border, focus state, error state) or you'll get a partially-styled
element. If you want most defaults plus a tweak, the cleanest fix is to
edit `core_components.ex` to change the default class.
