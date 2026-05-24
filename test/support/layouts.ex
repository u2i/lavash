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
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script>
          (function() {
            var meta = document.querySelector("meta[name=csrf-token]");
            var token = meta && meta.getAttribute("content");
            var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: { _csrf_token: token }
            });
            liveSocket.connect();
            window.liveSocket = liveSocket;
          })();
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
