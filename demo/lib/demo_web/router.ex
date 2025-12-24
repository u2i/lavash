defmodule DemoWeb.Router do
  use DemoWeb, :router
  use AshAuthentication.Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authentication routes
  scope "/", DemoWeb do
    pipe_through :browser

    sign_in_route(auth_routes_prefix: "/auth")
    sign_out_route AuthController
    auth_routes AuthController, Demo.Accounts.User, path: "/auth"
    reset_route auth_routes_prefix: "/auth"
  end

  scope "/", DemoWeb do
    pipe_through :browser

    live "/", CounterLive
    live "/products", ProductsLive
    live "/products/new", ProductEditLive
    live "/products-socket", ProductsSocketLive
    live "/products/:product_id/edit", ProductEditLive
    live "/categories", CategoriesLive
    live "/components", ComponentsDemoLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", DemoWeb do
  #   pipe_through :api
  # end
end
