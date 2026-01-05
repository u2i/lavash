defmodule Lavash.Rx do
  @moduledoc """
  A reactive expression that captures AST for isomorphic execution.

  The `rx/1` macro captures an Elixir expression at compile time, storing
  both the source string (for JS transpilation) and the transformed AST
  (for server-side evaluation).

  ## Usage

  Use `rx()` to wrap expressions in `calculate` declarations:

      calculate :tag_count, rx(length(@tags))
      calculate :can_add, rx(@max == nil or length(@items) < @max)
      calculate :doubled, rx(@count * 2)

  ## Supported Expressions

  Expressions that can be transpiled to JavaScript:
  - Arithmetic: `@count + 1`, `@price * @quantity`
  - Comparisons: `@count > 0`, `@name == "test"`
  - Boolean: `@enabled and @visible`, `not @disabled`
  - Conditionals: `if(@count > 0, do: "yes", else: "no")`
  - List operations: `length(@items)`, `@items ++ ["new"]`
  - Enum functions: `Enum.map/2`, `Enum.filter/2`, `Enum.join/2`

  ## Reusable Functions with defrx

  Use `defrx` to define functions that can be called within `rx()` expressions:

      defrx valid_expiry?(digits) do
        String.length(digits) == 4 &&
          String.to_integer(String.slice(digits, 0, 2) || "0") >= 1 &&
          String.to_integer(String.slice(digits, 0, 2) || "0") <= 12
      end

      calculate :expiry_valid, rx(valid_expiry?(@expiry_digits))

  The function body is expanded inline at each call site.

  ## Importing defrx functions from other modules

  Create a module with reusable defrx functions:

      defmodule MyApp.Validators do
        use Lavash.Rx.Functions

        defrx valid_email?(email) do
          String.length(email) > 0 && String.contains?(email, "@")
        end
      end

  Then import them in your LiveView:

      defmodule MyAppWeb.FormLive do
        use Lavash.LiveView
        import Lavash.Rx
        import_rx MyApp.Validators

        calculate :email_valid, rx(valid_email?(@email))
      end

  ## Fields

  - `:source` - The expression as a source string
  - `:ast` - The transformed AST for server-side evaluation
  - `:deps` - List of dependency field names (atoms)
  """
  defstruct [:source, :ast, :deps]

  @doc """
  Defines a reusable reactive function for use in `rx()` expressions.

  This macro registers the function so it's available during JS generation
  in the ColocatedTransformer.

  ## Examples

      defrx valid_expiry?(digits) do
        String.length(digits) == 4 &&
          String.to_integer(String.slice(digits, 0, 2) || "0") >= 1 &&
          String.to_integer(String.slice(digits, 0, 2) || "0") <= 12
      end

      defrx valid_cvv?(digits, is_amex) do
        if(is_amex, do: String.length(digits) == 4, else: String.length(digits) == 3)
      end

  Note: defrx bodies must be single expressions. Variable assignments like
  `len = String.length(digits)` are not supported.
  """
  defmacro defrx({name, _, params}, do: body) when is_atom(name) do
    param_names = for {p, _, _} <- params || [], do: p
    arity = length(param_names)
    body_source = Macro.to_string(body)

    quote do
      # Register in module attribute for access by transformers
      # Format: {name, arity, params, body_ast, body_source}
      # - body_ast is used by DefrxExpander to expand defrx calls in rx ASTs
      # - body_source is used by ColocatedTransformer for JS expansion
      Module.register_attribute(__MODULE__, :lavash_defrx, accumulate: true)
      @lavash_defrx {unquote(name), unquote(arity), unquote(param_names), unquote(Macro.escape(body)), unquote(body_source)}
    end
  end

  @doc """
  Imports defrx functions from another module.

  The imported functions become available for use in `rx()` expressions
  in the current module.

  ## Example

      defmodule MyApp.Validators do
        use Lavash.Rx.Functions

        defrx valid_email?(email) do
          String.length(email) > 0 && String.contains?(email, "@")
        end
      end

      defmodule MyAppWeb.UserLive do
        use Lavash.LiveView
        import Lavash.Rx
        import_rx MyApp.Validators

        calculate :email_valid, rx(valid_email?(@email))
      end

  You can also import only specific functions:

      import_rx MyApp.Validators, only: [valid_email?: 1]

  """
  defmacro import_rx(module, opts \\ []) do
    quote do
      # Register the import for use during DSL compilation
      Module.register_attribute(__MODULE__, :lavash_defrx_imports, accumulate: true)
      @lavash_defrx_imports {unquote(module), unquote(opts)}
    end
  end

  @doc """
  Captures a reactive expression at compile time.

  The expression is stored as both source string (for JS transpilation)
  and transformed AST (for server-side evaluation). Dependencies are
  automatically extracted from `@field` references.

  ## Examples

      rx(length(@tags))
      rx(@count * @multiplier)
      rx(if @active, do: "on", else: "off")
  """
  defmacro rx(body) do
    # Look up defrx definitions from the calling module (if available at compile time)
    local_defs = Module.get_attribute(__CALLER__.module, :lavash_defrx) || []

    # Look up imported defrx definitions
    imports = Module.get_attribute(__CALLER__.module, :lavash_defrx_imports) || []
    imported_defs = collect_imported_defrx(imports)

    # Build a map of {name, arity} -> {params, body_ast}
    # Local definitions override imports
    # Format from defrx: {name, arity, params, body_ast, body_source}
    defrx_map =
      Enum.reduce(imported_defs ++ local_defs, %{}, fn {name, arity, params, body_ast, _body_source}, acc ->
        Map.put(acc, {name, arity}, {params, body_ast})
      end)

    # Expand any defrx calls in the body (for Elixir evaluation)
    expanded_body = expand_defrx_calls(body, defrx_map)

    source = Macro.to_string(expanded_body)
    ast = transform_at_refs(expanded_body)
    deps = extract_deps(expanded_body)

    quote do
      %Lavash.Rx{
        source: unquote(source),
        ast: unquote(Macro.escape(ast)),
        deps: unquote(Macro.escape(deps))
      }
    end
  end

  # Collect defrx definitions from imported modules
  defp collect_imported_defrx(imports) do
    Enum.flat_map(imports, fn {module, opts} ->
      try do
        defs = module.__defrx_definitions__()

        case Keyword.get(opts, :only) do
          nil ->
            defs

          only_list ->
            Enum.filter(defs, fn {name, arity, _, _, _} ->
              {name, arity} in only_list
            end)
        end
      rescue
        UndefinedFunctionError ->
          # Module doesn't export defrx definitions
          []
      end
    end)
  end

  # Expand calls to defrx-defined functions by substituting params with args
  defp expand_defrx_calls({name, meta, args}, defrx_map) when is_atom(name) and is_list(args) do
    arity = length(args)
    expanded_args = Enum.map(args, &expand_defrx_calls(&1, defrx_map))

    case Map.get(defrx_map, {name, arity}) do
      {params, body} ->
        # Substitute params with args in the body
        substitutions = Enum.zip(params, expanded_args) |> Map.new()
        substituted = substitute_vars(body, substitutions)
        # Recursively expand any nested defrx calls in the substituted body
        expand_defrx_calls(substituted, defrx_map)

      nil ->
        {name, meta, expanded_args}
    end
  end

  defp expand_defrx_calls({form, meta, args}, defrx_map) when is_list(args) do
    {expand_defrx_calls(form, defrx_map), meta, Enum.map(args, &expand_defrx_calls(&1, defrx_map))}
  end

  defp expand_defrx_calls({left, right}, defrx_map) do
    {expand_defrx_calls(left, defrx_map), expand_defrx_calls(right, defrx_map)}
  end

  defp expand_defrx_calls(list, defrx_map) when is_list(list) do
    Enum.map(list, &expand_defrx_calls(&1, defrx_map))
  end

  defp expand_defrx_calls(other, _defrx_map), do: other

  # Substitute variable references with their values
  defp substitute_vars({var_name, meta, context}, substitutions) when is_atom(var_name) and is_atom(context) do
    case Map.get(substitutions, var_name) do
      nil -> {var_name, meta, context}
      value -> value
    end
  end

  defp substitute_vars({form, meta, args}, substitutions) when is_list(args) do
    {substitute_vars(form, substitutions), meta, Enum.map(args, &substitute_vars(&1, substitutions))}
  end

  defp substitute_vars({left, right}, substitutions) do
    {substitute_vars(left, substitutions), substitute_vars(right, substitutions)}
  end

  defp substitute_vars(list, substitutions) when is_list(list) do
    Enum.map(list, &substitute_vars(&1, substitutions))
  end

  defp substitute_vars(other, _substitutions), do: other

  # Transform @var references to Map.get(state, :var) for runtime evaluation
  # Use Macro.var with nil context to create an unhygienic variable reference
  # that can be bound in the target context (the generated code)

  # Path access via bracket notation: @params["name"] → get_in(state, [:params, "name"])
  defp transform_at_refs({{:., _, [Access, :get]}, _, [{:@, _, [{var_name, _, _}]}, key]})
       when is_atom(var_name) do
    state_var = Macro.var(:state, nil)
    quote do: get_in(unquote(state_var), [unquote(var_name), unquote(key)])
  end

  # Nested path access: @params["address"]["city"] → get_in(state, [:params, "address", "city"])
  defp transform_at_refs({{:., _, [Access, :get]}, _, [inner, key]}) do
    case extract_path_for_transform(inner, [key]) do
      {:ok, var_name, path} ->
        state_var = Macro.var(:state, nil)
        quote do: get_in(unquote(state_var), [unquote(var_name) | unquote(path)])

      :not_a_path ->
        # Not a path rooted at @var, transform normally
        transformed_inner = transform_at_refs(inner)
        quote do: Access.get(unquote(transformed_inner), unquote(key))
    end
  end

  # Dot access: @params.name → get_in(state, [:params, :name])
  defp transform_at_refs({{:., _, [{:@, _, [{var_name, _, _}]}, field]}, _, []})
       when is_atom(var_name) and is_atom(field) do
    state_var = Macro.var(:state, nil)
    quote do: get_in(unquote(state_var), [unquote(var_name), unquote(field)])
  end

  # Simple @var reference
  defp transform_at_refs({:@, _, [{var_name, _, _}]}) when is_atom(var_name) do
    state_var = Macro.var(:state, nil)
    quote do: Map.get(unquote(state_var), unquote(var_name), nil)
  end

  defp transform_at_refs({form, meta, args}) when is_list(args) do
    {form, meta, Enum.map(args, &transform_at_refs/1)}
  end

  defp transform_at_refs({left, right}) do
    {transform_at_refs(left), transform_at_refs(right)}
  end

  defp transform_at_refs(list) when is_list(list) do
    Enum.map(list, &transform_at_refs/1)
  end

  defp transform_at_refs(other), do: other

  # Helper for transform - extract path from nested Access.get for transformation
  defp extract_path_for_transform({:@, _, [{var_name, _, _}]}, path) when is_atom(var_name) do
    {:ok, var_name, path}
  end

  defp extract_path_for_transform({{:., _, [Access, :get]}, _, [inner, key]}, path) do
    extract_path_for_transform(inner, [key | path])
  end

  defp extract_path_for_transform(_, _), do: :not_a_path

  # Extract dependency names from @var references
  # Supports both simple refs (@count) and path-based refs (@params["name"], @params.name)
  defp extract_deps(expr) do
    expr
    |> find_at_refs([])
    |> Enum.uniq()
  end

  # Path access via bracket notation: @params["name"] or @params[:key]
  # AST: {{:., _, [Access, :get]}, _, [{:@, _, [{var, _, _}]}, key]}
  defp find_at_refs(
         {{:., _, [Access, :get]}, _, [{:@, _, [{var_name, _, _}]}, key]},
         acc
       )
       when is_atom(var_name) do
    [{:path, var_name, [key]} | acc]
  end

  # Nested path access: @params["address"]["city"]
  # Continue extracting path segments
  defp find_at_refs(
         {{:., _, [Access, :get]}, _, [inner, key]},
         acc
       ) do
    case extract_path(inner, [key]) do
      {:ok, var_name, path} -> [{:path, var_name, path} | acc]
      :not_a_path -> find_at_refs(inner, acc)
    end
  end

  # Dot access: @params.name
  # AST: {{:., _, [{:@, _, [{var, _, _}]}, field]}, _, []}
  defp find_at_refs(
         {{:., _, [{:@, _, [{var_name, _, _}]}, field]}, _, []},
         acc
       )
       when is_atom(var_name) and is_atom(field) do
    [{:path, var_name, [field]} | acc]
  end

  # Simple @var reference
  defp find_at_refs({:@, _, [{var_name, _, _}]}, acc) when is_atom(var_name) do
    [var_name | acc]
  end

  defp find_at_refs({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &find_at_refs/2)
  end

  defp find_at_refs({left, right}, acc) do
    acc = find_at_refs(left, acc)
    find_at_refs(right, acc)
  end

  defp find_at_refs(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &find_at_refs/2)
  end

  defp find_at_refs(_other, acc), do: acc

  # Helper to extract nested path from Access.get chains
  defp extract_path({:@, _, [{var_name, _, _}]}, path) when is_atom(var_name) do
    {:ok, var_name, path}
  end

  defp extract_path({{:., _, [Access, :get]}, _, [inner, key]}, path) do
    extract_path(inner, [key | path])
  end

  defp extract_path(_, _), do: :not_a_path
end
