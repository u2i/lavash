defmodule DemoWeb.AddressEditModal do
  @moduledoc """
  A Lavash Component for adding/editing a shipping address in a modal.

  Uses the Lavash.Modal plugin for modal behavior:
  - open controls open state: nil | :create | {:edit, id}
  - Modal chrome, wrapper are auto-generated

  Opening via parent binding:
  - Parent sets :address_modal to :create or {:edit, id}
  - Modal binds open to parent's :address_modal

  ## Example usage

      <.lavash_component
        module={DemoWeb.AddressEditModal}
        id="address-edit-modal"
        session_id={@session_id}
        open={@address_modal}
        bind={[open: :address_modal]}
      />
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  alias DemoWeb.CoreComponents
  import Lavash.LiveView.Components, only: [input: 1, select: 1]
  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Forms.Address

  # Session ID from parent for scoping addresses
  prop :session_id, :string, required: true

  # Configure modal behavior - open is nil | :create | {:edit, id}
  modal do
    open_field :open
    async_assign :address_form
    max_width :md
  end

  render_loading fn assigns ->
    ~H"""
    <div class="p-6">
      <div class="animate-pulse">
        <div class="h-6 bg-gray-200 rounded w-1/3 mb-6"></div>
        <div class="h-10 bg-gray-200 rounded mb-4"></div>
        <div class="grid grid-cols-2 gap-4 mb-4">
          <div class="h-10 bg-gray-200 rounded"></div>
          <div class="h-10 bg-gray-200 rounded"></div>
        </div>
        <div class="h-10 bg-gray-200 rounded mb-4"></div>
        <div class="h-10 bg-gray-200 rounded"></div>
      </div>
    </div>
    """
  end

  render fn assigns ->
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-xl font-bold">
          {if @address_form_action == :create, do: "Add address", else: "Edit address"}
        </h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <.form for={@address_form} phx-change="validate" phx-submit="save" phx-target={@myself} class="space-y-4">
        <!-- Country dropdown -->
        <.select
          field={@address_form[:country]}
          label="Country/Region"
          options={[{"United States", "United States"}, {"Canada", "Canada"}]}
          prompt="Select..."
        />

        <!-- Name row -->
        <div class="grid grid-cols-2 gap-4">
          <.input
            field={@address_form[:first_name]}
            label="First name"
            errors={@address_form_first_name_errors}
            show_errors={assigns[:address_form_first_name_show_errors]}
          />
          <.input
            field={@address_form[:last_name]}
            label="Last name"
            errors={@address_form_last_name_errors}
            show_errors={assigns[:address_form_last_name_show_errors]}
          />
        </div>

        <!-- Company (optional - no validation) -->
        <.input
          field={@address_form[:company]}
          label="Company (optional)"
        />

        <!-- Address -->
        <.input
          field={@address_form[:address]}
          label="Address"
          errors={@address_form_address_errors}
          show_errors={assigns[:address_form_address_show_errors]}
        />

        <!-- Apartment (optional - no validation) -->
        <.input
          field={@address_form[:apartment]}
          label="Apartment, suite, etc. (optional)"
        />

        <!-- City / State / ZIP row -->
        <div class="grid grid-cols-3 gap-4">
          <.input
            field={@address_form[:city]}
            label="City"
            errors={@address_form_city_errors}
            show_errors={assigns[:address_form_city_show_errors]}
          />
          <.select
            field={@address_form[:state]}
            label="State"
            options={us_states()}
            prompt="Select..."
          />
          <.input
            field={@address_form[:zip]}
            label="ZIP code"
            errors={@address_form_zip_errors}
            show_errors={assigns[:address_form_zip_show_errors]}
          />
        </div>

        <!-- Phone (optional - no validation) -->
        <.input
          field={@address_form[:phone]}
          label="Phone (optional)"
          type="tel"
        />

        <!-- Submit -->
        <div class="flex gap-3 pt-4 border-t">
          <CoreComponents.button type="submit" phx-disable-with="Saving..." class="flex-1 btn-primary">
            {if @address_form_action == :create, do: "Save address", else: "Update address"}
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

  # Extract address ID from open state: {:edit, id} -> id, otherwise nil
  defp extract_address_id({:edit, id}), do: id
  defp extract_address_id(_), do: nil

  # Load the address when editing (open = {:edit, id})
  read :address, Address do
    id fn state -> extract_address_id(state.open) end
  end

  # Form for address entry/editing
  form :address_form, Address do
    data result(:address)
    create :save
    update :update
  end

  actions do
    action :save do
      # Only inject session_id for create (update already has it from the loaded record)
      set :address_form_params, fn %{state: state} ->
        if is_nil(state.address) do
          # Create mode - inject session_id
          Map.put(state.address_form_params || %{}, "session_id", state.session_id)
        else
          # Update mode - no need to inject session_id
          state.address_form_params || %{}
        end
      end
      submit :address_form, on_success: :on_saved
    end

    action :on_saved do
      # Close modal - this propagates back to parent via binding
      set :open, nil
    end
  end

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
