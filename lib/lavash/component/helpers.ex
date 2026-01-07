defmodule Lavash.Component.Helpers do
  @moduledoc """
  Helper functions for using Lavash components in LiveViews.
  """

  @doc """
  Extracts component states from connect_params and stores them in socket assigns.

  Call this in your LiveView's mount/3:

      def mount(_params, _session, socket) do
        socket = Lavash.Component.Helpers.init_component_states(socket)
        {:ok, socket}
      end

  Then pass the state to components:

      <.live_component
        module={MyComponent}
        id="my-component"
        __lavash_initial_state__={Lavash.Component.Helpers.get_component_state(@__lavash_component_states__, "my-component")}
      />
  """
  def init_component_states(socket) do
    component_states =
      if Phoenix.LiveView.connected?(socket) do
        connect_params = Phoenix.LiveView.get_connect_params(socket) || %{}
        get_in(connect_params, ["_lavash_state", "_components"]) || %{}
      else
        %{}
      end

    Phoenix.Component.assign(socket, :__lavash_component_states__, component_states)
  end

  @doc """
  Gets the state for a specific component by ID.
  """
  def get_component_state(component_states, component_id) when is_map(component_states) do
    Map.get(component_states, component_id, %{})
  end

  def get_component_state(nil, _component_id), do: %{}

  @doc """
  Builds the optimistic state map for a component.

  This is used to expose component state via data attributes for
  potential client-side access (without a JavaScript hook).
  """
  def optimistic_state(module, assigns) do
    # Get optimistic state fields
    state_fields = module.__lavash__(:optimistic_fields)

    # Get forms - their params are automatically optimistic
    forms = module.__lavash__(:forms)

    # Build the state map from optimistic fields
    state_map =
      Enum.reduce(state_fields, %{}, fn field, acc ->
        value = Map.get(assigns, field.name)
        Map.put(acc, field.name, value)
      end)

    # Add form params - forms are implicitly optimistic for client-side validation
    state_map =
      Enum.reduce(forms, state_map, fn form, acc ->
        params_field = :"#{form.name}_params"
        value = Map.get(assigns, params_field, %{})
        Map.put(acc, params_field, value)
      end)

    # Add derives, unwrapping async values
    derives = get_optimistic_derives(module)

    Enum.reduce(derives, state_map, fn derive, acc ->
      value = Map.get(assigns, derive.name)

      # Unwrap async values
      value =
        case value do
          %Phoenix.LiveView.AsyncResult{ok?: true, result: v} -> v
          %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> nil
          %Phoenix.LiveView.AsyncResult{} -> nil
          {:ok, v} -> v
          :loading -> nil
          {:error, _} -> nil
          v -> v
        end

      Map.put(acc, derive.name, value)
    end)
  end

  defp get_optimistic_derives(module) do
    # Get derives from module introspection
    derives = module.__lavash__(:derived_fields)
    calculations = module.__lavash__(:calculations)

    # Filter to only optimistic derives
    optimistic_derives =
      Enum.filter(derives, fn derive ->
        Map.get(derive, :optimistic, false)
      end)

    # Calculations are optimistic by default
    optimistic_calculations =
      Enum.filter(calculations, fn calc ->
        Map.get(calc, :optimistic, true)
      end)

    optimistic_derives ++ optimistic_calculations
  end
end
