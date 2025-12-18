defmodule DemoWeb.ProductCard do
  @moduledoc """
  A product card component demonstrating Lavash.Component.

  Features:
  - Props from parent (product data)
  - Socket state (expanded) - survives reconnects
  - Ephemeral state (hovered) - lost on reconnect
  - Derived state (show_details)
  """
  use Lavash.Component

  prop :product, :map, required: true

  state :expanded, :boolean, from: :socket, default: false
  state :hovered, :boolean, from: :ephemeral, default: false

  derive :show_details do
    argument :expanded, state(:expanded)
    argument :hovered, state(:hovered)
    run fn %{expanded: e, hovered: h}, _ -> e or h end
  end

  actions do
    action :toggle_expand do
      update :expanded, &(!&1)
    end

    action :set_hover, [:value] do
      set :hovered, &(&1.params.value == "true")
    end
  end

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "bg-white rounded-lg shadow p-4 transition-all cursor-pointer",
        @expanded && "ring-2 ring-indigo-500",
        @hovered && "shadow-lg"
      ]}
      phx-click="toggle_expand"
      phx-target={@myself}
      phx-mouseenter="set_hover"
      phx-mouseleave="set_hover"
      phx-value-value={if @hovered, do: "false", else: "true"}
    >
      <div class="flex items-start justify-between">
        <h3 class="font-medium text-gray-900">{@product.name}</h3>
        <span class={[
          "text-xs px-2 py-1 rounded-full",
          @product.in_stock && "bg-green-100 text-green-800",
          !@product.in_stock && "bg-red-100 text-red-800"
        ]}>
          {if @product.in_stock, do: "In Stock", else: "Out of Stock"}
        </span>
      </div>

      <p class="text-sm text-gray-500 mt-1">{@product.category}</p>

      <div class="flex items-center justify-between mt-3">
        <span class="text-lg font-bold text-indigo-600">
          ${Decimal.to_string(@product.price)}
        </span>
        <span class="text-sm text-yellow-600">
          {"★" |> String.duplicate(round(Decimal.to_float(@product.rating)))}
        </span>
      </div>
      
    <!-- Expanded details - shown when expanded OR hovered -->
      <div :if={@show_details} class="mt-4 pt-4 border-t border-gray-100">
        <div class="text-xs text-gray-500 space-y-1">
          <p><strong>Rating:</strong> {Decimal.to_string(@product.rating)}/5</p>
          <p><strong>Category:</strong> {@product.category}</p>
          <p class="text-indigo-600">
            {if @expanded, do: "Click to collapse", else: "Click to keep expanded"}
          </p>
        </div>
      </div>
      
    <!-- State indicator -->
      <div class="mt-2 text-xs text-gray-400">
        <span :if={@expanded} class="text-indigo-500">expanded (survives reconnect)</span>
        <span :if={@hovered and not @expanded} class="text-gray-400">hovered (ephemeral)</span>
      </div>
    </div>
    """
  end
end
