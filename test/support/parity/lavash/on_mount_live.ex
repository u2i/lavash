defmodule Lavash.Parity.Lavash.OnMountLive do
  @moduledoc """
  Lavash DSL expression of the on_mount parity suite — paired
  with `Lavash.Parity.Vanilla.OnMountLive`.

  No new DSL surface for on_mount. The `on_mount {Mod, :tag}`
  macro is part of Phoenix.LiveView and works unchanged inside
  a `use Lavash.LiveView` module. The hook module
  (`Lavash.Parity.OnMountHook`) is shared verbatim with the
  vanilla fixture.

  This is by design: on_mount is already a clean capability with
  a clear vanilla API. Adding a lavash-specific wrapper would
  fork the docs and add no value. If a user wants the hook
  itself to be declarative (e.g. `on_mount_hook :require_user
  do ... end`), that's a future addition — for today, plain
  Elixir hooks work fine.
  """
  use Lavash.LiveView

  on_mount({Lavash.Parity.OnMountHook, :require_user})
  on_mount({Lavash.Parity.OnMountHook, :audit})

  # Hook-derived assigns surface here just like any other socket
  # assigns. The lavash DSL doesn't need to know about them.
  state :greeting, :string, default: "(unset)"

  template do
    ~H"""
    <div id="on-mount-lavash">
      <p id="current-user-id">{@current_user_id}</p>
      <p id="current-user-email">{@current_user_email}</p>
      <p id="audited">{not is_nil(@audited_at)}</p>
    </div>
    """
  end
end

defmodule Lavash.Parity.Lavash.LoginLive do
  @moduledoc false
  use Lavash.LiveView

  template do
    ~H"""
    <div id="parity-login">please sign in</div>
    """
  end
end
