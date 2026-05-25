defmodule Lavash.Actions.Redirect do
  @moduledoc """
  An action op that calls `Phoenix.LiveView.redirect/2` on the
  socket. Full-page reload to an external URL or to a non-live
  route in the same app.

  Distinct from `navigate` (live-session push_navigate) and from
  `push_patch` (URL update without remount).

  ## Example

      action :go_external do
        redirect "https://example.com"
      end

      action :sign_out do
        redirect "/auth/sign_out"
      end
  """
  defstruct [:to, __spark_metadata__: nil]
end
