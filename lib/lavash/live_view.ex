defmodule Lavash.LiveView do
  @moduledoc """
  Use this module to create a Lavash-powered LiveView.

  ## Example

      defmodule MyApp.ProfileLive do
        use Lavash.LiveView

        state do
          url do
            field :user_id, :integer, required: true
            field :tab, :string, default: "overview"
          end

          ephemeral do
            field :editing, :boolean, default: false
          end
        end

        derived do
          field :user, depends_on: [:user_id], async: true, compute: &load_user/1
        end

        assigns do
          assign :user
          assign :tab
        end

        actions do
          action :change_tab, params: [:tab] do
            set :tab, & &1.params.tab
          end
        end

        defp load_user(%{user_id: id}), do: MyApp.Accounts.get_user!(id)
      end
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.Dsl]]

  @impl Spark.Dsl
  def handle_opts(opts) do
    quote do
      use Phoenix.LiveView, unquote(opts)
      require Phoenix.Component
      import Phoenix.Component

      # Register module attributes for optimistic macros (optimistic_action only)
      Module.register_attribute(__MODULE__, :__lavash_optimistic_actions__, accumulate: true)

      @before_compile Lavash.LiveView.Compiler

      import Lavash.LiveView.Helpers
      import Lavash.Optimistic.Macros, only: [optimistic_action: 3]
    end
  end
end
