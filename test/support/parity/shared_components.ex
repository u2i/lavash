defmodule Lavash.Parity.SharedComponents do
  @moduledoc """
  A plain-Phoenix.Component module shared between vanilla and
  lavash parity fixtures. Demonstrates:

    * pure function components (no `use Phoenix.LiveView`)
    * `attr` with type, default, required, values constraints
    * `attr :rest, :global` for HTML-attr passthrough
    * named slot with attributes
    * a recursive component (a tree renderer)

  Both fixtures `import` this module and call `<.button>` /
  `<.badge>` / `<.tree_node>` from their templates. Parity
  verifies the same rendered output on both sides.
  """
  use Phoenix.Component

  attr :rest, :global, include: ~w(disabled type)
  attr :class, :string, default: nil
  attr :variant, :atom, values: [:primary, :secondary, :danger], default: :primary
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button class={["btn", "btn-#{@variant}", @class]} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, default: 0
  attr :tone, :atom, values: [:info, :warn, :danger], default: :info

  def badge(assigns) do
    ~H"""
    <span class={"badge badge-#{@tone}"}>
      <span class="badge-label">{@label}</span>
      <span :if={@count > 0} class="badge-count">{@count}</span>
    </span>
    """
  end

  # Recursive component: renders a tree node with arbitrarily nested
  # children. Exercises the same-module recursion case — the
  # component refers to itself via `<.tree_node ...>` in its own
  # body.
  attr :node, :map, required: true

  def tree_node(assigns) do
    ~H"""
    <li class="tree-node">
      <span class="node-label">{@node.label}</span>
      <ul :if={Map.get(@node, :children, []) != []} class="children">
        <.tree_node :for={child <- @node.children} node={child} />
      </ul>
    </li>
    """
  end
end
