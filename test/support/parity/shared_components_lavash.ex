defmodule Lavash.Parity.SharedComponentsLavash do
  @moduledoc """
  Lavash DSL expression of the shared function-component module.
  Paired with `Lavash.Parity.SharedComponents` (vanilla).

  Both compile to the same Phoenix function components — same
  `button/1`, `badge/1`, `tree_node/1` signatures, same attr
  schemas, same render output. The only difference is the
  declaration shape: vanilla uses positional `attr ... slot ...
  def`, lavash uses the block form.
  """
  use Lavash.LiveView
  # See issue #20: Phoenix.Component's @on_definition hook
  # doesn't reach modules using lavash through Spark's eval.
  # The `components do component ...` block generates calls to
  # `attr` and `slot` which depend on that hook being installed.
  use Phoenix.Component

  components do
    component :button do
      prop :rest, :global, include: ~w(disabled type)
      prop :class, :string, default: nil
      prop :variant, :atom, values: [:primary, :secondary, :danger], default: :primary
      slot :inner_block, required: true

      render fn assigns ->
        ~H"""
        <button class={["btn", "btn-#{@variant}", @class]} {@rest}>
          {render_slot(@inner_block)}
        </button>
        """
      end
    end

    component :badge do
      prop :label, :string, required: true
      prop :count, :integer, default: 0
      prop :tone, :atom, values: [:info, :warn, :danger], default: :info

      render fn assigns ->
        ~H"""
        <span class={"badge badge-#{@tone}"}>
          <span class="badge-label">{@label}</span>
          <span :if={@count > 0} class="badge-count">{@count}</span>
        </span>
        """
      end
    end

    component :tree_node do
      prop :node, :map, required: true

      render fn assigns ->
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
  end

  # The components module needs to satisfy LiveView's mount/render
  # callbacks even though it's primarily a component library. We
  # use a stub template that's never rendered (the module isn't
  # routed).
  template do
    ~H"<div>component library — not routed</div>"
  end
end
