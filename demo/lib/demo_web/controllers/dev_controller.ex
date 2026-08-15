defmodule DemoWeb.DevController do
  @moduledoc """
  Dev-tools endpoints. `reset/2` destroys the current (anonymous)
  visitor — DB-level cascades take their todos, carts, orders, and
  addresses with them — and drops the session, so the next request
  mints a fresh user. The semantics live in `Demo.Accounts.User`'s
  `:reset` action.
  """
  use DemoWeb, :controller

  @doc false
  def reset(conn, _params) do
    case conn.assigns.current_user do
      %{id: _} = user -> Demo.Accounts.reset_visitor!(user)
      _ -> :ok
    end

    conn
    |> clear_session()
    |> put_flash(:info, "Your demo data has been reset.")
    |> redirect(to: safe_referer(conn))
  end

  # Bounce back to wherever the reset was clicked from; internal paths only.
  defp safe_referer(conn) do
    case get_req_header(conn, "referer") do
      [ref | _] ->
        case URI.parse(ref) do
          %URI{path: path} when is_binary(path) -> path
          _ -> "/"
        end

      _ ->
        "/"
    end
  end
end
