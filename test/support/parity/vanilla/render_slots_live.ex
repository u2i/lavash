defmodule Lavash.Parity.Vanilla.RenderSlotsLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the render/slots parity
  suite. Exercises:

    * a function component with a required slot (:header)
    * an optional slot (:footer)
    * a slot with attributes (:row, key: :id, label: :string)
    * the implicit :inner_block

  Shows that lavash's render path supports the same slot
  machinery vanilla does, because both go through
  Phoenix.Component.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :name, "world")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="render-slots-vanilla">
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
