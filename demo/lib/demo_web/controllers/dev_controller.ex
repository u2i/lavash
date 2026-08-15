defmodule DemoWeb.DevController do
  @moduledoc """
  Dev-tools endpoints. `reset/2` wipes everything the current
  (anonymous) visitor owns so the demo starts fresh — the data
  semantics live in each domain's `wipe_for_user!/1`.
  """
  use DemoWeb, :controller

  @doc false
  def reset(conn, _params) do
    case conn.assigns.current_user do
      %{id: user_id} ->
        Demo.Cart.wipe_for_user!(user_id)
        Demo.Orders.wipe_for_user!(user_id)
        Demo.Todos.wipe_for_user!(user_id)

      _ ->
        :ok
    end

    conn
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
