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
    sign_out_route(AuthController)
    auth_routes(AuthController, Demo.Accounts.User, path: "/auth")
    reset_route(auth_routes_prefix: "/auth")
  end

  # Demos index (home page). Anonymous identity everywhere: every
  # visitor gets their own data (todos, carts, ...) without logging
  # in — EnsureUser creates the anonymous user, live_user_ensure
  # carries it into the LiveViews.
  scope "/", DemoWeb do
    pipe_through [:browser, :ensure_user]

    live_session :home,
      layout: {DemoWeb.Layouts, :demo},
      on_mount: [{DemoWeb.LiveUserAuth, :live_user_ensure}, DemoWeb.SourceLink] do
      live "/", DemosIndexLive
      live "/chat", StreamingChatLive
    end
  end

  # Storefront (public, with automatic anonymous user creation)
  scope "/storefront", DemoWeb do
    pipe_through [:browser, :ensure_user]

    live_session :storefront,
      layout: {DemoWeb.Layouts, :app},
      on_mount: [{DemoWeb.LiveUserAuth, :live_user_ensure}, DemoWeb.SourceLink] do
      live "/", StorefrontLive
      live "/products", Storefront.ProductsLive
      live "/products/:product_id", Storefront.ProductLive
      live "/checkout", Storefront.CheckoutLive
    end
  end

  # Customer account — same anonymous identity as everywhere else, so
  # a visitor's orders/addresses are reachable without signing in.
  scope "/account", DemoWeb do
    pipe_through [:browser, :ensure_user]

    live_session :account,
      layout: {DemoWeb.Layouts, :demo},
      on_mount: [{DemoWeb.LiveUserAuth, :live_user_ensure}, DemoWeb.SourceLink] do
      live "/", Account.DashboardLive
      live "/orders", Account.OrdersLive
      live "/orders/:order_id", Account.OrderDetailLive
      live "/settings", Account.SettingsLive
    end
  end

  # Admin section
  scope "/admin", DemoWeb.Admin do
    pipe_through :browser

    live "/", DashboardLive
    live "/products", ProductsLive
    live "/products/new", ProductEditLive
    live "/products/:product_id/edit", ProductEditLive
    live "/categories", CategoriesLive
    live "/orders", OrdersLive
    live "/orders/:order_id", OrderDetailLive
  end

  # Lavash.Reactive demos (plain LiveView, no DSL)
  scope "/lv", DemoWeb.LiveViewDemos do
    pipe_through :browser

    live "/", IndexLive
    live "/counter", CounterLive
    live "/plain-counter", PlainCounterLive
  end

  # Demo/playground routes — same anonymous identity as the home scope.
  scope "/demos", DemoWeb do
    pipe_through [:browser, :ensure_user]

    live_session :demos,
      layout: {DemoWeb.Layouts, :demo},
      on_mount: [{DemoWeb.LiveUserAuth, :live_user_ensure}, DemoWeb.SourceLink] do
      live "/counter", CounterLive
      live "/products", ProductsLive
      live "/products-socket", ProductsSocketLive
      live "/components", ComponentsDemoLive
      live "/bindings", BindingsDemoLive
      live "/tag-editor", TagEditorDemoLive
      live "/todos", TodosLive
      live "/toggle", ToggleDemoLive
      live "/form-validation", FormValidationDemoLive
      live "/checkout", CheckoutDemoLive
      live "/flyover", FlyoverDemoLive
      live "/modal", ModalDemoLive
      live "/nesting", NestingDemoLive
      live "/validation", ValidationDemoLive
    end
  end

  # Dev tools: wipe every piece of data belonging to the current
  # (anonymous) visitor and start fresh.
  scope "/dev", DemoWeb do
    pipe_through [:browser, :ensure_user]

    post "/reset", DevController, :reset
  end
end
