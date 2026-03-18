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

    # Collect props
    props =
      if function_exported?(module, :__lavash__, 1) do
        module.__lavash__(:props)
      else
        []
      end

    Enum.reduce(props, state_map, fn prop, acc ->
      value = Map.get(assigns, prop.name, prop.default)
      Map.put(acc, prop.name, value)
    end)
  end
end
