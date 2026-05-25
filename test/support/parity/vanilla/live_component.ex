defmodule Lavash.Parity.Vanilla.CounterComponent do
  @moduledoc """
  Vanilla `Phoenix.LiveComponent` reference for the
  live-component parity suite.

  Has its own state (`:count`), receives a `:label` prop from
  the parent, handles its own `phx-click` events targeted to
  `@myself`, and renders independently.
  """
  use Phoenix.LiveComponent

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :count, 0)}
  end

  @impl true
  def update(assigns, socket) do
    # The parent re-rendering with new :label passes through
    # update/2 each time. Component-local state (:count) is
    # preserved across updates unless we explicitly reset.
    {:ok, assign(socket, label: assigns.label, id: assigns.id)}
  end

  @impl true
  def handle_event("inc", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply, assign(socket, :count, 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="counter-component">
      <p class="label">{@label}</p>
      <p class="count">{@count}</p>
      <button phx-click="inc" phx-target={@myself}>+1</button>
      <button phx-click="reset" phx-target={@myself}>reset</button>
    </div>
    """
  end
end

defmodule Lavash.Parity.Vanilla.LiveComponentLive do
  @moduledoc """
  Host LiveView that mounts two `CounterComponent` instances
  with different labels. Independence between instances and
  `phx-target` routing are verified by the parity tests.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :parent_label_a, "A")}
  end

  @impl true
  def handle_event("toggle_label_a", _params, socket) do
    new = if socket.assigns.parent_label_a == "A", do: "A!", else: "A"
    {:noreply, assign(socket, :parent_label_a, new)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="live-component-vanilla">
      <button id="toggle-label-a" phx-click="toggle_label_a">toggle A label</button>

      <.live_component
        module={Lavash.Parity.Vanilla.CounterComponent}
        id="comp-a"
        label={@parent_label_a}
      />

      <.live_component
        module={Lavash.Parity.Vanilla.CounterComponent}
        id="comp-b"
        label="B"
      />
    </div>
    """
  end
end
