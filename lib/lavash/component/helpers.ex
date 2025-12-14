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
end
