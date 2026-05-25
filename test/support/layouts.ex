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

          // Lavash global namespace + global event listeners (the
          // phx:_lavash_sync handler) are installed as side effects
          // of importing from /assets/lavash/index.js.

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
