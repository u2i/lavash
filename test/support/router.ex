defmodule Lavash.TestRouter do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Lavash.TestLayouts, :root})
    plug(:put_secure_browser_headers)
  end

  scope "/magic", Lavash.Test.Magic do
    pipe_through(:browser)

    live("/counter", CounterLive)
    live("/typed", TypedLive)
    live("/chained", ChainedDerivedLive)
    live("/chained-ephemeral", ChainedEphemeralLive)
    live("/async-chain", AsyncChainLive)
    live("/products/:product_id/counter", CounterLive)
    live("/products/:product_id", PathParamLive)
    live("/component-host", ComponentHostLive)
    live("/guarded", GuardedActionsLive)
    live("/modal-host", ModalHostLive)
    live("/bindings-direct", BindingDirectHostLive)
    live("/bindings-nested", BindingNestedHostLive)
    live("/bindings-siblings", BindingSiblingsHostLive)
    live("/dom-directives", DomDirectivesLive)
    live("/arrays", ArraysLive)
    live("/form", FormLive)
  end
end
