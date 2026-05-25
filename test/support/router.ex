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
    live("/custom-mount", CustomMountLive)
    live("/url-name", UrlNameLive)
    live("/url-mismatch", UrlMismatchLive)
  end

  # Parallel "explicit" path: plain Phoenix.LiveView, no Lavash DSL.
  # Only the features that meaningfully translate without the DSL are
  # mirrored — bindings, optimistic state, DOM directives, forms, and
  # overlays are intentionally absent because they ARE the DSL.
  scope "/explicit", Lavash.Test.Explicit do
    pipe_through(:browser)

    live("/counter", CounterLive)
    live("/chained", ChainedDerivedLive)
    live("/chained-ephemeral", ChainedEphemeralLive)
    live("/async-chain", AsyncChainLive)
  end
end
