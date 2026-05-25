defmodule Lavash.Parity.Vanilla.HandleParamsLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the handle_params/3
  parity suite. Exercises:

    * URL params read at mount AND on every patch
    * `push_patch` triggering handle_params with new params
    * a server-derived assign that depends on a URL param
      (here: page title built from :tab)
    * path params (`:tab` part of the URL pattern)
    * a side effect bound to URL changes (here: a hit counter that
      bumps each time handle_params fires)
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :hits, 0)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = Map.get(params, "tab", "overview")
    page = Map.get(params, "page", "1") |> String.to_integer()

    title = "Tab: " <> tab <> " (page " <> Integer.to_string(page) <> ")"

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:page, page)
     |> assign(:title, title)
     |> update(:hits, &(&1 + 1))}
  end

  @impl true
  def handle_event("goto_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: "/parity/vanilla/handle_params?tab=" <> tab)}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    next = socket.assigns.page + 1

    {:noreply,
     push_patch(socket,
       to:
         "/parity/vanilla/handle_params?tab=" <>
           socket.assigns.tab <> "&page=" <> Integer.to_string(next)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="handle-params-vanilla">
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
end
