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

        acc
        |> Map.put(params_field, Map.get(assigns, params_field, %{}))
        |> Map.put(server_errors_field, Map.get(assigns, server_errors_field, %{}))
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

  @doc """
  Renders a child component with bindings, auto-injecting the parent CID.

  When used inside a Lavash.Component, this helper automatically passes
  `__lavash_parent_cid__` so that bound field updates can be routed back
  to the parent component.

  ## Usage

      <.child_component
        module={MyClientComponent}
        id="my-child"
        bind={[count: :my_count]}
        count={@my_count}
        myself={@myself}
      />

  This is equivalent to:

      <.live_component
        module={MyClientComponent}
        id="my-child"
        bind={[count: :my_count]}
        count={@my_count}
        __lavash_parent_cid__={@myself}
      />
  """
  attr :module, :atom, required: true
  attr :id, :string, required: true
  attr :myself, :any, required: true, doc: "The parent component's @myself"
  attr :bind, :list, default: nil
  attr :__lavash_client_bindings__, :map, default: %{}, doc: "Auto-injected by ~L sigil"
  attr :rest, :global, include: ~w(items count open)

  def child_component(assigns) do
    # Get parent's client bindings from assigns (set by Lavash.Component runtime)
    # This is automatically available - no need to pass explicitly
    parent_client_bindings = assigns[:__lavash_client_bindings__] || %{}

    # Build the assigns for live_component, injecting parent CID if bindings exist
    component_assigns =
      assigns.rest
      |> Map.put(:module, assigns.module)
      |> Map.put(:id, assigns.id)

    component_assigns =
      if assigns.bind do
        # Resolve bindings through parent's binding map for client-side propagation
        # If parent's field X is bound to grandparent's field Y, then child binding
        # to X should actually resolve to Y so lavash-set events reach the root LiveView
        #
        # Server-side still uses the original bindings for routing through each component
        # Client-side uses resolved bindings for direct propagation via lavash-set events

        resolved_client_bindings =
          Enum.into(assigns.bind, %{}, fn {child_field, parent_field} ->
            # Check if parent's field is itself bound to a grandparent
            case Map.get(parent_client_bindings, parent_field) do
              nil -> {child_field, parent_field}
              grandparent_field -> {child_field, grandparent_field}
            end
          end)

        component_assigns
        |> Map.put(:bind, assigns.bind)  # Keep original for server-side
        |> Map.put(:__lavash_parent_cid__, assigns.myself)
        |> Map.put(:__lavash_client_bindings__, resolved_client_bindings)  # For client-side
      else
        component_assigns
      end

    assigns = assign(assigns, :__component_assigns__, component_assigns)

    ~H"""
    <.live_component {@__component_assigns__} />
    """
  end
end
