defmodule Lavash.Component.Helpers do
  @moduledoc """
  Helper functions for using Lavash components in LiveViews.
  """
  use Phoenix.Component

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

    # Add form params and server errors - forms are implicitly optimistic for client-side validation
    state_map =
      Enum.reduce(forms, state_map, fn form, acc ->
        params_field = :"#{form.name}_params"
        server_errors_field = :"#{form.name}_server_errors"

        action_field = :"#{form.name}_action"

        acc
        |> Map.put(params_field, Map.get(assigns, params_field, %{}))
        |> Map.put(server_errors_field, Map.get(assigns, server_errors_field, %{}))
        |> Map.put(action_field, Map.get(assigns, action_field))
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
    # Read from persisted field specs (set by ExpandFields transformer)
    specs = Spark.Dsl.Extension.get_persisted(module, :lavash_field_specs) || []

    Enum.filter(specs, &Map.get(&1, :optimistic, false))
  end

end
