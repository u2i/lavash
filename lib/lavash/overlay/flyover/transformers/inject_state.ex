defmodule Lavash.Overlay.Flyover.Transformers.InjectState do
  @moduledoc """
  Transformer that injects flyover state and actions into a Lavash Component.

  This transformer:
  1. Adds the open_field as an animated ephemeral state field (if not already defined)
  2. Adds :close action that sets open_field to nil
  3. Adds :noop action for preventing backdrop click propagation
  4. Merges close behavior into any user-defined :close action
  5. Merges form params clearing into :open action (if exists)

  The open_field uses `animated: true` which triggers ExpandAnimatedStates to add:
  - `{open_field}_phase` state field
  - `{open_field}_visible` calculation
  - `{open_field}_animating` calculation
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: false

  # Run before GenerateRender
  # ExpandAnimatedStates will run after us via its after?(InjectState) clause
  def before?(Lavash.Overlay.Flyover.Transformers.GenerateRender), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    open_field = Transformer.get_option(dsl_state, [:flyover], :open_field) || :open
    async_assign = Transformer.get_option(dsl_state, [:flyover], :async_assign)

    dsl_state
    |> maybe_add_open_input(open_field, async_assign)
    |> add_is_open_calculation(open_field)
    |> add_or_merge_close_action(open_field)
    |> add_noop_action()
    |> merge_form_params_clear_into_open()
    |> then(&{:ok, &1})
  end

  # Add the open_field as animated ephemeral state if not already defined
  # Flyover owns its own open/closed state; parent opens via invoke
  # Uses animated: [...] for phase tracking and animation coordination
  defp maybe_add_open_input(dsl_state, open_field, async_assign) do
    existing_states = Transformer.get_entities(dsl_state, [:states])

    if Enum.any?(existing_states, &(&1.name == open_field)) do
      # User already defined this state field, don't override
      dsl_state
    else
      # Build animated options
      # preserve_dom: true keeps the content visible during exit animation
      # type: :flyover tells the animation system this is a flyover (for FlyoverAnimator)
      animated_opts =
        if async_assign do
          [async: async_assign, preserve_dom: true, duration: 200, type: :flyover]
        else
          [preserve_dom: true, duration: 200, type: :flyover]
        end

      state_field = %Lavash.State.Field{
        name: open_field,
        type: :any,
        from: :ephemeral,
        default: nil,
        optimistic: true,
        animated: animated_opts
      }

      Transformer.add_entity(dsl_state, [:states], state_field)
    end
  end

  # Add is_open calculation: rx(@open_field != nil)
  # This provides a convenient boolean for templates instead of checking nil
  defp add_is_open_calculation(dsl_state, open_field) do
    existing_calculations = Transformer.get_entities(dsl_state, [:calculations]) || []

    if Enum.any?(existing_calculations, &(&1.name == :is_open)) do
      # User already defined is_open, don't override
      dsl_state
    else
      # Build the rx struct for "@open_field != nil"
      # The AST needs to reference the state variable via Map.get(state, :open_field)
      state_var = Macro.var(:state, nil)

      ast =
        quote do
          Map.get(unquote(state_var), unquote(open_field), nil) != nil
        end

      rx = %Lavash.Rx{
        source: "@#{open_field} != nil",
        ast: ast,
        deps: [open_field]
      }

      calculation = %Lavash.Component.Calculate{
        name: :is_open,
        rx: rx,
        optimistic: true
      }

      Transformer.add_entity(dsl_state, [:calculations], calculation)
    end
  end

  # Add :close action or merge into existing one
  # Close sets the open_field to nil (flyover owns its state)
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
        notify_parents: []
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
        notify_parents: []
      }

      Transformer.add_entity(dsl_state, [:actions], noop_action)
    end
  end

  # Merge form params clearing into the :open action
  # This ensures that when opening a flyover with a different record,
  # stale form params from the previous record are cleared
  defp merge_form_params_clear_into_open(dsl_state) do
    existing_actions = Transformer.get_entities(dsl_state, [:actions])
    existing_open = Enum.find(existing_actions, &(&1.name == :open))

    if existing_open do
      # Get all forms defined in the component
      forms = Transformer.get_entities(dsl_state, [:forms])

      # Create set operations to clear each form's params
      clear_params_sets =
        Enum.map(forms, fn form ->
          params_field = :"#{form.name}_params"
          %Lavash.Actions.Set{field: params_field, value: nil}
        end)

      # Merge our sets into the existing open action (at the beginning)
      updated_open = %{existing_open | sets: clear_params_sets ++ (existing_open.sets || [])}

      Transformer.replace_entity(
        dsl_state,
        [:actions],
        updated_open,
        &(&1.name == :open)
      )
    else
      # No :open action defined, nothing to merge
      dsl_state
    end
  end
end
