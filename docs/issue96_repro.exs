# Standalone repro: a stream delete pushed shortly after join is
# sometimes not applied by the LiveView JS client — the deleted row
# survives in the DOM even though the diff was delivered.
#
# Single-file, per the phoenix_live_view issue template.
#
#   - A PubSub broadcast triggers stream_delete_by_dom_id. It is timed
#     from the DEAD render (`?delay=N` ms after the initial HTTP GET),
#     so sweeping N walks the delete across the websocket join
#     handshake — before / during / after — where the loss lives.
#     Pass a unique `?t=` token per trial to keep topics isolated.
#   - The page self-judges with DELIVERY AWARENESS: a wire capture
#     installed before connect counts incoming "diff" frames, so the
#     verdicts distinguish:
#         PASS   — delete diff arrived, row removed (correct)
#         FAIL   — delete diff ARRIVED, row still in the DOM  <== BUG
#         NODIFF — broadcast fired before the LV subscribed (too
#                  early; artifact of the sweep, not the bug)
#   - `?reload=1` additionally recreates the reload+rejoin recipe: the
#     first load reloads itself shortly after joining and only the
#     second load judges.
#   - Each page load reports its verdict back through the LiveView,
#     so the server prints one line per trial:  VERDICT delay=30 FAIL
#
# Run:    elixir issue96_repro.exs
# Drive:  load http://localhost:4919/?delay=150&t=abc123 repeatedly
#         (each load is a fresh join; vary delay, unique t each time).
#         Headless works too — verdicts are logged server-side, no DOM
#         inspection needed:
#
#   for i in $(seq 1 50); do
#     "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
#       --headless=new --disable-gpu --user-data-dir="$(mktemp -d)" \
#       "http://localhost:4919/?delay=$((RANDOM % 600))&t=$i" \
#       >/dev/null 2>&1 & CPID=$!
#     sleep 8; kill $CPID 2>/dev/null
#   done

Application.put_env(:sample, Repro.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4919],
  server: true,
  live_view: [signing_salt: "aaaaaaaa"],
  secret_key_base: String.duplicate("a", 64)
)

Mix.install([
  {:bandit, "~> 1.0"},
  {:jason, "~> 1.0"},
  {:phoenix, "~> 1.7"},
  {:phoenix_live_view, "~> 1.2"}
])

defmodule Repro.HomeLive do
  use Phoenix.LiveView, layout: {__MODULE__, :live}

  def mount(params, _session, socket) do
    delay =
      case Integer.parse(params["delay"] || "30") do
        {n, _} -> max(n, 1)
        _ -> 30
      end

    rows = [
      %{id: "doomed", body: "doomed row"},
      %{id: "keeper", body: "keeper row"}
    ]

    # The delete is timed from the DEAD render (the initial HTTP GET),
    # not from connected mount: this lets the broadcast land before,
    # during, or after the websocket join handshake depending on
    # `delay` — the fragile window is around join. A delete anchored to
    # connected mount can only ever arrive after the join is complete,
    # which never reproduces the loss.
    topic = "repro:" <> (params["t"] || "default")

    # SUB/BCAST lines classify NODIFF verdicts: SUB before BCAST means
    # the LiveView WAS subscribed when the broadcast fired, so a diff
    # was pushed — a NODIFF verdict in that ordering is a real loss.
    # BCAST before SUB means the broadcast was simply too early.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Repro.PubSub, topic)
      IO.puts("SUB t=#{params["t"]} at=#{System.system_time(:millisecond)}")
    else
      spawn(fn ->
        Process.sleep(delay)
        Phoenix.PubSub.broadcast(Repro.PubSub, topic, :delete_row)
        IO.puts("BCAST t=#{params["t"]} at=#{System.system_time(:millisecond)}")
      end)
    end

    {:ok,
     socket
     |> assign(:delay, delay)
     |> assign(:t, params["t"])
     |> stream(:items, rows)}
  end

  def handle_info(:delete_row, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :items, "items-doomed")}
  end

  def handle_event("report", %{"verdict" => verdict}, socket) do
    IO.puts("VERDICT t=#{socket.assigns.t} delay=#{socket.assigns.delay} #{verdict}")
    {:noreply, socket}
  end

  def render("live.html", assigns) do
    ~H"""
    <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.14/priv/static/phoenix.min.js">
    </script>
    <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.2.9/priv/static/phoenix_live_view.min.js">
    </script>
    <script>
      // Wire capture BEFORE connect: count every "diff" frame so the
      // page can distinguish arrived-but-unapplied from never-arrived.
      window.__diffs = 0;
      const liveSocket = new window.LiveView.LiveSocket(
        "/live",
        window.Phoenix.Socket,
        {}
      );
      liveSocket.socket.onMessage((m) => {
        if (m && m.event === "diff") window.__diffs++;
      });
      liveSocket.connect();
      window.liveSocket = liveSocket;
    </script>
    {@inner_content}
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <p>delay: {@delay}ms</p>
      <div id="items" phx-update="stream">
        <div :for={{dom_id, row} <- @streams.items} id={dom_id} class="entry">
          <span class="body">{row.body}</span>
        </div>
      </div>
      <button id="report" phx-click="report" phx-value-verdict="?" hidden>report</button>
      <script>
        (function judge() {
          // ?reload=1 recreates the reload+rejoin recipe: the first load
          // reloads itself shortly after joining; only the second load
          // judges. The delete race then happens against a rejoin that
          // is tearing down a previous live session.
          const params = new URLSearchParams(location.search);
          if (params.get("reload") === "1" && !sessionStorage.getItem("__r")) {
            sessionStorage.setItem("__r", "1");
            setTimeout(() => location.reload(), 120 + Math.random() * 150);
            return;
          }

          const report = (verdict) => {
            const btn = document.getElementById("report");
            btn.setAttribute("phx-value-verdict", verdict);
            btn.click();
            document.title = verdict;
          };

          const started = Date.now();
          (function poll() {
            if (window.__diffs > 0) {
              // Diff observed arriving — give the patch a beat, then judge.
              return setTimeout(() => {
                const d = document.getElementById("items-doomed");
                const k = document.getElementById("items-keeper");
                if (!k) report("BROKENPAGE");
                else if (d) report("FAIL");
                else report("PASS");
              }, 300);
            }
            if (Date.now() - started > 4000) {
              const d = document.getElementById("items-doomed");
              const k = document.getElementById("items-keeper");
              if (!k) return report("BROKENPAGE");
              return report(d ? "NODIFF" : "PASS_WITHOUT_OBSERVED_DIFF");
            }
            setTimeout(poll, 50);
          })();
        })();
      </script>
    </div>
    """
  end
end

defmodule Repro.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/" do
    pipe_through(:browser)
    live("/", Repro.HomeLive)
  end
end

defmodule Repro.Endpoint do
  use Phoenix.Endpoint, otp_app: :sample
  socket("/live", Phoenix.LiveView.Socket)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(Repro.Router)
end

{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Repro.PubSub}, Repro.Endpoint],
    strategy: :one_for_one
  )
IO.puts("Repro server on http://localhost:4919 — VERDICT lines follow")
Process.sleep(:infinity)
