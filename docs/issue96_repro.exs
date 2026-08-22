# Standalone repro: a stream delete pushed shortly after join is
# sometimes not applied by the LiveView JS client (the deleted row
# survives in the DOM).
#
# Self-contained: no PubSub, no test harness. The LiveView schedules
# its own stream_delete_by_dom_id via Process.send_after in connected
# mount. The page self-judges with delivery awareness — it counts
# incoming "diff" messages on the socket, so it can distinguish:
#
#   PASS   — delete diff arrived, row removed (correct)
#   FAIL   — delete diff ARRIVED, row still in the DOM  <-- the bug
#   NODIFF — delete diff never arrived within the deadline
#            (delivery/timing artifact, NOT the bug)
#
# The verdict is reported back through the LiveView itself
# (phx-click push), so the server logs one line per page load:
#
#   VERDICT delay=32 FAIL
#
# Run:  elixir issue96_repro.exs
# Drive (any real-time page loader; each load is a fresh join):
#   CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
#   for i in $(seq 1 60); do
#     timeout 5 "$CHROME" --headless=new --disable-gpu \
#       "http://localhost:4919/?delay=$((RANDOM % 80))" >/dev/null 2>&1
#   done
#   # verdicts appear on the server's stdout

Mix.install([{:phoenix_playground, "~> 0.1"}])

defmodule ReproLive do
  use Phoenix.LiveView

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

    if connected?(socket) do
      Process.send_after(self(), :delete_row, delay)
    end

    {:ok,
     socket
     |> assign(:delay, delay)
     |> stream(:items, rows)}
  end

  def handle_info(:delete_row, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :items, "items-doomed")}
  end

  def handle_event("report", %{"verdict" => verdict}, socket) do
    IO.puts("VERDICT delay=#{socket.assigns.delay} #{verdict}")
    {:noreply, socket}
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
        // Delivery-aware self-judge. Counts socket messages so a
        // missing diff (delivery artifact) is distinguished from an
        // arrived-but-unapplied diff (the bug).
        (function judge() {
          if (!window.liveSocket || !window.liveSocket.socket) {
            return setTimeout(judge, 5);
          }
          let diffs = 0;
          window.liveSocket.socket.onMessage((m) => {
            // LV pushes stream deletes as "diff" events on the lv topic
            if (m && m.event === "diff") diffs++;
          });

          const report = (verdict) => {
            const btn = document.getElementById("report");
            btn.setAttribute("phx-value-verdict", verdict);
            btn.click();
          };

          const started = Date.now();
          (function poll() {
            const doomed = document.getElementById("items-doomed");
            const keeper = document.getElementById("items-keeper");
            if (diffs > 0) {
              // Give the patch one extra beat after arrival, then judge.
              return setTimeout(() => {
                const d = document.getElementById("items-doomed");
                const k = document.getElementById("items-keeper");
                if (!k) report("BROKENPAGE");
                else if (d) report("FAIL");
                else report("PASS");
              }, 300);
            }
            if (Date.now() - started > 4000) {
              if (!keeper) return report("BROKENPAGE");
              return report(doomed ? "NODIFF" : "PASS_WITHOUT_DIFF");
            }
            setTimeout(poll, 50);
          })();
        })();
      </script>
    </div>
    """
  end
end

PhoenixPlayground.start(live: ReproLive, port: 4919, open_browser: false)
