defmodule Lavash.Test.Magic.VanillaStreamLive do
  @moduledoc """
  #96 attribution fixture: a PLAIN Phoenix.LiveView (no lavash DSL,
  no lavash hook, no lavash JS on the page's elements) with a stream
  and a PubSub-triggered targeted `stream_delete_by_dom_id`.

  Mirrors the failing recipe from stream_projection_test's variant A
  (reload + rejoin, then delete-only diff) so the bug can be
  attributed: reproduces here → upstream LiveView client; doesn't →
  lavash interference.
  """
  use Phoenix.LiveView

  alias Lavash.Test.Magic.StreamList.Entry

  def mount(params, _session, socket) do
    list_id = params["list_id"] || "default"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Lavash.PubSub, "vanilla_stream:#{list_id}")
    end

    entries =
      Entry
      |> Ash.Query.for_read(:for_list, %{list_id: list_id})
      |> Ash.read!()

    {:ok,
     socket
     |> assign(:list_id, list_id)
     |> stream(:ventries, entries)}
  end

  def handle_info({:deleted, id}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :ventries, "ventries-#{id}")}
  end

  def handle_info({:written, entry}, socket) do
    {:noreply, stream_insert(socket, :ventries, entry)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div id="ventries" phx-update="stream">
        <div :for={{dom_id, row} <- @streams.ventries} id={dom_id} class="entry">
          <span class="body">{row.body}</span>
        </div>
      </div>
    </div>
    """
  end
end
