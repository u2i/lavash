defmodule DemoWeb.Storefront.AddressEditModal do
  @moduledoc """
  Address editing modal for storefront checkout.
  Uses SQLite-backed addresses scoped to the current user.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  import Lavash.LiveView.Components, only: [input: 1, select: 1]
  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Orders.Address

  modal do
    open_field :open
    async_assign :address_form
    max_width :md
  end

  calculate :edit_address_id, rx(extract_address_id(@open)), optimistic: false

  def extract_address_id({:edit, id}), do: id
  def extract_address_id(_), do: nil

  read :address, Address do
    id state(:edit_address_id)
  end

  form :address_form, Address do
    data result(:address)
    create :save
    update :update
  end

  calculate :address_form_valid,
            rx(
              @address_form_params != nil and
                @address_form_params["first_name"] != "" and
                @address_form_params["last_name"] != "" and
                @address_form_params["address"] != "" and
                @address_form_params["city"] != "" and
                @address_form_params["state"] != "" and
                @address_form_params["zip"] != "" and
                @address_form_params["country"] != ""
            )

  actions do
    action :save do
      submit :address_form, on_success: :on_saved
    end

    action :on_saved do
      set :open, nil
    end
  end

  render_loading fn assigns ->
    ~L"""
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
    ~L"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-xl font-bold">
          {if @address_form_action == :create, do: "Add address", else: "Edit address"}
        </h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <.form for={@address_form} phx-change="validate_address_form" phx-submit="save" phx-target={@myself} class="space-y-4">
        <.select
          field={@address_form[:country]}
          label="Country/Region"
          options={[{"United States", "United States"}, {"Canada", "Canada"}]}
          prompt="Select..."
        />

        <div class="grid grid-cols-2 gap-4">
          <.input field={@address_form[:first_name]} label="First name" errors={@address_form_first_name_errors} />
          <.input field={@address_form[:last_name]} label="Last name" errors={@address_form_last_name_errors} />
        </div>

        <.input field={@address_form[:company]} label="Company (optional)" />
        <.input field={@address_form[:address]} label="Address" errors={@address_form_address_errors} />
        <.input field={@address_form[:apartment]} label="Apartment, suite, etc. (optional)" />

        <div class="grid grid-cols-3 gap-4">
          <.input field={@address_form[:city]} label="City" errors={@address_form_city_errors} />
          <.select field={@address_form[:state]} label="State" options={us_states()} prompt="Select..." />
          <.input field={@address_form[:zip]} label="ZIP code" errors={@address_form_zip_errors} />
        </div>

        <.input field={@address_form[:phone]} label="Phone (optional)" type="tel" />

        <!-- TODO: address_form_valid is server-computed here because overlay Components
             don't yet get client hooks for form validation. Move to client-side once
             GenerateClientHook supports overlays with forms. -->
        <div class="flex gap-3 pt-4 border-t">
          <button type="submit" disabled={!@address_form_valid} phx-disable-with="Saving..."
            class={"flex-1 btn " <> if(@address_form_valid, do: "btn-primary", else: "btn-disabled")}>
            {if @address_form_action == :create, do: "Save address", else: "Update address"}
          </button>
          <button type="button" phx-click="close" class="btn btn-outline">Cancel</button>
        </div>
      </.form>
    </div>
    """
  end

  defp us_states do
    [
      {"Alabama", "AL"}, {"Alaska", "AK"}, {"Arizona", "AZ"}, {"Arkansas", "AR"},
      {"California", "CA"}, {"Colorado", "CO"}, {"Connecticut", "CT"}, {"Delaware", "DE"},
      {"Florida", "FL"}, {"Georgia", "GA"}, {"Hawaii", "HI"}, {"Idaho", "ID"},
      {"Illinois", "IL"}, {"Indiana", "IN"}, {"Iowa", "IA"}, {"Kansas", "KS"},
      {"Kentucky", "KY"}, {"Louisiana", "LA"}, {"Maine", "ME"}, {"Maryland", "MD"},
      {"Massachusetts", "MA"}, {"Michigan", "MI"}, {"Minnesota", "MN"}, {"Mississippi", "MS"},
      {"Missouri", "MO"}, {"Montana", "MT"}, {"Nebraska", "NE"}, {"Nevada", "NV"},
      {"New Hampshire", "NH"}, {"New Jersey", "NJ"}, {"New Mexico", "NM"}, {"New York", "NY"},
      {"North Carolina", "NC"}, {"North Dakota", "ND"}, {"Ohio", "OH"}, {"Oklahoma", "OK"},
      {"Oregon", "OR"}, {"Pennsylvania", "PA"}, {"Rhode Island", "RI"}, {"South Carolina", "SC"},
      {"South Dakota", "SD"}, {"Tennessee", "TN"}, {"Texas", "TX"}, {"Utah", "UT"},
      {"Vermont", "VT"}, {"Virginia", "VA"}, {"Washington", "WA"}, {"West Virginia", "WV"},
      {"Wisconsin", "WI"}, {"Wyoming", "WY"}
    ]
  end
end
