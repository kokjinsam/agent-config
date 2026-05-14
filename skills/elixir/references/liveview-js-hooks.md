# LiveView JS hooks

LiveView's diff-and-patch model is incompatible with raw `<script>` tags
in templates — when the surrounding DOM gets patched, the script may or
may not re-run, and there's no clean lifecycle. Hooks are the supported
way to attach JS to elements.

Two flavors:

- **Inline colocated hooks** — written in the same HEEx file as the
  element they attach to. Best for small, element-specific behavior
  (input masks, click handlers, focus management).
- **External hooks** — defined in `assets/js/` and wired into the
  `LiveSocket` constructor. Best for shared logic used across many
  templates, or anything substantial enough to warrant its own file.

Both flavors require:

1. A unique DOM id on the element (`<div id="phone-1" phx-hook="...">`).
   Without an id the compiler errors out.
2. `phx-update="ignore"` *if* the hook manages its own DOM. Without it,
   LiveView's patcher will overwrite the hook's changes whenever the
   parent re-renders.

## Inline colocated hooks

Write the hook as a `<script>` with `:type={Phoenix.LiveView.ColocatedHook}`
right next to the element. The build pipeline picks it up and integrates
it into the `app.js` bundle automatically.

Colocated hook names **must start with a `.`** — that's how LiveView
distinguishes them from external hooks at the `phx-hook=".Name"` site.

    <input
      type="text"
      name="user[phone_number]"
      id="user-phone-number"
      phx-hook=".PhoneNumber"
    />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value
              .replace(/\D/g, "")
              .match(/^(\d{3})(\d{3})(\d{4})$/)
            if (match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

The script tag can sit anywhere in the template — adjacent to the
element, at the top of the file, etc. The colocated hook system handles
extraction during compilation.

## External hooks

Define an object with the LiveView hook lifecycle methods, then pass it
to the `LiveSocket` constructor:

    // assets/js/hooks/my_hook.js
    export const MyHook = {
      mounted() { /* ... */ },
      updated() { /* ... */ },
      destroyed() { /* ... */ }
    }

    // assets/js/app.js
    import { MyHook } from "./hooks/my_hook"

    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    })

In templates, refer to the hook by name (no leading dot for external
hooks):

    <div id="my-hook" phx-hook="MyHook" phx-update="ignore">
      ...
    </div>

## Pushing events: server → client

`push_event/3` queues an event for the client to receive. Always
re-bind/return the socket — `push_event` returns a new socket, and
ignoring it loses the queued event.

    socket = push_event(socket, "scroll_to_bottom", %{id: "messages"})
    # or:
    {:noreply, push_event(socket, "scroll_to_bottom", %{id: "messages"})}

On the client side, hooks handle events with `this.handleEvent`:

    mounted() {
      this.handleEvent("scroll_to_bottom", ({ id }) => {
        document.getElementById(id).scrollTo(0, 1e9)
      })
    }

## Pushing events: client → server (with reply)

Hooks call `this.pushEvent` and can receive a server reply:

    mounted() {
      this.el.addEventListener("click", () => {
        this.pushEvent("ping", { ts: Date.now() }, reply => {
          console.log("server replied:", reply)
        })
      })
    }

On the server, return a `:reply` tuple from `handle_event/3`:

    def handle_event("ping", %{"ts" => ts}, socket) do
      {:reply, %{pong: ts}, socket}
    end

If no reply is needed, return the usual `{:noreply, socket}` and omit
the reply callback on the client.
