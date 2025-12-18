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
    socket =
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

    # Project form metadata (action_type) for each form
    project_form_metadata(socket, module, derived)
  end

  # For each form, project :form_action assign with the action type
  defp project_form_metadata(socket, module, derived) do
    forms = safe_get(module, :forms)

    Enum.reduce(forms, socket, fn form_entity, sock ->
      form_name = form_entity.name
      action_assign = :"#{form_name}_action"

      raw_value = Map.get(derived, form_name)

      action_type =
        case raw_value do
          %Lavash.Form{action_type: type} -> type
          %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil -> :loading
          %Phoenix.LiveView.AsyncResult{failed: failed} when failed != nil -> {:error, failed}
          _ -> nil
        end

      Phoenix.Component.assign(sock, action_assign, action_type)
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
    read_fields = safe_get(module, :reads) |> Enum.map(& &1.name)
    form_fields = safe_get(module, :forms) |> Enum.map(& &1.name)

    # Component-specific fields
    prop_fields = safe_get(module, :props) |> Enum.map(& &1.name)

    url_fields ++
      ephemeral_fields ++
      socket_fields ++ derived_fields ++ read_fields ++ form_fields ++ prop_fields
  end

  # Safely get entities, returning empty list if not defined
  defp safe_get(module, key) do
    try do
      module.__lavash__(key)
    rescue
      _ -> []
    end
  end

  # Unwrap values for template rendering:
  # - Lavash.Form -> Phoenix.HTML.Form for form helpers
  # - AsyncResult with Lavash.Form inside -> AsyncResult with Phoenix.HTML.Form (keep wrapper!)
  # - All other values passed through as-is (including AsyncResult structs)
  defp unwrap_for_assign(%Lavash.Form{form: form}), do: form

  defp unwrap_for_assign(
         %Phoenix.LiveView.AsyncResult{ok?: true, result: %Lavash.Form{form: form}} = async
       ) do
    # Keep the AsyncResult wrapper so <.async_result> can work with it
    %{async | result: form}
  end

  defp unwrap_for_assign(other), do: other
end
