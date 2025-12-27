defmodule Lavash.Components.ChipSet do
  @moduledoc """
  A multi-select chip set component with parent state binding.

  This component manages selection state through bindings to the parent's
  Lavash state, enabling the reactive graph to flow through the component.

  ## Usage

      # In parent LiveView:
      state :roast, {:array, :string}, from: :url, default: []

      # In template:
      <.live_component
        module={Lavash.Components.ChipSet}
        id="roast-filter"
        bind={[selected: :roast]}
        values={["light", "medium", "dark"]}
      />

  The component binds its internal `selected` state to the parent's `roast`
  state. When chips are toggled, the parent's state updates and the
  dependency graph recomputes.
  """

  use Lavash.LiveComponent

  # Binding declaration - this gets connected to parent state
  bind :selected, {:array, :string}

  # Props passed from parent
  prop :values, {:list, :string}, required: true
  prop :labels, :map, default: %{}
  prop :chip_class, :keyword_list, default: nil

  @default_chip_class [
    base: "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer",
    active: "bg-primary text-primary-content border-primary",
    inactive: "bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50"
  ]

  def render(assigns) do
    chip_class = assigns[:chip_class] || @default_chip_class
    base = Keyword.get(chip_class, :base, "")
    active = Keyword.get(chip_class, :active, "")
    inactive = Keyword.get(chip_class, :inactive, "")

    assigns =
      assigns
      |> Phoenix.Component.assign(:active_class, String.trim("#{base} #{active}"))
      |> Phoenix.Component.assign(:inactive_class, String.trim("#{base} #{inactive}"))

    # Get the bound parent field name for optimistic updates
    binding_map = assigns[:__lavash_binding_map__] || %{}
    parent_field = Map.get(binding_map, :selected)

    # Always assign all optimistic-related keys (even if nil) for template stability
    assigns =
      assigns
      |> Phoenix.Component.assign(:optimistic_action, if(parent_field, do: "toggle_#{parent_field}"))
      |> Phoenix.Component.assign(:optimistic_derive, if(parent_field, do: "#{parent_field}_chips"))
      |> Phoenix.Component.assign(:optimistic_enabled, parent_field != nil)

    # Generate script tag for optimistic updates if bound
    script_tag =
      if parent_field do
        js = generate_optimistic_js(parent_field, assigns.values, assigns.active_class, assigns.inactive_class)
        id = assigns.id
        Phoenix.HTML.raw(~s[<script id="#{id}-optimistic">#{js}</script>])
      else
        ""
      end

    assigns = Phoenix.Component.assign(assigns, :script_tag, script_tag)

    ~H"""
    <div class="flex flex-wrap gap-2">
      <button
        :for={value <- @values}
        type="button"
        class={if value in (@selected || []), do: @active_class, else: @inactive_class}
        phx-click="toggle"
        phx-value-val={value}
        phx-target={@myself}
        data-optimistic={@optimistic_action}
        data-optimistic-value={if @optimistic_enabled, do: value}
        data-optimistic-class={if @optimistic_enabled, do: "#{@optimistic_derive}.#{value}"}
      >
        {Map.get(@labels || %{}, value, humanize(value))}
      </button>
      {@script_tag}
    </div>
    """
  end

  def handle_event("toggle", %{"val" => val}, socket) do
    # DEBUG: Log every toggle event received
    require Logger
    Logger.warning("[ChipSet] toggle event received: val=#{val}")

    # When bound to parent, send a toggle operation (not the full value).
    # This is critical for rapid clicks: if we sent the full computed value,
    # a second click would use stale assigns and overwrite the first click's change.
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, :selected) do
      nil ->
        # Not bound - update locally
        selected = socket.assigns[:selected] || []

        new_selected =
          if val in selected do
            List.delete(selected, val)
          else
            [val | selected]
          end

        {:noreply, Phoenix.Component.assign(socket, :selected, new_selected)}

      parent_field ->
        # Bound to parent - send toggle operation (not full value)
        send(self(), {:lavash_component_toggle, parent_field, val})
        {:noreply, socket}
    end
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp generate_optimistic_js(field, values, active_class, inactive_class) do
    action_name = "toggle_#{field}"
    derive_name = "#{field}_chips"
    values_json = Jason.encode!(values)

    """
    (function() {
      // Find the parent module from the optimistic wrapper
      const wrapper = document.querySelector('[data-lavash-module]');
      if (!wrapper) return;
      const moduleName = wrapper.dataset.lavashModule;
      if (!moduleName) return;

      // Ensure the module registry exists
      window.Lavash = window.Lavash || {};
      window.Lavash.optimistic = window.Lavash.optimistic || {};
      window.Lavash.optimistic[moduleName] = window.Lavash.optimistic[moduleName] || {};

      const fns = window.Lavash.optimistic[moduleName];

      if (!fns.#{action_name}) {
        fns.#{action_name} = function(state, value) {
          const list = state.#{field} || [];
          const idx = list.indexOf(value);
          if (idx >= 0) {
            return { #{field}: list.filter(v => v !== value) };
          } else {
            return { #{field}: [...list, value] };
          }
        };
      }
      if (!fns.#{derive_name}) {
        fns.#{derive_name} = function(state) {
          const ACTIVE = #{Jason.encode!(active_class)};
          const INACTIVE = #{Jason.encode!(inactive_class)};
          const values = #{values_json};
          const selected = state.#{field} || [];
          const result = {};
          for (const v of values) {
            result[v] = selected.includes(v) ? ACTIVE : INACTIVE;
          }
          return result;
        };
        if (!fns.__derives__) fns.__derives__ = [];
        if (!fns.__derives__.includes("#{derive_name}")) {
          fns.__derives__.push("#{derive_name}");
        }
      }
    })();
    """
  end
end
