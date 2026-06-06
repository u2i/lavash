defmodule Lavash.LiveView do
  @moduledoc """
  Use this module to create a Lavash-powered LiveView.

  Declares the DSL surface (`state`, `calculate`, `read`, `form`, `actions`,
  etc.), provides the `template do ~H end` block, and wires the template
  transformer + optimistic JS hook.

  ## Example

      defmodule MyAppWeb.ProfileLive do
        use Lavash.LiveView

        state :user_id, :integer, from: :url, required: true
        state :tab, :string, from: :url, default: "overview"
        state :editing, :boolean, default: false

        read :user, MyApp.Accounts.User do
          id state(:user_id)
          async true
        end

        actions do
          action :change_tab, [:tab] do
            set :tab, rx(@tab)
          end
        end

        template do
          ~H\"\"\"
          <div>
            <h1>{@user.name}</h1>
            <button phx-click="change_tab" phx-value-tab="overview">Overview</button>
          </div>
          \"\"\"
        end
      end

  For the non-DSL on-ramp (reactive engine without the template
  transformer or optimistic JS), see `Lavash.LiveView.Explicit`.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.Dsl]]

  @impl Spark.Dsl
  def handle_opts(opts) do
    quote do
      use Phoenix.LiveView, unquote(opts)

      # Mark module type for sigil context detection
      @__lavash_module_type__ :live_view

      # Register module attributes for optimistic macros and render definitions
      Module.register_attribute(__MODULE__, :__lavash_optimistic_actions__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_renders__, accumulate: true)

      import Lavash.LiveView.Helpers
      import Lavash.Optimistic.Macros, only: [optimistic_action: 3]
      import Lavash.Template.RenderMacro
    end
  end
end
