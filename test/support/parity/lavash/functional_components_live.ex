defmodule Lavash.Parity.Lavash.FunctionalComponentsLive do
  @moduledoc """
  Lavash side of the cross-module functional-components parity
  suite. Imports `Lavash.Parity.SharedComponentsLavash` (which
  defined its components via `components do component ... end end`)
  and renders the same surface as the vanilla side.

  Identical rendered output between the two confirms that
  lavash's block-structured component DSL compiles to
  Phoenix-equivalent function components.
  """
  use Lavash.LiveView
  # Spark-built modules export many auto-generated helpers
  # (persisted/0, spark_is/0, ...) that would collide on
  # wholesale import — restrict to the component functions.
  import Lavash.Parity.SharedComponentsLavash, only: [button: 1, badge: 1, tree_node: 1]

  template do
    ~H"""
    <div id="functional-components-lavash">
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
