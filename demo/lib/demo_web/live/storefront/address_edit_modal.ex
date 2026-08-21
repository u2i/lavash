defmodule DemoWeb.Storefront.AddressEditModal do
  @moduledoc """
  Address editing modal for storefront checkout.
  Uses SQLite-backed addresses scoped to the current user.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  import Lavash.Optimistic.Components, only: [input: 1, select: 1]
  import Lavash.Overlay.Modal.Helpers, only: [modal_close_button: 1]

  alias Demo.Orders.Address

  import_rx DemoWeb.AddressRegions

  modal do
    open_field :open
    async_assign :address_form
    max_width :md
  end

  # Region select derives from the chosen country (issue #39),
  # optimistically: region_options/region_label are defrx functions, so
  # switching country swaps the option list client-side instantly.
  # Depends only on form params (kept in client state) — a dependency on
  # the async @address read would stall the calc chain during load.
  calculate :region_country, rx(@address_form_params["country"] || "United States")
  calculate :region_options, rx(region_options(@region_country))
  calculate :region_label, rx(region_label(@region_country))
  calculate :region_selected, rx(@address_form_params["state"] || "")

  # Passed in by the host LiveView so the create form can
  # `relate_actor(:user)` to the signed-in customer.
  prop :actor, :map, default: nil

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

  actions do
    action :close do
      set :open, nil
    end

    action :save do
      submit :address_form, on_success: :on_saved
    end

    action :on_saved do
      set :open, nil
    end
  end

  template_loading do
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

  template do
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-xl font-bold">
          {if @address_form_action == :create, do: "Add address", else: "Edit address"}
        </h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>

      <.form
        for={@address_form}
        phx-change="validate_address_form"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-4"
      >
        <.select
          field={@address_form[:country]}
          label="Country/Region"
          options={[{"United States", "United States"}, {"Canada", "Canada"}]}
          prompt="Select..."
        />

        <div class="grid grid-cols-2 gap-4">
          <.input
            field={@address_form[:first_name]}
            label="First name"
            errors={@address_form_first_name_errors}
          />
          <.input
            field={@address_form[:last_name]}
            label="Last name"
            errors={@address_form_last_name_errors}
          />
        </div>

        <.input field={@address_form[:company]} label="Company (optional)" />
        <.input field={@address_form[:address]} label="Address" errors={@address_form_address_errors} />
        <.input field={@address_form[:apartment]} label="Apartment, suite, etc. (optional)" />

        <div class="grid grid-cols-3 gap-4">
          <.input field={@address_form[:city]} label="City" errors={@address_form_city_errors} />
          <%!-- Inline select (not <.select>) so the :for over the
               optimistic @region_options is auto-extracted as a
               subtree derive and re-renders client-side. --%>
          <div>
            <label class="floating-label w-full">
              <%!-- bind/form/field/valid are auto-injected from the
                   name={@address_form[:state].name} shorthand — the
                   old hand-written bind actually BLOCKED the fuller
                   injection (the has-bind guard short-circuits) --%>
              <select
                name={@address_form[:state].name}
                class="select select-bordered w-full"
              >
                <option
                  :for={opt <- @region_options}
                  value={opt.code}
                  selected={opt.code == @region_selected}
                  disabled={opt.code == ""}
                >
                  {opt.name}
                </option>
              </select>
              <span style="opacity: 100%; top: 0; translate: -12.5% calc(-50% - 0.125em); scale: 0.75; pointer-events: auto;">{@region_label}</span>
            </label>
          </div>
          <.input field={@address_form[:zip]} label="ZIP code" errors={@address_form_zip_errors} />
        </div>

        <.input field={@address_form[:phone]} label="Phone (optional)" type="tel" />

        <div class="flex gap-3 pt-4 border-t">
          <button
            type="submit"
            disabled={not @address_form_valid}
            phx-disable-with="Saving..."
            class={"flex-1 btn " <> if(@address_form_valid, do: "btn-primary", else: "btn-disabled")}
          >
            {if @address_form_action == :create, do: "Save address", else: "Update address"}
          </button>
          <button type="button" phx-click="close" class="btn btn-outline">Cancel</button>
        </div>
      </.form>
    </div>
    """
  end
end
