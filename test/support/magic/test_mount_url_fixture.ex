defmodule Lavash.Test.Magic.MountUrlLive do
  @moduledoc """
  Fixture: `mount do run` bodies must see URL state (path/query
  params), the way plain LiveView's mount/3 sees params. Regression
  for the ProductLive bounce — URL state used to hydrate only in
  handle_params, so mount-time reads of a URL field always got nil.
  """
  use Lavash.LiveView

  state :thing_id, :string, from: :url
  state :seen_at_mount, :string, default: nil

  mount do
    run fn socket ->
      Lavash.Socket.put_state(socket, :seen_at_mount, socket.assigns[:thing_id] || "MISSING")
    end
  end

  template do
    ~H"""
    <div id="seen">{@seen_at_mount}</div>
    """
  end
end
