defmodule Lavash.Template do
  @moduledoc """
  Unified template compilation that generates both server-side HEEx and client-side JS
  from a single template source.

  This module provides utilities for parsing HEEx templates and generating:
  1. Standard Phoenix.LiveView.Rendered structs for server-side rendering
  2. JavaScript functions for client-side optimistic updates (via colocated hooks)

  ## Example

      defmodule MyComponent do
        use Lavash.LiveComponent

        bind :selected, {:array, :string}

        # Template DSL that generates both HEEx and a colocated hook
        template :chips do
          ~T\"\"\"
          <button
            :for={value <- @values}
            l-optimistic="toggle_selected"
            l-optimistic-value={value}
            l-class={if value in @selected, do: @active_class, else: @inactive_class}
          >
            {value}
          </button>
          \"\"\"
        end
      end

  The `l-` prefixed attributes are Lavash-specific and control JS generation:
  - `l-optimistic` - Names the optimistic action function to generate
  - `l-optimistic-value` - The value passed to the action function
  - `l-class` - Generates a class derive function (updates element className)
  - `l-text` - Generates a text content derive function

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
      :self ->
        # Self-closing tag
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
    ast_to_js(other)
  end

  # Infer the action body from the event name
  defp infer_action_body(event, var, _id_param) do
    case event do
      "toggle" <> _ ->
        "return { ...#{var}, selected: !#{var}.selected };"

      "select" <> _ ->
        "return { ...#{var}, selected: true };"

      "deselect" <> _ ->
        "return { ...#{var}, selected: false };"

      _ ->
        "return { ...#{var} }; // TODO: implement for event '#{event}'"
    end
  end

  defp generate_derive_js(%{type: :class, expr: {:expr, code, _}, context: context}) do
    js_expr = elixir_to_js(code)

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
    js_expr = elixir_to_js(code)

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
    js_expr = elixir_to_js(code)

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
  Translates Elixir expression code to JavaScript.

  Handles common patterns:
  - `if cond, do: x, else: y` -> `cond ? x : y`
  - `@var` -> `state.var`
  - `item.field` -> `item.field`
  - `Enum.member?(list, val)` -> `list.includes(val)`
  """
  def elixir_to_js(code) when is_binary(code) do
    code
    |> Code.string_to_quoted!()
    |> ast_to_js()
  end

  defp ast_to_js({:if, _, [condition, [do: do_clause, else: else_clause]]}) do
    cond_js = ast_to_js(condition)
    do_js = ast_to_js(do_clause)
    else_js = ast_to_js(else_clause)
    "(#{cond_js} ? #{do_js} : #{else_js})"
  end

  defp ast_to_js({:if, _, [condition, [do: do_clause]]}) do
    cond_js = ast_to_js(condition)
    do_js = ast_to_js(do_clause)
    "(#{cond_js} ? #{do_js} : null)"
  end

  # @variable -> state.variable
  defp ast_to_js({:@, _, [{var_name, _, _}]}) when is_atom(var_name) do
    "state.#{var_name}"
  end

  # Enum.member?(list, val) -> list.includes(val)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, _, [list, val]}) do
    "#{ast_to_js(list)}.includes(#{ast_to_js(val)})"
  end

  # Map.get(map, key) -> map[key]
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [map, key]}) do
    "#{ast_to_js(map)}[#{ast_to_js(key)}]"
  end

  # Map.get(map, key, default) -> (map[key] ?? default)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [map, key, default]}) do
    "(#{ast_to_js(map)}[#{ast_to_js(key)}] ?? #{ast_to_js(default)})"
  end

  # humanize(value) -> capitalize first letter, replace underscores with spaces
  defp ast_to_js({:humanize, _, [value]}) do
    js_val = ast_to_js(value)
    "(#{js_val}.toString().replace(/_/g, ' ').replace(/^\\w/, c => c.toUpperCase()))"
  end

  # length(list) -> list.length
  defp ast_to_js({:length, _, [list]}) do
    "(#{ast_to_js(list)}.length)"
  end

  # Enum.count(list) -> list.length
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [list]}) do
    "(#{ast_to_js(list)}.length)"
  end

  # Enum.join(list, sep) -> list.join(sep)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _, [list, sep]}) do
    "(#{ast_to_js(list)}.join(#{ast_to_js(sep)}))"
  end

  # Enum.join(list) -> list.join(",")
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _, [list]}) do
    "(#{ast_to_js(list)}.join(\",\"))"
  end

  # Enum.map(list, fn x -> expr end) -> list.map(x => expr)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [list, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.map(#{var_str} => #{body_js}))"
  end

  # Enum.filter(list, fn x -> expr end) -> list.filter(x => expr)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [list, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.filter(#{var_str} => #{body_js}))"
  end

  # item.field -> item.field (dot access)
  defp ast_to_js({{:., _, [Access, :get]}, _, [obj, key]}) do
    "#{ast_to_js(obj)}[#{ast_to_js(key)}]"
  end

  defp ast_to_js({:., _, [obj, field]}) when is_atom(field) do
    "#{ast_to_js(obj)}.#{field}"
  end

  # Function call on object: item.field (alternate AST form)
  defp ast_to_js({{:., _, [obj, field]}, _, []}) when is_atom(field) do
    "#{ast_to_js(obj)}.#{field}"
  end

  # Variable reference
  defp ast_to_js({var_name, _, nil}) when is_atom(var_name) do
    to_string(var_name)
  end

  defp ast_to_js({var_name, _, context}) when is_atom(var_name) and is_atom(context) do
    to_string(var_name)
  end

  # String literal
  defp ast_to_js(str) when is_binary(str) do
    inspect(str)
  end

  # Number literal
  defp ast_to_js(num) when is_number(num) do
    to_string(num)
  end

  # Boolean literal
  defp ast_to_js(bool) when is_boolean(bool) do
    to_string(bool)
  end

  # Atom literal (convert to string)
  defp ast_to_js(atom) when is_atom(atom) do
    inspect(to_string(atom))
  end

  # List literal
  defp ast_to_js(list) when is_list(list) do
    elements = Enum.map(list, &ast_to_js/1) |> Enum.join(", ")
    "[#{elements}]"
  end

  # Binary operators
  defp ast_to_js({op, _, [left, right]}) when op in [:==, :!=, :&&, :||, :and, :or, :>, :<, :>=, :<=, :+, :-, :*, :/] do
    js_op =
      case op do
        :== -> "==="
        :!= -> "!=="
        :and -> "&&"
        :or -> "||"
        other -> to_string(other)
      end

    "(#{ast_to_js(left)} #{js_op} #{ast_to_js(right)})"
  end

  # not operator
  defp ast_to_js({:not, _, [expr]}) do
    "!#{ast_to_js(expr)}"
  end

  defp ast_to_js({:!, _, [expr]}) do
    "!#{ast_to_js(expr)}"
  end

  # "in" operator: value in list -> list.includes(value)
  defp ast_to_js({:in, _, [value, list]}) do
    "#{ast_to_js(list)}.includes(#{ast_to_js(value)})"
  end

  # String concatenation with <>
  defp ast_to_js({:<>, _, [left, right]}) do
    "(#{ast_to_js(left)} + #{ast_to_js(right)})"
  end

  # Fallback - return as comment for debugging
  defp ast_to_js(other) do
    "/* unknown: #{inspect(other)} */"
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
    js_expr = elixir_to_js(code)
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
            condition_js = elixir_to_js(if_expr)

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

  # Render element parts inline (no wrapper backticks)
  defp render_element_parts(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      ["<#{tag}#{attrs_js}></#{tag}>"]
    else
      children_parts = tree_to_js_parts(children, ctx)
      ["<#{tag}#{attrs_js}>"] ++ children_parts ++ ["</#{tag}>"]
    end
  end

  # Render element wrapped in backticks (for use inside map/ternary)
  defp render_element_wrapped(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      "`<#{tag}#{attrs_js}></#{tag}>`"
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
    js_expr = elixir_to_js(code)
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
        {to_string(var), ast_to_js(collection)}

      _ ->
        # Fallback
        {"item", "[]"}
    end
  end

  @doc """
  Compiles a template source into both HEEx and a JS render function.

  This is the main entry point for the `optimistic_template` macro.
  Returns `{heex_source, js_render_fn}` where:
  - `heex_source` is the template with phx-update="ignore" regions
  - `js_render_fn` is JavaScript code that renders the template client-side

  The JS render function:
  - Takes state as input
  - Creates DOM elements directly
  - Handles :for loops by iterating and creating elements
  - Evaluates class expressions for each element
  """
  def compile_template(source) do
    tokens = tokenize(source)
    tree = parse(tokens)

    # Generate both outputs
    heex_source = generate_heex_with_template(source, tree)
    js_render_fn = generate_js_render_function(tree)

    {heex_source, js_render_fn}
  end

  @doc """
  Compiles a template with calculation support.

  Like `compile_template/1` but also generates JS functions for each calculation,
  allowing them to run on the client side for optimistic updates.

  ## Parameters
  - `source` - The HEEx template source
  - `calculations` - List of `{name, source_string, ast}` tuples

  ## Returns
  `{heex_source, js_code}` where js_code includes calculation functions.
  """
  def compile_template_with_calculations(source, calculations) do
    tokens = tokenize(source)
    tree = parse(tokens)

    # Generate both outputs
    heex_source = generate_heex_with_template(source, tree)
    js_render_fn = generate_js_render_function_with_calculations(tree, calculations)

    {heex_source, js_render_fn}
  end

  @doc """
  Compiles a template with full client-side render support.

  Generates a JS hook that includes a `render(state)` function which
  fully regenerates the component's innerHTML from state. This allows
  the client to handle `:for` loops and `:if` conditionals.

  ## Parameters
  - `source` - The HEEx template source
  - `calculations` - List of `{name, source_string, ast}` tuples

  ## Returns
  `{heex_source, js_code}` where js_code includes the render function.
  """
  def compile_template_with_render(source, calculations) do
    tokens = tokenize(source)
    tree = parse(tokens)

    # Generate both outputs
    heex_source = generate_heex_with_template(source, tree)
    js_code = generate_js_hook_with_render(tree, calculations)

    {heex_source, js_code}
  end

  # Generate JS for calculations
  defp generate_calculation_js(calculations) do
    calculations
    |> Enum.map(fn {name, source, _ast} ->
      # Parse the source string and convert to JS
      js_expr = elixir_to_js(source)
      "    #{name}(state) {\n      return #{js_expr};\n    }"
    end)
    |> Enum.join(",\n")
  end

  # Generate a JS hook with calculation support
  defp generate_js_render_function_with_calculations(_tree, calculations) do
    calc_js = generate_calculation_js(calculations)
    calc_names = Enum.map(calculations, fn {name, _, _} -> to_string(name) end)
    calc_names_json = Jason.encode!(calc_names)
    calc_comma = if calc_js != "", do: ",", else: ""

    # Build the JS in parts to avoid heredoc interpolation issues with ternary operators
    ~s"""
    // Generated JS hook for optimistic updates with calculations
    export default {
      mounted() {
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.pendingCount = 0;
        this.calculations = #{calc_names_json};
        // Bindings map: {localField: parentField} for URL sync
        this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");

        // Store hook reference for onBeforeElUpdated callback
        this.el.__lavash_hook__ = this;

        this.clickHandler = this.handleClick.bind(this);
        this.el.addEventListener("click", this.clickHandler, true);
      },

    #{calc_js}#{calc_comma}

      runCalculations() {
        for (const name of this.calculations) {
          if (typeof this[name] === 'function') {
            this.state[name] = this[name](this.state);
          }
        }
      },

      handleClick(e) {
        const target = e.target.closest("[data-optimistic]");
        if (!target) return;

        e.stopPropagation();

        const actionName = target.dataset.optimistic;
        const value = target.dataset.optimisticValue;

        // Track pending action for onBeforeElUpdated to check
        this.pendingCount++;

        // Apply optimistic update immediately
        this.applyOptimisticAction(actionName, value);
        this.runCalculations();
        this.applyOptimisticClasses();
        this.applyOptimisticDisplays();

        // Sync URL via parent LavashOptimistic hook
        this.syncParentUrl();

        // Send to server with callback to track completion
        const phxEvent = target.dataset.phxClick || actionName.split("_")[0];
        this.pushEventTo(this.el, phxEvent, { val: value }, () => {
          this.pendingCount--;
        });
      },

      applyOptimisticAction(actionName, value) {
        if (actionName.startsWith("toggle_")) {
          const field = actionName.replace("toggle_", "");
          const current = this.state[field] || [];
          if (current.includes(value)) {
            this.state[field] = current.filter(v => v !== value);
          } else {
            this.state[field] = [...current, value];
          }
        }
      },

      applyOptimisticClasses() {
        const elements = this.el.querySelectorAll("[data-optimistic]");
        const activeClass = this.state.active_class || "";
        const inactiveClass = this.state.inactive_class || "";

        elements.forEach(el => {
          const actionName = el.dataset.optimistic;
          const value = el.dataset.optimisticValue;

          if (actionName.startsWith("toggle_")) {
            const field = actionName.replace("toggle_", "");
            const fieldState = this.state[field] || [];
            const isActive = fieldState.includes(value);
            el.className = isActive ? activeClass : inactiveClass;
          }
        });
      },

      applyOptimisticDisplays() {
        const displays = this.el.querySelectorAll("[data-optimistic-display]");

        displays.forEach(el => {
          const field = el.dataset.optimisticDisplay;
          const value = this.state[field];
          if (value !== undefined) {
            el.textContent = value;
          }
        });
      },

      updated() {
        // onBeforeElUpdated (in app.js) handles preserving optimistic visuals
        // during morphdom patches. Here we only need to sync state when server catches up.
        const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

        if (this.pendingCount === 0) {
          // No pending actions - accept server state fully
          this.state = { ...serverState };
          this.runCalculations();
        }
        // When pendingCount > 0, keep our optimistic state - visuals are already
        // preserved by onBeforeElUpdated modifying the incoming server HTML
      },

      // Sync bound fields to parent's LavashOptimistic hook for URL updates
      syncParentUrl() {
        if (Object.keys(this.bindings).length === 0) return;

        // Find parent LavashOptimistic hook
        const parentRoot = document.getElementById("lavash-optimistic-root");
        if (!parentRoot || !parentRoot.__lavash_hook__) return;

        const parentHook = parentRoot.__lavash_hook__;

        // Update parent state with bound field values
        for (const [localField, parentField] of Object.entries(this.bindings)) {
          const value = this.state[localField];
          if (value !== undefined) {
            parentHook.state[parentField] = value;
          }
        }

        // Trigger parent URL sync
        if (typeof parentHook.syncUrl === 'function') {
          parentHook.syncUrl();
        }
      },

      destroyed() {
        if (this.clickHandler) {
          this.el.removeEventListener("click", this.clickHandler, true);
        }
      }
    };
    """
  end

  # Generate a JS hook with full render support - regenerates innerHTML from state
  # This approach handles :for loops and :if conditionals properly
  defp generate_js_hook_with_render(tree, calculations) do
    calc_js = generate_calculation_js(calculations)
    calc_names = Enum.map(calculations, fn {name, _, _} -> to_string(name) end)
    calc_names_json = Jason.encode!(calc_names)
    calc_comma = if calc_js != "", do: ",", else: ""

    # Generate the render function body from the template tree
    render_parts = tree_to_js_parts(tree, %{})
    render_body = "`" <> Enum.join(render_parts, "") <> "`"

    ~s"""
    // Generated JS hook with full render support
    // Helper function for humanize
    function humanize(value) {
      return String(value).replace(/_/g, ' ').replace(/^\\w/, c => c.toUpperCase());
    }

    export default {
      mounted() {
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.pendingCount = 0;
        this.calculations = #{calc_names_json};
        // Bindings map: {localField: parentField} for URL sync
        this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");

        // Store hook reference for onBeforeElUpdated callback
        this.el.__lavash_hook__ = this;

        this.clickHandler = this.handleClick.bind(this);
        this.el.addEventListener("click", this.clickHandler, true);
      },

    #{calc_js}#{calc_comma}

      runCalculations() {
        for (const name of this.calculations) {
          if (typeof this[name] === 'function') {
            this.state[name] = this[name](this.state);
          }
        }
      },

      // Full render function - regenerates innerHTML from state
      render(state) {
        return #{render_body};
      },

      // Update DOM using morphdom for efficient diffing
      updateDOM() {
        const newHtml = this.render(this.state);
        // Create a temporary container to parse the new HTML
        const temp = document.createElement('div');
        temp.innerHTML = newHtml;
        // morphdom the first child (the actual content) into our container
        if (temp.firstElementChild && window.morphdom) {
          // If we have a single root element, morph it directly
          const currentChild = this.el.firstElementChild;
          const newChild = temp.firstElementChild;
          if (currentChild && newChild) {
            window.morphdom(currentChild, newChild);
          } else {
            // Fallback to innerHTML if structure doesn't match
            this.el.innerHTML = newHtml;
          }
        } else {
          // Fallback if morphdom not available
          this.el.innerHTML = newHtml;
        }
      },

      handleClick(e) {
        const target = e.target.closest("[data-optimistic]");
        if (!target) return;

        e.stopPropagation();

        const actionName = target.dataset.optimistic;
        const value = target.dataset.optimisticValue;

        // Track pending action for onBeforeElUpdated to check
        this.pendingCount++;

        // Apply optimistic update immediately
        this.applyOptimisticAction(actionName, value);
        this.runCalculations();

        // Re-render using morphdom for efficient updates
        this.updateDOM();

        // Sync URL via parent LavashOptimistic hook
        this.syncParentUrl();

        // Send to server with callback to track completion
        const phxEvent = target.dataset.phxClick || actionName.split("_")[0];
        this.pushEventTo(this.el, phxEvent, { val: value }, () => {
          this.pendingCount--;
        });
      },

      applyOptimisticAction(actionName, value) {
        if (actionName.startsWith("toggle_")) {
          const field = actionName.replace("toggle_", "");
          const current = this.state[field] || [];
          if (current.includes(value)) {
            this.state[field] = current.filter(v => v !== value);
          } else {
            this.state[field] = [...current, value];
          }
        }
      },

      updated() {
        // When server responds with new state
        const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

        if (this.pendingCount === 0) {
          // No pending actions - accept server state fully
          this.state = { ...serverState };
          this.runCalculations();
          // Server already rendered the DOM, no need to re-render
        }
        // When pendingCount > 0, onBeforeElUpdated preserves our innerHTML
        // so we keep the optimistic render
      },

      // Sync bound fields to parent's LavashOptimistic hook for URL updates
      syncParentUrl() {
        if (Object.keys(this.bindings).length === 0) return;

        // Find parent LavashOptimistic hook
        const parentRoot = document.getElementById("lavash-optimistic-root");
        if (!parentRoot || !parentRoot.__lavash_hook__) return;

        const parentHook = parentRoot.__lavash_hook__;

        // Update parent state with bound field values
        for (const [localField, parentField] of Object.entries(this.bindings)) {
          const value = this.state[localField];
          if (value !== undefined) {
            parentHook.state[parentField] = value;
          }
        }

        // Trigger parent URL sync
        if (typeof parentHook.syncUrl === 'function') {
          parentHook.syncUrl();
        }
      },

      destroyed() {
        if (this.clickHandler) {
          this.el.removeEventListener("click", this.clickHandler, true);
        }
      }
    };
    """
  end

  # Generate HEEx that includes a <template> tag for client-side rendering
  defp generate_heex_with_template(source, _tree) do
    # For now, pass through the source but wrap dynamic regions
    # The actual implementation would mark regions for phx-update="ignore"
    source
  end

  # Generate a JS hook that applies optimistic updates to server-rendered content
  # Server renders the actual DOM, JS only modifies classes on click
  defp generate_js_render_function(_tree) do
    """
    // Generated JS hook for optimistic updates on server-rendered content
    export default {
      mounted() {
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.serverVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
        this.clientVersion = this.serverVersion;
        this.pendingActions = []; // Track pending optimistic actions

        // Handle clicks via event delegation
        this.clickHandler = this.handleClick.bind(this);
        this.el.addEventListener("click", this.clickHandler, true);
      },

      handleClick(e) {
        const target = e.target.closest("[data-optimistic]");
        if (!target) return;

        e.stopPropagation();

        const actionName = target.dataset.optimistic;
        const value = target.dataset.optimisticValue;

        // Apply optimistic update to state
        this.clientVersion++;
        this.applyOptimisticAction(actionName, value);

        // Track this pending action so we can re-apply after server update if needed
        this.pendingActions.push({ action: actionName, value, version: this.clientVersion });

        // Apply class changes directly to DOM
        this.applyOptimisticClasses();

        // Send event to server
        const phxEvent = target.dataset.phxClick || actionName.split("_")[0];
        this.pushEventTo(this.el, phxEvent, { val: value });
      },

      applyOptimisticAction(actionName, value) {
        if (actionName.startsWith("toggle_")) {
          const field = actionName.replace("toggle_", "");
          const current = this.state[field] || [];
          if (current.includes(value)) {
            this.state[field] = current.filter(v => v !== value);
          } else {
            this.state[field] = [...current, value];
          }
        }
      },

      applyOptimisticClasses() {
        // Find all elements with data-optimistic and update their classes based on state
        const elements = this.el.querySelectorAll("[data-optimistic]");
        const activeClass = this.state.active_class || "";
        const inactiveClass = this.state.inactive_class || "";

        elements.forEach(el => {
          const actionName = el.dataset.optimistic;
          const value = el.dataset.optimisticValue;

          if (actionName.startsWith("toggle_")) {
            const field = actionName.replace("toggle_", "");
            const fieldState = this.state[field] || [];
            const isActive = fieldState.includes(value);

            el.className = isActive ? activeClass : inactiveClass;
          }
        });
      },

      updated() {
        const serverState = JSON.parse(this.el.dataset.lavashState || "{}");
        const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);

        if (newServerVersion >= this.clientVersion) {
          // Server has caught up - accept server state, clear pending
          this.serverVersion = newServerVersion;
          this.clientVersion = newServerVersion;
          this.state = { ...serverState };
          this.pendingActions = [];
          // Server DOM is authoritative, no need to re-apply classes
        } else {
          // Client is ahead - merge server state but keep pending fields
          const pendingFields = new Set(
            this.pendingActions.map(a => a.action.replace("toggle_", ""))
          );

          for (const [key, value] of Object.entries(serverState)) {
            if (!pendingFields.has(key)) {
              this.state[key] = value;
            }
          }

          // Re-apply optimistic classes since LiveView just patched the DOM
          this.applyOptimisticClasses();
        }
      },

      destroyed() {
        if (this.clickHandler) {
          this.el.removeEventListener("click", this.clickHandler, true);
        }
      }
    };
    """
  end

  @doc """
  Generates a colocated LiveView hook from extracted Lavash attributes.

  The hook follows the Phoenix LiveView 1.1 colocated hooks format:
  - Exports a default object with mounted/updated/destroyed lifecycle methods
  - Manages optimistic state and DOM updates
  - Integrates with the parent LiveView for server sync

  ## Options

  - `:hook_name` - The name of the hook (used for registration)
  - `:field_name` - The primary state field being managed
  - `:values` - Static list of values (for filter chips)
  - `:active_class` - CSS class for active/selected state
  - `:inactive_class` - CSS class for inactive state
  """
  def generate_colocated_hook(lavash_attrs, opts \\ []) do
    hook_name = Keyword.get(opts, :hook_name, "LavashOptimisticHook")
    field_name = Keyword.get(opts, :field_name)
    values = Keyword.get(opts, :values, [])
    active_class = Keyword.get(opts, :active_class, "active")
    inactive_class = Keyword.get(opts, :inactive_class, "inactive")

    # Generate action functions from extracted attrs
    action_fns = generate_hook_actions(lavash_attrs.actions, field_name)

    # Generate derive functions
    derive_fns = generate_hook_derives(lavash_attrs.derives, field_name, values, active_class, inactive_class)

    # Build the complete hook
    """
    // Generated by Lavash.Template - #{hook_name}
    // Colocated hook for optimistic updates

    export default {
      mounted() {
        // Parse initial state from data attributes
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.pending = {};
        this.serverVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
        this.clientVersion = this.serverVersion;

        // Derive names and dependency graph
        this.deriveNames = #{Jason.encode!(extract_derive_names(lavash_attrs.derives, field_name))};
        this.graph = #{generate_graph_json(lavash_attrs.derives, field_name)};

        // Optimistic functions
        this.fns = {
    #{action_fns}
    #{derive_fns}
        };

        // Set up event listeners
        this.el.addEventListener("click", this.handleClick.bind(this), true);
      },

      handleClick(e) {
        const target = e.target.closest("[data-optimistic]");
        if (!target) return;

        const actionName = target.dataset.optimistic;
        const value = target.dataset.optimisticValue;

        this.runOptimisticAction(actionName, value);

        // Clear LiveView's element lock for rapid clicks
        target.removeAttribute("data-phx-ref-src");
        target.removeAttribute("data-phx-ref-lock");
        setTimeout(() => {
          target.removeAttribute("data-phx-ref-src");
          target.removeAttribute("data-phx-ref-lock");
        }, 0);
      },

      runOptimisticAction(actionName, value) {
        const fn = this.fns[actionName];
        if (!fn) return;

        this.clientVersion++;

        try {
          const delta = fn(this.state, value);

          const changedFields = [];
          for (const [key, val] of Object.entries(delta)) {
            this.state[key] = val;
            this.pending[key] = val;
            changedFields.push(key);
          }

          this.recomputeDerives(changedFields);
          this.updateDOM();
        } catch (err) {
          console.error("[LavashOptimistic] Action error:", err);
        }
      },

      recomputeDerives(changedFields) {
        // Find affected derives via graph
        const affected = this.findAffectedDerives(changedFields);
        const sorted = this.topologicalSort(affected);

        for (const name of sorted) {
          const fn = this.fns[name];
          if (fn) {
            try {
              this.state[name] = fn(this.state);
            } catch (err) {
              // Ignore derive computation errors
            }
          }
        }
      },

      findAffectedDerives(changedFields) {
        if (!changedFields) return Object.keys(this.graph);

        const affected = new Set();
        const queue = [...changedFields];

        while (queue.length > 0) {
          const field = queue.shift();
          for (const [deriveName, meta] of Object.entries(this.graph)) {
            if (meta.deps && meta.deps.includes(field) && !affected.has(deriveName)) {
              affected.add(deriveName);
              queue.push(deriveName);
            }
          }
        }

        return Array.from(affected);
      },

      topologicalSort(deriveNames) {
        const result = [];
        const visited = new Set();
        const visiting = new Set();

        const visit = (name) => {
          if (visited.has(name) || visiting.has(name)) return;
          visiting.add(name);

          const meta = this.graph[name];
          if (meta && meta.deps) {
            for (const dep of meta.deps) {
              if (deriveNames.includes(dep)) visit(dep);
            }
          }

          visiting.delete(name);
          visited.add(name);
          result.push(name);
        };

        for (const name of deriveNames) visit(name);
        return result;
      },

      updateDOM() {
        // Update elements with data-optimistic-class
        const classElements = this.el.querySelectorAll("[data-optimistic-class]");
        classElements.forEach(el => {
          const path = el.dataset.optimisticClass;
          const [field, key] = path.split(".");
          const classMap = this.state[field];
          if (classMap && key && classMap[key]) {
            el.className = classMap[key];
          }
        });

        // Update elements with data-optimistic-display (text content)
        const displayElements = this.el.querySelectorAll("[data-optimistic-display]");
        displayElements.forEach(el => {
          const fieldName = el.dataset.optimisticDisplay;
          const value = this.state[fieldName];
          if (value !== undefined) {
            el.textContent = value;
          }
        });
      },

      updated() {
        const serverState = JSON.parse(this.el.dataset.lavashState || "{}");
        const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);

        if (newServerVersion >= this.clientVersion) {
          // Server caught up - accept all server state
          this.serverVersion = newServerVersion;
          this.state = { ...serverState };
          this.pending = {};
        } else {
          // Server stale - keep optimistic state for pending fields
          for (const [key, serverValue] of Object.entries(serverState)) {
            if (!(key in this.pending)) {
              this.state[key] = serverValue;
            }
          }
        }

        this.recomputeDerives();
        this.updateDOM();
      },

      destroyed() {
        this.el.removeEventListener("click", this.handleClick.bind(this), true);
      }
    };
    """
  end

  defp generate_hook_actions(actions, _field_name) do
    actions
    |> Enum.map(&generate_hook_action/1)
    |> Enum.join("\n")
  end

  defp generate_hook_action(%{name: name, context: %{for: %{var: _var, collection: collection}}}) do
    field = extract_field_name(collection)

    # For array toggle actions (like filter chips)
    """
          #{name}(state, value) {
            const current = state.#{field} || [];
            const #{field} = current.includes(value)
              ? current.filter(v => v !== value)
              : [...current, value];
            return { #{field} };
          },
    """
  end

  defp generate_hook_action(%{name: name}) do
    """
          #{name}(state, value) {
            // TODO: Implement action
            return {};
          },
    """
  end

  defp generate_hook_derives(derives, field_name, values, active_class, inactive_class) do
    derives
    |> Enum.map(&generate_hook_derive(&1, field_name, values, active_class, inactive_class))
    |> Enum.join("\n")
  end

  defp generate_hook_derive(%{type: :class, context: %{for: %{collection: collection}}}, field_name, values, active_class, inactive_class) do
    derive_name = "#{field_name || extract_field_name(collection)}_chips"
    values_json = Jason.encode!(values)

    """
          #{derive_name}(state) {
            const ACTIVE = #{Jason.encode!(active_class)};
            const INACTIVE = #{Jason.encode!(inactive_class)};
            const values = #{values_json};
            const selected = state.#{field_name || extract_field_name(collection)} || [];
            const result = {};
            for (const v of values) {
              result[v] = selected.includes(v) ? ACTIVE : INACTIVE;
            }
            return result;
          },
    """
  end

  defp generate_hook_derive(_, _, _, _, _), do: ""

  defp extract_derive_names(derives, field_name) do
    derives
    |> Enum.map(fn
      %{type: :class, context: %{for: %{collection: collection}}} ->
        "#{field_name || extract_field_name(collection)}_chips"
      _ ->
        nil
    end)
    |> Enum.filter(& &1)
  end

  defp generate_graph_json(derives, field_name) do
    graph =
      derives
      |> Enum.reduce(%{}, fn
        %{type: :class, context: %{for: %{collection: collection}}}, acc ->
          derive_name = "#{field_name || extract_field_name(collection)}_chips"
          field = field_name || extract_field_name(collection)
          Map.put(acc, derive_name, %{deps: [field]})

        _, acc ->
          acc
      end)

    Jason.encode!(graph)
  end
end
