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
  defp ast_to_js({op, _, [left, right]}) when op in [:==, :!=, :&&, :||, :and, :or] do
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

  # Generate HEEx that includes a <template> tag for client-side rendering
  defp generate_heex_with_template(source, _tree) do
    # For now, pass through the source but wrap dynamic regions
    # The actual implementation would mark regions for phx-update="ignore"
    source
  end

  # Generate a JS function that renders the template
  # Uses Shadow DOM for isolation and morphdom for efficient DOM diffing
  defp generate_js_render_function(tree) do
    render_code = tree_to_js_render(tree, "root", 0)

    """
    // Generated JS render function with Shadow DOM + morphdom
    export default {
      mounted() {
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.pending = {};
        this.serverVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
        this.clientVersion = this.serverVersion;

        // Create Shadow DOM for isolation from LiveView patching
        this.shadow = this.el.attachShadow({ mode: 'open' });

        // Copy styles into shadow DOM (inherit from light DOM)
        this.injectStyles();

        // Create render container inside shadow
        this.container = document.createElement('div');
        this.shadow.appendChild(this.container);

        // Initial render
        this.render();

        // Handle clicks - use shadow root for event delegation
        this.shadow.addEventListener("click", this.handleClick.bind(this), true);
      },

      injectStyles() {
        // Adopt stylesheets if supported (modern browsers)
        if (document.adoptedStyleSheets && this.shadow.adoptedStyleSheets !== undefined) {
          this.shadow.adoptedStyleSheets = [...document.adoptedStyleSheets];
        } else {
          // Fallback: copy all stylesheets
          const styles = document.querySelectorAll('link[rel="stylesheet"], style');
          styles.forEach(style => {
            this.shadow.appendChild(style.cloneNode(true));
          });
        }
      },

      handleClick(e) {
        const target = e.target.closest("[data-optimistic]");
        if (!target) return;

        const actionName = target.dataset.optimistic;
        const value = target.dataset.optimisticValue;

        // Run optimistic update
        this.runOptimisticAction(actionName, value);

        // Dispatch the original phx-click event to LiveView
        // We need to bubble this up through the shadow boundary
        const phxEvent = target.dataset.phxClick || actionName.replace("toggle_", "toggle");
        this.el.dispatchEvent(new CustomEvent("phx:click", {
          bubbles: true,
          detail: { event: phxEvent, value: { val: value } }
        }));

        // Also trigger the actual phx-click by finding and clicking a hidden trigger
        // or by sending directly via pushEvent
        if (this.el.phxHook) {
          this.el.phxHook.pushEvent(phxEvent, { val: value });
        }
      },

      runOptimisticAction(actionName, value) {
        this.clientVersion++;

        // Default array toggle action
        if (actionName.startsWith("toggle_")) {
          const field = actionName.replace("toggle_", "");
          const current = this.state[field] || [];
          if (current.includes(value)) {
            this.state[field] = current.filter(v => v !== value);
          } else {
            this.state[field] = [...current, value];
          }
          this.pending[field] = this.state[field];
        }

        this.render();
      },

      render() {
        const state = this.state;

        // Build new DOM in a fragment
        const root = document.createElement('div');

    #{render_code}

        // Use morphdom to efficiently diff and patch
        if (window.morphdom) {
          morphdom(this.container, root, {
            childrenOnly: false,
            onBeforeElUpdated: (fromEl, toEl) => {
              // Preserve focus state
              if (fromEl === document.activeElement) {
                return false;
              }
              return true;
            }
          });
        } else {
          // Fallback: replace innerHTML
          this.container.innerHTML = root.innerHTML;
        }
      },

      updated() {
        const serverState = JSON.parse(this.el.dataset.lavashState || "{}");
        const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);

        if (newServerVersion >= this.clientVersion) {
          this.serverVersion = newServerVersion;
          this.state = { ...serverState };
          this.pending = {};
        } else {
          for (const [key, serverValue] of Object.entries(serverState)) {
            if (!(key in this.pending)) {
              this.state[key] = serverValue;
            }
          }
        }

        this.render();
      },

      destroyed() {
        this.shadow.removeEventListener("click", this.handleClick.bind(this), true);
      }
    };
    """
  end

  # Convert parsed tree to JS render code
  defp tree_to_js_render(nodes, parent_var, depth) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, idx} ->
      tree_to_js_render(node, parent_var, depth, idx)
    end)
    |> Enum.join("\n")
  end

  defp tree_to_js_render({:element, tag, attrs, children, _meta}, parent_var, depth, idx) do
    indent = String.duplicate("    ", depth + 2)
    el_var = "el_#{depth}_#{idx}"

    # Check for :for loop
    for_attr = Enum.find(attrs, fn {name, _} -> name == ":for" end)

    if for_attr do
      {":for", {:expr, for_code, _}} = for_attr
      # Parse "item <- @items" pattern
      case parse_for_expr(for_code) do
        %{var: loop_var, collection: collection} ->
          coll_js = ast_to_js(collection)
          loop_var_str = to_string(loop_var)

          # Filter out :for from attrs for the inner element
          inner_attrs = Enum.reject(attrs, fn {name, _} -> name == ":for" end)
          attrs_js = attrs_to_js(inner_attrs, loop_var_str, el_var)
          children_js = tree_to_js_render(children, el_var, depth + 1)

          """
          #{indent}for (const #{loop_var_str} of #{coll_js}) {
          #{indent}  const #{el_var} = document.createElement('#{tag}');
          #{attrs_js}
          #{children_js}
          #{indent}  #{parent_var}.appendChild(#{el_var});
          #{indent}}
          """

        nil ->
          # Fallback if we can't parse the for expression
          attrs_js = attrs_to_js(attrs, nil, el_var)
          children_js = tree_to_js_render(children, el_var, depth + 1)

          """
          #{indent}const #{el_var} = document.createElement('#{tag}');
          #{attrs_js}
          #{children_js}
          #{indent}#{parent_var}.appendChild(#{el_var});
          """
      end
    else
      attrs_js = attrs_to_js(attrs, nil, el_var)
      children_js = tree_to_js_render(children, el_var, depth + 1)

      """
      #{indent}const #{el_var} = document.createElement('#{tag}');
      #{attrs_js}
      #{children_js}
      #{indent}#{parent_var}.appendChild(#{el_var});
      """
    end
  end

  defp tree_to_js_render({:text, content}, parent_var, depth, _idx) do
    indent = String.duplicate("    ", depth + 2)
    trimmed = String.trim(content)
    if trimmed == "" do
      ""
    else
      """
      #{indent}#{parent_var}.appendChild(document.createTextNode(#{Jason.encode!(trimmed)}));
      """
    end
  end

  defp tree_to_js_render({:expr, code, _meta}, parent_var, depth, _idx) do
    indent = String.duplicate("    ", depth + 2)
    js_expr = elixir_to_js(code)
    """
    #{indent}#{parent_var}.appendChild(document.createTextNode(#{js_expr}));
    """
  end

  defp tree_to_js_render(_, _parent_var, _depth, _idx), do: ""

  # Convert attrs to JS code that sets them on an element
  defp attrs_to_js(attrs, loop_var, el_var) do
    attrs
    |> Enum.map(fn
      {name, {:expr, code, _}} when name == "class" ->
        js_expr = elixir_to_js_with_loop_var(code, loop_var)
        "        #{el_var}.className = #{js_expr};"

      {name, {:string, value}} when name == "class" ->
        "        #{el_var}.className = #{Jason.encode!(value)};"

      {"phx-click", {:string, value}} ->
        "        #{el_var}.dataset.optimistic = #{Jason.encode!(value)};"

      {"phx-value-" <> _param_name, {:expr, code, _}} ->
        js_expr = elixir_to_js_with_loop_var(code, loop_var)
        "        #{el_var}.dataset.optimisticValue = #{js_expr};"

      {name, {:expr, code, _}} when name not in [":for", ":if"] ->
        js_expr = elixir_to_js_with_loop_var(code, loop_var)
        "        #{el_var}.setAttribute(#{Jason.encode!(name)}, #{js_expr});"

      {name, {:string, value}} when name not in [":for", ":if"] ->
        "        #{el_var}.setAttribute(#{Jason.encode!(name)}, #{Jason.encode!(value)});"

      _ ->
        ""
    end)
    |> Enum.filter(&(&1 != ""))
    |> Enum.join("\n")
  end

  # Convert Elixir to JS, handling loop variable references
  defp elixir_to_js_with_loop_var(code, nil), do: elixir_to_js(code)
  defp elixir_to_js_with_loop_var(code, loop_var) do
    # Replace references to the loop variable
    code
    |> Code.string_to_quoted!()
    |> ast_to_js_with_loop_var(loop_var)
  end

  defp ast_to_js_with_loop_var({:if, _, [condition, [do: do_clause, else: else_clause]]}, loop_var) do
    cond_js = ast_to_js_with_loop_var(condition, loop_var)
    do_js = ast_to_js_with_loop_var(do_clause, loop_var)
    else_js = ast_to_js_with_loop_var(else_clause, loop_var)
    "(#{cond_js} ? #{do_js} : #{else_js})"
  end

  defp ast_to_js_with_loop_var({:@, _, [{var_name, _, _}]}, _loop_var) when is_atom(var_name) do
    "state.#{var_name}"
  end

  defp ast_to_js_with_loop_var({var_name, _, nil}, loop_var) when is_atom(var_name) do
    if to_string(var_name) == loop_var do
      loop_var
    else
      to_string(var_name)
    end
  end

  defp ast_to_js_with_loop_var({var_name, _, context}, loop_var) when is_atom(var_name) and is_atom(context) do
    if to_string(var_name) == loop_var do
      loop_var
    else
      to_string(var_name)
    end
  end

  # Enum.member? with loop var
  defp ast_to_js_with_loop_var({{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, _, [list, val]}, loop_var) do
    "#{ast_to_js_with_loop_var(list, loop_var)}.includes(#{ast_to_js_with_loop_var(val, loop_var)})"
  end

  # in operator
  defp ast_to_js_with_loop_var({:in, _, [val, list]}, loop_var) do
    "#{ast_to_js_with_loop_var(list, loop_var)}.includes(#{ast_to_js_with_loop_var(val, loop_var)})"
  end

  defp ast_to_js_with_loop_var(str, _loop_var) when is_binary(str), do: Jason.encode!(str)
  defp ast_to_js_with_loop_var(num, _loop_var) when is_number(num), do: to_string(num)
  defp ast_to_js_with_loop_var(bool, _loop_var) when is_boolean(bool), do: to_string(bool)

  defp ast_to_js_with_loop_var(other, _loop_var), do: ast_to_js(other)

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
