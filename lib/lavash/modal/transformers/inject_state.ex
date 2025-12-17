defmodule Lavash.Modal.Transformers.InjectState do
  @moduledoc """
  Transformer that injects modal state and actions into a Lavash Component.

  This transformer:
  1. Adds the open_field as an ephemeral state field (if not already defined)
  2. Adds :close action that sets open_field to nil
  3. Adds :noop action for preventing backdrop click propagation
  4. Merges close behavior into any user-defined :close action
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(Lavash.Modal.Transformers.GenerateRender), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    open_field = Transformer.get_option(dsl_state, [:modal], :open_field) || :open

    dsl_state
    |> maybe_add_open_input(open_field)
    |> add_or_merge_close_action(open_field)
    |> add_noop_action()
    |> then(&{:ok, &1})
  end

  # Add the open_field as an ephemeral state field if not already defined
  defp maybe_add_open_input(dsl_state, open_field) do
    existing_states = Transformer.get_entities(dsl_state, [:states])

    if Enum.any?(existing_states, &(&1.name == open_field)) do
      # User already defined this state field, don't override
      dsl_state
    else
      state_field = %Lavash.StateField{
        name: open_field,
        type: :any,
        from: :ephemeral,
        default: nil
      }

      Transformer.add_entity(dsl_state, [:states], state_field)
    end
  end

  # Add :close action or merge into existing one
  defp add_or_merge_close_action(dsl_state, open_field) do
    existing_actions = Transformer.get_entities(dsl_state, [:actions])
    existing_close = Enum.find(existing_actions, &(&1.name == :close))

    close_set = %Lavash.Actions.Set{field: open_field, value: nil}

    if existing_close do
      # Merge our set into the existing close action
      updated_close = %{existing_close | sets: [close_set | existing_close.sets || []]}

      Transformer.replace_entity(
        dsl_state,
        [:actions],
        updated_close,
        &(&1.name == :close)
      )
    else
      # Create new close action
      close_action = %Lavash.Actions.Action{
        name: :close,
        params: [],
        when: [],
        sets: [close_set],
        updates: [],
        effects: [],
        submits: [],
        navigates: [],
        flashes: [],
        invokes: [],
        notify_parents: [],
        emits: []
      }

      Transformer.add_entity(dsl_state, [:actions], close_action)
    end
  end

  # Add :noop action if not already defined
  defp add_noop_action(dsl_state) do
    existing_actions = Transformer.get_entities(dsl_state, [:actions])

    if Enum.any?(existing_actions, &(&1.name == :noop)) do
      dsl_state
    else
      noop_action = %Lavash.Actions.Action{
        name: :noop,
        params: [],
        when: [],
        sets: [],
        updates: [],
        effects: [],
        submits: [],
        navigates: [],
        flashes: [],
        invokes: [],
        notify_parents: [],
        emits: []
      }

      Transformer.add_entity(dsl_state, [:actions], noop_action)
    end
  end
end
