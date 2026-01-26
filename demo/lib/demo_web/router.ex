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

  # Pipeline that ensures a user exists (creates anonymous user if needed)
  pipeline :ensure_user do
    plug DemoWeb.Plugs.EnsureUser
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

  # Demos index (home page)
  scope "/", DemoWeb do
    pipe_through :browser

    live "/", DemosIndexLive
  end

  # Storefront (public, with automatic anonymous user creation)
  scope "/storefront", DemoWeb do
    pipe_through [:browser, :ensure_user]

    live_session :storefront, on_mount: {DemoWeb.LiveUserAuth, :live_user_ensure} do
      live "/", StorefrontLive
      live "/products", Storefront.ProductsLive
      live "/products/:product_id", Storefront.ProductLive
    end
  end

  # Customer account (requires login)
  scope "/account", DemoWeb do
    pipe_through :browser

    live "/", Account.DashboardLive
    live "/orders", Account.OrdersLive
    live "/settings", Account.SettingsLive
  end

  # Admin section
  scope "/admin", DemoWeb.Admin do
    pipe_through :browser

    live "/", DashboardLive
    live "/products", ProductsLive
    live "/products/new", ProductEditLive
    live "/products/:product_id/edit", ProductEditLive
    live "/categories", CategoriesLive
  end

  # Demo/playground routes
  scope "/demos", DemoWeb do
    pipe_through :browser

    live "/counter", CounterLive
    live "/products", ProductsLive
    live "/products-socket", ProductsSocketLive
    live "/components", ComponentsDemoLive
    live "/bindings", BindingsDemoLive
    live "/tag-editor", TagEditorDemoLive
    live "/toggle", ToggleDemoLive
    live "/form-validation", FormValidationDemoLive
    live "/checkout", CheckoutDemoLive
    live "/flyover", FlyoverDemoLive
    live "/modal", ModalDemoLive
    live "/nesting", NestingDemoLive
    live "/validation", ValidationDemoLive
  end
end
