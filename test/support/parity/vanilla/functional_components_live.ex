defmodule Lavash.Parity.Vanilla.FunctionalComponentsLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the cross-module
  functional-components parity suite. Imports
  `Lavash.Parity.SharedComponents` and exercises:

    * a button with a typed attr (`variant`)
    * a button with `:rest` global attr passthrough
    * a badge with conditional inner content
    * a recursive tree_node renderer

  Both vanilla and lavash sides import the SAME function
  components for their respective sides — the lavash side imports
  `Lavash.Parity.SharedComponentsLavash` (built via the
  `components do component ...` block) which compiles to the
  same Phoenix function components as the vanilla side.
  """
  use Phoenix.LiveView
  import Lavash.Parity.SharedComponents

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="functional-components-vanilla">
      <.button id="b1" variant={:primary}>Click me</.button>
      <.button id="b2" variant={:danger} class="big" disabled>Delete</.button>

      <.badge label="messages" count={3} tone={:info} />
      <.badge label="empty" count={0} />

      <ul id="tree">
        <.tree_node node={
          %{
            label: "root",
            children: [
              %{label: "a", children: []},
              %{label: "b", children: [%{label: "b1", children: []}]}
            ]
          }
        } />
      </ul>
    </div>
    """
  end
end
