defmodule Lavash.Component.Transformers.GenerateClientHook do
  @moduledoc """
  Spark transformer that generates a client-side JS hook for a Lavash Component.

  When a component has actions with transpilable `rx()` expressions, this
  transformer generates a colocated JS hook (via `createClientComponentHook`)
  that enables optimistic client-side rendering.

  The hook provides:
  - A JS render function transpiled from the `~L` template
  - Action functions transpiled from `set :field, rx(...)` expressions
  - Derive functions from `calculate :name, rx(...)` declarations
  - morphdom-based DOM patching for instant UI updates

  Only generates a hook if the component has transpilable actions.
  Components without optimistic actions remain server-rendered only.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Lavash.Component.CompilerHelpers
  alias Lavash.Optimistic.ActionJs

  # Run after ExpandAnimatedStates and ExpandFields
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  # Run before ExtractColocatedJs
  def before?(Lavash.Optimistic.Transformers.ExtractColocatedJs), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    env = Transformer.get_persisted(dsl_state, :env)

    if is_nil(module) or is_nil(env) do
      {:ok, dsl_state}
    else
      # Skip components that use overlay extensions (modal/flyover) —
      # they have their own animation mechanism, not client-side rendering
      has_overlay = Transformer.get_persisted(dsl_state, :lavash_overlay_render_generator) != nil

      actions = Transformer.get_entities(dsl_state, [:actions]) || []

      # Only consider actions where ALL sets are transpilable to JS
      optimistic_actions =
        if has_overlay do
          []
        else
          actions
          |> Enum.filter(fn action ->
            sets = action.sets || []
            updates = action.updates || []
            has_transpilable = (sets ++ updates) != []

            has_transpilable &&
              Enum.all?(sets, fn set ->
                case ActionJs.analyze_value(set.value) do
                  {:rx, _} -> true
                  {:literal, _} -> true
                  :from_params_value -> true
                  _ -> false
                end
              end)
          end)
        end

      if optimistic_actions == [] do
        {:ok, dsl_state}
      else
        generate(dsl_state, env, optimistic_actions)
      end
    end
  end

  defp generate(dsl_state, env, optimistic_actions) do
    # Get template source from render macro
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []
    template_source = resolve_template_source(lavash_renders)

    if is_nil(template_source) do
      {:ok, dsl_state}
    else
      # Convert DSL actions to ClientComponent action format
      # ClientComponent expects: {name, field, key, run_source, validate_source, max}
      action_tuples = actions_to_tuples(optimistic_actions)

      # Store as module attribute so the existing GenerateHook can read them
      for tuple <- action_tuples do
        Module.put_attribute(env.module, :__lavash_optimistic_actions__, tuple)
      end

      # Store template in renders attribute if not already there
      # The existing GenerateHook reads from :__lavash_renders__

      # Now delegate to the existing GenerateHook transformer
      # It reads from module attributes and generates the JS hook
      Lavash.ClientComponent.Transformers.GenerateHook.transform(dsl_state)
    end
  end

  # Convert DSL action entities to ClientComponent action tuples
  defp actions_to_tuples(actions) do
    Enum.flat_map(actions, fn action ->
      sets = action.sets || []
      updates = action.updates || []

      set_tuples =
        Enum.flat_map(sets, fn set ->
          case ActionJs.analyze_value(set.value) do
            {:rx, source} ->
              [{action.name, set.field, nil,
                "fn _current, _params -> #{source} end",
                nil, nil}]

            :from_params_value ->
              [{action.name, set.field, nil, nil, nil, nil}]

            {:literal, value} ->
              [{action.name, set.field, nil,
                "fn _current, _params -> #{inspect(value)} end",
                nil, nil}]

            _ -> []
          end
        end)

      update_tuples =
        Enum.map(updates, fn update ->
          source = Macro.to_string(update.fun)
          {action.name, update.field, nil, source, nil, nil}
        end)

      set_tuples ++ update_tuples
    end)
  end

  defp resolve_template_source(lavash_renders) do
    renders_map = Map.new(lavash_renders)

    case Map.get(renders_map, :__render_fn__) do
      nil -> nil
      escaped_fn -> extract_source(escaped_fn)
    end
  end

  defp extract_source({:fn, _, [{:->, _, [[_], body]}]}), do: extract_compiled_source(body)
  defp extract_source(_), do: nil

  defp extract_compiled_source({:sigil_L, _, [{:<<>>, _, [source]}, _]}) when is_binary(source), do: source
  defp extract_compiled_source({:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]}) do
    Keyword.get(fields, :source)
  end
  defp extract_compiled_source({:__block__, _, [inner]}), do: extract_compiled_source(inner)
  defp extract_compiled_source({:quote, _, [[do: ast]]}), do: extract_compiled_source(ast)
  defp extract_compiled_source(_), do: nil
end
