defmodule Lavash.Assigns do
  @moduledoc """
  Projects metadata into socket assigns.

  State and derived values are written eagerly to assigns by
  `Lavash.Socket.put_state/3` and `Lavash.Socket.put_derived/3`.
  This module handles only form metadata projection and
  component state propagation.
  """

  def project(socket, module) do
    socket
    |> Lavash.Optimistic.Version.project()
    |> project_form_metadata(module)
  end

  # For each form, project :form_action assign with the action type
  defp project_form_metadata(socket, module) do
    forms = safe_get(module, :forms)

    Enum.reduce(forms, socket, fn form_entity, sock ->
      form_name = form_entity.name
      action_assign = :"#{form_name}_action"

      raw_value = socket.assigns[form_name]

      action_type =
        case raw_value do
          %Lavash.Form{action_type: type} ->
            type

          # When the form is loaded via `async_assign`, the resolved
          # value is wrapped in an AsyncResult. Unwrap the ok-case
          # so `:address_form_action` reflects the inner form's
          # `:create` or `:update` rather than falling through to
          # `nil` (which would make `@form_action == :create`
          # always false in the template — and silently invert
          # "Add" vs "Edit" labels). See u2i/lavash regression
          # added with `Lavash.AssignsTest`.
          %Phoenix.LiveView.AsyncResult{ok?: true, result: %Lavash.Form{action_type: type}} ->
            type

          %Phoenix.LiveView.AsyncResult{loading: loading} when loading != nil ->
            :loading

          %Phoenix.LiveView.AsyncResult{failed: failed} when failed != nil ->
            {:error, failed}

          _ ->
            nil
        end

      Phoenix.Component.assign(sock, action_assign, action_type)
    end)
  end

  # Safely get entities, returning empty list if not defined
  defp safe_get(module, key) do
    module.__lavash__(key)
  rescue
    _ -> []
  end
end
