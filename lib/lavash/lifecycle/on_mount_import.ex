defmodule Lavash.Lifecycle.OnMountImport do
  @moduledoc """
  Re-exports `Phoenix.LiveView.on_mount/1` so the macro is in
  scope inside `use Lavash.LiveView` modules without the user
  having to write `import Phoenix.LiveView, only: [on_mount: 1]`.

  This is a workaround for issue #20: Phoenix.LiveView's macros
  installed via `__using__` don't propagate through Spark's
  `handle_opts` eval. Re-exporting via a thin module that
  Lavash's `imports:` list pulls in restores the macro to user
  module scope.

  Once #20 is resolved (likely a Spark upstream fix), this
  module can be deleted.
  """

  @doc """
  Forwards to `Phoenix.LiveView.on_mount/1`. Declares an on_mount
  hook for the surrounding LiveView. The argument is a
  `{Module, :tag}` tuple or just a `Module` for the default tag.

  See `Phoenix.LiveView.on_mount/1` for full semantics.
  """
  defmacro on_mount(hook) do
    quote do
      require Phoenix.LiveView
      Phoenix.LiveView.on_mount(unquote(hook))
    end
  end
end
