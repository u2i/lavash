defmodule Lavash.Parity.Lavash.HandleParamsLive do
  @moduledoc """
  Lavash DSL expression of the handle_params parity suite —
  paired with `Lavash.Parity.Vanilla.HandleParamsLive`.

  Coverage vs vanilla:

    * `:tab` from URL — `state :tab, from: :url, default: "overview"`. ✓
    * `:page` from URL — `state :page, from: :url, default: 1`. ✓
    * Derived `:title` — `calculate :title, rx(...)`. ✓
    * `push_patch` from an action — `push_patch` op (parity-1 commit). ✓
    * `:hits` side effect bumped on every `handle_params` —
      requires a `handle_params/3` override today. Likely shape
      down the road: a `handle_params do ... end` block that
      runs ops on every URL change.
  """
  use Lavash.LiveView

  state :tab, :string, from: :url, default: "overview", optimistic: true
  state :page, :integer, from: :url, default: 1, optimistic: true
  state :hits, :integer, default: 0, optimistic: true

  calculate :title, rx("Tab: " <> @tab <> " (page " <> Integer.to_string(@page) <> ")"),
    optimistic: false

  actions do
    # In lavash, mutating a `from: :url` state automatically syncs
    # the URL — no explicit push_patch needed. The vanilla side
    # does it manually because vanilla has no concept of URL-bound
    # state. Same observable result: clicking "billing" navigates
    # to ?tab=billing and the page re-renders.
    action :goto_tab, [:tab] do
      set :tab, rx(@tab)
    end

    action :next_page do
      set :page, rx(@page + 1)
    end
  end

  template do
    ~H"""
    <div id="handle-params-lavash">
      <p id="tab">{@tab}</p>
      <p id="page">{@page}</p>
      <p id="title">{@title}</p>
      <p id="hits">{@hits}</p>

      <button id="goto-billing" phx-click="goto_tab" phx-value-tab="billing">billing</button>
      <button id="goto-overview" phx-click="goto_tab" phx-value-tab="overview">overview</button>
      <button id="next-page" phx-click="next_page">next page</button>
    </div>
    """
  end

  # Escape hatch for the hits-counter side effect. Until the DSL
  # grows a `handle_params do ... end` block, chain into the
  # runtime and then bump :hits.
  @impl Phoenix.LiveView
  def handle_params(params, uri, socket) do
    {:noreply, socket} = Lavash.LiveView.Runtime.handle_params(__MODULE__, params, uri, socket)
    {:noreply, Lavash.Socket.put_state(socket, :hits, socket.assigns.hits + 1)}
  end
end
