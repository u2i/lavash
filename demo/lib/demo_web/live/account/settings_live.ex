defmodule DemoWeb.Account.SettingsLive do
  @moduledoc """
  Account settings: profile info (read-only for the demo) and an
  address book where users can add, edit, and delete saved
  shipping addresses.

  The address book reuses the existing `AddressEditModal` from the
  storefront flow (modal-based create/edit). Deletes are inline
  with a confirm prompt. Both flows showcase lavash patterns:
  modal-host bindings, optimistic UI on list mutations, declarative
  set ops to open/close the modal.
  """
  use Lavash.LiveView

  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: DemoWeb.Endpoint,
    router: DemoWeb.Router,
    statics: DemoWeb.static_paths()

  alias Demo.Orders.Address

  state :_user_id, :string, from: :ephemeral
  state :current_user, :map, from: :assigns, assigns_key: :current_user
  state :address_modal, :any, from: :ephemeral, default: nil, optimistic: true

  read :addresses, Address, :for_user do
    argument :user_id, state(:_user_id)
    async false
    invalidate :pubsub
  end

  calculate :has_addresses?, rx(@addresses != nil and @addresses != []), optimistic: false

  actions do
    action :add_address do
      set :address_modal, :create
    end

    action :edit_address, [:id] do
      set :address_modal, rx({:edit, @id})
    end

    action :delete_address, [:id] do
      effect fn state ->
        case Ash.get(Address, state.id, error?: false) do
          {:ok, %Address{} = addr} ->
            Ash.destroy!(addr)
            # Tell any LV reading `Address` to re-run. The form-runtime
            # broadcast only fires on create/update; a raw `Ash.destroy!`
            # has to broadcast itself.
            Lavash.PubSub.broadcast(Address)

          _ ->
            :ok
        end
      end
    end
  end

  mount do
    run fn socket ->
      user = socket.assigns[:current_user]
      Lavash.Socket.put_state(socket, :_user_id, user && user.id)
    end
  end

  template do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link navigate={~p"/account"} class="btn btn-ghost btn-sm">&larr;</.link>
        <h1 class="text-2xl font-bold">Settings</h1>
      </div>

      <%= if @current_user do %>
        <!-- Account Details -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Account Details</h2>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Email</span>
              </label>
              <input
                type="email"
                value={@current_user.email}
                class="input input-bordered"
                disabled
              />
              <label class="label">
                <span class="label-text-alt text-base-content/50">
                  Contact support to change your email.
                </span>
              </label>
            </div>
          </div>
        </div>

        <!-- Saved Addresses -->
        <div class="card bg-base-200">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">Saved Addresses</h2>
              <button phx-click="add_address" class="btn btn-primary btn-sm">
                Add address
              </button>
            </div>

            <%= if @has_addresses? do %>
              <ul class="divide-y divide-base-300/40 -mx-4">
                <li :for={addr <- @addresses} class="px-4 py-4 flex items-start gap-4">
                  <div class="flex-1 text-sm space-y-0.5">
                    <p :if={addr.label} class="font-medium uppercase text-xs text-base-content/50">
                      {addr.label}
                    </p>
                    <p class="font-medium">{addr.first_name} {addr.last_name}</p>
                    <p :if={addr.company} class="text-base-content/70">{addr.company}</p>
                    <p>{addr.address}</p>
                    <p :if={addr.apartment}>{addr.apartment}</p>
                    <p>{addr.city}, {addr.state} {addr.zip}</p>
                    <p :if={addr.country and addr.country != "United States"}>
                      {addr.country}
                    </p>
                    <p :if={addr.phone} class="text-base-content/70">{addr.phone}</p>
                  </div>
                  <div class="flex gap-2">
                    <button
                      phx-click="edit_address"
                      phx-value-id={addr.id}
                      class="btn btn-ghost btn-sm"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_address"
                      phx-value-id={addr.id}
                      data-confirm="Delete this address?"
                      class="btn btn-ghost btn-sm text-error"
                    >
                      Delete
                    </button>
                  </div>
                </li>
              </ul>
            <% else %>
              <div class="text-center py-8 text-base-content/50">
                <p>No saved addresses yet.</p>
                <p class="text-sm mt-1">
                  Add one to speed up future checkouts.
                </p>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Password (placeholder) -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Password</h2>
            <p class="text-base-content/70">
              Change your password or reset it via email.
            </p>
            <div class="card-actions mt-4">
              <a href="/password-reset" class="btn btn-outline">
                Send reset link
              </a>
            </div>
          </div>
        </div>

        <!-- Address Edit Modal -->
        <.lavash_component
          module={DemoWeb.Storefront.AddressEditModal}
          id="settings-address-modal"
          open={@address_modal}
          actor={@current_user}
          bind={[open: :address_modal]}
        />
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center">
            <p class="text-base-content/70">Please sign in to manage your settings.</p>
            <div class="card-actions justify-center mt-4">
              <a href="/sign-in" class="btn btn-primary">Sign In</a>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
