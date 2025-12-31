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

  ## Fields

  - `:source` - The expression as a source string
  - `:ast` - The transformed AST for server-side evaluation
  - `:deps` - List of dependency field names (atoms)
  """
  defstruct [:source, :ast, :deps]

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
    source = Macro.to_string(body)
    ast = transform_at_refs(body)
    deps = extract_deps(body)

    quote do
      %Lavash.Rx{
        source: unquote(source),
        ast: unquote(Macro.escape(ast)),
        deps: unquote(deps)
      }
    end
  end

  # Transform @var references to Map.get(state, :var) for runtime evaluation
  # Use Macro.var with nil context to create an unhygienic variable reference
  # that can be bound in the target context (the generated code)
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

  # Extract dependency names from @var references
  defp extract_deps(expr) do
    expr
    |> find_at_refs([])
    |> Enum.uniq()
  end

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
end

defmodule Lavash.Component.State do
  @moduledoc """
  A state field that connects component state to parent state.

  This is the unified state entity used by both LiveComponent and ClientComponent.
  State fields are bound to parent LiveView state and can be modified through
  optimistic actions.

  ## Fields

  - `:name` - The atom name of the state field
  - `:type` - The type specification (e.g., `:boolean`, `{:array, :string}`)
  - `:from` - Storage location (`:parent` for components, default)
  - `:default` - Default value if not provided

  ## Usage

  In LiveComponent or ClientComponent:

      state :tags, {:array, :string}
      state :active, :boolean, default: false

  The state field will be bound to the parent's state of the same name
  via the `bind` prop.
  """
  defstruct [:name, :type, :from, :default, __spark_metadata__: nil]
end

defmodule Lavash.Component.Prop do
  @moduledoc """
  A prop passed from the parent component.

  Props are read-only values that a component receives from its parent.
  They cannot be modified by the component itself.

  ## Fields

  - `:name` - The atom name of the prop
  - `:type` - The type specification (e.g., `:string`, `{:array, :string}`)
  - `:required` - Whether the prop must be provided (default: false)
  - `:default` - Default value if not provided
  """
  defstruct [:name, :type, :required, :default, __spark_metadata__: nil]
end

defmodule Lavash.Component.Template do
  @moduledoc """
  A component template that compiles to both HEEx and JS.

  The template source is parsed and transformed during compilation
  to generate both server-side HEEx rendering and client-side
  JavaScript for optimistic updates.
  """
  defstruct [:source, __spark_metadata__: nil]
end

defmodule Lavash.Component.Calculate do
  @moduledoc """
  A calculated field computed from state using a reactive expression.

  Calculations use `rx()` to capture expressions that reference state via
  `@field` syntax. They are transpiled to JavaScript for client-side
  optimistic updates.

  ## Fields

  - `:name` - The atom name of the calculated field
  - `:rx` - A `Lavash.Rx` struct containing the expression
  - `:optimistic` - Whether to transpile to JS (default: true)

  ## Usage

      calculate :tag_count, rx(length(@tags))
      calculate :can_add, rx(@max == nil or length(@items) < @max)
      calculate :server_only, rx(complex_fn(@data)), optimistic: false
  """
  defstruct [:name, :rx, optimistic: true, async: false, reads: [], __spark_metadata__: nil]
end

defmodule Lavash.Component.OptimisticAction do
  @moduledoc """
  An optimistic action that generates both client JS and server handlers.

  Optimistic actions define state transformations that run on both client
  and server. The `run` function is compiled to both Elixir and JavaScript,
  ensuring consistent behavior.

  ## Fields

  - `:name` - The action name (used for event routing)
  - `:field` - The state field this action operates on
  - `:run` - Function that transforms the field value
  - `:run_source` - Source string for JS compilation
  - `:validate` - Optional validation function
  - `:validate_source` - Source string for JS validation
  - `:max` - Optional prop/state field containing max length limit
  """
  defstruct [:name, :field, :run, :run_source, :validate, :validate_source, :max, __spark_metadata__: nil]
end
