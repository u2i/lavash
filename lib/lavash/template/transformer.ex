defmodule Lavash.Template.Transformer do
  @moduledoc """
  Transforms HEEx templates at compile time to inject data-lavash-* attributes.

  This module analyzes templates and automatically adds the appropriate data attributes
  based on the module's DSL declarations (state fields, forms, actions, derives, etc.).

  ## Form Field Shorthand

  Use `field={@form[:field]}` to inject all form-related attributes (same syntax as Phoenix):

      <input type="text" field={@payment[:card_number]} />

  Expands to:

      <input type="text"
        name={@payment[:card_number].name}
        value={@payment[:card_number].value || ""}
        data-lavash-bind="payment_params.card_number"
        data-lavash-form="payment"
        data-lavash-field="card_number"
        data-lavash-valid="payment_card_number_valid"
      />

  Override any generated attribute by specifying it explicitly:

      <input field={@payment[:cvv]}
             data-lavash-valid="cvv_valid" />  <!-- custom validation field -->

  ## Pattern Recognition

  The transformer recognizes these patterns and injects attributes:

  1. **Form Inputs** - `<input name={@form[:field].name}>` or `name="form[field]"`
     → Injects `data-lavash-bind`, `data-lavash-form`, `data-lavash-field`

  2. **State Bindings** - `<input value={@field}>` where field is optimistic state
     → Injects `data-lavash-bind`

  3. **Action Buttons** - `<button phx-click="action_name">` where action is declared
     → Injects `data-lavash-action`, `data-lavash-value` (if phx-value-* present)

  4. **Optimistic Actions in ClientComponent** - `<button data-lavash-action="toggle">`
     → Injects `data-lavash-state-field` based on optimistic_action declaration

  5. **State Display** - `{@field}` inside element, where field is optimistic
     → Injects `data-lavash-display` on parent element

  6. **Conditional Visibility** - `:if={@bool_field}` where field is optimistic boolean
     → Injects `data-lavash-visible`

  7. **Enabled/Disabled** - `disabled={not @field}` where field is optimistic boolean
     → Injects `data-lavash-enabled`

  ## Opt-Out

  Add `data-lavash-manual` to any element to skip auto-injection for that element.

  ## Usage

  The transformer is automatically invoked by Lavash.LiveView and Lavash.ClientComponent
  compilers. To disable auto-transformation:

      use Lavash.LiveView, auto_attributes: false
  """

  @doc """
  Transform a template source string, injecting data-lavash-* attributes.

  Returns the modified template source.

  ## Options

  - `:context` - `:live_view` (default) or `:client_component`
  - `:metadata` - Pre-built metadata map (optional, will be built from module if not provided)
  """
  def transform(template_source, module, opts \\ []) do
    # Use pre-built metadata if provided, otherwise build from module
    metadata =
      case Keyword.get(opts, :metadata) do
        nil -> build_metadata(module, opts)
        meta -> Map.put(meta, :context, Keyword.get(opts, :context, meta[:context] || :live_view))
      end

    if Enum.empty?(metadata.optimistic_fields) and
       Enum.empty?(metadata.optimistic_derives) and
       Enum.empty?(metadata.forms) and
       Enum.empty?(metadata.actions) and
       Enum.empty?(metadata.optimistic_actions) do
      # No Lavash features to transform
      template_source
    else
      do_transform(template_source, metadata)
    end
  end

  @doc """
  Build metadata map from module's DSL declarations.
  """
  def build_metadata(module, opts) do
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

  # Get optimistic state fields as a map of name => metadata
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

  # Get optimistic derives as a map of name => metadata
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

  # Get calculations (all are optimistic by default)
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

  # Get forms as a map of name => metadata
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

  # Extract field names from an Ash resource
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

  # Get actions as a map of name => metadata
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

  # Get optimistic_actions for ClientComponent (different structure)
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

  # Main transformation logic
  defp do_transform(template_source, metadata) do
    # Parse template into tokens
    case tokenize(template_source) do
      {:ok, tokens} ->
        # Transform tokens
        transformed = transform_tokens(tokens, metadata, %{})
        # Convert back to string
        tokens_to_string(transformed)

      {:error, _reason} ->
        # If parsing fails, return original
        template_source
    end
  end

  # Simple tokenizer that preserves structure for transformation
  # Returns a list of tokens: {:text, string} | {:tag, tag_info} | {:expr, string}
  defp tokenize(source) do
    tokens = do_tokenize(source, [], "")
    {:ok, Enum.reverse(tokens)}
  rescue
    e -> {:error, e}
  end

  defp do_tokenize("", acc, buffer) do
    if buffer == "" do
      acc
    else
      [{:text, buffer} | acc]
    end
  end

  # Handle HEEx expressions: {@field} or {expression}
  defp do_tokenize("{" <> rest, acc, buffer) do
    acc = if buffer == "", do: acc, else: [{:text, buffer} | acc]
    {expr, remaining} = extract_expr(rest, "", 1)
    do_tokenize(remaining, [{:expr, expr} | acc], "")
  end

  # Handle EEx expressions: <%= ... %>
  defp do_tokenize("<%=" <> rest, acc, buffer) do
    acc = if buffer == "", do: acc, else: [{:text, buffer} | acc]
    {expr, remaining} = extract_eex_expr(rest, "")
    do_tokenize(remaining, [{:eex, expr} | acc], "")
  end

  # Handle EEx control: <% ... %>
  defp do_tokenize("<%" <> rest, acc, buffer) do
    acc = if buffer == "", do: acc, else: [{:text, buffer} | acc]
    {expr, remaining} = extract_eex_expr(rest, "")
    do_tokenize(remaining, [{:eex_control, expr} | acc], "")
  end

  # Handle self-closing tags: <tag ... />
  defp do_tokenize("<" <> rest, acc, buffer) do
    case extract_tag(rest) do
      {:ok, tag_info, remaining} ->
        acc = if buffer == "", do: acc, else: [{:text, buffer} | acc]
        do_tokenize(remaining, [{:tag, tag_info} | acc], "")

      :not_tag ->
        do_tokenize(rest, acc, buffer <> "<")
    end
  end

  defp do_tokenize(<<char::utf8, rest::binary>>, acc, buffer) do
    do_tokenize(rest, acc, buffer <> <<char::utf8>>)
  end

  # Extract expression content, handling nested braces
  defp extract_expr("}" <> rest, acc, 1), do: {acc, rest}
  defp extract_expr("}" <> rest, acc, depth), do: extract_expr(rest, acc <> "}", depth - 1)
  defp extract_expr("{" <> rest, acc, depth), do: extract_expr(rest, acc <> "{", depth + 1)
  defp extract_expr(<<char::utf8, rest::binary>>, acc, depth), do: extract_expr(rest, acc <> <<char::utf8>>, depth)
  defp extract_expr("", acc, _depth), do: {acc, ""}

  # Extract EEx expression until %>
  defp extract_eex_expr("%>" <> rest, acc), do: {acc, rest}
  defp extract_eex_expr(<<char::utf8, rest::binary>>, acc), do: extract_eex_expr(rest, acc <> <<char::utf8>>)
  defp extract_eex_expr("", acc), do: {acc, ""}

  # Extract tag information
  defp extract_tag(source) do
    # Match tag name (including component names like .modal or MyComponent)
    case Regex.run(~r/^([\w\.]+)/, source) do
      [_, tag_name] ->
        rest = String.slice(source, String.length(tag_name)..-1//1)
        {attrs, remaining, self_closing} = extract_attrs(rest)
        {:ok, %{name: tag_name, attrs: attrs, self_closing: self_closing}, remaining}

      nil ->
        # Check for closing tag
        if String.starts_with?(source, "/") do
          :not_tag
        else
          :not_tag
        end
    end
  end

  # Extract attributes from tag
  defp extract_attrs(source) do
    extract_attrs(String.trim_leading(source), [], false)
  end

  defp extract_attrs("/>" <> rest, attrs, _self_closing) do
    {Enum.reverse(attrs), rest, true}
  end

  defp extract_attrs(">" <> rest, attrs, _self_closing) do
    {Enum.reverse(attrs), rest, false}
  end

  defp extract_attrs("", attrs, self_closing) do
    {Enum.reverse(attrs), "", self_closing}
  end

  defp extract_attrs(source, attrs, self_closing) do
    source = String.trim_leading(source)

    cond do
      String.starts_with?(source, "/>") ->
        extract_attrs(source, attrs, self_closing)

      String.starts_with?(source, ">") ->
        extract_attrs(source, attrs, self_closing)

      source == "" ->
        {Enum.reverse(attrs), "", self_closing}

      true ->
        case extract_single_attr(source) do
          {:ok, attr, rest} ->
            extract_attrs(rest, [attr | attrs], self_closing)

          :error ->
            # Skip character and continue
            <<_::utf8, rest::binary>> = source
            extract_attrs(rest, attrs, self_closing)
        end
    end
  end

  # Extract a single attribute
  defp extract_single_attr(source) do
    # Match attribute name (including special attrs like :if, :for, phx-click, etc.)
    case Regex.run(~r/^([\w:@\-\.]+)/, source) do
      [_, attr_name] ->
        rest = String.slice(source, String.length(attr_name)..-1//1)
        rest = String.trim_leading(rest)

        cond do
          # Boolean attribute (no value)
          not String.starts_with?(rest, "=") ->
            {:ok, {attr_name, :boolean}, rest}

          # Attribute with value
          String.starts_with?(rest, "=") ->
            rest = String.slice(rest, 1..-1//1)
            rest = String.trim_leading(rest)
            {value, remaining} = extract_attr_value(rest)
            {:ok, {attr_name, value}, remaining}
        end

      nil ->
        :error
    end
  end

  # Extract attribute value
  defp extract_attr_value("{" <> rest) do
    {expr, remaining} = extract_expr(rest, "", 1)
    {{:expr, expr}, remaining}
  end

  defp extract_attr_value("\"" <> rest) do
    {value, remaining} = extract_string(rest, "")
    {{:string, value}, remaining}
  end

  defp extract_attr_value(source) do
    # Unquoted value or expression
    case Regex.run(~r/^([^\s>]+)/, source) do
      [_, value] ->
        rest = String.slice(source, String.length(value)..-1//1)
        {{:string, value}, rest}

      nil ->
        {{:string, ""}, source}
    end
  end

  defp extract_string("\"" <> rest, acc), do: {acc, rest}
  defp extract_string("\\\"" <> rest, acc), do: extract_string(rest, acc <> "\"")
  defp extract_string(<<char::utf8, rest::binary>>, acc), do: extract_string(rest, acc <> <<char::utf8>>)
  defp extract_string("", acc), do: {acc, ""}

  # Transform tokens based on metadata
  defp transform_tokens(tokens, metadata, context) do
    Enum.map(tokens, fn token ->
      transform_token(token, metadata, context)
    end)
  end

  defp transform_token({:tag, tag_info}, metadata, _context) do
    # Skip if has data-lavash-manual
    if has_attr?(tag_info.attrs, "data-lavash-manual") do
      {:tag, tag_info}
    else
      transformed_attrs = maybe_inject_attrs(tag_info, metadata)
      {:tag, %{tag_info | attrs: transformed_attrs}}
    end
  end

  defp transform_token(token, _metadata, _context), do: token

  # Check if tag already has an attribute
  defp has_attr?(attrs, name) do
    Enum.any?(attrs, fn {attr_name, _} -> attr_name == name end)
  end

  # Get attribute value
  defp get_attr(attrs, name) do
    case Enum.find(attrs, fn {attr_name, _} -> attr_name == name end) do
      {_, value} -> value
      nil -> nil
    end
  end

  # Inject attributes based on pattern matching
  defp maybe_inject_attrs(tag_info, metadata) do
    attrs = tag_info.attrs

    attrs
    |> maybe_inject_form_input(tag_info, metadata)
    |> maybe_inject_state_binding(tag_info, metadata)
    |> maybe_inject_action(tag_info, metadata)
    |> maybe_inject_visibility(tag_info, metadata)
    |> maybe_inject_enabled(tag_info, metadata)
    |> maybe_inject_client_component_action(tag_info, metadata)
  end

  # Pattern 1: Form inputs
  # Supports two patterns:
  # a) Explicit: name={@form[:field].name} - injects data-lavash-* attributes
  # b) Shorthand: field={@form[:field]} - injects name, value, and all data-lavash-* (Phoenix-style)
  defp maybe_inject_form_input(attrs, tag_info, metadata) do
    if tag_info.name in ["input", "textarea", "select"] do
      # Check for shorthand pattern first: field={@form[:field]} (Phoenix-style)
      case get_attr(attrs, "field") do
        {:expr, expr} ->
          case parse_form_field_access_expr(expr) do
            {:ok, form, field} when is_map_key(metadata.forms, form) ->
              inject_full_form_attrs(attrs, form, field, expr)

            _ ->
              # Fall through to explicit pattern
              maybe_inject_form_input_explicit(attrs, tag_info, metadata)
          end

        _ ->
          # Fall through to explicit pattern
          maybe_inject_form_input_explicit(attrs, tag_info, metadata)
      end
    else
      attrs
    end
  end

  # Explicit pattern: name={@form[:field].name}
  defp maybe_inject_form_input_explicit(attrs, _tag_info, metadata) do
    if not has_attr?(attrs, "data-lavash-bind") do
      case get_attr(attrs, "name") do
        {:expr, expr} ->
          case parse_form_field_expr(expr) do
            {:ok, form, field} when is_map_key(metadata.forms, form) ->
              inject_form_attrs(attrs, form, field)

            _ ->
              attrs
          end

        {:string, name} ->
          case parse_form_field_string(name) do
            {:ok, form, field} ->
              form_atom = String.to_atom(form)
              if is_map_key(metadata.forms, form_atom) do
                inject_form_attrs(attrs, form_atom, String.to_atom(field))
              else
                attrs
              end

            _ ->
              attrs
          end

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  # Full injection for shorthand pattern - injects name, value, and all data-lavash-*
  defp inject_full_form_attrs(attrs, form, field, _expr) do
    form_str = to_string(form)
    field_str = to_string(field)

    # Remove the shorthand attribute and inject everything
    attrs
    |> Enum.reject(fn {name, _} -> name == "field" end)
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

  # Parse @form[:field].name pattern
  defp parse_form_field_expr(expr) do
    # Match patterns like: @registration[:name].name
    case Regex.run(~r/@(\w+)\[:(\w+)\]\.name/, expr) do
      [_, form, field] ->
        {:ok, String.to_atom(form), String.to_atom(field)}

      nil ->
        :error
    end
  end

  # Parse form[field] string pattern
  defp parse_form_field_string(name) do
    case Regex.run(~r/^(\w+)\[(\w+)\]$/, name) do
      [_, form, field] -> {:ok, form, field}
      nil -> :error
    end
  end

  # Parse @form[:field] pattern (for shorthand data-lavash-form-field={@form[:field]})
  defp parse_form_field_access_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]$/, String.trim(expr)) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  # Pattern 2: State bindings (value={@field} on inputs)
  defp maybe_inject_state_binding(attrs, tag_info, metadata) do
    if tag_info.name in ["input", "textarea", "select"] and
       not has_attr?(attrs, "data-lavash-bind") do
      case get_attr(attrs, "value") do
        {:expr, "@" <> field_name} ->
          field_atom = String.to_atom(field_name)

          if is_map_key(metadata.optimistic_fields, field_atom) do
            add_attr_if_missing(attrs, "data-lavash-bind", {:string, field_name})
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

  # Pattern 3: Action buttons
  defp maybe_inject_action(attrs, tag_info, metadata) do
    if tag_info.name in ["button", "a", "div", "span"] and
       not has_attr?(attrs, "data-lavash-action") do
      case get_attr(attrs, "phx-click") do
        {:string, action_name} ->
          action_atom = String.to_atom(action_name)
          if is_map_key(metadata.actions, action_atom) do
            attrs = add_attr_if_missing(attrs, "data-lavash-action", {:string, action_name})
            # Check for phx-value-* and extract value
            maybe_inject_action_value(attrs)
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

  # Extract value from phx-value-* attributes
  defp maybe_inject_action_value(attrs) do
    if has_attr?(attrs, "data-lavash-value") do
      attrs
    else
      # Find any phx-value-* attribute
      case Enum.find(attrs, fn {name, _} -> String.starts_with?(name, "phx-value-") end) do
        {_, {:string, value}} ->
          add_attr_if_missing(attrs, "data-lavash-value", {:string, value})

        {_, {:expr, expr}} ->
          add_attr_if_missing(attrs, "data-lavash-value", {:expr, expr})

        nil ->
          attrs
      end
    end
  end

  # Pattern 4: Conditional visibility (:if={@bool_field})
  defp maybe_inject_visibility(attrs, _tag_info, metadata) do
    if not has_attr?(attrs, "data-lavash-visible") do
      case get_attr(attrs, ":if") do
        {:expr, "@" <> field_name} ->
          field_atom = String.to_atom(field_name)

          if is_optimistic_boolean?(field_atom, metadata) do
            add_attr_if_missing(attrs, "data-lavash-visible", {:string, field_name})
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

  # Pattern 5: Enabled/disabled state (disabled={not @field})
  defp maybe_inject_enabled(attrs, _tag_info, metadata) do
    if not has_attr?(attrs, "data-lavash-enabled") do
      case get_attr(attrs, "disabled") do
        {:expr, expr} ->
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
    else
      attrs
    end
  end

  # Parse "not @field" pattern
  defp parse_negated_field(expr) do
    expr = String.trim(expr)

    case Regex.run(~r/^not\s+@(\w+)$/, expr) do
      [_, field] -> {:ok, field}
      nil -> :error
    end
  end

  # Check if field is an optimistic boolean
  defp is_optimistic_boolean?(field_atom, metadata) do
    cond do
      is_map_key(metadata.optimistic_fields, field_atom) ->
        field = metadata.optimistic_fields[field_atom]
        field.type == :boolean

      is_map_key(metadata.optimistic_derives, field_atom) ->
        # Assume derives can be boolean
        true

      is_map_key(metadata.calculations, field_atom) ->
        # Calculations can be boolean
        true

      true ->
        false
    end
  end

  # Pattern 6: ClientComponent actions (inject data-lavash-state-field)
  defp maybe_inject_client_component_action(attrs, _tag_info, metadata) do
    if metadata.context == :client_component and
       not has_attr?(attrs, "data-lavash-state-field") do
      case get_attr(attrs, "data-lavash-action") do
        {:string, action_name} ->
          action_atom = String.to_atom(action_name)

          if is_map_key(metadata.optimistic_actions, action_atom) do
            action = metadata.optimistic_actions[action_atom]
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

  # Add attribute if not already present
  defp add_attr_if_missing(attrs, name, value) do
    if has_attr?(attrs, name) do
      attrs
    else
      attrs ++ [{name, value}]
    end
  end

  # Convert tokens back to string
  defp tokens_to_string(tokens) do
    Enum.map_join(tokens, "", &token_to_string/1)
  end

  defp token_to_string({:text, text}), do: text
  defp token_to_string({:expr, expr}), do: "{#{expr}}"
  defp token_to_string({:eex, expr}), do: "<%=#{expr}%>"
  defp token_to_string({:eex_control, expr}), do: "<%#{expr}%>"

  defp token_to_string({:tag, tag_info}) do
    attrs_str = attrs_to_string(tag_info.attrs)
    closing = if tag_info.self_closing, do: " />", else: ">"
    "<#{tag_info.name}#{attrs_str}#{closing}"
  end

  defp attrs_to_string([]), do: ""

  defp attrs_to_string(attrs) do
    attrs_str =
      Enum.map_join(attrs, " ", fn
        {name, :boolean} -> name
        {name, {:string, value}} -> ~s(#{name}="#{escape_attr_value(value)}")
        {name, {:expr, expr}} -> "#{name}={#{expr}}"
      end)

    " " <> attrs_str
  end

  defp escape_attr_value(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
