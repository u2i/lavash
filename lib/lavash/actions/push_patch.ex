defmodule Lavash.Actions.PushPatch do
  @moduledoc """
  An action op that calls `Phoenix.LiveView.push_patch/2` on the
  socket. Updates the URL and re-runs `handle_params/3` without
  remounting the LiveView, so calc/state hydration from the new
  URL flows through normally.

  Distinct from `navigate` (which `push_navigate`s and remounts in
  the same live session) and from `redirect` (external full-page
  reload).

  ## Example

      action :focus_item, [:id] do
        push_patch "/items/?selected=" <> @id
      end
  """
  defstruct [:to, __spark_metadata__: nil]
end
