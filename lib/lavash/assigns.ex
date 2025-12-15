defmodule Lavash.Assigns do
  @moduledoc """
  Projects state and derived values into socket assigns.

  All declared fields (state, derived, forms) are automatically
  projected as assigns - no explicit assigns section needed.
  """

  alias Lavash.Socket, as: LSocket

  def project(socket, module) do
    state = LSocket.state(socket)
    derived = LSocket.derived(socket)

    # Store component states in process dictionary for child lavash_component calls
    component_states = LSocket.get(socket, :component_states) || %{}
    Lavash.LiveView.Helpers.put_component_states(component_states)

    # Collect all field names - different for LiveViews vs Components
    all_fields = collect_field_names(module)

    # Project each field as an assign
    Enum.reduce(all_fields, socket, fn field_name, sock ->
      raw_value =
        cond do
          Map.has_key?(state, field_name) -> Map.get(state, field_name)
          Map.has_key?(derived, field_name) -> Map.get(derived, field_name)
          true -> nil
        end

      value = unwrap_for_assign(raw_value)
      Phoenix.Component.assign(sock, field_name, value)
    end)
  end

  # Collect field names based on module type (LiveView vs Component)
  defp collect_field_names(module) do
    # Common fields for both LiveViews and Components
    ephemeral_fields = safe_get(module, :ephemeral_fields) |> Enum.map(& &1.name)
    socket_fields = safe_get(module, :socket_fields) |> Enum.map(& &1.name)
    derived_fields = safe_get(module, :derived_fields) |> Enum.map(& &1.name)

    # LiveView-specific fields
    url_fields = safe_get(module, :url_fields) |> Enum.map(& &1.name)
    form_fields = safe_get(module, :forms) |> Enum.map(& &1.name)

    # Component-specific fields
    prop_fields = safe_get(module, :props) |> Enum.map(& &1.name)

    url_fields ++ ephemeral_fields ++ socket_fields ++ derived_fields ++ form_fields ++ prop_fields
  end

  # Safely get entities, returning empty list if not defined
  defp safe_get(module, key) do
    try do
      module.__lavash__(key)
    rescue
      _ -> []
    end
  end

  # Extract the Phoenix form from Lavash.Form for template rendering
  defp unwrap_for_assign(%Lavash.Form{form: form}), do: form
  defp unwrap_for_assign(other), do: other
end
