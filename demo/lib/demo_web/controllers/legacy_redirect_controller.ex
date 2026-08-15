defmodule DemoWeb.LegacyRedirectController do
  @moduledoc """
  Permanent redirects from the pre-reorganization demo prefixes:
  /demos/* moved to /dsl/*, /lv/* to /reactive/* (except the
  hand-coded JS counter, now /js-counter). Bare prefixes go home —
  the landing page is the single index for all three structures.
  """
  use DemoWeb, :controller

  def dsl(conn, %{"path" => []}), do: moved(conn, "/")
  def dsl(conn, %{"path" => path}), do: moved(conn, "/dsl/" <> Enum.join(path, "/"))

  def reactive(conn, %{"path" => []}), do: moved(conn, "/")
  def reactive(conn, %{"path" => ["plain-counter"]}), do: moved(conn, "/js-counter")
  def reactive(conn, %{"path" => ["products"]}), do: moved(conn, "/builder/products")
  def reactive(conn, %{"path" => ["todos"]}), do: moved(conn, "/builder/todos")
  def reactive(conn, %{"path" => path}), do: moved(conn, "/reactive/" <> Enum.join(path, "/"))

  defp moved(conn, to) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: to)
  end
end
