defmodule Lavash.Rx.Transpiler do
  @moduledoc """
  Translates Elixir expressions to JavaScript.

  This module handles the core transpilation of Elixir AST to JavaScript code,
  enabling optimistic client-side evaluation of reactive expressions.

  ## Supported Constructs

  ### Literals
  - Strings, numbers, booleans, nil, atoms
  - Lists and maps

  ### Operators
  - Comparison: `==`, `!=`, `>`, `<`, `>=`, `<=`
  - Logical: `&&`, `||`, `and`, `or`, `not`, `!`
  - Arithmetic: `+`, `-`, `*`, `/`
  - String: `<>` (concatenation)
  - List: `++` (concatenation), `in` (membership)
  - Pipe: `|>`

  ### Control Flow
  - `if cond, do: x, else: y` → ternary operator

  ### State References
  - `@variable` → `state.variable`
  - `@nested.field` → `state.nested.field`

  ### String Functions
  - `String.length/1`, `String.trim/1`
  - `String.to_integer/1`, `String.to_float/1`
  - `String.contains?/2`, `String.starts_with?/2`, `String.ends_with?/2`
  - `String.replace/3`, `String.slice/3`, `String.match?/2`

  ### Enum Functions
  - `Enum.member?/2`, `Enum.count/1`, `Enum.join/1,2`
  - `Enum.map/2`, `Enum.filter/2`, `Enum.reject/2`

  ### Map Functions
  - `Map.get/2,3`

  ### Utility Functions
  - `length/1`, `is_nil/1`, `humanize/1`, `get_in/2`
  - `valid_card_number?/1` (custom validation)

  ## Usage

      iex> Lavash.Transpiler.to_js("@count + 1")
      "(state.count + 1)"

      iex> Lavash.Transpiler.to_js("if @active, do: \\"on\\", else: \\"off\\"")
      "(state.active ? \\"on\\" : \\"off\\")"

  ## Validation

  Use `validate/1` to check if an expression can be fully transpiled:

      iex> Lavash.Transpiler.validate("@count + 1")
      :ok

      iex> Lavash.Transpiler.validate("Ash.read!(Product)")
      {:error, "Ash.read!"}
  """

  @doc """
  Translates an Elixir expression string to JavaScript.

  Returns the JavaScript code as a string. Untranspilable expressions
  are converted to `undefined` with a comment indicating the issue.

  ## Examples

      iex> Lavash.Transpiler.to_js("@count")
      "state.count"

      iex> Lavash.Transpiler.to_js("length(@items)")
      "(state.items.length)"

      iex> Lavash.Transpiler.to_js("if @a, do: 1, else: 2")
      "(state.a ? 1 : 2)"
  """
  @spec to_js(String.t()) :: String.t()
  def to_js(code) when is_binary(code) do
    code
    |> Code.string_to_quoted!()
    |> ast_to_js()
  end

  @doc """
  Translates an Elixir AST to JavaScript.

  This is the lower-level function that works directly with AST.
  Use `to_js/1` for string input.
  """
  @spec ast_to_js(Macro.t()) :: String.t()
  def ast_to_js(ast)

  # if-else -> ternary
  def ast_to_js({:if, _, [condition, [do: do_clause, else: else_clause]]}) do
    cond_js = ast_to_js(condition)
    do_js = ast_to_js(do_clause)
    else_js = ast_to_js(else_clause)
    "(#{cond_js} ? #{do_js} : #{else_js})"
  end

  def ast_to_js({:if, _, [condition, [do: do_clause]]}) do
    cond_js = ast_to_js(condition)
    do_js = ast_to_js(do_clause)
    "(#{cond_js} ? #{do_js} : null)"
  end

  # cond -> nested ternaries
  # cond do
  #   condition1 -> result1
  #   condition2 -> result2
  #   true -> default
  # end
  def ast_to_js({:cond, _, [[do: clauses]]}) do
    cond_to_nested_ternary(clauses)
  end

  defp cond_to_nested_ternary([{:->, _, [[condition], result]}]) do
    # Last clause - if condition is `true`, just return result, otherwise make ternary
    case condition do
      true -> ast_to_js(result)
      _ -> "(#{ast_to_js(condition)} ? #{ast_to_js(result)} : null)"
    end
  end

  defp cond_to_nested_ternary([{:->, _, [[condition], result]} | rest]) do
    "(#{ast_to_js(condition)} ? #{ast_to_js(result)} : #{cond_to_nested_ternary(rest)})"
  end

  # @variable -> state.variable
  def ast_to_js({:@, _, [{var_name, _, _}]}) when is_atom(var_name) do
    "state.#{var_name}"
  end

  # Enum.member?(list, val) -> list.includes(val)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, _, [list, val]}) do
    "#{ast_to_js(list)}.includes(#{ast_to_js(val)})"
  end

  # Map.get(map, key) -> map[key]
  def ast_to_js({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [map, key]}) do
    "#{ast_to_js(map)}[#{ast_to_js(key)}]"
  end

  # Map.get(map, key, default) -> (map[key] ?? default)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [map, key, default]}) do
    "(#{ast_to_js(map)}[#{ast_to_js(key)}] ?? #{ast_to_js(default)})"
  end

  # humanize(value) -> capitalize first letter, replace underscores with spaces
  def ast_to_js({:humanize, _, [value]}) do
    js_val = ast_to_js(value)
    "(#{js_val}.toString().replace(/_/g, ' ').replace(/^\\w/, c => c.toUpperCase()))"
  end

  # length(list) -> list.length
  def ast_to_js({:length, _, [list]}) do
    "(#{ast_to_js(list)}.length)"
  end

  # is_nil(x) -> (x === null || x === undefined)
  def ast_to_js({:is_nil, _, [expr]}) do
    js_expr = ast_to_js(expr)
    "(#{js_expr} === null || #{js_expr} === undefined)"
  end

  # String.length(str) -> str.length
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :length]}, _, [str]}) do
    "(#{ast_to_js(str)}.length)"
  end

  # String.to_float(str) -> parseFloat(str)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :to_float]}, _, [str]}) do
    "parseFloat(#{ast_to_js(str)})"
  end

  # String.to_integer(str) -> parseInt(str, 10)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :to_integer]}, _, [str]}) do
    "parseInt(#{ast_to_js(str)}, 10)"
  end

  # String.trim(str) -> str.trim()
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :trim]}, _, [str]}) do
    "(#{ast_to_js(str)}.trim())"
  end

  # String.graphemes(str) -> [...str] (spread into array of chars)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :graphemes]}, _, [str]}) do
    "([...#{ast_to_js(str)}])"
  end

  # String.split(str, pattern) -> str.split(pattern)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :split]}, _, [str, pattern]}) do
    "(#{ast_to_js(str)}.split(#{ast_to_js(pattern)}))"
  end

  # String.match?(str, regex) -> regex.test(str)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :match?]}, _, [str, {:sigil_r, _, [{:<<>>, _, [pattern]}, []]}]}) do
    "(/#{pattern}/.test(#{ast_to_js(str)}))"
  end

  # String.contains?(str, substring) -> str.includes(substring)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :contains?]}, _, [str, substring]}) do
    "(#{ast_to_js(str)}.includes(#{ast_to_js(substring)}))"
  end

  # String.starts_with?(str, prefix) -> str.startsWith(prefix)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :starts_with?]}, _, [str, prefix]}) do
    "(#{ast_to_js(str)}.startsWith(#{ast_to_js(prefix)}))"
  end

  # String.ends_with?(str, suffix) -> str.endsWith(suffix)
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :ends_with?]}, _, [str, suffix]}) do
    "(#{ast_to_js(str)}.endsWith(#{ast_to_js(suffix)}))"
  end

  # String.replace(str, pattern, replacement) with regex
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :replace]}, _, [str, {:sigil_r, _, [{:<<>>, _, [pattern]}, _opts]}, replacement]}) do
    "(#{ast_to_js(str)}.replace(/#{pattern}/g, #{ast_to_js(replacement)}))"
  end

  # String.replace(str, pattern, replacement) with string pattern
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :replace]}, _, [str, pattern, replacement]}) when is_binary(pattern) do
    escaped_pattern = Regex.escape(pattern)
    "(#{ast_to_js(str)}.replace(/#{escaped_pattern}/g, #{ast_to_js(replacement)}))"
  end

  # String.slice(str, start, length) with constants
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :slice]}, _, [str, start, len]}) when is_integer(start) and is_integer(len) do
    "(#{ast_to_js(str)}.slice(#{start}, #{start + len}))"
  end

  # String.slice(str, start, length) with dynamic values
  def ast_to_js({{:., _, [{:__aliases__, _, [:String]}, :slice]}, _, [str, start, len]}) do
    str_js = ast_to_js(str)
    start_js = ast_to_js(start)
    len_js = ast_to_js(len)
    "(#{str_js}.slice(#{start_js}, #{start_js} + #{len_js}))"
  end

  # String.chunk(str, size) or Lavash.Rx.String.chunk(str, size) with constant size
  def ast_to_js({{:., _, [{:__aliases__, _, modules}, :chunk]}, _, [str, size]})
       when modules in [[:String], [:Lavash, :String]] and is_integer(size) do
    "(#{ast_to_js(str)}.match(/.{1,#{size}}/g) || [])"
  end

  # String.chunk or Lavash.Rx.String.chunk with dynamic size
  def ast_to_js({{:., _, [{:__aliases__, _, modules}, :chunk]}, _, [str, size]})
       when modules in [[:String], [:Lavash, :String]] do
    str_js = ast_to_js(str)
    size_js = ast_to_js(size)
    "(#{str_js}.match(new RegExp('.{1,' + #{size_js} + '}', 'g')) || [])"
  end

  # get_in(map, [keys]) -> nested access
  def ast_to_js({:get_in, _, [map, keys]}) when is_list(keys) do
    base = ast_to_js(map)
    path = Enum.map(keys, fn
      k when is_atom(k) -> ".#{k}"
      k when is_binary(k) -> "[#{inspect(k)}]"
      k -> "[#{ast_to_js(k)}]"
    end)
    "(#{base}#{Enum.join(path, "")})"
  end

  # get_in with dynamic keys list
  def ast_to_js({:get_in, _, [map, keys_expr]}) do
    map_js = ast_to_js(map)
    keys_js = ast_to_js(keys_expr)
    "(#{keys_js}.reduce((acc, key) => acc?.[key], #{map_js}))"
  end

  # Enum.count(list) -> list.length
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [list]}) do
    "(#{ast_to_js(list)}.length)"
  end

  # Enum.join(list, sep) -> list.join(sep)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _, [list, sep]}) do
    "(#{ast_to_js(list)}.join(#{ast_to_js(sep)}))"
  end

  # Enum.join(list) -> list.join(",")
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _, [list]}) do
    "(#{ast_to_js(list)}.join(\",\"))"
  end

  # Enum.map(list, fn x -> expr end) -> list.map(x => expr)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [list, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.map(#{var_str} => #{body_js}))"
  end

  # Enum.map(list, fn {a, b} -> expr end) -> list.map(([a, b]) => expr) - tuple destructuring
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [list, {:fn, _, [{:->, _, [[{{var1, _, _}, {var2, _, _}}], body]}]}]}) do
    var1_str = to_string(var1)
    var2_str = to_string(var2)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.map(([#{var1_str}, #{var2_str}]) => #{body_js}))"
  end

  # Enum.filter(list, fn x -> expr end) -> list.filter(x => expr)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [list, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.filter(#{var_str} => #{body_js}))"
  end

  # Enum.reject(list, fn x -> expr end) -> list.filter(x => !expr)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [list, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.filter(#{var_str} => !(#{body_js})))"
  end

  # Enum.reject with capture: Enum.reject(list, &(&1 == val))
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [list, {:&, _, [{:==, _, [{:&, _, [1]}, val]}]}]}) do
    val_js = ast_to_js(val)
    "(#{ast_to_js(list)}.filter(x => x !== #{val_js}))"
  end

  # Enum.reverse(list) -> [...list].reverse()
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, [list]}) do
    "([...#{ast_to_js(list)}].reverse())"
  end

  # Enum.sum(list) -> list.reduce((a, b) => a + b, 0)
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :sum]}, _, [list]}) do
    "(#{ast_to_js(list)}.reduce((a, b) => a + b, 0))"
  end

  # Enum.with_index(list) -> list.map((item, index) => [item, index])
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :with_index]}, _, [list]}) do
    "(#{ast_to_js(list)}.map((item, index) => [item, index]))"
  end

  # Enum.reduce(list, acc, fn {item, index}, acc -> ... end)
  # Handle tuple destructuring in reduce for with_index pattern
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [list, initial, {:fn, _, [{:->, _, [[{{var1, _, _}, {var2, _, _}}, {acc_var, _, _}], body]}]}]}) do
    var1_str = to_string(var1)
    var2_str = to_string(var2)
    acc_str = to_string(acc_var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.reduce((#{acc_str}, [#{var1_str}, #{var2_str}]) => #{body_js}, #{ast_to_js(initial)}))"
  end

  # Enum.reduce(list, acc, fn item, acc -> ... end) - simple form
  def ast_to_js({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [list, initial, {:fn, _, [{:->, _, [[{var, _, _}, {acc_var, _, _}], body]}]}]}) do
    var_str = to_string(var)
    acc_str = to_string(acc_var)
    body_js = ast_to_js(body)
    "(#{ast_to_js(list)}.reduce((#{acc_str}, #{var_str}) => #{body_js}, #{ast_to_js(initial)}))"
  end

  # Access.get style: item["key"]
  def ast_to_js({{:., _, [Access, :get]}, _, [obj, key]}) do
    "#{ast_to_js(obj)}[#{ast_to_js(key)}]"
  end

  # Dot access on AST node
  def ast_to_js({:., _, [obj, field]}) when is_atom(field) do
    "#{ast_to_js(obj)}.#{field}"
  end

  # Function call on object: item.field (alternate AST form)
  def ast_to_js({{:., _, [obj, field]}, _, []}) when is_atom(field) do
    "#{ast_to_js(obj)}.#{field}"
  end

  # Variable reference
  def ast_to_js({var_name, _, nil}) when is_atom(var_name) do
    to_string(var_name)
  end

  def ast_to_js({var_name, _, context}) when is_atom(var_name) and is_atom(context) do
    to_string(var_name)
  end

  # String literal
  def ast_to_js(str) when is_binary(str) do
    inspect(str)
  end

  # Number literal
  def ast_to_js(num) when is_number(num) do
    to_string(num)
  end

  # Boolean literal
  def ast_to_js(bool) when is_boolean(bool) do
    to_string(bool)
  end

  # nil literal
  def ast_to_js(nil) do
    "null"
  end

  # Atom literal (convert to string)
  def ast_to_js(atom) when is_atom(atom) do
    inspect(to_string(atom))
  end

  # List literal
  def ast_to_js(list) when is_list(list) do
    elements = Enum.map(list, &ast_to_js/1) |> Enum.join(", ")
    "[#{elements}]"
  end

  # Binary operators
  def ast_to_js({op, _, [left, right]}) when op in [:==, :!=, :&&, :||, :and, :or, :>, :<, :>=, :<=, :+, :-, :*, :/] do
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

  # rem(a, b) -> (a % b)
  def ast_to_js({:rem, _, [left, right]}) do
    "(#{ast_to_js(left)} % #{ast_to_js(right)})"
  end

  # not operator
  def ast_to_js({:not, _, [expr]}) do
    "!#{ast_to_js(expr)}"
  end

  def ast_to_js({:!, _, [expr]}) do
    "!#{ast_to_js(expr)}"
  end

  # "in" operator: value in list -> list.includes(value)
  def ast_to_js({:in, _, [value, list]}) do
    "#{ast_to_js(list)}.includes(#{ast_to_js(value)})"
  end

  # String concatenation with <>
  def ast_to_js({:<>, _, [left, right]}) do
    "(#{ast_to_js(left)} + #{ast_to_js(right)})"
  end

  # List concatenation with ++ -> [...list1, ...list2]
  def ast_to_js({:++, _, [left, right]}) do
    "[...#{ast_to_js(left)}, ...#{ast_to_js(right)}]"
  end

  # Pipe operator: a |> f(b) -> f(a, b)
  def ast_to_js({:|>, _, [left, right]}) do
    expanded = Macro.unpipe({:|>, [], [left, right]})
    result = Enum.reduce(expanded, nil, fn
      {expr, 0}, nil -> expr
      {call, pos}, acc -> insert_pipe_arg(call, acc, pos)
    end)
    ast_to_js(result)
  end

  # String interpolation: "#{expr}" -> template literal `${expr}`
  def ast_to_js({:<<>>, _, parts}) do
    js_parts =
      Enum.map(parts, fn
        str when is_binary(str) ->
          str
          |> String.replace("\\", "\\\\")
          |> String.replace("`", "\\`")
          |> String.replace("${", "\\${")

        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, {:binary, _, _}]} ->
          "${#{ast_to_js(expr)}}"

        {:"::", _, [expr, {:binary, _, _}]} ->
          "${#{ast_to_js(expr)}}"

        other ->
          "${#{ast_to_js(other)}}"
      end)

    "`#{Enum.join(js_parts, "")}`"
  end

  # Map literal %{} or %{key: value, ...}
  def ast_to_js({:%{}, _, pairs}) when is_list(pairs) do
    if pairs == [] do
      "{}"
    else
      js_pairs = Enum.map(pairs, fn {key, value} ->
        js_key = if is_atom(key), do: inspect(key), else: ast_to_js(key)
        "#{js_key}: #{ast_to_js(value)}"
      end)
      "{#{Enum.join(js_pairs, ", ")}}"
    end
  end

  # Fallback - return undefined for untranspilable expressions
  def ast_to_js(other) do
    safe_repr = inspect(other) |> String.replace(~r/[{}:\[\]]/, "_")
    "(undefined /* untranspilable: #{safe_repr} */)"
  end

  # Helper to insert piped value into a function call
  defp insert_pipe_arg({func, meta, args}, value, pos) when is_list(args) do
    {func, meta, List.insert_at(args, pos, value)}
  end

  defp insert_pipe_arg({func, meta, nil}, value, _pos) do
    {func, meta, [value]}
  end

  # ===========================================================================
  # Validation
  # ===========================================================================

  @doc """
  Validates that an Elixir expression can be transpiled to JavaScript.

  Returns `:ok` if the expression is fully transpilable, or
  `{:error, description}` if it contains unsupported constructs.

  ## Examples

      iex> Lavash.Transpiler.validate("length(@tags)")
      :ok

      iex> Lavash.Transpiler.validate("Ash.read!(Product)")
      {:error, "Ash.read!"}
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(source) when is_binary(source) do
    ast = Code.string_to_quoted!(source)
    validate_ast(ast)
  end

  defp validate_ast({:if, _, [condition, [do: do_clause, else: else_clause]]}) do
    with :ok <- validate_ast(condition),
         :ok <- validate_ast(do_clause),
         :ok <- validate_ast(else_clause) do
      :ok
    end
  end

  defp validate_ast({:if, _, [condition, [do: do_clause]]}) do
    with :ok <- validate_ast(condition),
         :ok <- validate_ast(do_clause) do
      :ok
    end
  end

  # cond expression
  defp validate_ast({:cond, _, [[do: clauses]]}) do
    Enum.reduce_while(clauses, :ok, fn {:->, _, [[condition], result]}, _acc ->
      with :ok <- validate_ast(condition),
           :ok <- validate_ast(result) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # rem/2
  defp validate_ast({:rem, _, [left, right]}) do
    with :ok <- validate_ast(left),
         :ok <- validate_ast(right) do
      :ok
    end
  end

  # @variable references are always transpilable
  defp validate_ast({:@, _, [{_var_name, _, _}]}), do: :ok

  # Supported Enum functions
  defp validate_ast({{:., _, [{:__aliases__, _, [:Enum]}, func]}, _, args})
       when func in [:member?, :count, :join, :map, :filter, :reject, :reverse, :sum, :with_index, :reduce] do
    validate_all_args(args)
  end

  # Supported Map functions
  defp validate_ast({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, args}) do
    validate_all_args(args)
  end

  # length/1
  defp validate_ast({:length, _, [arg]}), do: validate_ast(arg)

  # humanize/1
  defp validate_ast({:humanize, _, [arg]}), do: validate_ast(arg)

  # is_nil/1
  defp validate_ast({:is_nil, _, [arg]}), do: validate_ast(arg)

  # get_in/2
  defp validate_ast({:get_in, _, [map, keys]}) do
    with :ok <- validate_ast(map),
         :ok <- validate_ast(keys) do
      :ok
    end
  end

  # Supported String functions
  defp validate_ast({{:., _, [{:__aliases__, _, modules}, func]}, _, args})
       when modules in [[:String], [:Lavash, :String]] and
            func in [:length, :to_float, :to_integer, :trim, :match?, :contains?, :starts_with?, :ends_with?, :replace, :slice, :chunk, :graphemes, :split] do
    validate_all_args(args)
  end

  # Binary operators
  defp validate_ast({op, _, [left, right]})
       when op in [:==, :!=, :&&, :||, :and, :or, :>, :<, :>=, :<=, :+, :-, :*, :/, :<>, :++, :in, :|>] do
    with :ok <- validate_ast(left),
         :ok <- validate_ast(right) do
      :ok
    end
  end

  # Unary operators
  defp validate_ast({op, _, [expr]}) when op in [:not, :!] do
    validate_ast(expr)
  end

  # Dot access (field access)
  defp validate_ast({{:., _, [_obj, _field]}, _, []}) do
    :ok
  end

  defp validate_ast({:., _, [obj, _field]}) do
    validate_ast(obj)
  end

  # Access syntax
  defp validate_ast({{:., _, [Access, :get]}, _, [obj, key]}) do
    with :ok <- validate_ast(obj),
         :ok <- validate_ast(key) do
      :ok
    end
  end

  # Variable reference
  defp validate_ast({var_name, _, nil}) when is_atom(var_name), do: :ok
  defp validate_ast({var_name, _, context}) when is_atom(var_name) and is_atom(context), do: :ok

  # Literals
  defp validate_ast(str) when is_binary(str), do: :ok
  defp validate_ast(num) when is_number(num), do: :ok
  defp validate_ast(bool) when is_boolean(bool), do: :ok
  defp validate_ast(nil), do: :ok
  defp validate_ast(atom) when is_atom(atom), do: :ok

  # List literal
  defp validate_ast(list) when is_list(list) do
    validate_all_args(list)
  end

  # Map literal
  defp validate_ast({:%{}, _, pairs}) when is_list(pairs) do
    Enum.reduce_while(pairs, :ok, fn {key, value}, :ok ->
      with :ok <- validate_ast(key),
           :ok <- validate_ast(value) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # String interpolation
  defp validate_ast({:<<>>, _, parts}) do
    Enum.reduce_while(parts, :ok, fn
      str, :ok when is_binary(str) ->
        {:cont, :ok}

      {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, {:binary, _, _}]}, :ok ->
        case validate_ast(expr) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {:"::", _, [expr, {:binary, _, _}]}, :ok ->
        case validate_ast(expr) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      other, :ok ->
        case validate_ast(other) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  # Anonymous function with single arg (used in Enum.map, etc.)
  defp validate_ast({:fn, _, [{:->, _, [[_arg], body]}]}) do
    validate_ast(body)
  end

  # Anonymous function with two args (used in Enum.reduce, etc.)
  defp validate_ast({:fn, _, [{:->, _, [[_arg1, _arg2], body]}]}) do
    validate_ast(body)
  end

  # Anonymous function with tuple destructuring in reduce (used in Enum.reduce with with_index)
  defp validate_ast({:fn, _, [{:->, _, [[{_var1, _var2}, _acc], body]}]}) do
    validate_ast(body)
  end

  # Anonymous function with single tuple arg (used in Enum.map with with_index result)
  defp validate_ast({:fn, _, [{:->, _, [[{_var1, _var2}], body]}]}) do
    validate_ast(body)
  end

  # Capture syntax &(&1 == val)
  defp validate_ast({:&, _, [{op, _, [{:&, _, [1]}, val]}]}) when op in [:==, :!=] do
    validate_ast(val)
  end

  defp validate_ast({:&, _, [_]}) do
    :ok
  end

  # Two-element tuples (keyword-like)
  defp validate_ast({left, right}) do
    with :ok <- validate_ast(left),
         :ok <- validate_ast(right) do
      :ok
    end
  end

  # Generic function call - not supported unless explicitly handled above
  defp validate_ast({{:., _, [{:__aliases__, _, modules}, func]}, _, _args}) do
    module_name = Enum.join(modules, ".")
    {:error, "#{module_name}.#{func}"}
  end

  # Local function call - not transpilable
  defp validate_ast({func, _, args}) when is_atom(func) and is_list(args) do
    if func in [:length, :humanize, :if, :not, :!] do
      validate_all_args(args)
    else
      {:error, "#{func}/#{length(args)}"}
    end
  end

  # Fallback - unknown construct
  defp validate_ast(other) do
    {:error, inspect(other)}
  end

  defp validate_all_args(args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      case validate_ast(arg) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
