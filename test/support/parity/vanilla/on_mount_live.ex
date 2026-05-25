defmodule Lavash.Parity.Vanilla.OnMountLive do
  @moduledoc """
  Vanilla `Phoenix.LiveView` reference for the on_mount parity
  suite. Installs two hooks from `Lavash.Parity.OnMountHook`:

    * `:require_user` — auth gate; redirects when session has no
      user id
    * `:audit` — stamps `:audited_at` into assigns

  Hooks fire in declaration order; both must run before the
  LV's own `mount/3`.
  """
  use Phoenix.LiveView

  on_mount({Lavash.Parity.OnMountHook, :require_user})
  on_mount({Lavash.Parity.OnMountHook, :audit})

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="on-mount-vanilla">
      <p id="current-user-id">{@current_user_id}</p>
      <p id="current-user-email">{@current_user_email}</p>
      <p id="audited">{not is_nil(@audited_at)}</p>
    </div>
    """
  end
end

defmodule Lavash.Parity.Vanilla.LoginLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="parity-login">please sign in</div>
    """
  end
end
