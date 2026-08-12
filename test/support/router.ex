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
    live("/modal-no-close-host", ModalNoCloseHostLive)
    live("/modal-async-host", ModalAsyncHostLive)
    live("/modal-ssr-host", ModalSsrHostLive)
    live("/bindings-direct", BindingDirectHostLive)
    live("/bindings-nested", BindingNestedHostLive)
    live("/bindings-siblings", BindingSiblingsHostLive)
    live("/dom-directives", DomDirectivesLive)
    live("/transpiler-edge", TranspilerEdgeLive)
    live("/arrays", ArraysLive)
    live("/form", FormLive)
    live("/custom-mount", CustomMountLive)
    live("/url-name", UrlNameLive)
    live("/url-mismatch", UrlMismatchLive)
    live("/assigns", AssignsLive)
    live("/checkbox-bind", CheckboxBindLive)
    live("/dependent-select", DependentSelectLive)
    live("/client-cart", ClientCartLive)
    live("/stacked-modals", StackedModalsHostLive)
    live("/mount-url", MountUrlLive)
    live("/mount-url/:thing_id", MountUrlLive)
    live("/filters", FilterLive)
    live("/tag-editor", TagHostLive)
    live("/socket-counter", SocketCounterLive)
    live("/stream-list", StreamListLive)
    live("/trigger-flyover", TriggerFlyoverHostLive)
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

  # Parity suite: vanilla Phoenix.LiveView reference + the lavash
  # DSL expression of the same behaviour. Each feature has both
  # routes; tests in test/lavash/parity/<feature>_test.exs run the
  # same assertions against both and fail if they diverge.
  scope "/parity/vanilla", Lavash.Parity.Vanilla do
    pipe_through(:browser)

    live("/handle_event", HandleEventLive)
    live("/handle_event_landing", HandleEventLandingLive)
    live("/mount", MountLive)
    live("/handle_params", HandleParamsLive)
    live("/handle_info", HandleInfoLive)
    live("/render_slots", RenderSlotsLive)
    live("/on_mount", OnMountLive)
    live("/functional_components", FunctionalComponentsLive)
    live("/live_component", LiveComponentLive)
    live("/handle_async", HandleAsyncLive)
    live("/terminate", TerminateLive)
    live("/streams", StreamsLive)
    live("/uploads", UploadsLive)
  end

  scope "/parity/lavash", Lavash.Parity.Lavash do
    pipe_through(:browser)

    live("/handle_event", HandleEventLive)
    live("/handle_event_landing", HandleEventLandingLive)
    live("/mount", MountLive)
    live("/handle_params", HandleParamsLive)
    live("/handle_info", HandleInfoLive)
    live("/render_slots", RenderSlotsLive)
    live("/on_mount", OnMountLive)
    live("/functional_components", FunctionalComponentsLive)
    live("/live_component", LiveComponentLive)
    live("/handle_async", HandleAsyncLive)
    live("/terminate", TerminateLive)
    live("/streams", StreamsLive)
    live("/uploads", UploadsLive)
  end

  # Shared login destination both parity sides redirect to when
  # the require_user hook halts an unauthenticated mount.
  scope "/parity" do
    pipe_through(:browser)

    live("/login", Lavash.Parity.Vanilla.LoginLive)
  end
end
