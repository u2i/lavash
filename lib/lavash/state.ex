defmodule Lavash.State do
  @moduledoc """
  State hydration and management.
  """

  alias Lavash.Type
  alias Lavash.Socket, as: LSocket

  def hydrate_url(socket, module, params) do
    url_fields = module.__lavash__(:url_fields)

    state =
      Enum.reduce(url_fields, LSocket.state(socket), fn field, state ->
        value = parse_url_field(field, params)
        Map.put(state, field.name, value)
      end)

    LSocket.put(socket, :state, state)
  end

  def hydrate_ephemeral(socket, module) do
    ephemeral_fields = module.__lavash__(:ephemeral_fields)

    state =
      Enum.reduce(ephemeral_fields, LSocket.state(socket), fn field, state ->
        # Only set if not already present (preserve across reconnects if needed)
        if Map.has_key?(state, field.name) do
          state
        else
          Map.put(state, field.name, field.default)
        end
      end)

    LSocket.put(socket, :state, state)
  end

  @doc """
  Hydrates socket fields from connect params.
  Socket fields survive reconnects via JS client sync.
  """
  def hydrate_socket(socket, module, connect_params) do
    socket_fields = module.__lavash__(:socket_fields)
    client_state = get_in(connect_params, ["_lavash_state"]) || %{}

    state =
      Enum.reduce(socket_fields, LSocket.state(socket), fn field, state ->
        # Try to get from client state, fall back to default
        key = to_string(field.name)
        raw_value = Map.get(client_state, key)

        value =
          cond do
            # No key in client state - use default
            not Map.has_key?(client_state, key) -> field.default
            # Nil value - use default
            is_nil(raw_value) -> field.default
            # Empty string for non-string types - use default
            raw_value == "" and field.type != :string -> field.default
            # Decode the value
            true -> decode_type(raw_value, field.type)
          end

        Map.put(state, field.name, value)
      end)

    LSocket.put(socket, :state, state)
  end

  defp parse_url_field(field, params) do
    raw = Map.get(params, to_string(field.name))

    cond do
      is_nil(raw) and field.required ->
        raise "Required URL field #{field.name} not present"

      is_nil(raw) ->
        field.default

      field.decode ->
        field.decode.(raw)

      true ->
        decode_type(raw, field.type)
    end
  end

  defp decode_type(value, type) do
    case Type.parse(type, value) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise ArgumentError, "Failed to parse #{inspect(value)} as #{inspect(type)}: #{reason}"
    end
  end
end
