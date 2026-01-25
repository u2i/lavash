defmodule Lavash.Template.TokenTransformer do
  @moduledoc """
  Unified token transformer for Lavash templates.

  This module implements `Lavash.TokenTransformer` to handle all compile-time
  template transformations at the token level:

  1. **`data-lavash-*` attributes** on HTML elements (for JS hooks/optimistic updates)
  2. **`__lavash_client_bindings__`** on component calls (for binding chain propagation)

  ## Token Structure

  Tokens from `Phoenix.LiveView.Tokenizer`:

  - `{:tag, name, attrs, meta}` - HTML elements
  - `{:remote_component, name, attrs, meta}` - `<Foo.bar>` components
  - `{:local_component, name, attrs, meta}` - `<.foo>` components
  - `{:slot, name, attrs, meta}` - `<:header>` slots
  - `{:close, type, name, meta}` - Closing tags
  - `{:text, content, meta}` - Text content
  - `{:expr, marker, content}` - `{...}` expressions

  Attributes are `{name, value, attr_meta}` where value is:
  - `{:string, content, str_meta}` - `"literal"`
  - `{:expr, content, expr_meta}` - `{@foo}`
  - `nil` - Boolean attribute

  ## Usage

  Pass this module as `:token_transformer` to `Lavash.TagEngine`:

      EEx.compile_string(source,
        engine: Lavash.TagEngine,
        tag_handler: Phoenix.LiveView.HTMLEngine,
        token_transformer: Lavash.Template.TokenTransformer,
        lavash_metadata: %{...}
      )
  """

  @behaviour Lavash.TokenTransformer

  @impl true
  def transform(tokens, state) do
    metadata = state[:lavash_metadata] || %{}

    tokens
    |> Enum.map(&transform_token(&1, metadata, state))
  end

  # Transform individual tokens
  defp transform_token({:tag, name, attrs, meta}, metadata, _state) do
    if has_attr?(attrs, "data-lavash-manual") do
      {:tag, name, attrs, meta}
    else
      new_attrs = maybe_inject_tag_attrs(name, attrs, meta, metadata)
      {:tag, name, new_attrs, meta}
    end
  end

  defp transform_token({:remote_component, name, attrs, meta}, metadata, state) do
    new_attrs = maybe_inject_component_attrs(name, attrs, meta, metadata, state)
    {:remote_component, name, new_attrs, meta}
  end

  defp transform_token({:local_component, name, attrs, meta}, metadata, state) do
    new_attrs = maybe_inject_component_attrs(name, attrs, meta, metadata, state)
    {:local_component, name, new_attrs, meta}
  end

  defp transform_token(token, _metadata, _state), do: token

  # ===========================================================================
  # Component Transformations (__lavash_client_bindings__)
  # ===========================================================================

  # Lavash component names that should receive __lavash_client_bindings__
  @lavash_components ~w(lavash_component child_component)

  # Only inject __lavash_client_bindings__ when:
  # 1. Context is :component (Lavash.Component) - these receive bindings from parent
  # 2. Component is a Lavash component (lavash_component, child_component)
  # 3. Not already present
  # LiveViews are top-level and don't have __lavash_client_bindings__ to pass down
  # Regular Phoenix components (form, input, link, etc.) should NOT receive this
  defp maybe_inject_component_attrs(name, attrs, meta, metadata, _state) do
    context = metadata[:context]

    # Only inject in component context for Lavash components
    if context == :component and
         name in @lavash_components and
         not has_attr?(attrs, "__lavash_client_bindings__") do
      binding_attr =
        {"__lavash_client_bindings__",
         {:expr, "@__lavash_client_bindings__", meta},
         meta}

      attrs ++ [binding_attr]
    else
      attrs
    end
  end

  # ===========================================================================
  # Tag Transformations (data-lavash-*)
  # ===========================================================================

  defp maybe_inject_tag_attrs(name, attrs, _meta, metadata) do
    attrs
    |> maybe_inject_form_input(name, metadata)
    |> maybe_inject_state_binding(name, metadata)
    |> maybe_inject_action(name, metadata)
    |> maybe_inject_visibility(metadata)
    |> maybe_inject_enabled(metadata)
    |> maybe_inject_client_component_action(metadata)
  end

  # Pattern 1: Form inputs
  # Supports two patterns:
  # a) Explicit: name={@form[:field].name} - injects data-lavash-* attributes
  # b) Shorthand: field={@form[:field]} - injects name, value, and all data-lavash-*
  defp maybe_inject_form_input(attrs, name, metadata) when name in ["input", "textarea", "select"] do
    forms = metadata[:forms] || %{}

    case get_attr_value(attrs, "field") do
      {:expr, expr, _meta} ->
        case parse_form_field_access_expr(expr) do
          {:ok, form, field} ->
            if is_map_key(forms, form) do
              inject_full_form_attrs(attrs, form, field)
            else
              maybe_inject_form_input_explicit(attrs, metadata)
            end

          _ ->
            maybe_inject_form_input_explicit(attrs, metadata)
        end

      _ ->
        maybe_inject_form_input_explicit(attrs, metadata)
    end
  end

  defp maybe_inject_form_input(attrs, _name, _metadata), do: attrs

  defp maybe_inject_form_input_explicit(attrs, metadata) do
    forms = metadata[:forms] || %{}

    if has_attr?(attrs, "data-lavash-bind") do
      attrs
    else
      case get_attr_value(attrs, "name") do
        {:expr, expr, _meta} ->
          case parse_form_field_expr(expr) do
            {:ok, form, field} ->
              if is_map_key(forms, form) do
                inject_form_attrs(attrs, form, field)
              else
                attrs
              end

            _ ->
              attrs
          end

        {:string, name_value, _meta} ->
          case parse_form_field_string(name_value) do
            {:ok, form_str, field_str} ->
              form = String.to_atom(form_str)

              if is_map_key(forms, form) do
                inject_form_attrs(attrs, form, String.to_atom(field_str))
              else
                attrs
              end

            _ ->
              attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp inject_full_form_attrs(attrs, form, field) do
    form_str = to_string(form)
    field_str = to_string(field)

    attrs
    |> reject_attr("field")
    |> add_attr_if_missing("name", {:expr, "@#{form_str}[:#{field_str}].name"})
    |> add_attr_if_missing("value", {:expr, "@#{form_str}[:#{field_str}].value || \"\""})
    |> add_attr_if_missing("data-lavash-bind", {:string, "#{form_str}_params.#{field_str}"})
    |> add_attr_if_missing("data-lavash-form", {:string, form_str})
    |> add_attr_if_missing("data-lavash-field", {:string, field_str})
    |> add_attr_if_missing("data-lavash-valid", {:string, "#{form_str}_#{field_str}_valid"})
  end

  defp inject_form_attrs(attrs, form, field) do
    form_str = to_string(form)
    field_str = to_string(field)

    attrs
    |> add_attr_if_missing("data-lavash-bind", {:string, "#{form_str}_params.#{field_str}"})
    |> add_attr_if_missing("data-lavash-form", {:string, form_str})
    |> add_attr_if_missing("data-lavash-field", {:string, field_str})
    |> add_attr_if_missing("data-lavash-valid", {:string, "#{form_str}_#{field_str}_valid"})
  end

  # Pattern 2: State bindings (value={@field} on inputs)
  defp maybe_inject_state_binding(attrs, name, metadata)
       when name in ["input", "textarea", "select"] do
    if has_attr?(attrs, "data-lavash-bind") do
      attrs
    else
      case get_attr_value(attrs, "value") do
        {:expr, "@" <> field_name, _meta} ->
          field_atom = String.to_atom(field_name)

          if is_map_key(metadata[:optimistic_fields] || %{}, field_atom) do
            add_attr_if_missing(attrs, "data-lavash-bind", {:string, field_name})
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp maybe_inject_state_binding(attrs, _name, _metadata), do: attrs

  # Pattern 3: Action buttons
  defp maybe_inject_action(attrs, name, metadata) when name in ["button", "a", "div", "span"] do
    if has_attr?(attrs, "data-lavash-action") do
      attrs
    else
      case get_attr_value(attrs, "phx-click") do
        {:string, action_name, _meta} ->
          action_atom = String.to_atom(action_name)
          actions_map = metadata[:actions] || %{}

          if is_map_key(actions_map, action_atom) do
            attrs
            |> add_attr_if_missing("data-lavash-action", {:string, action_name})
            |> maybe_inject_action_value()
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp maybe_inject_action(attrs, _name, _metadata), do: attrs

  defp maybe_inject_action_value(attrs) do
    if has_attr?(attrs, "data-lavash-value") do
      attrs
    else
      case find_phx_value_attr(attrs) do
        {_name, {:string, value, _meta}, _attr_meta} ->
          add_attr_if_missing(attrs, "data-lavash-value", {:string, value})

        {_name, {:expr, expr, _meta}, _attr_meta} ->
          add_attr_if_missing(attrs, "data-lavash-value", {:expr, expr})

        nil ->
          attrs
      end
    end
  end

  defp find_phx_value_attr(attrs) do
    Enum.find(attrs, fn {name, _value, _meta} ->
      String.starts_with?(name, "phx-value-")
    end)
  end

  # Pattern 4: Conditional visibility (:if={@bool_field})
  defp maybe_inject_visibility(attrs, metadata) do
    if has_attr?(attrs, "data-lavash-visible") do
      attrs
    else
      case get_attr_value(attrs, ":if") do
        {:expr, "@" <> field_name, _meta} ->
          field_atom = String.to_atom(field_name)

          if is_optimistic_boolean?(field_atom, metadata) do
            add_attr_if_missing(attrs, "data-lavash-visible", {:string, field_name})
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  # Pattern 5: Enabled/disabled state (disabled={not @field})
  defp maybe_inject_enabled(attrs, metadata) do
    if has_attr?(attrs, "data-lavash-enabled") do
      attrs
    else
      case get_attr_value(attrs, "disabled") do
        {:expr, expr, _meta} ->
          case parse_negated_field(expr) do
            {:ok, field_name} ->
              field_atom = String.to_atom(field_name)

              if is_optimistic_boolean?(field_atom, metadata) do
                add_attr_if_missing(attrs, "data-lavash-enabled", {:string, field_name})
              else
                attrs
              end

            :error ->
              attrs
          end

        _ ->
          attrs
      end
    end
  end

  # Pattern 6: ClientComponent actions (inject data-lavash-state-field)
  defp maybe_inject_client_component_action(attrs, metadata) do
    if metadata[:context] == :client_component and
         not has_attr?(attrs, "data-lavash-state-field") do
      case get_attr_value(attrs, "data-lavash-action") do
        {:string, action_name, _meta} ->
          action_atom = String.to_atom(action_name)
          optimistic_actions = metadata[:optimistic_actions] || %{}

          if is_map_key(optimistic_actions, action_atom) do
            action = optimistic_actions[action_atom]
            field_str = to_string(action.field)
            add_attr_if_missing(attrs, "data-lavash-state-field", {:string, field_str})
          else
            attrs
          end

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  # ===========================================================================
  # Attribute Helpers
  # ===========================================================================

  defp has_attr?(attrs, name) do
    Enum.any?(attrs, fn {attr_name, _value, _meta} -> attr_name == name end)
  end

  defp get_attr_value(attrs, name) do
    case Enum.find(attrs, fn {attr_name, _value, _meta} -> attr_name == name end) do
      {_name, value, _meta} -> value
      nil -> nil
    end
  end

  defp reject_attr(attrs, name) do
    Enum.reject(attrs, fn {attr_name, _value, _meta} -> attr_name == name end)
  end

  defp add_attr_if_missing(attrs, name, value) do
    if has_attr?(attrs, name) do
      attrs
    else
      # Use meta with required fields for injected attributes
      attr_meta = %{line: 1, column: 1}
      value_with_meta = wrap_value_with_meta(value, attr_meta)
      attrs ++ [{name, value_with_meta, attr_meta}]
    end
  end

  # String values need delimiter in meta for TagEngine's handle_tag_attrs
  defp wrap_value_with_meta({:string, value}, _meta) do
    {:string, value, %{delimiter: ?", line: 1, column: 1}}
  end

  defp wrap_value_with_meta({:expr, value}, meta), do: {:expr, value, meta}
  defp wrap_value_with_meta(value, _meta), do: value

  # ===========================================================================
  # Parsing Helpers
  # ===========================================================================

  # Parse @form[:field].name pattern
  defp parse_form_field_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]\.name/, expr) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  # Parse form[field] string pattern
  defp parse_form_field_string(name) do
    case Regex.run(~r/^(\w+)\[(\w+)\]$/, name) do
      [_, form, field] -> {:ok, form, field}
      nil -> :error
    end
  end

  # Parse @form[:field] pattern (shorthand)
  defp parse_form_field_access_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]$/, String.trim(expr)) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  # Parse "not @field" pattern
  defp parse_negated_field(expr) do
    case Regex.run(~r/^not\s+@(\w+)$/, String.trim(expr)) do
      [_, field] -> {:ok, field}
      nil -> :error
    end
  end

  # Check if field is an optimistic boolean
  defp is_optimistic_boolean?(field_atom, metadata) do
    cond do
      is_map_key(metadata[:optimistic_fields] || %{}, field_atom) ->
        field = metadata[:optimistic_fields][field_atom]
        field.type == :boolean

      is_map_key(metadata[:optimistic_derives] || %{}, field_atom) ->
        true

      is_map_key(metadata[:calculations] || %{}, field_atom) ->
        true

      true ->
        false
    end
  end

  # ===========================================================================
  # Metadata Builder
  # ===========================================================================

  @doc """
  Build metadata map from module's DSL declarations.

  This is called at compile time to gather information about the module's
  state, forms, actions, etc. for use during token transformation.
  """
  def build_metadata(module, opts \\ []) do
    context = Keyword.get(opts, :context, :live_view)

    %{
      context: context,
      optimistic_fields: get_optimistic_fields(module),
      optimistic_derives: get_optimistic_derives(module),
      calculations: get_calculations(module),
      forms: get_forms(module),
      actions: get_actions(module),
      optimistic_actions: get_optimistic_actions(module, context)
    }
  end

  defp get_optimistic_fields(module) do
    if function_exported?(module, :__lavash__, 1) do
      module.__lavash__(:optimistic_fields)
      |> Enum.map(fn field -> {field.name, field} end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp get_optimistic_derives(module) do
    if function_exported?(module, :__lavash__, 1) do
      module.__lavash__(:optimistic_derives)
      |> Enum.map(fn derive -> {derive.name, derive} end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp get_calculations(module) do
    if function_exported?(module, :__lavash_calculations__, 0) do
      module.__lavash_calculations__()
      |> Enum.map(fn
        {name, _source, _ast, _deps} -> {name, %{optimistic: true}}
        {name, _source, _ast, _deps, opt, _async, _reads} -> {name, %{optimistic: opt}}
      end)
      |> Enum.filter(fn {_name, meta} -> meta.optimistic end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp get_forms(module) do
    if function_exported?(module, :__lavash__, 1) do
      module.__lavash__(:forms)
      |> Enum.map(fn form ->
        fields = extract_form_fields(form.resource)
        {form.name, %{resource: form.resource, fields: fields}}
      end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp extract_form_fields(resource) do
    if Code.ensure_loaded?(resource) and function_exported?(resource, :spark_dsl_config, 0) do
      Ash.Resource.Info.attributes(resource)
      |> Enum.map(& &1.name)
    else
      []
    end
  rescue
    _ -> []
  end

  defp get_actions(module) do
    if function_exported?(module, :__lavash__, 1) do
      module.__lavash__(:actions)
      |> Enum.map(fn action -> {action.name, action} end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp get_optimistic_actions(module, :client_component) do
    if Module.get_attribute(module, :__lavash_optimistic_actions__) do
      Module.get_attribute(module, :__lavash_optimistic_actions__)
      |> Enum.map(fn {name, field, _run, _validate, _max} ->
        {name, %{field: field}}
      end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp get_optimistic_actions(_module, _context), do: %{}
end
