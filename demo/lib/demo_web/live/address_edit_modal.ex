defmodule DemoWeb.AddressEditModal do
  @moduledoc """
  A Lavash Component for adding/editing a shipping address in a modal.

  Uses the Lavash.Modal plugin for modal behavior:
  - open controls open state (nil = closed, truthy = open)
  - Modal chrome, wrapper are auto-generated

  Opening the modal from client-side:
  - JS.dispatch("open-panel", to: "#address-edit-modal-modal", detail: %{open: true})

  ## Example usage

      <.lavash_component
        module={DemoWeb.AddressEditModal}
        id="address-edit-modal"
        session_id={@session_id}
      />
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  alias DemoWeb.CoreComponents
  import Lavash.LiveView.Components, only: [input: 1]
  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Forms.Address

  # Session ID from parent for scoping addresses
  prop :session_id, :string, required: true

  # Configure modal behavior
  modal do
    open_field :open
    max_width :md
  end

  # Form for address entry (create mode)
  form :address_form, Address do
    create :save
  end

  render fn assigns ->
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-xl font-bold">Add address</h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <.form for={@address_form} phx-change="validate" phx-submit="save" phx-target={@myself} class="space-y-4">
        <!-- Country dropdown -->
        <CoreComponents.input
          field={@address_form[:country]}
          type="select"
          label="Country/Region"
          options={[{"United States", "United States"}, {"Canada", "Canada"}]}
        />

        <!-- Name row -->
        <div class="grid grid-cols-2 gap-4">
          <.input
            field={@address_form[:first_name]}
            label="First name"
            errors={@address_form_first_name_errors}
            show_errors={assigns[:address_form_first_name_show_errors]}
            floating={false}
          />
          <.input
            field={@address_form[:last_name]}
            label="Last name"
            errors={@address_form_last_name_errors}
            show_errors={assigns[:address_form_last_name_show_errors]}
            floating={false}
          />
        </div>

        <!-- Company (optional - no validation) -->
        <.input
          field={@address_form[:company]}
          label="Company (optional)"
          floating={false}
        />

        <!-- Address -->
        <.input
          field={@address_form[:address]}
          label="Address"
          errors={@address_form_address_errors}
          show_errors={assigns[:address_form_address_show_errors]}
          floating={false}
        />

        <!-- Apartment (optional - no validation) -->
        <.input
          field={@address_form[:apartment]}
          label="Apartment, suite, etc. (optional)"
          floating={false}
        />

        <!-- City / State / ZIP row -->
        <div class="grid grid-cols-3 gap-4">
          <.input
            field={@address_form[:city]}
            label="City"
            errors={@address_form_city_errors}
            show_errors={assigns[:address_form_city_show_errors]}
            floating={false}
          />
          <CoreComponents.input
            field={@address_form[:state]}
            type="select"
            label="State"
            options={us_states()}
            prompt="Select..."
          />
          <.input
            field={@address_form[:zip]}
            label="ZIP code"
            errors={@address_form_zip_errors}
            show_errors={assigns[:address_form_zip_show_errors]}
            floating={false}
          />
        </div>

        <!-- Phone (optional - no validation) -->
        <.input
          field={@address_form[:phone]}
          label="Phone (optional)"
          type="tel"
          floating={false}
        />

        <!-- Submit -->
        <div class="flex gap-3 pt-4 border-t">
          <CoreComponents.button type="submit" phx-disable-with="Saving..." class="flex-1 btn-primary">
            Save address
          </CoreComponents.button>
          <CoreComponents.button
            type="button"
            phx-click={Phoenix.LiveView.JS.dispatch("close-panel", to: "#address-edit-modal-modal")}
            class="btn-outline"
          >
            Cancel
          </CoreComponents.button>
        </div>
      </.form>
    </div>
    """
  end

  actions do
    action :save do
      # Inject session_id into form params before submit
      set :address_form_params, fn %{state: state} ->
        Map.put(state.address_form_params || %{}, "session_id", state.session_id)
      end
      submit :address_form, on_success: :on_saved
    end

    action :on_saved do
      # Close modal - PubSub will notify the parent to refresh the address list
      set :open, nil
    end
  end

  # US states for dropdown
  defp us_states do
    [
      {"Alabama", "AL"},
      {"Alaska", "AK"},
      {"Arizona", "AZ"},
      {"Arkansas", "AR"},
      {"California", "CA"},
      {"Colorado", "CO"},
      {"Connecticut", "CT"},
      {"Delaware", "DE"},
      {"Florida", "FL"},
      {"Georgia", "GA"},
      {"Hawaii", "HI"},
      {"Idaho", "ID"},
      {"Illinois", "IL"},
      {"Indiana", "IN"},
      {"Iowa", "IA"},
      {"Kansas", "KS"},
      {"Kentucky", "KY"},
      {"Louisiana", "LA"},
      {"Maine", "ME"},
      {"Maryland", "MD"},
      {"Massachusetts", "MA"},
      {"Michigan", "MI"},
      {"Minnesota", "MN"},
      {"Mississippi", "MS"},
      {"Missouri", "MO"},
      {"Montana", "MT"},
      {"Nebraska", "NE"},
      {"Nevada", "NV"},
      {"New Hampshire", "NH"},
      {"New Jersey", "NJ"},
      {"New Mexico", "NM"},
      {"New York", "NY"},
      {"North Carolina", "NC"},
      {"North Dakota", "ND"},
      {"Ohio", "OH"},
      {"Oklahoma", "OK"},
      {"Oregon", "OR"},
      {"Pennsylvania", "PA"},
      {"Rhode Island", "RI"},
      {"South Carolina", "SC"},
      {"South Dakota", "SD"},
      {"Tennessee", "TN"},
      {"Texas", "TX"},
      {"Utah", "UT"},
      {"Vermont", "VT"},
      {"Virginia", "VA"},
      {"Washington", "WA"},
      {"West Virginia", "WV"},
      {"Wisconsin", "WI"},
      {"Wyoming", "WY"}
    ]
  end
end
