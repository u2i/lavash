defmodule Lavash.Component.Compiler do
  @moduledoc """
  Runtime utilities for Lavash Component compilation.

  Component callbacks (render/1, update/2, handle_event/2, introspection functions)
  are generated via Transformer.eval in ExtractColocatedJs.
  """

  @doc false
  def build_client_state(module, assigns) do
    # Collect optimistic state fields
    state_fields =
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:optimistic_fields)
      else
        []
      end

    state_map =
      Enum.reduce(state_fields, %{}, fn field, acc ->
        Map.put(acc, field.name, Map.get(assigns, field.name))
      end)

    # Props referenced by JS-side calcs/actions always ship. Beyond
    # those, ship any prop whose value is a JSON primitive: subtree
    # templates reference props the dep analysis can't see (class
    # strings, placeholders — `${state.tag_class}` in the generated
    # render), and a missing prop renders literally as "undefined" on
    # the first client re-render. Non-primitive props (Ash structs)
    # stay excluded — they'd crash Jason.encode and have no JS use.
    js_deps = collect_js_deps(module)

    props =
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:props)
      else
        []
      end

    Enum.reduce(props, state_map, fn prop, acc ->
      value = Map.get(assigns, prop.name, prop.default)

      cond do
        prop.name in js_deps -> Map.put(acc, prop.name, value)
        json_primitive?(value) -> Map.put(acc, prop.name, value)
        true -> acc
      end
    end)
  end

  defp json_primitive?(v)
       when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) or is_atom(v),
       do: true

  defp json_primitive?(_), do: false

  # Collect all field names referenced by JS calculations and action rx expressions.
  defp collect_js_deps(module) do
    calcs =
      if function_exported?(module, :__lavash_calculations__, 0) do
        module.__lavash_calculations__()
      else
        []
      end

    calc_deps =
      Enum.flat_map(calcs, fn {_name, _source, _ast, deps, _opt, _async, _reads} -> deps end)

    action_deps =
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:actions)
        |> Enum.flat_map(fn action ->
          set_deps =
            Enum.flat_map(action.sets || [], fn s ->
              case s.value do
                %Lavash.Rx{deps: deps} -> deps
                _ -> []
              end
            end)

          run_deps =
            Enum.flat_map(action.runs || [], fn r ->
              case r do
                %{reads: reads} when is_list(reads) -> reads
                _ -> []
              end
            end)

          set_deps ++ run_deps
        end)
      else
        []
      end

    MapSet.new(calc_deps ++ action_deps)
  end
end
