defmodule Lavash.State.MissingRequiredFieldError do
  @moduledoc """
  Raised when a `from: :url, required: true` state field is absent from the URL
  on mount or handle_params. Carries the offending field name so callers
  (error pages, telemetry, etc.) can pattern-match.
  """
  defexception [:field, :message]

  @impl true
  def exception(opts) do
    field = Keyword.fetch!(opts, :field)
    %__MODULE__{field: field, message: "required URL field #{inspect(field)} not present"}
  end
end

defmodule Lavash.State do
  @moduledoc """
  State hydration and management.
  """

  require Logger

  alias Lavash.Socket, as: LSocket
  alias Lavash.Type

  def hydrate_url(socket, module, params) do
    url_fields = module.__lavash__(:url_fields)

    Enum.reduce(url_fields, socket, fn field, sock ->
      value = parse_url_field(field, params)
      LSocket.put_state(sock, field.name, value)
    end)
  end

  @doc """
  Hydrates `from: :session` state from the Plug session map. Each
  field's `:session_key` (defaults to the field name as a string)
  is looked up; if absent, the field's `:default` is used. Session
  state is read once at mount and isn't re-read on subsequent
  events — like `from: :ephemeral` but seeded from the session at
  mount time.
  """
  def hydrate_session(socket, module, session) do
    session_fields = module.__lavash__(:session_fields)

    Enum.reduce(session_fields, socket, fn field, sock ->
      key = session_key(field)

      value =
        case Map.get(session, key) do
          nil -> field.default
          raw when is_binary(raw) and field.type != :string -> decode_type(raw, field.type)
          raw -> raw
        end

      LSocket.put_state(sock, field.name, value)
    end)
  end

  defp session_key(%{session_key: name}) when is_binary(name), do: name
  defp session_key(field), do: to_string(field.name)

  @doc """
  Hydrates fields declared `from: :assigns` by reading the named key
  out of `socket.assigns` at mount time.

  Runs AFTER any Phoenix `on_mount` hooks have completed (because
  hydrate_assigns is called inside `Lavash.LiveView.Runtime.mount/4`,
  which the runtime invokes from inside the LiveView's mount/3, by
  which point on_mount has run). So an assign that an on_mount
  installed — e.g. `:current_user` from `AshAuthentication.LiveView` —
  is present when this lifts it into lavash state.

  One-way read. If the field is later mutated via lavash actions, the
  change does NOT propagate back to socket.assigns. The socket assign
  is the source of truth at mount; lavash state is the source of
  truth thereafter.

  Resolution: `field.assigns_key` if set, otherwise `field.name`.
  Missing assigns fall back to `field.default`.
  """
  def hydrate_assigns(socket, module) do
    assigns_fields = module.__lavash__(:assigns_fields)

    Enum.reduce(assigns_fields, socket, fn field, sock ->
      key = field.assigns_key || field.name

      value =
        case Map.fetch(sock.assigns, key) do
          {:ok, v} -> v
          :error -> field.default
        end

      LSocket.put_state(sock, field.name, value)
    end)
  end

  def hydrate_ephemeral(socket, module) do
    ephemeral_fields = module.__lavash__(:ephemeral_fields)
    current_state = LSocket.state(socket)

    Enum.reduce(ephemeral_fields, socket, fn field, sock ->
      # Only set if not already present (preserve across reconnects if needed)
      if Map.has_key?(current_state, field.name) do
        sock
      else
        # Support function/0 defaults for runtime-generated values
        value =
          case field.default do
            fun when is_function(fun, 0) -> fun.()
            other -> other
          end

        LSocket.put_state(sock, field.name, value)
      end
    end)
  end

  @doc """
  Hydrates forms - creates implicit ephemeral state for form params.
  """
  def hydrate_forms(socket, module) do
    forms = module.__lavash__(:forms)
    current_state = LSocket.state(socket)

    Enum.reduce(forms, socket, fn form, sock ->
      params_field = :"#{form.name}_params"
      server_errors_field = :"#{form.name}_server_errors"

      sock
      |> then(fn s ->
        if Map.has_key?(current_state, params_field),
          do: s,
          else: LSocket.put_state(s, params_field, %{})
      end)
      |> then(fn s ->
        if Map.has_key?(current_state, server_errors_field),
          do: s,
          else: LSocket.put_state(s, server_errors_field, %{})
      end)
    end)
  end

  @doc """
  Hydrates socket fields from connect params.
  Socket fields survive reconnects via JS client sync.
  """
  def hydrate_socket(socket, module, connect_params) do
    socket_fields = module.__lavash__(:socket_fields)
    client_state = get_in(connect_params, ["_lavash_state"]) || %{}

    Enum.reduce(socket_fields, socket, fn field, sock ->
      key = to_string(field.name)
      raw_value = Map.get(client_state, key)

      value =
        cond do
          not Map.has_key?(client_state, key) -> field.default
          is_nil(raw_value) -> field.default
          raw_value == "" and field.type != :string -> field.default
          true -> decode_type(raw_value, field.type)
        end

      LSocket.put_state(sock, field.name, value)
    end)
  end

  defp parse_url_field(field, params) do
    key = url_key(field)
    raw = Map.get(params, key)

    cond do
      is_nil(raw) and field.required ->
        raise Lavash.State.MissingRequiredFieldError, field: field.name

      is_nil(raw) ->
        maybe_warn_url_key_mismatch(field, key, params)
        field.default

      field.decode ->
        field.decode.(raw)

      true ->
        decode_type(raw, field.type)
    end
  end

  defp url_key(%{url_name: name}) when is_binary(name), do: name
  defp url_key(field), do: to_string(field.name)

  # Dev-only nudge: when a `from: :url, required: false` field falls back to
  # the default and there's no matching key in params at all, log a warning.
  # This catches the common typo where the URL key differs from the field
  # name (e.g. `?subject=alice` vs `state :subject_handle, from: :url`).
  defp maybe_warn_url_key_mismatch(field, key, params) do
    if field.from == :url and not field.required and not Map.has_key?(params, key) and
         params != %{} do
      Logger.warning(fn ->
        "[lavash] state :#{field.name} (from: :url) looked for param #{inspect(key)} " <>
          "but it was not present in the URL. Available keys: #{inspect(Map.keys(params))}. " <>
          "If the URL key is different from the field name, set `url_name: \"...\"` on the state."
      end)
    end

    :ok
  end

  defp decode_type(value, type) do
    case Type.parse(type, value) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        raise ArgumentError, "Failed to parse #{inspect(value)} as #{inspect(type)}: #{reason}"
    end
  end
end
