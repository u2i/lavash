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
            map_bys = action.map_bys || []
            has_transpilable = (sets ++ updates ++ map_bys) != []

            has_transpilable &&
              Enum.all?(sets, fn set ->
                case ActionJs.analyze_value(set.value) do
                  {:rx, _} -> true
                  {:literal, _} -> true
                  :from_params_value -> true
                  _ -> false
                end
              end) &&
              Enum.all?(map_bys, fn _mb -> true end)
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
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []
    template_source = resolve_template_source(lavash_renders)

    if is_nil(template_source) do
      {:ok, dsl_state}
    else
      # Get calculations
      calculations =
        (Transformer.get_entities(dsl_state, [:calculations]) || [])
        |> Enum.filter(&Map.get(&1, :optimistic, true))
        |> Enum.map(fn calc ->
          {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps}
        end)

      # Convert DSL actions to JS action specs
      action_specs = actions_to_js_specs(optimistic_actions)

      # Build metadata for template transformation
      optimistic_actions_map =
        action_specs
        |> Enum.map(fn %{name: name, field: field} -> {name, %{field: field}} end)
        |> Map.new()

      metadata = %{
        context: :client_component,
        optimistic_fields: %{},
        optimistic_derives: %{},
        calculations:
          calculations
          |> Enum.map(fn {name, _, _, _} -> {name, %{optimistic: true}} end)
          |> Map.new(),
        forms: %{},
        actions: %{},
        optimistic_actions: optimistic_actions_map
      }

      # Transform template (injects data-lavash-action etc.)
      transformed_source =
        Lavash.Template.Transformer.transform(template_source, env.module,
          context: :client_component,
          metadata: metadata
        )

      # Generate the JS hook code
      js_code = generate_js_hook(transformed_source, calculations, action_specs)

      # Write colocated hook file
      module_name = env.module |> Module.split() |> List.last()
      full_hook_name = "#{inspect(env.module)}.#{module_name}"

      hook_data = CompilerHelpers.write_colocated_hook(env, full_hook_name, js_code)

      dsl_state =
        dsl_state
        |> Transformer.persist(:lavash_client_hook_data, hook_data)
        |> Transformer.persist(:lavash_client_hook_name, full_hook_name)

      {:ok, dsl_state}
    end
  end

  # Convert DSL action entities to JS action specs
  defp actions_to_js_specs(actions) do
    Enum.flat_map(actions, fn action ->
      sets = action.sets || []
      updates = action.updates || []
      map_bys = action.map_bys || []

      set_specs =
        Enum.flat_map(sets, fn set ->
          case ActionJs.analyze_value(set.value) do
            {:rx, source} ->
              [%{type: :set, name: action.name, field: set.field,
                 run_source: "fn _current, _params -> #{source} end"}]

            :from_params_value ->
              [%{type: :set, name: action.name, field: set.field, run_source: nil}]

            {:literal, value} ->
              [%{type: :set, name: action.name, field: set.field,
                 run_source: "fn _current, _params -> #{inspect(value)} end"}]

            _ -> []
          end
        end)

      update_specs =
        Enum.map(updates, fn update ->
          source = Macro.to_string(update.fun)
          %{type: :set, name: action.name, field: update.field, run_source: source}
        end)

      map_by_specs =
        Enum.map(map_bys, fn mb ->
          source = cond do
            mb.transform == :remove -> ":remove"
            is_binary(mb.transform) -> mb.transform
            true ->
              case ActionJs.analyze_value(mb.transform) do
                {:rx, s} -> "fn item, _value -> #{s} end"
                _ -> nil
              end
          end

          %{type: :map_by, name: action.name, field: mb.field,
            key: mb.key, transform_source: source}
        end)
        |> Enum.filter(& &1.transform_source)

      set_specs ++ update_specs ++ map_by_specs
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

  # JS generation — delegates to the existing GenerateHook
  defp generate_js_hook(template_source, calculations, action_specs) do
    # Convert action specs to the format GenerateHook.generate_js_hook expects
    actions =
      Enum.map(action_specs, fn spec ->
        case spec[:type] do
          :map_by ->
            # map_by specs: use key for keyed array mutation
            # Transform the rx source to a run_source that GenerateHook understands
            run_source = spec.transform_source

            %{
              name: spec.name,
              field: spec.field,
              key: spec.key,
              run_source: run_source,
              validate_source: nil,
              max: nil
            }

          _ ->
            %{
              name: spec.name,
              field: spec.field,
              key: nil,
              run_source: spec[:run_source],
              validate_source: nil,
              max: nil
            }
        end
      end)

    Lavash.ClientComponent.Transformers.GenerateHook.generate_js_hook(
      template_source,
      calculations,
      actions
    )
  end
end
