defmodule Lavash.Binding.Validation do
  @moduledoc """
  Validates `bind={[child_field: :parent_field]}` sites.

  A component's bindable surface is exactly its `from: :bound` state
  fields (`__lavash__(:bound_fields)`). Binding anything else — a prop,
  an `:ephemeral`/`:socket` field, an unknown name — is an error: the
  child's declaration would be making state-source choices the binding
  silently overrides (issue #87).

  Two call sites:

  - **Compile time** (`Lavash.Optimistic.ClientBindingsTransformer`):
    when the template's `module={...}` resolves to a compiled Lavash
    component and `bind` is a literal keyword list, both the child side
    and the parent side are checked and failures raise `CompileError`.
  - **Runtime** (`Lavash.Component.Runtime` on first mount): the child
    side is re-checked with the actual module, catching dynamic
    `module={...}` / `bind={...}` the transformer couldn't see.

  Child-side rules:

  1. The bound field must be a state field declared `from: :bound`.
  2. Props are one-way (parent-set, read-only) and can never be bound.

  Parent-side rules (compile time only — they need the parent's field
  declarations, which the runtime child doesn't have):

  3. The parent side must not be a calculation — writes can't propagate
     into a derived value.
  4. Concrete type mismatch between the two sides is an error.
  5. If the child field participates in optimistic prediction, the
     parent field must be client-visible (optimistic, animated, or
     setter-backed) — otherwise the child's predictions resolve through
     the client-binding chain to a field that doesn't exist in client
     state.
  """

  alias Lavash.State.Field

  @doc """
  Validates the child side of bind pairs against the child module's
  declarations. Returns `:ok` or `{:error, message}`.

  Skips (returns `:ok`) when the module doesn't expose lavash
  introspection — a non-lavash module fails loudly elsewhere.
  """
  def validate_child_side(child_module, pairs) do
    if lavash_component?(child_module) do
      bound = MapSet.new(child_module.__lavash__(:bound_fields), & &1.name)
      states = Map.new(child_module.__lavash__(:states), &{&1.name, &1})
      props = MapSet.new(child_module.__lavash__(:props), & &1.name)

      Enum.find_value(pairs, :ok, fn {child_field, _parent_field} ->
        cond do
          MapSet.member?(bound, child_field) ->
            nil

          MapSet.member?(props, child_field) ->
            {:error,
             "cannot bind #{inspect(child_module)}.#{child_field}: it is a prop " <>
               "(one-way, parent-set). Props can't be bound — declare it as " <>
               "`state :#{child_field}, ..., from: :bound` to make it bindable."}

          match?(%Field{}, states[child_field]) ->
            {:error,
             "cannot bind #{inspect(child_module)}.#{child_field}: it is declared " <>
               "`from: #{inspect(states[child_field].from)}`. Only `from: :bound` " <>
               "state fields are bindable — the parent field owns source and " <>
               "seeding for a bound field, so the child must not claim its own."}

          true ->
            {:error,
             "cannot bind #{inspect(child_module)}.#{child_field}: no such state " <>
               "field. Bindable fields on #{inspect(child_module)}: " <>
               "#{format_names(bound)}."}
        end
      end)
    else
      :ok
    end
  end

  @doc """
  Validates the parent side of bind pairs using the parent's
  token-transformer metadata (all_state_fields, optimistic_fields,
  calculation_names). Returns `:ok` or `{:error, message}`.
  """
  def validate_parent_side(child_module, pairs, metadata) do
    all_state = metadata[:all_state_fields] || %{}
    calc_names = metadata[:calculation_names] || MapSet.new()
    child_states = Map.new(child_module.__lavash__(:states), &{&1.name, &1})
    parent = metadata[:caller_module]

    Enum.find_value(pairs, :ok, fn {child_field, parent_field} ->
      child_state = child_states[child_field]
      parent_state = all_state[parent_field]

      cond do
        MapSet.member?(calc_names, parent_field) ->
          {:error,
           "cannot bind to #{inspect(parent)}.#{parent_field}: it is a calculation. " <>
             "Bound fields are two-way — writes from the child can't propagate " <>
             "into a derived value. Bind to a state field instead."}

        is_nil(child_state) or is_nil(parent_state) ->
          # Unknown parent fields keep today's warning path (the
          # transformer logs it); unknown child fields are the child
          # side's error.
          nil

        not compatible_type?(child_state.type, field_type(parent_state)) ->
          {:error,
           "type mismatch binding #{inspect(child_module)}.#{child_field} " <>
             "(#{inspect(child_state.type)}) to #{inspect(parent)}.#{parent_field} " <>
             "(#{inspect(field_type(parent_state))}). The two sides are one piece " <>
             "of state — their types must agree (or one side must be :any)."}

        Field.optimistic?(child_state) and not client_visible?(parent_state) ->
          {:error,
           "#{inspect(child_module)}.#{child_field} is optimistic, but the bound " <>
             "parent field #{inspect(parent)}.#{parent_field} is not client-visible. " <>
             "The child's predictions resolve through the binding chain to " <>
             "`#{parent_field}` in the root's client state — mark it " <>
             "`optimistic: true` (or give it a setter) so the prediction has " <>
             "somewhere to land."}

        true ->
          nil
      end
    end)
  end

  defp lavash_component?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :__lavash__, 1)
  end

  defp compatible_type?(a, b) when a in [nil, :any] or b in [nil, :any], do: true
  defp compatible_type?(a, a), do: true
  defp compatible_type?(_, _), do: false

  # all_state_fields values are Field structs for states but plain prop
  # structs for props — both carry :type.
  defp field_type(%{type: type}), do: type
  defp field_type(_), do: :any

  defp client_visible?(%Field{} = field) do
    Field.optimistic?(field) or field.setter == true
  end

  # Props as parent side (component mid-chain pass-through) don't carry
  # optimistic flags — treat as visible and let the chain's real owner
  # be validated at its own bind site.
  defp client_visible?(_), do: true

  defp format_names(names) do
    case Enum.sort(names) do
      [] -> "(none declared)"
      list -> Enum.map_join(list, ", ", &":#{&1}")
    end
  end
end
