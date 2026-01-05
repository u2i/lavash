defmodule Lavash.Optimistic.ExpandAnimatedStates do
  @moduledoc """
  Spark transformer that expands animated state fields into phase tracking state and calculations.

  When a state field has `animated: true` or `animated: [options]`, this transformer:

  1. Adds a `{field}_phase` ephemeral state field (string, default "idle")
  2. Adds a `{field}_visible` calculation: phase != "idle"
  3. Adds a `{field}_animating` calculation: phase in ["entering", "exiting"]
  4. If `async: :async_field` option is set, adds `{field}_async_ready` calculation

  ## Phase State Machine

  The phases are:
  - `"idle"` - closed/hidden state
  - `"entering"` - animation in progress
  - `"loading"` - waiting for async data (only when async option set)
  - `"visible"` - fully open/visible
  - `"exiting"` - close animation in progress

  ## Options

  - `async: :field_name` - coordinate with async data loading
  - `preserve_dom: true` - keep DOM alive during exit animation
  - `duration: 200` - fallback timeout in ms

  ## Example

      state :product_id, :any, animated: [async: :product, preserve_dom: true]

  Expands to:
      state :product_id, :any
      state :product_id_phase, :string, from: :ephemeral, default: "idle"
      calculate :product_id_visible, rx(@product_id_phase != "idle")
      calculate :product_id_animating, rx(@product_id_phase == "entering" or @product_id_phase == "exiting")
      calculate :product_id_async_ready, rx(@product_id_phase == "visible" or @product != nil)
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  # Run after Modal's InjectState (which adds animated state fields)
  # but before DefrxExpander and ColocatedTransformer
  def after?(Lavash.Modal.Transformers.InjectState), do: true
  def after?(_), do: false

  def before?(Lavash.Optimistic.DefrxExpander), do: true
  def before?(Lavash.Optimistic.ColocatedTransformer), do: true
  def before?(Lavash.Modal.Transformers.GenerateRender), do: true
  def before?(_), do: false

  @doc """
  Transform the DSL state by expanding animated state fields.
  """
  def transform(dsl_state) do
    states = Transformer.get_entities(dsl_state, [:states]) || []

    # Only check StateField structs that have the animated field
    # (MultiSelect and Toggle don't have animated support)
    animated_states =
      Enum.filter(states, fn state ->
        is_struct(state, Lavash.State.Field) and
          Map.get(state, :animated) not in [nil, false]
      end)

    if Enum.empty?(animated_states) do
      {:ok, dsl_state}
    else
      dsl_state = Enum.reduce(animated_states, dsl_state, &expand_animated_state/2)
      {:ok, dsl_state}
    end
  end

  defp expand_animated_state(state, dsl_state) do
    field = state.name
    opts = normalize_animated_opts(state.animated)

    dsl_state
    |> add_phase_state(field)
    |> add_visible_calculation(field)
    |> add_animating_calculation(field)
    |> maybe_add_async_ready_calculation(field, opts)
    |> persist_animated_config(field, opts)
  end

  # Normalize animated option to keyword list
  defp normalize_animated_opts(true), do: []
  defp normalize_animated_opts(opts) when is_list(opts), do: opts

  # Add {field}_phase ephemeral state
  defp add_phase_state(dsl_state, field) do
    phase_field = :"#{field}_phase"
    existing_states = Transformer.get_entities(dsl_state, [:states]) || []

    if Enum.any?(existing_states, &(&1.name == phase_field)) do
      # User already defined this, don't override
      dsl_state
    else
      phase_state = %Lavash.State.Field{
        name: phase_field,
        type: :string,
        from: :ephemeral,
        default: "idle",
        optimistic: true
      }

      Transformer.add_entity(dsl_state, [:states], phase_state)
    end
  end

  # Add {field}_visible calculation: rx(@{field}_phase != "idle")
  defp add_visible_calculation(dsl_state, field) do
    calc_name = :"#{field}_visible"
    phase_field = :"#{field}_phase"
    existing_calcs = Transformer.get_entities(dsl_state, [:calculations]) || []

    if Enum.any?(existing_calcs, &(&1.name == calc_name)) do
      dsl_state
    else
      state_var = Macro.var(:state, nil)

      ast =
        quote do
          Map.get(unquote(state_var), unquote(phase_field), "idle") != "idle"
        end

      rx = %Lavash.Rx{
        source: "@#{phase_field} != \"idle\"",
        ast: ast,
        deps: [phase_field]
      }

      calculation = %Lavash.Component.Calculate{
        name: calc_name,
        rx: rx,
        optimistic: true
      }

      Transformer.add_entity(dsl_state, [:calculations], calculation)
    end
  end

  # Add {field}_animating calculation: rx(@{field}_phase == "entering" or @{field}_phase == "exiting")
  defp add_animating_calculation(dsl_state, field) do
    calc_name = :"#{field}_animating"
    phase_field = :"#{field}_phase"
    existing_calcs = Transformer.get_entities(dsl_state, [:calculations]) || []

    if Enum.any?(existing_calcs, &(&1.name == calc_name)) do
      dsl_state
    else
      state_var = Macro.var(:state, nil)

      ast =
        quote do
          phase = Map.get(unquote(state_var), unquote(phase_field), "idle")
          phase == "entering" or phase == "exiting"
        end

      rx = %Lavash.Rx{
        source: "@#{phase_field} == \"entering\" or @#{phase_field} == \"exiting\"",
        ast: ast,
        deps: [phase_field]
      }

      calculation = %Lavash.Component.Calculate{
        name: calc_name,
        rx: rx,
        optimistic: true
      }

      Transformer.add_entity(dsl_state, [:calculations], calculation)
    end
  end

  # Conditionally add {field}_async_ready when async option is specified
  defp maybe_add_async_ready_calculation(dsl_state, field, opts) do
    case Keyword.get(opts, :async) do
      nil ->
        dsl_state

      async_field ->
        add_async_ready_calculation(dsl_state, field, async_field)
    end
  end

  # Add {field}_async_ready calculation
  # True when phase is visible OR the async data has loaded
  defp add_async_ready_calculation(dsl_state, field, async_field) do
    calc_name = :"#{field}_async_ready"
    phase_field = :"#{field}_phase"
    existing_calcs = Transformer.get_entities(dsl_state, [:calculations]) || []

    if Enum.any?(existing_calcs, &(&1.name == calc_name)) do
      dsl_state
    else
      state_var = Macro.var(:state, nil)

      ast =
        quote do
          phase = Map.get(unquote(state_var), unquote(phase_field), "idle")
          async_data = Map.get(unquote(state_var), unquote(async_field))
          phase == "visible" or async_data != nil
        end

      rx = %Lavash.Rx{
        source: "@#{phase_field} == \"visible\" or @#{async_field} != nil",
        ast: ast,
        deps: [phase_field, async_field]
      }

      calculation = %Lavash.Component.Calculate{
        name: calc_name,
        rx: rx,
        optimistic: true
      }

      Transformer.add_entity(dsl_state, [:calculations], calculation)
    end
  end

  # Persist animated config for JavaScript generation
  defp persist_animated_config(dsl_state, field, opts) do
    animated_fields =
      Transformer.get_persisted(dsl_state, :lavash_animated_fields) || []

    config = %{
      field: field,
      phase_field: :"#{field}_phase",
      async: Keyword.get(opts, :async),
      preserve_dom: Keyword.get(opts, :preserve_dom, false),
      duration: Keyword.get(opts, :duration, 200)
    }

    Transformer.persist(dsl_state, :lavash_animated_fields, [config | animated_fields])
  end
end
