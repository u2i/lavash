defmodule Lavash.Reactive.GraphMacro do
  @moduledoc """
  Macro for defining reactive graphs with client-side JS generation.

  `defgraph` provides a declarative block syntax that:
  1. Defines a reactive graph (states + derives) for server-side use
  2. Transpiles `rx()` expressions to JavaScript for client-side optimistic updates
  3. Generates a colocated JS hook that Phoenix bundles automatically

  ## Usage

      defmodule MyAppWeb.CounterLive do
        use Phoenix.LiveView
        import Lavash.Rx
        import Lavash.Reactive.GraphMacro

        defgraph do
          state :count, 0
          state :step, 1
          derive :doubled, rx(@count * @step)
          derive :quad, rx(@doubled * 2)
        end

        def mount(_params, _session, socket) do
          {:ok, Lavash.Reactive.init(socket, __reactive_graph__())}
        end
      end

  ## What it generates

  - `__reactive_graph__/0` — returns a cached `%Lavash.Rx.Graph{}` (via `persistent_term`)
  - `__phoenix_macro_components__/0` — registers the colocated JS hook with Phoenix
  - A colocated JS file with compute functions and dependency graph metadata

  ## Async derives

  Derives marked `async: true` are server-only — they appear in the graph metadata
  but have no JS compute function. The client skips them during recomputation.

      derive :results, rx(search(@query)), async: true
  """

  defmacro defgraph(do: block) do
    {states, derives} = extract_declarations(block)

    # Build JS at compile time from the rx sources
    js_derives = build_js_derives(derives)
    js_code = generate_js(js_derives, states)

    # Write colocated JS file
    env = __CALLER__
    colocated_data =
      if js_code do
        Macro.escape(write_colocated_js(env, js_code))
      end

    # Build the pipe chain AST for the runtime graph builder
    steps =
      Enum.map(states, fn {name, default} ->
        quote do: Lavash.Reactive.state(unquote(name), unquote(default))
      end) ++
      Enum.map(derives, fn {name, rx_ast, opts} ->
        if opts == [] do
          quote do: Lavash.Reactive.derive(unquote(name), unquote(rx_ast))
        else
          quote do: Lavash.Reactive.derive(unquote(name), unquote(rx_ast), unquote(opts))
        end
      end)

    # Build: Reactive.new() |> Reactive.state(:x, 0) |> ... |> Reactive.build()
    pipe_chain =
      steps
      |> Enum.reduce(quote(do: Lavash.Reactive.new()), fn step, acc ->
        # Insert acc as first arg: Reactive.state(:name, val) -> Reactive.state(acc, :name, val)
        {call, meta, args} = step
        {call, meta, [acc | args]}
      end)

    pipe_chain = quote do: Lavash.Reactive.build(unquote(pipe_chain))

    quote do
      def __reactive_graph__ do
        Lavash.Reactive.graph(__MODULE__, fn ->
          unquote(pipe_chain)
        end)
      end

      if unquote(not is_nil(colocated_data)) do
        @__lavash_reactive_colocated_data__ unquote(colocated_data)
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedJS => [@__lavash_reactive_colocated_data__]
          }
        end
      end
    end
  end

  # Extract state and derive declarations from the block AST
  defp extract_declarations({:__block__, _, exprs}), do: extract_from_list(exprs)
  defp extract_declarations(single), do: extract_from_list([single])

  defp extract_from_list(exprs) do
    Enum.reduce(exprs, {[], []}, fn expr, {states, derives} ->
      case expr do
        {:state, _, [name, default]} ->
          {[{name, default} | states], derives}

        {:derive, _, [name, rx_expr]} ->
          {states, [{name, rx_expr, []} | derives]}

        {:derive, _, [name, rx_expr, opts]} ->
          {states, [{name, rx_expr, opts} | derives]}

        _ ->
          {states, derives}
      end
    end)
    |> then(fn {states, derives} -> {Enum.reverse(states), Enum.reverse(derives)} end)
  end

  # Build JS derive info from the extracted declarations.
  # rx_expr is the unexpanded {:rx, _, [body]} AST — we extract source and deps
  # directly from the body, same way the rx() macro does.
  defp build_js_derives(derives) do
    Enum.flat_map(derives, fn {name, rx_ast, opts} ->
      async = Keyword.get(opts, :async, false)

      case extract_rx_body(rx_ast) do
        {:ok, body} ->
          source = Macro.to_string(body)
          deps = extract_deps(body) |> Enum.map(&normalize_dep_to_string/1) |> Enum.uniq()

          if async do
            [{to_string(name), nil, deps}]
          else
            js_expr = Lavash.Rx.Transpiler.to_js(source)
            [{to_string(name), js_expr, deps}]
          end

        :error ->
          []
      end
    end)
  end

  # Extract the body expression from an unexpanded rx() macro call
  defp extract_rx_body({:rx, _, [body]}), do: {:ok, body}
  defp extract_rx_body(_), do: :error

  # Extract dependency names from @var references (mirrors Lavash.Rx.extract_deps)
  defp extract_deps(expr), do: find_at_refs(expr, []) |> Enum.uniq()

  defp find_at_refs({:@, _, [{var_name, _, _}]}, acc) when is_atom(var_name), do: [var_name | acc]

  defp find_at_refs({{:., _, [Access, :get]}, _, [{:@, _, [{var_name, _, _}]}, _key]}, acc)
       when is_atom(var_name),
       do: [var_name | acc]

  defp find_at_refs({{:., _, [{:@, _, [{var_name, _, _}]}, _field]}, _, []}, acc)
       when is_atom(var_name),
       do: [var_name | acc]

  defp find_at_refs({_form, _meta, args}, acc) when is_list(args),
    do: Enum.reduce(args, acc, &find_at_refs/2)

  defp find_at_refs({left, right}, acc), do: find_at_refs(right, find_at_refs(left, acc))
  defp find_at_refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &find_at_refs/2)
  defp find_at_refs(_other, acc), do: acc

  defp normalize_dep_to_string({:path, root, _path}), do: to_string(root)
  defp normalize_dep_to_string(atom) when is_atom(atom), do: to_string(atom)

  # Generate the JS module code
  defp generate_js(js_derives, _states) do
    # Only derives with JS expressions (non-async)
    fns = Enum.filter(js_derives, fn {_name, js_expr, _deps} -> js_expr != nil end)

    if fns == [] do
      nil
    else
      fn_strs =
        Enum.map(fns, fn {name, js_expr, _deps} ->
          "  #{name}(state) {\n    return #{js_expr};\n  }"
        end)

      derive_names = Enum.map(fns, fn {name, _, _} -> name end)

      # Build graph metadata
      deps_map = Map.new(js_derives, fn {name, _js, deps} -> {name, deps} end)
      topo_order = topo_sort_deps(deps_map)
      dependents = build_dependents(deps_map)

      graph_json = Jason.encode!(%{
        topo_order: topo_order,
        deps: deps_map,
        dependents: dependents
      })

      """
      export default {
      #{Enum.join(fn_strs, ",\n")},
      __derives__: #{Jason.encode!(derive_names)},
      __graph__: #{graph_json}
      };
      """
    end
  end

  # Write the JS file using CompilerHelpers
  defp write_colocated_js(env, js_code) do
    target_dir = Lavash.Component.CompilerHelpers.get_target_dir()
    module_dir = Path.join(target_dir, inspect(env.module))

    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    filename = "reactive_#{hash}.js"
    full_path = Path.join(module_dir, filename)

    File.mkdir_p!(module_dir)

    needs_write =
      case File.read(full_path) do
        {:ok, existing} -> existing != js_code
        {:error, _} -> true
      end

    if needs_write do
      case File.ls(module_dir) do
        {:ok, files} ->
          for file <- files, String.starts_with?(file, "reactive_"), file != filename do
            File.rm(Path.join(module_dir, file))
          end
        _ -> :ok
      end

      File.write!(full_path, js_code)
    end

    module_name = inspect(env.module)
    {filename, %{name: module_name, key: "optimistic"}}
  end

  # Kahn's algorithm — mirrors ColocatedTransformer
  defp topo_sort_deps(deps_map) do
    names = Map.keys(deps_map)
    derive_names = MapSet.new(names)

    in_degree =
      Map.new(names, fn name ->
        count = (deps_map[name] || []) |> Enum.count(&MapSet.member?(derive_names, &1))
        {name, count}
      end)

    queue = for {name, 0} <- in_degree, do: name
    kahn(queue, in_degree, deps_map, derive_names, [])
  end

  defp kahn([], _in_degree, _deps_map, _derive_names, result), do: Enum.reverse(result)

  defp kahn([node | rest], in_degree, deps_map, derive_names, result) do
    dependents =
      for {name, dep_list} <- deps_map,
          node in dep_list,
          MapSet.member?(derive_names, name),
          do: name

    {in_degree, new_ready} =
      Enum.reduce(dependents, {in_degree, []}, fn dep, {deg, ready} ->
        new_deg = Map.update!(deg, dep, &(&1 - 1))
        if new_deg[dep] == 0, do: {new_deg, [dep | ready]}, else: {new_deg, ready}
      end)

    kahn(rest ++ new_ready, in_degree, deps_map, derive_names, [node | result])
  end

  defp build_dependents(deps_map) do
    Enum.reduce(deps_map, %{}, fn {name, dep_list}, acc ->
      Enum.reduce(dep_list, acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, [name], &[name | &1])
      end)
    end)
  end
end
