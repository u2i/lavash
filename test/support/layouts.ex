defmodule Lavash.TestLayouts do
  use Phoenix.Component

  def root(assigns) do
    assigns = assign_new(assigns, :csrf_token, fn -> Plug.CSRFProtection.get_csrf_token() end)

    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Lavash Test</title>
        <script type="module">
          import { Socket } from "/assets/phoenix/phoenix.mjs";
          import { LiveSocket } from "/assets/phoenix_live_view/phoenix_live_view.esm.js";
          import { lavash, defaultConcerns, getHooks, getState } from "/assets/lavash/index.js";

          // Per-module optimistic functions (transpiled rx() bodies +
          // action delta computers) extracted by Phoenix.LiveView.ColocatedJS
          // at compile time. Each generated module SELF-REGISTERS into
          // window.Lavash.optimistic when imported, so this bare
          // side-effect import of the manifest is all the wiring needed.
          // Without this import, optimistic actions and calc recomputes
          // never fire client-side — the e2e tests would still pass
          // (server reconciliation lands eventually) but they wouldn't
          // be verifying any optimistic behaviour.
          import "/assets/phoenix-colocated/lavash/index.js";

          const meta = document.querySelector("meta[name=csrf-token]");
          const token = meta && meta.getAttribute("content");

          // Build the lavash decorator with all standard concerns.
          // Wrap an empty hook ({}) since lavash's server-side runtime
          // emits <div phx-hook="LavashOptimistic"> — getHooks
          // registers the decorated hook under that name.
          const lavashDecorator = lavash({ concerns: defaultConcerns });

          const liveSocket = new LiveSocket("/live", Socket, {
            params: () => ({ _csrf_token: token, _lavash_state: getState() }),
            hooks: getHooks(lavashDecorator)
          });
          // Wire capture for e2e evidence dumps (#96): registered
          // BEFORE connect so join replies and every diff are recorded
          // with zero test-side timing perturbation.
          window.__msgs = [];
          liveSocket.socket.onMessage((m) => {
            try { window.__msgs.push(JSON.stringify(m)); } catch (e) {}
          });

          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
