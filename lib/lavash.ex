defmodule Lavash do
  @moduledoc """
  Lavash - A declarative state management layer for Phoenix LiveView.

  Lavash provides an Ash-inspired DSL for managing LiveView state with:

  - **URL State**: Bidirectionally synced with URL params
  - **Ephemeral State**: Socket-only state, lost on disconnect
  - **Derived State**: Computed values with dependency tracking
  - **Assigns**: Projection of state into template assigns
  - **Actions**: State transformers triggered by events

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

        def render(assigns) do
          ~H\"\"\"
          <div>...</div>
          \"\"\"
        end
      end
  """
end
