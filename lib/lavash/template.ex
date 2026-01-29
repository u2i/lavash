defmodule Lavash.Template do
  @moduledoc """
  Unified template compilation that generates both server-side HEEx and client-side JS
  from a single template source.

  This module provides utilities for parsing HEEx templates and generating:
  1. Standard Phoenix.LiveView.Rendered structs for server-side rendering
  2. JavaScript functions for client-side optimistic updates (via colocated hooks)

  ## Example

      defmodule MyComponent do
        use Lavash.ClientComponent

        state :selected, {:array, :string}

        optimistic_action :toggle_selected, :selected,
          run: fn selected, value ->
            if value in selected, do: List.delete(selected, value), else: selected ++ [value]
          end

        template \"\"\"
        <button
          :for={value <- @values}
          data-lavash-action="toggle_selected"
          data-lavash-value={value}
          class={if value in @selected, do: @active_class, else: @inactive_class}
        >
          {value}
        </button>
        \"\"\"
      end

  ## Generated Colocated Hook

  The template macro generates a Phoenix LiveView 1.1 colocated hook that:
  - Tracks component state for optimistic updates
  - Runs client-side action functions before server response
  - Recomputes derived values (like class maps) automatically
  - Updates the DOM instantly while server catches up
  """

  alias Phoenix.LiveView.Tokenizer

  @doc """
  Tokenizes HEEx source into a list of tokens.

  Returns a list of tokens that can be analyzed for JS generation.
  """
  def tokenize(source) do
    state = Tokenizer.init(0, "nofile", source, Phoenix.LiveView.HTMLEngine)

    case Tokenizer.tokenize(source, [line: 1, column: 1], [], {:text, :enabled}, state) do
      {tokens, _cont} ->
        Tokenizer.finalize(tokens, "nofile", {:text, :enabled}, source)
    end
  end

  @doc """
  Parses tokens into a tree structure.

  Each node is:
  - `{:element, tag, attrs, children, meta}` for HTML elements
  - `{:text, content}` for text nodes
  - `{:expr, code, meta}` for Elixir expressions
  - `{:component, module, attrs, slots, meta}` for components
  """
  def parse(tokens) do
    {tree, []} = parse_children(tokens, [])
    tree
  end

  defp parse_children([], acc), do: {Enum.reverse(acc), []}

  defp parse_children([{:close, :tag, _name, _meta} | _rest] = tokens, acc) do
    {Enum.reverse(acc), tokens}
  end

  defp parse_children([{:tag, name, attrs, meta} | rest], acc) do
    case meta[:closing] do
      closing when closing in [:self, :void] ->
        # Self-closing tag or void element (like input, br, img)
        node = {:element, name, parse_attrs(attrs), [], meta}
        parse_children(rest, [node | acc])

      _ ->
        # Opening tag - find children until close tag
        {children, rest2} = parse_children(rest, [])

        # Pop the close tag
        rest3 =
          case rest2 do
            [{:close, :tag, ^name, _} | r] -> r
            _ -> rest2
          end

        node = {:element, name, parse_attrs(attrs), children, meta}
        parse_children(rest3, [node | acc])
    end
  end

  defp parse_children([{:text, content, _meta} | rest], acc) do
    node = {:text, content}
    parse_children(rest, [node | acc])
  end

  defp parse_children([{:expr, code, meta} | rest], acc) do
    node = {:expr, code, meta}
    parse_children(rest, [node | acc])
  end

  # body_expr is the token type for expressions inside element content
  # like {Map.get(@labels, v, humanize(v))} in button text
  defp parse_children([{:body_expr, code, meta} | rest], acc) do
    node = {:expr, code, meta}
    parse_children(rest, [node | acc])
  end

  defp parse_children([{:special_attr, type, name, value, meta} | rest], acc) do
    # Handle :for, :if, :let etc - these modify the parent element
    # For now, include as a special node
    node = {:special_attr, type, name, value, meta}
    parse_children(rest, [node | acc])
  end

  defp parse_children([_unknown | rest], acc) do
    # Skip unknown tokens for now
    parse_children(rest, acc)
  end

  defp parse_attrs(attrs) do
    Enum.map(attrs, fn
      # Tokenizer returns 3-tuples: {name, value, meta}
      {name, {:expr, code, expr_meta}, _attr_meta} ->
        {name, {:expr, code, expr_meta}}

      {name, {:string, value, _str_meta}, _attr_meta} ->
        {name, {:string, value}}

      {name, nil, _attr_meta} ->
        {name, {:boolean, true}}

      # Also handle 2-tuples in case format varies
      {name, {:expr, code, meta}} ->
        {name, {:expr, code, meta}}

      {name, {:string, value, _meta}} ->
        {name, {:string, value}}

      {name, nil} ->
        {name, {:boolean, true}}

      other ->
        other
    end)
  end

  @doc """
  Extracts Lavash-specific attributes from parsed tree.

  Returns a map with:
  - `:actions` - List of optimistic actions found
  - `:derives` - List of derive expressions (class, text, etc.)
  - `:loops` - List of :for loop contexts
  """
  def extract_lavash_attrs(tree) do
    extract_lavash_attrs(tree, %{actions: [], derives: [], loops: []}, %{})
  end

  defp extract_lavash_attrs(nodes, acc, context) when is_list(nodes) do
    Enum.reduce(nodes, acc, &extract_lavash_attrs(&1, &2, context))
  end

  defp extract_lavash_attrs({:element, _tag, attrs, children, _meta}, acc, context) do
    # Check for :for special attribute in this element
    context =
      case find_for_context(attrs) do
        nil -> context
        for_ctx -> Map.put(context, :for, for_ctx)
      end

    acc =
      Enum.reduce(attrs, acc, fn
        {"l-optimistic", {:string, action_name}}, acc ->
          # Find associated phx-click and phx-value-* attrs
          phx_click = find_attr(attrs, "phx-click")
          phx_values = find_phx_values(attrs)

          action = %{
            name: action_name,
            event: phx_click,
            params: phx_values,
            context: context
          }

          %{acc | actions: [action | acc.actions]}

        {"l-class", expr}, acc ->
          derive = %{type: :class, expr: expr, context: context}
          %{acc | derives: [derive | acc.derives]}

        {"l-text", expr}, acc ->
          derive = %{type: :text, expr: expr, context: context}
          %{acc | derives: [derive | acc.derives]}

        _, acc ->
          acc
      end)

    extract_lavash_attrs(children, acc, context)
  end

  defp extract_lavash_attrs({:text, _}, acc, _ctx), do: acc
  defp extract_lavash_attrs({:expr, _, _}, acc, _ctx), do: acc
  defp extract_lavash_attrs({:special_attr, :for, _, value, _}, acc, _ctx) do
    # Track :for loops at the top level
    %{acc | loops: [{:for, value} | acc.loops]}
  end
  defp extract_lavash_attrs({:special_attr, _, _, _, _}, acc, _ctx), do: acc

  # Parse :for attribute to extract loop variable and collection
  defp find_for_context(attrs) do
    case Enum.find(attrs, fn {name, _} -> name == ":for" end) do
      {":for", {:expr, code, _}} ->
        # Parse "item <- @items" to extract {var, collection}
        parse_for_expr(code)

      _ ->
        nil
    end
  end

  # Parse a for comprehension expression like "item <- @items"
  defp parse_for_expr(code) do
    case Code.string_to_quoted(code) do
      {:ok, {:<-, _, [{var, _, _}, collection]}} when is_atom(var) ->
        %{var: var, collection: collection}

      _ ->
        nil
    end
  end

  defp find_attr(attrs, name) do
    case Enum.find(attrs, fn {n, _} -> n == name end) do
      {_, {:string, value}} -> value
      {_, {:expr, code, _}} -> {:expr, code}
      _ -> nil
    end
  end

  defp find_phx_values(attrs) do
    attrs
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "phx-value-") end)
    |> Enum.map(fn {name, value} ->
      param_name = String.replace_prefix(name, "phx-value-", "")
      {param_name, value}
    end)
  end

  @doc """
  Generates JavaScript from extracted Lavash attributes.
  """
  def generate_js(lavash_attrs) do
    action_fns =
      lavash_attrs.actions
      |> Enum.map(&generate_action_js/1)
      |> Enum.join("\n")

    derive_fns =
      lavash_attrs.derives
      |> Enum.map(&generate_derive_js/1)
      |> Enum.join("\n")

    """
    {
    #{action_fns}
    #{derive_fns}
    }
    """
  end

  defp generate_action_js(%{name: name, event: event, params: params, context: context}) do
    case context do
      %{for: %{var: var, collection: _collection}} ->
        # Check if this is an array membership toggle vs object property toggle
        # by looking at the phx-value param - if it references the loop var directly,
        # it's an array membership toggle
        case detect_action_pattern(params, var, event) do
          {:array_toggle, target_field, _value_param} ->
            # This is a toggle for array membership (like filter chips)
            """
              #{name}(state, value) {
                const current = state.#{target_field} || [];
                const #{target_field} = current.includes(value)
                  ? current.filter(v => v !== value)
                  : [...current, value];
                return { #{target_field} };
              },
            """

          {:object_toggle, field_name} ->
            # This action operates on items in a collection by id
            action_body = infer_action_body(event, var, nil)

            """
              #{name}(state, value) {
                const id = value;
                const #{field_name} = state.#{field_name}.map(#{var} => {
                  if (#{var}.id !== id) return #{var};
                  #{action_body}
                });
                return { #{field_name} };
              },
            """
        end

      _ ->
        # Simple state toggle
        """
          #{name}(state, value) {
            // Non-collection action - implement based on event: #{inspect(event)}
            return {};
          },
        """
    end
  end

  defp generate_action_js(%{name: name, event: event}) do
    """
      #{name}(state, value) {
        // Simple action for event: #{inspect(event)}
        return {};
      },
    """
  end

  # Detect if this is an array membership toggle or object property toggle
  defp detect_action_pattern(params, loop_var, event) do
    loop_var_str = to_string(loop_var)

    # Look for a param that references the loop variable directly (not .id)
    direct_var_param =
      Enum.find(params, fn {_name, value} ->
        case value do
          {:expr, code, _} -> String.trim(code) == loop_var_str
          _ -> false
        end
      end)

    case direct_var_param do
      {param_name, _} ->
        # The param directly references the loop var - this is array membership
        # The target field is inferred from the event name (toggle_roast -> roast)
        target_field = infer_target_field(event, param_name)
        {:array_toggle, target_field, param_name}

      nil ->
        # Check for .id access - this is object property toggle
        id_param = find_id_param(params)

        if id_param do
          # Get the collection name from context
          {:object_toggle, "items"}
        else
          {:object_toggle, "items"}
        end
    end
  end

  # Infer target field from event name
  # "toggle_roast" -> "roast", "select_origin" -> "origin"
  defp infer_target_field(event, param_name) do
    cond do
      String.starts_with?(event, "toggle_") ->
        String.replace_prefix(event, "toggle_", "")

      String.starts_with?(event, "select_") ->
        String.replace_prefix(event, "select_", "")

      true ->
        param_name
    end
  end

  # Find the id parameter from phx-value-* attributes
  defp find_id_param(params) do
    case Enum.find(params, fn {name, _} -> name == "id" end) do
      {"id", _} -> "id"
      _ -> nil
    end
  end

  # Extract just the field name from @field_name AST
  defp extract_field_name({:@, _, [{field_name, _, _}]}) when is_atom(field_name) do
    to_string(field_name)
  end

  defp extract_field_name(other) do
    # Fallback to full ast_to_js conversion
    Lavash.Rx.Transpiler.ast_to_js(other)
  end

  # Infer the action body from the event name
  # This provides convention-based actions for common event patterns.
  # For custom logic, define an explicit optimistic_action in your module.
  defp infer_action_body(event, var, _id_param) do
    case event do
      "toggle" <> _ ->
        "return { ...#{var}, selected: !#{var}.selected };"

      "select" <> _ ->
        "return { ...#{var}, selected: true };"

      "deselect" <> _ ->
        "return { ...#{var}, selected: false };"

      "increment" <> _ ->
        "return { ...#{var}, count: (#{var}.count || 0) + 1 };"

      "decrement" <> _ ->
        "return { ...#{var}, count: Math.max(0, (#{var}.count || 0) - 1) };"

      _ ->
        # Fallback: identity function with TODO marker
        # To add support for this event, either:
        # 1. Add a pattern match above (for convention-based events), or
        # 2. Define an explicit optimistic_action in your ClientComponent/LiveView
        "return { ...#{var} }; // TODO: implement for event '#{event}'"
    end
  end

  defp generate_derive_js(%{type: :class, expr: {:expr, code, _}, context: context}) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)

    case context do
      %{for: %{var: var, collection: collection}} ->
        # This derive generates a class map for each item in the collection
        field_name = extract_field_name(collection)
        derive_name = "#{field_name}_classes"

        # Check if we're iterating over simple values or objects
        # Simple values: for roast <- @roast_options (key is the value itself)
        # Objects: for item <- @items (key is item.id)
        key_expr = detect_key_expr(code, var)

        """
          #{derive_name}(state) {
            const result = {};
            for (const #{var} of state.#{field_name}) {
              result[#{key_expr}] = #{js_expr};
            }
            return result;
          },
        """

      _ ->
        """
          derive_class(state) {
            return #{js_expr};
          },
        """
    end
  end

  defp generate_derive_js(%{type: :text, expr: {:expr, code, _}, context: context}) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)

    case context do
      %{for: %{var: var, collection: collection}} ->
        field_name = extract_field_name(collection)
        derive_name = "#{field_name}_text"
        key_expr = detect_key_expr(code, var)

        """
          #{derive_name}(state) {
            const result = {};
            for (const #{var} of state.#{field_name}) {
              result[#{key_expr}] = #{js_expr};
            }
            return result;
          },
        """

      _ ->
        """
          derive_text(state) {
            return #{js_expr};
          },
        """
    end
  end

  defp generate_derive_js(%{type: type, expr: {:expr, code, _}}) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)

    """
      derive_#{type}(state) {
        return #{js_expr};
      },
    """
  end

  defp generate_derive_js(_), do: ""

  # Detect what to use as the key for the result map
  # If the expression uses var.something, it's an object and we use var.id
  # If it uses var directly, it's a simple value and we use var
  defp detect_key_expr(code, var) do
    var_str = to_string(var)

    # Check if the expression contains var.something (object access)
    if String.contains?(code, "#{var_str}.") do
      "#{var_str}.id"
    else
      var_str
    end
  end


  @doc """
  Debug helper to inspect tokenization and parsing.
  """
  def debug(source) do
    tokens = tokenize(source)
    tree = parse(tokens)
    lavash = extract_lavash_attrs(tree)

    %{
      tokens: tokens,
      tree: tree,
      lavash: lavash,
      js: generate_js(lavash)
    }
  end

  # ===========================================================================
  # JS Render Function Generation
  # ===========================================================================
  #
  # Transpiles a HEEx template to a JavaScript render function that produces
  # HTML as a template literal string. This allows the client to fully own
  # the DOM during optimistic updates.
  #
  # Input (HEEx):
  #   <div class="flex gap-2">
  #     <button :for={v <- @values} class={if v in @selected, do: "active", else: "inactive"}>
  #       {humanize(v)}
  #     </button>
  #     <span :if={@show_count}>({@count} selected)</span>
  #   </div>
  #
  # Output (JS render function):
  #   render(state) {
  #     return `<div class="flex gap-2">${state.values.map(v =>
  #       `<button class="${state.selected.includes(v) ? "active" : "inactive"}">${
  #         humanize(v)
  #       }</button>`
  #     ).join('')}${state.show_count ? `<span>(${state.count} selected)</span>` : ''}</div>`;
  #   }
  #
  # ===========================================================================

  @doc """
  Generates a JS render function from a parsed template tree.

  Returns a JavaScript function body that takes `state` and returns an HTML string.
  """
  def generate_js_render(tree) do
    # tree_to_js_parts returns raw parts without wrapper backticks
    parts = tree_to_js_parts(tree, %{})
    body = "`" <> Enum.join(parts, "") <> "`"
    """
    render(state) {
      return #{body};
    }
    """
  end

  @doc """
  Generates a JS render function from template source.

  Convenience wrapper that tokenizes, parses, and generates in one call.

  ## Example

      iex> source = ~S(<button :for={v <- @values} class={if v in @selected, do: "on", else: "off"}>{v}</button>)
      iex> Lavash.Template.generate_js_render_from_source(source)
      # => render(state) { return `${state.values.map(v => `<button class="${state.selected.includes(v) ? "on" : "off"}">${v}</button>`).join('')}`; }
  """
  def generate_js_render_from_source(source) do
    source
    |> tokenize()
    |> parse()
    |> generate_js_render()
  end

  # Convert parsed tree nodes to JS template literal parts (without wrapper backticks)
  # Returns a list of string parts that can be joined into a template literal body
  defp tree_to_js_parts(nodes, ctx) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_js_parts(&1, ctx))
  end

  # Single node to parts
  defp node_to_js_parts({:text, content}, _ctx) do
    escaped = content
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("${", "\\${")
    [escaped]
  end

  # Expression node (like {humanize(v)} or {@field})
  defp node_to_js_parts({:expr, code, _meta}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    ["${#{js_expr}}"]
  end

  # Element with :for special attribute
  defp node_to_js_parts({:element, tag, attrs, children, meta}, ctx) do
    case find_special_attr(attrs, :for) do
      {:for, for_expr} ->
        # Parse the for expression: "v <- @values"
        {var, collection_js} = parse_for_to_js(for_expr)

        # Remove :for from attrs and recurse with var in context
        attrs_without_for = reject_special_attr(attrs, :for)
        new_ctx = Map.put(ctx, :loop_var, var)

        inner = render_element_wrapped(tag, attrs_without_for, children, meta, new_ctx)

        # Wrap in map().join('')
        ["${#{collection_js}.map(#{var} => #{inner}).join('')}"]

      nil ->
        # Check for :if
        case find_special_attr(attrs, :if) do
          {:if, if_expr} ->
            # Parse condition
            condition_js = Lavash.Rx.Transpiler.to_js(if_expr)

            # Remove :if from attrs and render normally
            attrs_without_if = reject_special_attr(attrs, :if)
            inner = render_element_wrapped(tag, attrs_without_if, children, meta, ctx)

            # Wrap in ternary
            ["${#{condition_js} ? #{inner} : ''}"]

          nil ->
            # Regular element - return inline parts
            render_element_parts(tag, attrs, children, meta, ctx)
        end
    end
  end

  # Special attribute node (standalone - shouldn't happen in well-formed input)
  defp node_to_js_parts({:special_attr, _, _, _, _}, _ctx), do: []

  # HTML void elements that cannot have children and must not have closing tags
  @void_elements ~w(area base br col embed hr img input link meta source track wbr)

  # Render element parts inline (no wrapper backticks)
  defp render_element_parts(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        ["<#{tag}#{attrs_js}>"]
      else
        ["<#{tag}#{attrs_js}></#{tag}>"]
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      ["<#{tag}#{attrs_js}>"] ++ children_parts ++ ["</#{tag}>"]
    end
  end

  # Render element wrapped in backticks (for use inside map/ternary)
  defp render_element_wrapped(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        "`<#{tag}#{attrs_js}>`"
      else
        "`<#{tag}#{attrs_js}></#{tag}>`"
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      children_js = Enum.join(children_parts, "")
      "`<#{tag}#{attrs_js}>#{children_js}</#{tag}>`"
    end
  end

  # Render attributes to JS - handles static strings and expressions
  defp render_attrs_to_js(attrs, ctx) do
    attrs
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, ":") end)
    |> Enum.map(fn {name, value} -> render_attr_to_js(name, value, ctx) end)
    |> Enum.join("")
  end

  # Static string attribute
  defp render_attr_to_js(name, {:string, value}, _ctx) do
    # Escape for HTML attribute
    escaped = escape_attr_value(value)
    " #{name}=\"#{escaped}\""
  end

  # Expression attribute (like class={expr} or data-value={v})
  defp render_attr_to_js(name, {:expr, code, _}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    " #{name}=\"${#{js_expr}}\""
  end

  # Boolean attribute
  defp render_attr_to_js(name, {:boolean, true}, _ctx) do
    " #{name}"
  end

  defp render_attr_to_js(_name, {:boolean, false}, _ctx) do
    ""
  end

  # Fallback
  defp render_attr_to_js(_name, _value, _ctx), do: ""

  # Escape attribute value for HTML
  defp escape_attr_value(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Find a special attribute by type
  defp find_special_attr(attrs, type) do
    key = ":#{type}"
    case Enum.find(attrs, fn {name, _} -> name == key end) do
      {^key, {:expr, code, _}} -> {type, code}
      _ -> nil
    end
  end

  # Remove a special attribute
  defp reject_special_attr(attrs, type) do
    key = ":#{type}"
    Enum.reject(attrs, fn {name, _} -> name == key end)
  end

  # Parse a for comprehension to JS: "v <- @values" -> {"v", "state.values"}
  defp parse_for_to_js(code) do
    case Code.string_to_quoted(code) do
      {:ok, {:<-, _, [{var, _, _}, collection]}} when is_atom(var) ->
        {to_string(var), Lavash.Rx.Transpiler.ast_to_js(collection)}

      _ ->
        # Fallback
        {"item", "[]"}
    end
  end
end
