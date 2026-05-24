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
          import { LavashOptimistic, SyncedVar, OverlayAnimator } from "/assets/lavash/index.js";

          // Lavash's colocated hooks register on window.Lavash.
          window.Lavash = window.Lavash || {};
          window.Lavash.SyncedVar = SyncedVar;
          window.Lavash.OverlayAnimator = OverlayAnimator;
          window.Lavash.optimistic = window.Lavash.optimistic || {};

          const meta = document.querySelector("meta[name=csrf-token]");
          const token = meta && meta.getAttribute("content");

          const liveSocket = new LiveSocket("/live", Socket, {
            params: { _csrf_token: token },
            hooks: { LavashOptimistic }
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
