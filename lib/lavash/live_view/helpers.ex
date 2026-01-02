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

    # Add auto-generated form validation fields BEFORE calculations
    # Because calculations may reference *_show_errors fields
    state_map = add_form_validation_fields(state_map, forms)

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

  # Add auto-generated form validation fields to the state map
  defp add_form_validation_fields(state_map, forms) do
    Enum.reduce(forms, state_map, fn form, acc ->
      resource = form.resource
      form_name = form.name
      params_field = :"#{form_name}_params"

      # Check if resource has transpilable constraints
      if Code.ensure_loaded?(resource) and function_exported?(resource, :spark_dsl_config, 0) do
        validations = Lavash.Form.ConstraintTranspiler.extract_validations(resource)

        # Add individual field validations, errors, and show_errors
        acc =
          Enum.reduce(validations, acc, fn validation, inner_acc ->
            params = Map.get(inner_acc, params_field, %{})

            # Add _valid field
            valid_field = :"#{form_name}_#{validation.field}_valid"
            is_valid = compute_validation(validation, params)
            inner_acc = Map.put(inner_acc, valid_field, is_valid)

            # Add _errors field (list of error messages)
            errors_field = :"#{form_name}_#{validation.field}_errors"
            errors = compute_errors(validation, params)
            inner_acc = Map.put(inner_acc, errors_field, errors)

            # Add _show_errors field (false initially - set by JS on blur/submit)
            show_errors_field = :"#{form_name}_#{validation.field}_show_errors"
            Map.put(inner_acc, show_errors_field, false)
          end)

        # Add combined form validation and errors
        if length(validations) > 0 do
          field_names = Enum.map(validations, & &1.field)

          all_valid =
            Enum.all?(field_names, fn field ->
              Map.get(acc, :"#{form_name}_#{field}_valid", false)
            end)

          all_errors =
            Enum.flat_map(field_names, fn field ->
              Map.get(acc, :"#{form_name}_#{field}_errors", [])
            end)

          acc
          |> Map.put(:"#{form_name}_valid", all_valid)
          |> Map.put(:"#{form_name}_errors", all_errors)
        else
          acc
        end
      else
        acc
      end
    end)
  end

  # Compute error messages for a field based on which constraints fail
  defp compute_errors(validation, params) do
    field = validation.field
    field_str = to_string(field)
    value = Map.get(params, field_str)

    # Don't show errors if field is empty (unless required)
    is_empty = is_nil(value) or String.length(String.trim(to_string(value))) == 0

    errors = []

    # Required check
    errors =
      if validation.required and is_empty do
        [Lavash.Form.ConstraintTranspiler.error_message(:required, nil) | errors]
      else
        errors
      end

    # Only check other constraints if field is not empty
    errors =
      if not is_empty do
        errors ++ check_constraint_errors(validation, value)
      else
        errors
      end

    Enum.reverse(errors)
  end

  defp check_constraint_errors(validation, value) do
    case validation.type do
      :string -> check_string_errors(value, validation.constraints)
      :integer -> check_integer_errors(value, validation.constraints)
      _ -> []
    end
  end

  defp check_string_errors(value, constraints) do
    value_str = to_string(value || "")
    trimmed = String.trim(value_str)
    len = String.length(trimmed)
    errors = []

    errors =
      case Map.get(constraints, :min_length) do
        nil -> errors
        min ->
          if len < min do
            [Lavash.Form.ConstraintTranspiler.error_message(:min_length, min) | errors]
          else
            errors
          end
      end

    errors =
      case Map.get(constraints, :max_length) do
        nil -> errors
        max ->
          if len > max do
            [Lavash.Form.ConstraintTranspiler.error_message(:max_length, max) | errors]
          else
            errors
          end
      end

    errors =
      case Map.get(constraints, :match) do
        nil -> errors
        regex ->
          if String.match?(value_str, regex) do
            errors
          else
            [Lavash.Form.ConstraintTranspiler.error_message(:match, regex) | errors]
          end
      end

    errors
  end

  defp check_integer_errors(value, constraints) do
    parsed =
      case value do
        nil -> 0
        "" -> 0
        v when is_integer(v) -> v
        v -> String.to_integer(to_string(v))
      end

    errors = []

    errors =
      case Map.get(constraints, :min) do
        nil -> errors
        min ->
          if parsed < min do
            [Lavash.Form.ConstraintTranspiler.error_message(:min, min) | errors]
          else
            errors
          end
      end

    errors =
      case Map.get(constraints, :max) do
        nil -> errors
        max ->
          if parsed > max do
            [Lavash.Form.ConstraintTranspiler.error_message(:max, max) | errors]
          else
            errors
          end
      end

    errors
  rescue
    _ -> [Lavash.Form.ConstraintTranspiler.error_message(:match, nil)]
  end

  # Compute a single validation field's value
  defp compute_validation(validation, params) do
    field = validation.field
    field_str = to_string(field)
    value = Map.get(params, field_str)

    # Required check
    required_ok =
      if validation.required do
        not is_nil(value) and String.length(String.trim(to_string(value))) > 0
      else
        true
      end

    # Type-specific constraint checks
    constraint_ok =
      case validation.type do
        :string -> check_string_constraints(value, validation.constraints)
        :integer -> check_integer_constraints(value, validation.constraints)
        _ -> true
      end

    required_ok and constraint_ok
  end

  defp check_string_constraints(value, constraints) do
    value_str = to_string(value || "")
    trimmed = String.trim(value_str)

    min_ok =
      case Map.get(constraints, :min_length) do
        nil -> true
        min -> String.length(trimmed) >= min
      end

    max_ok =
      case Map.get(constraints, :max_length) do
        nil -> true
        max -> String.length(trimmed) <= max
      end

    match_ok =
      case Map.get(constraints, :match) do
        nil -> true
        regex -> String.match?(value_str, regex)
      end

    min_ok and max_ok and match_ok
  end

  defp check_integer_constraints(value, constraints) do
    parsed =
      case value do
        nil -> 0
        "" -> 0
        v when is_integer(v) -> v
        v -> String.to_integer(to_string(v))
      end

    min_ok =
      case Map.get(constraints, :min) do
        nil -> true
        min -> parsed >= min
      end

    max_ok =
      case Map.get(constraints, :max) do
        nil -> true
        max -> parsed <= max
      end

    min_ok and max_ok
  rescue
    _ -> false
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
  with the appropriate `data-lavash-display` attribute.

  ## Examples

      # Simple usage - renders a span
      <.o field={:count} value={@count} />
      # Outputs: <span data-lavash-display="count">5</span>

      # With custom tag
      <.o field={:count} value={@count} tag="div" />
      # Outputs: <div data-lavash-display="count">5</div>

      # With additional attributes
      <.o field={:doubled} value={@doubled} class="text-xl font-bold" />
      # Outputs: <span data-lavash-display="doubled" class="text-xl font-bold">10</span>

      # With inner block for custom content (value still used for optimistic updates)
      <.o field={:count} value={@count}>
        Count: {@count}
      </.o>
      # Outputs: <span data-lavash-display="count">Count: 5</span>
  """
  attr :field, :atom, required: true, doc: "The state/derive field name"
  attr :value, :any, required: true, doc: "The current value from assigns"
  attr :tag, :string, default: "span", doc: "The HTML tag to use (default: span)"
  attr :rest, :global, doc: "Additional HTML attributes"
  slot :inner_block, doc: "Optional custom content (defaults to displaying value)"

  def o(assigns) do
    assigns = assign(assigns, :field_name, to_string(assigns.field))

    ~H"""
    <.dynamic_tag name={@tag} data-lavash-display={@field_name} {@rest}>
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@value}
      <% end %>
    </.dynamic_tag>
    """
  end

  @doc """
  Renders an element with conditional visibility based on boolean state.

  This component generates a wrapper element with `data-lavash-visible` attribute,
  which the JS hook uses to show/hide the element by toggling the `hidden` class.

  ## Examples

      # Simple usage - visible when @is_logged_in is true
      <.visible field={:is_logged_in} when={@is_logged_in}>
        Welcome back!
      </.visible>
      # Outputs: <div data-lavash-visible="is_logged_in">Welcome back!</div>

      # With custom tag
      <.visible field={:has_errors} when={@has_errors} tag="span">
        There are errors
      </.visible>
      # Outputs: <span data-lavash-visible="has_errors">There are errors</span>

      # With additional attributes
      <.visible field={:show_advanced} when={@show_advanced} class="mt-4 p-4 bg-gray-100">
        Advanced settings...
      </.visible>

      # Initially hidden (server render matches client behavior)
      <.visible field={:show_details} when={false}>
        Details content
      </.visible>
      # Outputs: <div data-lavash-visible="show_details" class="hidden">Details content</div>
  """
  attr :field, :atom, required: true, doc: "The boolean state field name"
  attr :when, :boolean, required: true, doc: "The current boolean value from assigns"
  attr :tag, :string, default: "div", doc: "The HTML tag to use (default: div)"
  attr :rest, :global, doc: "Additional HTML attributes"
  slot :inner_block, required: true, doc: "Content to show/hide"

  def visible(assigns) do
    assigns = assign(assigns, :field_name, to_string(assigns.field))
    # Add hidden class if value is falsy (for server-rendered consistency)
    assigns = assign(assigns, :hidden_class, if(assigns.when, do: nil, else: "hidden"))

    ~H"""
    <.dynamic_tag name={@tag} data-lavash-visible={@field_name} class={@hidden_class} {@rest}>
      {render_slot(@inner_block)}
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
        data-lavash-action={@action_name}
        data-lavash-value={value}
        data-lavash-class={"#{@derive_name}.#{value}"}
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
      data-lavash-action={@action_name}
      data-lavash-class={@derive_name}
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

  @doc """
  Renders form field errors with optimistic updates.

  This component displays error messages from auto-generated `*_errors` fields.
  Errors are only shown after the field has been touched (blur) or form submitted.

  ## Examples

      # Basic usage - shows errors from registration_name_errors
      <.field_errors form={:registration} field={:name} errors={@registration_name_errors} />

      # With custom class
      <.field_errors form={:registration} field={:age} errors={@registration_age_errors} class="text-sm text-red-500" />
  """
  attr :form, :atom, required: true, doc: "The form name (e.g., :registration)"
  attr :field, :atom, required: true, doc: "The field name (e.g., :name)"
  attr :errors, :list, required: true, doc: "The errors list from assigns (e.g., @registration_name_errors)"
  attr :class, :string, default: "text-red-500 text-sm", doc: "CSS class for error messages"
  attr :rest, :global, doc: "Additional HTML attributes"

  def field_errors(assigns) do
    errors_field = "#{assigns.form}_#{assigns.field}_errors"
    form_name = to_string(assigns.form)
    field_name = to_string(assigns.field)

    assigns =
      assigns
      |> assign(:errors_field, errors_field)
      |> assign(:form_name, form_name)
      |> assign(:field_name, field_name)

    # Errors are hidden initially - JS will show them when touched/submitted
    ~H"""
    <div
      data-lavash-errors={@errors_field}
      data-lavash-form={@form_name}
      data-lavash-field={@field_name}
      class="hidden"
      {@rest}
    >
      <%!-- Content is managed by JS based on touched/submitted state --%>
    </div>
    """
  end

  @doc """
  Renders form field success indicator with optimistic updates.

  This component displays a success message when the field is valid.
  Only shown after the field has been touched (blur) or form submitted.

  ## Examples

      # Basic usage
      <.field_success form={:registration} field={:name} valid={@registration_name_valid} />

      # With custom message
      <.field_success form={:registration} field={:email} valid={@registration_email_valid} message="Valid email!" />
  """
  attr :form, :atom, required: true, doc: "The form name (e.g., :registration)"
  attr :field, :atom, required: true, doc: "The field name (e.g., :name)"
  attr :valid, :boolean, required: true, doc: "The valid state from assigns"
  attr :valid_field, :string, default: nil, doc: "Custom valid field name for JS (defaults to form_field_valid)"
  attr :message, :string, default: "Looks good!", doc: "Success message to display"
  attr :class, :string, default: "text-green-500 text-sm", doc: "CSS class for success message"
  attr :rest, :global, doc: "Additional HTML attributes"

  def field_success(assigns) do
    # Use custom valid_field if provided, otherwise derive from form/field
    valid_field = assigns.valid_field || "#{assigns.form}_#{assigns.field}_valid"
    # show_errors is always derived from form/field (the touched state of the actual field)
    show_errors_field = "#{assigns.form}_#{assigns.field}_show_errors"
    form_name = to_string(assigns.form)
    field_name = to_string(assigns.field)

    assigns =
      assigns
      |> assign(:lavash_valid_field, valid_field)
      |> assign(:lavash_show_errors_field, show_errors_field)
      |> assign(:form_name, form_name)
      |> assign(:field_name, field_name)

    # Hidden initially - JS will show when touched/submitted AND valid
    ~H"""
    <p
      class={[@class, "hidden"]}
      data-lavash-success={@lavash_valid_field}
      data-lavash-show-errors={@lavash_show_errors_field}
      data-lavash-form={@form_name}
      data-lavash-field={@field_name}
      {@rest}
    >
      {"✓ " <> @message}
    </p>
    """
  end

  @doc """
  Renders a form error summary with optimistic updates.

  This component displays a summary of all form errors at the top of the form.
  Only shown after form submission if there are errors. The JS hook
  dynamically populates this with all field errors.

  ## Examples

      # Basic usage - shows all errors for the registration form
      <.error_summary form={:registration} />

      # With custom class
      <.error_summary form={:registration} class="bg-red-50 border border-red-200 p-4 rounded-lg" />
  """
  attr :form, :atom, required: true, doc: "The form name (e.g., :registration)"
  attr :class, :string, default: "bg-red-50 border border-red-200 p-4 rounded-lg text-red-600 text-sm mb-4", doc: "CSS class for the summary container"
  attr :rest, :global, doc: "Additional HTML attributes"

  def error_summary(assigns) do
    assigns = assign(assigns, :form_name, to_string(assigns.form))

    # Hidden initially - JS will show when form is submitted with errors
    ~H"""
    <div
      class={[@class, "hidden"]}
      data-lavash-error-summary={@form_name}
      {@rest}
    >
      <%!-- Content is managed by JS after form submission --%>
    </div>
    """
  end

  @doc """
  Renders a form field status indicator with optimistic updates.

  This component displays a small icon inside an input field indicating
  the validation state (valid, invalid, or neutral). Use this inside
  an input wrapper with `relative` positioning.

  ## Examples

      # Basic usage inside a positioned wrapper
      <div class="relative">
        <input type="text" ... />
        <.field_status form={:registration} field={:name} valid={@registration_name_valid} />
      </div>

      # The indicator is positioned at the right side of the input
  """
  attr :form, :atom, required: true, doc: "The form name (e.g., :registration)"
  attr :field, :atom, required: true, doc: "The field name (e.g., :name)"
  attr :valid, :boolean, required: true, doc: "Whether the field is valid (client validation)"
  attr :valid_field, :string, default: nil, doc: "Custom valid field name for JS"
  attr :class, :string, default: "absolute right-3 top-1/2 -translate-y-1/2 text-lg pointer-events-none", doc: "CSS class for positioning"
  attr :rest, :global, doc: "Additional HTML attributes"

  def field_status(assigns) do
    valid_field = assigns.valid_field || "#{assigns.form}_#{assigns.field}_valid"
    show_errors_field = "#{assigns.form}_#{assigns.field}_show_errors"
    form_name = to_string(assigns.form)
    field_name = to_string(assigns.field)

    assigns =
      assigns
      |> assign(:valid_field, valid_field)
      |> assign(:show_errors_field, show_errors_field)
      |> assign(:form_name, form_name)
      |> assign(:field_name, field_name)

    ~H"""
    <span
      class={@class}
      data-lavash-status={@valid_field}
      data-lavash-show-errors={@show_errors_field}
      data-lavash-form={@form_name}
      data-lavash-field={@field_name}
      {@rest}
    >
      <%!-- Content is managed by JS: ✓ (valid), ✗ (invalid), or empty (neutral) --%>
    </span>
    """
  end
end
