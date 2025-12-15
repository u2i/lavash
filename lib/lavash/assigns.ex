defmodule Lavash.Assigns do
  @moduledoc """
  Projects state and derived values into socket assigns.
  """

  alias Lavash.Socket, as: LSocket

  def project(socket, module) do
    assigns_config = module.__lavash__(:assigns)
    state = LSocket.state(socket)
    derived = LSocket.derived(socket)

    # Store component states in process dictionary for child lavash_component calls
    component_states = LSocket.get(socket, :component_states) || %{}
    Lavash.LiveView.Helpers.put_component_states(component_states)

    Enum.reduce(assigns_config, socket, fn assign_def, sock ->
      value = compute_assign(assign_def, state, derived)
      Phoenix.Component.assign(sock, assign_def.name, value)
    end)
  end

  defp compute_assign(assign_def, state, derived) do
    sources = assign_def.from || [assign_def.name]

    values =
      Enum.map(sources, fn source ->
        raw_value =
          cond do
            Map.has_key?(state, source) -> Map.get(state, source)
            Map.has_key?(derived, source) -> Map.get(derived, source)
            true -> nil
          end

        # Auto-extract form from Lavash.Form wrapper for template rendering
        unwrap_for_assign(raw_value)
      end)

    case assign_def.transform do
      nil when length(values) == 1 ->
        hd(values)

      nil ->
        # Multiple sources, no transform - return as map
        sources
        |> Enum.zip(values)
        |> Map.new()

      transform when is_function(transform, 1) ->
        case values do
          [single] -> transform.(single)
          multiple -> transform.(multiple)
        end
    end
  end

  # Extract the Phoenix form from Lavash.Form for template rendering
  defp unwrap_for_assign(%Lavash.Form{form: form}), do: form
  defp unwrap_for_assign(other), do: other
end
