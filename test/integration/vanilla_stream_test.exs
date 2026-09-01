defmodule Lavash.Integration.VanillaStreamTest do
  @moduledoc """
  #96 attribution: the reload+rejoin → delete-only-diff recipe against
  a PLAIN Phoenix.LiveView (no lavash anywhere on the page). If the
  row survives here too, the bug is upstream in the LiveView client's
  stream-delete application; if it never fails here, the interference
  is lavash's.
  """
  use Lavash.IntegrationCase, async: false

  alias Lavash.Test.Magic.StreamList.Entry

  setup do
    Ash.DataLayer.Ets.stop(Entry)
    :ok
  end

  defp seed_one!(list_id, body), do: seed_one!(list_id, body, _retry? = true)

  # `Ash.DataLayer.Ets.stop/1` (the per-test table wipe) tears the
  # table-owner process down asynchronously; under load the next create
  # can look up the dying owner and insert into a dead table
  # (:table_not_found). One retry lands after the owner registry has
  # caught up.
  defp seed_one!(list_id, body, retry?) do
    Entry
    |> Ash.Changeset.for_create(:create, %{list_id: list_id, body: body})
    |> Ash.create!()
  rescue
    e in Ash.Error.Unknown ->
      if retry? and Exception.message(e) =~ "table_not_found" do
        Process.sleep(50)
        seed_one!(list_id, body, false)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp unique_list, do: "vlist-#{System.unique_integer([:positive])}"

  defp eval(session, script) do
    execute_script(session, "return #{script}", fn value -> send(self(), {:eval, value}) end)

    receive do
      {:eval, value} -> value
    after
      5_000 -> :timeout
    end
  end

  # Intermittent by design — reproduces the upstream loss (#96).
  @tag :issue_96
  test "vanilla LV: delete-only diff applies after reload+rejoin", %{session: session} do
    list = unique_list()
    doomed = seed_one!(list, "doomed row")

    session = visit(session, "/magic/vanilla-stream?list_id=#{list}")
    session = assert_has(session, css("[data-phx-main].phx-connected", wait: 5_000))

    # Reload: fresh dead render + rejoin
    session = visit(session, "/magic/vanilla-stream?list_id=#{list}")
    session = assert_has(session, css("[data-phx-main].phx-connected", wait: 5_000))
    session = assert_has(session, css("#ventries-#{doomed.id} .body", text: "doomed row"))

    # Wire capture: every socket message from here on
    execute_script(session, """
    window.__msgs = [];
    window.liveSocket.socket.onMessage((m) => {
      try { window.__msgs.push(JSON.stringify(m)); } catch (e) {}
    });
    """)

    Phoenix.PubSub.broadcast(Lavash.PubSub, "vanilla_stream:#{list}", {:deleted, doomed.id})

    # Poll for removal; on survival, dump the wire trace as evidence
    survived? =
      Enum.reduce_while(1..20, true, fn _, _ ->
        if Wallabidi.Browser.has?(session, Wallabidi.Query.css("#ventries-#{doomed.id}")) do
          Process.sleep(150)
          {:cont, true}
        else
          {:halt, false}
        end
      end)

    if survived? do
      msgs = eval(session, "JSON.stringify(window.__msgs)")
      dom = eval(session, ~s|document.getElementById("ventries").outerHTML|)

      flunk("""
      #96 REPRODUCED on vanilla LiveView (no lavash): delete-only diff \
      received but row #ventries-#{doomed.id} survived.

      WIRE TRACE:
      #{msgs}

      DOM:
      #{dom}
      """)
    end
  end
end
