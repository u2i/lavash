defmodule Lavash.Assigns do
  @moduledoc """
  Projects state and derived values into socket assigns.
  """

  def project(socket, module) do
    assigns_config = module.__lavash__(:assigns)
    state = socket.assigns.__lavash_state__
    derived = socket.assigns.__lavash_derived__

    Enum.reduce(assigns_config, socket, fn assign_def, sock ->
      value = compute_assign(assign_def, state, derived)
      Phoenix.Component.assign(sock, assign_def.name, value)
    end)
  end

  defp compute_assign(assign_def, state, derived) do
    sources = assign_def.from || [assign_def.name]

    values =
      Enum.map(sources, fn source ->
        cond do
          Map.has_key?(state, source) -> Map.get(state, source)
          Map.has_key?(derived, source) -> Map.get(derived, source)
          true -> nil
        end
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
end
