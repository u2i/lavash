defmodule Lavash.LiveView.Helpers do
  @moduledoc """
  Helper functions available in Lavash LiveViews.
  """

  use Phoenix.Component

  @doc """
  Stores component states in process dictionary for child components to access.
  Call this at the start of your render function, or use the `lavash_render` wrapper.
  """
  def put_component_states(states) do
    Process.put(:__lavash_component_states__, states)
  end

  @doc """
  Gets component states from process dictionary.
  """
  def get_component_states do
    Process.get(:__lavash_component_states__, %{})
  end

  @doc """
  Builds the optimistic state map from assigns based on DSL metadata.

  Collects all state fields and derives marked with `optimistic: true` and
  extracts their current values from assigns. For async derives, unwraps the
  `{:ok, value}` tuple to get the raw value.

  ## Example

      # In your LiveView module
      state :count, :integer, from: :url, default: 0, optimistic: true
      state :multiplier, :integer, from: :ephemeral, default: 2, optimistic: true

      derive :doubled, optimistic: true do
        # ...
      end

      # In render/1
      def render(assigns) do
        assigns = assign(assigns, :optimistic_state, optimistic_state(__MODULE__, assigns))
        # ...
      end
  """
  def optimistic_state(module, assigns) do
    # Get optimistic state fields
    state_fields = module.__lavash__(:optimistic_fields)

    # Get optimistic derives
    derives = module.__lavash__(:optimistic_derives)

    # Get calculations from the calculate macro
    calculations = get_calculations(module)

    # Get forms - their params are automatically optimistic
    forms = get_forms(module)

    # Build the state map from optimistic fields
    state_map =
      Enum.reduce(state_fields, %{}, fn field, acc ->
        value = Map.get(assigns, field.name)
        Map.put(acc, field.name, value)
      end)

    # Add form params - forms are implicitly optimistic for client-side validation
    state_map =
      Enum.reduce(forms, state_map, fn form, acc ->
        params_field = :"#{form.name}_params"
        value = Map.get(assigns, params_field, %{})
        Map.put(acc, params_field, value)
      end)

    # Add derives, unwrapping async values
    state_map =
      Enum.reduce(derives, state_map, fn derive, acc ->
        value = Map.get(assigns, derive.name)

        # Unwrap async values - handle both AsyncResult structs and plain tuples
        value =
          case value do
            %Phoenix.LiveView.AsyncResult{ok?: true, result: v} -> v
            %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> nil
            %Phoenix.LiveView.AsyncResult{} -> nil
            {:ok, v} -> v
            :loading -> nil
            {:error, _} -> nil
            v -> v
          end

        Map.put(acc, derive.name, value)
      end)

    # Add calculations - compute them from state
    # Handle both legacy 4-tuple and new 7-tuple formats
    # Only include optimistic calculations (optimistic: true)
    Enum.reduce(calculations, state_map, fn calc, acc ->
      {name, _source, ast, _deps, optimistic} =
        case calc do
          {name, source, ast, deps} ->
            {name, source, ast, deps, true}

          {name, source, ast, deps, opt, _async, _reads} ->
            {name, source, ast, deps, opt}
        end

      # Skip non-optimistic calculations
      if not optimistic do
        acc
      else
        try do
          {result, _binding} = Code.eval_quoted(ast, [state: acc], __ENV__)
          Map.put(acc, name, result)
        rescue
          _ -> acc
        end
      end
    end)
  end

  defp get_calculations(module) do
    if function_exported?(module, :__lavash_calculations__, 0) do
      module.__lavash_calculations__()
    else
      []
    end
  end

  defp get_forms(module) do
    if function_exported?(module, :__lavash__, 1) do
      module.__lavash__(:forms)
    else
      []
    end
  end

  @doc """
  Renders an optimistic display element.

  This component eliminates the duplication of specifying both the field name
  and value when displaying optimistic state. It generates a wrapper element
  with the appropriate `data-optimistic-display` attribute.

  ## Examples

      # Simple usage - renders a span
      <.o field={:count} value={@count} />
      # Outputs: <span data-optimistic-display="count">5</span>

      # With custom tag
      <.o field={:count} value={@count} tag="div" />
      # Outputs: <div data-optimistic-display="count">5</div>

      # With additional attributes
      <.o field={:doubled} value={@doubled} class="text-xl font-bold" />
      # Outputs: <span data-optimistic-display="doubled" class="text-xl font-bold">10</span>

      # With inner block for custom content (value still used for optimistic updates)
      <.o field={:count} value={@count}>
        Count: {@count}
      </.o>
      # Outputs: <span data-optimistic-display="count">Count: 5</span>
  """
  attr :field, :atom, required: true, doc: "The state/derive field name"
  attr :value, :any, required: true, doc: "The current value from assigns"
  attr :tag, :string, default: "span", doc: "The HTML tag to use (default: span)"
  attr :rest, :global, doc: "Additional HTML attributes"
  slot :inner_block, doc: "Optional custom content (defaults to displaying value)"

  def o(assigns) do
    assigns = assign(assigns, :field_name, to_string(assigns.field))

    ~H"""
    <.dynamic_tag name={@tag} data-optimistic-display={@field_name} {@rest}>
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@value}
      <% end %>
    </.dynamic_tag>
    """
  end

  @doc """
  Renders a Lavash component with automatic state hydration.

  This function component wraps `Phoenix.Component.live_component/1` and automatically
  injects the component's persisted state from the parent's `@__lavash_component_states__`.

  ## Example

      <.lavash_component
        module={ProductCard}
        id={"product-\#{product.id}"}
        product={product}
      />
  """
  attr(:module, :atom, required: true, doc: "The Lavash component module")
  attr(:id, :string, required: true, doc: "The component ID (used for state namespacing)")
  attr(:rest, :global, doc: "Additional assigns passed to the component")

  def lavash_component(assigns) do
    # Get component states from process dictionary (set by parent during render)
    component_states = get_component_states()
    initial_state = Map.get(component_states, assigns.id, %{})

    # Build the assigns for live_component
    assigns =
      assigns
      |> assign(
        :__component_assigns__,
        assigns.rest
        |> Map.put(:module, assigns.module)
        |> Map.put(:id, assigns.id)
        |> Map.put(:__lavash_initial_state__, initial_state)
      )

    ~H"""
    <.live_component {@__component_assigns__} />
    """
  end

  @doc """
  Renders a set of chips for multi-select state.

  This component renders toggle buttons for each value in a multi-select field,
  with optimistic updates wired automatically.

  ## Examples

      # Basic usage with static values from DSL
      multi_select :roast, ["light", "medium", "dark"], from: :url

      <.chip_set field={:roast} chips={@roast_chips} values={["light", "medium", "dark"]} />

      # With custom labels
      <.chip_set
        field={:roast}
        chips={@roast_chips}
        values={["light", "medium", "dark"]}
        labels={%{"medium" => "Med"}}
      />

      # With dynamic values (e.g., from a read)
      <.chip_set
        field={:category}
        chips={@category_chips}
        values={Enum.map(@categories, & &1.slug)}
        labels={Map.new(@categories, &{&1.slug, &1.name})}
      />
  """
  attr :field, :atom, required: true, doc: "The multi-select state field name"
  attr :chips, :map, required: true, doc: "The chip class map from the derive (e.g., @roast_chips)"
  attr :values, :list, required: true, doc: "The list of possible values"
  attr :labels, :map, default: %{}, doc: "Optional map of value => display label"
  attr :class, :string, default: "flex flex-wrap gap-2", doc: "Container CSS class"
  attr :rest, :global, doc: "Additional HTML attributes for the container"

  def chip_set(assigns) do
    assigns = assign(assigns, :action_name, "toggle_#{assigns.field}")
    assigns = assign(assigns, :derive_name, "#{assigns.field}_chips")

    ~H"""
    <div class={@class} {@rest}>
      <button
        :for={value <- @values}
        type="button"
        class={@chips[value]}
        phx-click={@action_name}
        phx-value-val={value}
        data-optimistic={@action_name}
        data-optimistic-value={value}
        data-optimistic-class={"#{@derive_name}.#{value}"}
      >
        {Map.get(@labels, value, humanize(value))}
      </button>
    </div>
    """
  end

  @doc """
  Renders a toggle chip button for boolean state.

  This component renders a single toggle button with optimistic updates wired automatically.

  ## Examples

      # Basic usage
      toggle :in_stock, from: :url

      <.toggle_chip field={:in_stock} active={@in_stock} chip={@in_stock_chip} />

      # With custom label
      <.toggle_chip field={:in_stock} active={@in_stock} chip={@in_stock_chip} label="In Stock Only" />
  """
  attr :field, :atom, required: true, doc: "The toggle state field name"
  attr :active, :boolean, required: true, doc: "Whether the toggle is currently active"
  attr :chip, :string, required: true, doc: "The chip class from the derive (e.g., @in_stock_chip)"
  attr :label, :string, default: nil, doc: "Optional display label (defaults to humanized field name)"
  attr :rest, :global, doc: "Additional HTML attributes"

  def toggle_chip(assigns) do
    assigns = assign(assigns, :action_name, "toggle_#{assigns.field}")
    assigns = assign(assigns, :derive_name, "#{assigns.field}_chip")
    assigns = assign_new(assigns, :display_label, fn -> assigns.label || humanize(to_string(assigns.field)) end)

    ~H"""
    <button
      type="button"
      class={@chip}
      phx-click={@action_name}
      data-optimistic={@action_name}
      data-optimistic-class={@derive_name}
      {@rest}
    >
      {@display_label}
    </button>
    """
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
