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

  # nil literal
  defp ast_to_js(nil) do
    "null"
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

  # List concatenation with ++ -> [...list1, ...list2]
  defp ast_to_js({:++, _, [left, right]}) do
    "[...#{ast_to_js(left)}, ...#{ast_to_js(right)}]"
  end

  # Enum.reject(list, fn x -> expr end) -> list.filter(x => !expr)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [list, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.filter(#{var_str} => !(#{body_js})))"
  end

  # Enum.reject with capture: Enum.reject(list, &(&1 == val)) -> list.filter(x => x !== val)
  defp ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [list, {:&, _, [{:==, _, [{:&, _, [1]}, val]}]}]}) do
    val_js = ast_to_js(val)
    "(#{ast_to_js(list)}.filter(x => x !== #{val_js}))"
  end

  # String interpolation: "#{expr}" -> template literal `${expr}`
  # AST form: {:<<>>, _, [part1, part2, ...]}
  # where parts are either strings or {:"::", _, [expr, {:binary, _, _}]}
  defp ast_to_js({:<<>>, _, parts}) do
    js_parts =
      Enum.map(parts, fn
        # Plain string part
        str when is_binary(str) ->
          # Escape backticks and ${
          str
          |> String.replace("\\", "\\\\")
          |> String.replace("`", "\\`")
          |> String.replace("${", "\\${")

        # Interpolation: {:"::", _, [{expr}, {:binary, _, _}]}
        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, {:binary, _, _}]} ->
          "${#{ast_to_js(expr)}}"

        # Interpolation variant without to_string wrapper
        {:"::", _, [expr, {:binary, _, _}]} ->
          "${#{ast_to_js(expr)}}"

        other ->
          "${#{ast_to_js(other)}}"
      end)

    "`#{Enum.join(js_parts, "")}`"
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
    // Generated JS hook with client-side rendering
    function humanize(value) {
      return String(value).replace(/_/g, ' ').replace(/^\\w/, c => c.toUpperCase());
    }

    export default {
      mounted() {
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.calculations = #{calc_names_json};
        this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");
        this.pendingCount = 0;
        this.clickHandler = this.handleClick.bind(this);
        this.keydownHandler = this.handleKeydown.bind(this);
        this.inputHandler = this.handleInput.bind(this);
        this.el.addEventListener("click", this.clickHandler, true);
        this.el.addEventListener("keydown", this.keydownHandler, true);
        this.el.addEventListener("input", this.inputHandler, true);
        this.el.__lavash_hook__ = this;
      },

      updated() {
        // Server patch arrived - accept if no optimistic actions pending
        if (this.pendingCount === 0) {
          // Sync our state with server's authoritative state
          this.state = JSON.parse(this.el.dataset.lavashState || "{}");
          this.runCalculations();
        }
        // If pendingCount > 0, ignore server patch - client owns DOM
      },

    #{calc_js}#{calc_comma}

      runCalculations() {
        for (const name of this.calculations) {
          if (typeof this[name] === 'function') {
            this.state[name] = this[name](this.state);
          }
        }
      },

      render(state) {
        return #{render_body};
      },

      updateDOM() {
        const newHtml = this.render(this.state);
        const temp = document.createElement('div');
        temp.innerHTML = newHtml;
        if (temp.firstElementChild && window.morphdom) {
          const currentChild = this.el.firstElementChild;
          const newChild = temp.firstElementChild;
          if (currentChild && newChild) {
            window.morphdom(currentChild, newChild, {
              onBeforeElUpdated(fromEl, toEl) {
                // Preserve elements marked for server-only rendering
                if (fromEl.hasAttribute('data-lavash-preserve')) {
                  return false; // Skip this element and its children
                }
                return true;
              }
            });
          } else {
            this.el.innerHTML = newHtml;
          }
        } else {
          this.el.innerHTML = newHtml;
        }
      },

      handleInput(e) {
        // Stop input events from propagating to parent hooks
        // This prevents parent LiveView from overwriting state.tags with string input value
        const target = e.target.closest("[data-optimistic-field]");
        if (target) {
          e.stopPropagation();
        }
      },

      handleKeydown(e) {
        if (e.key !== "Enter") return;

        const input = e.target;
        const action = input.dataset.optimistic;
        const field = input.dataset.optimisticField;

        // Only handle "add" actions on Enter
        if (action !== "add" || !field) return;

        e.preventDefault();
        e.stopPropagation();
        const value = input.value.trim();
        if (!value) return;

        const current = this.state[field] || [];

        // Check for max limit (convention: max_<field> e.g. max_tags)
        const maxKey = `max_${field}`;
        const maxLimit = this.state[maxKey];
        if (maxLimit && current.length >= maxLimit) return;

        // Check for duplicate
        if (current.includes(value)) {
          input.value = "";
          return;
        }

        this.pendingCount++;

        // Apply optimistic add
        this.applyOptimisticAction("add", field, value);
        this.runCalculations();
        this.updateDOM();
        this.syncParentUrl();

        // Clear input after re-render (need to find it again)
        const newInput = this.el.querySelector(`[data-optimistic="add"][data-optimistic-field="${field}"]`);
        if (newInput) newInput.value = "";

        // Send to server - use field-specific event name
        const phxEvent = `add_${field.replace(/s$/, '')}`;
        this.pushEventTo(this.el, phxEvent, { val: value }, () => {
          this.pendingCount--;
        });
      },

      handleClick(e) {
        const target = e.target.closest("[data-optimistic]");
        if (!target) return;

        const action = target.dataset.optimistic;
        const field = target.dataset.optimisticField;
        const value = target.dataset.optimisticValue;

        // Skip non-click actions (handled by other listeners)
        if (action === "add" && !value) return;

        e.stopPropagation();

        // Increment pending count - client now owns DOM until server catches up
        this.pendingCount++;

        this.applyOptimisticAction(action, field, value);
        this.runCalculations();
        this.updateDOM();
        this.syncParentUrl();

        // Send to server - use field-specific event name for routing
        const phxEvent = target.dataset.phxClick || `${action}_${field.replace(/s$/, '')}`;
        this.pushEventTo(this.el, phxEvent, { val: value }, () => {
          this.pendingCount--;
        });
      },

      applyOptimisticAction(action, field, value) {
        const current = this.state[field] || [];

        if (action === "toggle") {
          if (current.includes(value)) {
            this.state[field] = current.filter(v => v !== value);
          } else {
            this.state[field] = [...current, value];
          }
        } else if (action === "remove") {
          this.state[field] = current.filter(v => v !== value);
        } else if (action === "add") {
          if (!current.includes(value)) {
            this.state[field] = [...current, value];
          }
        }
      },

      syncParentUrl() {
        if (Object.keys(this.bindings).length === 0) return;
        const parentRoot = document.getElementById("lavash-optimistic-root");
        if (!parentRoot || !parentRoot.__lavash_hook__) return;
        const parentHook = parentRoot.__lavash_hook__;
        const changedFields = [];
        for (const [localField, parentField] of Object.entries(this.bindings)) {
          const value = this.state[localField];
          if (value !== undefined) {
            parentHook.state[parentField] = value;
            // Mark as pending so parent rejects stale server patches for this field
            parentHook.pending[parentField] = value;
            changedFields.push(parentField);
          }
        }
        // Bump parent's client version so stale server patches are rejected
        if (changedFields.length > 0) {
          parentHook.clientVersion++;
        }
        // Recompute parent's derives that depend on the changed fields
        if (changedFields.length > 0 && typeof parentHook.recomputeDerives === 'function') {
          parentHook.recomputeDerives(changedFields);
        }
        // Update parent's DOM to reflect new derived values
        if (typeof parentHook.updateDOM === 'function') {
          parentHook.updateDOM();
        }
        if (typeof parentHook.syncUrl === 'function') {
          parentHook.syncUrl();
        }
      },

      destroyed() {
        if (this.clickHandler) {
          this.el.removeEventListener("click", this.clickHandler, true);
        }
        if (this.keydownHandler) {
          this.el.removeEventListener("keydown", this.keydownHandler, true);
        }
        if (this.inputHandler) {
          this.el.removeEventListener("input", this.inputHandler, true);
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
end
