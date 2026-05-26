defmodule Lavash.Component.Base do
  @moduledoc """
  Layer-1+2+3 entry point for stateful Phoenix LiveComponents: the
  full Lavash DSL surface minus the optimistic UI layer.

  See `Lavash.LiveView.Base` for the full discussion of what's
  kept and what's given up. The same rules apply at the component
  level: `optimistic: true`, `animated: ...`, and
  `calculate :foo, rx(...), optimistic: true` produce a friendly
  compile-time error directing you to either drop the flag or
  upgrade to `use Lavash.Component` for the full stack.

  ## Example

      defmodule MyAppWeb.UserCard do
        use Lavash.Component.Base

        prop :user, :map, required: true

        state :expanded, :boolean, default: false
        # `optimistic: true` would error — server-authoritative
        # is the contract.

        actions do
          action :toggle do
            set :expanded, rx(not @expanded)
          end
        end

        render fn assigns ->
          ~L\"\"\"
          <div phx-click="toggle" phx-target={@myself}>
            <h3>{@user.name}</h3>
            <div :if={@expanded}>...</div>
          </div>
          \"\"\"
        end
      end
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.Component.Dsl, Lavash.Dsl.BaseStrict]]

  @impl Spark.Dsl
  def handle_opts(opts) do
    quote do
      import Phoenix.LiveView
      @behaviour Phoenix.LiveComponent
      @before_compile Phoenix.LiveView.Renderer
      use Phoenix.Component,
          Keyword.merge([global_prefixes: []], Keyword.take(unquote(opts), [:global_prefixes]))

      @doc false
      def __live__, do: %{kind: :component, layout: false}

      @__lavash_module_type__ :component
      @__lavash_layer__ :base

      Module.register_attribute(__MODULE__, :__lavash_renders__, accumulate: true)

      import Lavash.Sigil, only: [sigil_L: 2]
      import Lavash.Template.RenderMacro
    end
  end
end
