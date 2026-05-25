defmodule Lavash.Parity.Lavash.RenderSlotsLive do
  @moduledoc """
  Lavash DSL expression of the render+slots parity suite — paired
  with `Lavash.Parity.Vanilla.RenderSlotsLive`.

  Both modules use the same Phoenix.Component primitives (`slot`,
  `attr`, `render_slot/1`) because lavash imports Phoenix.Component
  and the function-component machinery is unchanged. The only
  difference is the surrounding `use Lavash.LiveView` and the
  `state` declaration — neither affects how function components
  with slots work.
  """
  use Lavash.LiveView
  # Lavash's `use Lavash.LiveView` invokes `use Phoenix.LiveView`
  # inside a Spark.Dsl handle_opts eval context, which doesn't
  # install Phoenix.Component's @on_definition hook for `attr` /
  # `slot`. Users who define function components with slots in
  # the same module need to re-`use Phoenix.Component`
  # explicitly. (Tracked as a parity gap; the fix is upstream
  # of lavash — Spark's handle_opts eval model.)
  use Phoenix.Component

  state :name, :string, default: "world", optimistic: true

  template do
    ~H"""
    <div id="render-slots-lavash">
      <.card>
        <:header>Welcome, {@name}</:header>
        Body text inside the implicit inner_block.
        <:footer>cheers</:footer>
      </.card>

      <.list rows={[%{id: 1, label: "alpha"}, %{id: 2, label: "beta"}]}>
        <:row :let={row}>
          <span class="row-label">{row.label}</span>
        </:row>
      </.list>
    </div>
    """
  end

  attr :rest, :global
  slot :header, required: true
  slot :footer
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class="card" {@rest}>
      <header class="card-header">{render_slot(@header)}</header>
      <div class="card-body">{render_slot(@inner_block)}</div>
      <%= if @footer != [] do %>
        <footer class="card-footer">{render_slot(@footer)}</footer>
      <% end %>
    </section>
    """
  end

  attr :rows, :list, required: true
  slot :row, required: true

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={row <- @rows}>{render_slot(@row, row)}</li>
    </ul>
    """
  end
end
