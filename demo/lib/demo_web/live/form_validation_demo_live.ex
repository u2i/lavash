defmodule DemoWeb.FormValidationDemoLive do
  @moduledoc """
  Demo showcasing Ash form validation with client-side optimistic updates.

  This demonstrates:
  - Ash form DSL with `form :registration, Demo.Forms.Registration`
  - Auto-generated client-side validation from Ash resource constraints
  - Auto-generated error messages from Ash constraints
  - `extend_errors` DSL to add custom validation beyond Ash constraints
  - Real-time validation feedback without server round-trips
  - Form submission to Ash resource with ETS data layer

  The `form` DSL automatically generates:
  - `registration_name_valid`, `registration_email_valid`, `registration_age_valid`
  - `registration_name_errors`, `registration_email_errors`, `registration_age_errors`
  - `registration_valid`, `registration_errors` (combined)
  These are derived from Ash resource constraints (min_length, min, allow_nil?, etc.)

  The `extend_errors` DSL allows adding custom errors:
  - Custom errors are merged with auto-generated Ash errors
  - Visibility is controlled by the same show_errors state (touched/submitted)
  - No need for separate visibility calculations
  """
  use Lavash.LiveView
  import Lavash.Rx
  import Lavash.LiveView.Helpers, only: [field_errors: 1, field_success: 1, error_summary: 1, field_status: 1]

  alias Demo.Forms.Registration

  # Form params - Lavash automatically populates this from form events
  state :registration_params, :map, from: :ephemeral, default: %{}, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  # Ash form for server-side validation and submission
  # Auto-generates: registration_*_valid, registration_*_errors from Ash constraints
  form :registration, Registration do
    create :register
  end

  # Extend the auto-generated email errors with custom @ check
  # The error shows when the condition is true (i.e., when invalid)
  extend_errors :registration_email_errors do
    error rx(not String.contains?(@registration_params["email"] || "", "@")), "Must contain @"
  end

  # Email validity now just uses the extended validation
  # email_has_at is still needed for the input styling and success indicator
  calculate :email_has_at, rx(String.contains?(@registration_params["email"] || "", "@"))
  calculate :email_valid, rx(@registration_email_valid and @email_has_at)

  # Form validity - uses custom email_valid
  calculate :form_valid, rx(@registration_name_valid and @email_valid and @registration_age_valid)

  actions do
    action :save do
      submit :registration, on_success: :on_saved, on_error: :on_error
    end

    action :on_saved do
      set :submitted, true
    end

    action :on_error do
      # Form errors will be displayed via Ash form
    end

    action :reset do
      set :registration_params, %{}
      set :submitted, false
    end
  end

  # Using template DSL for auto-injection of data-lavash-* attributes
  # The transformer will add:
  # - data-lavash-bind, data-lavash-form, data-lavash-field on form inputs
  # - data-lavash-action on buttons with phx-click matching declared actions
  # - data-lavash-enabled on elements with disabled={not @bool_field}
  #
  # Note: Some attributes still need to be manual:
  # - data-lavash-valid="email_valid" (overrides default field name)
  # - data-lavash-toggle (complex class switching)
  template """
  <div id="form-validation-demo" class="max-w-lg mx-auto mt-10 p-6 bg-white rounded-lg shadow-lg">
    <h1 class="text-2xl font-bold text-center mb-2">Ash Form Validation</h1>
    <p class="text-gray-500 text-center mb-6 text-sm">
      Auto-generated validation from Ash resource constraints
    </p>

    <%= if @submitted do %>
      <div class="alert alert-success flex-col text-center">
        <div class="text-5xl mb-4">✓</div>
        <h2 class="text-xl font-semibold mb-2">Registration Complete!</h2>
        <div class="space-y-1">
          <p><strong>Name:</strong> {@registration_params["name"]}</p>
          <p><strong>Email:</strong> {@registration_params["email"]}</p>
          <p><strong>Age:</strong> {@registration_params["age"]}</p>
        </div>
        <button
          phx-click="reset"
          class="btn btn-success mt-4"
        >
          Start Over
        </button>
      </div>
    <% else %>
      <.form for={@registration} phx-submit="save" class="space-y-6">
        <%!-- Error Summary (shown after form submission with errors) --%>
        <.error_summary form={:registration} />

        <%!-- Name Field - auto-injected: data-lavash-bind, data-lavash-form, data-lavash-field --%>
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">
            Name <span class="text-error">*</span>
          </label>
          <div class="relative">
            <input
              type="text"
              name={@registration[:name].name}
              value={@registration[:name].value || ""}
              autocomplete="off"
              data-1p-ignore
              class={"input input-bordered w-full pr-10 " <>
                cond do
                  !assigns[:registration_name_show_errors] -> ""
                  @registration_name_valid -> "input-success"
                  true -> "input-error"
                end}
              placeholder="Enter your name"
            />
            <.field_status form={:registration} field={:name} valid={@registration_name_valid} />
          </div>
          <div class="h-5 mt-1">
            <.field_errors form={:registration} field={:name} errors={@registration_name_errors} />
            <.field_success form={:registration} field={:name} valid={@registration_name_valid} />
          </div>
        </div>

        <%!-- Email Field - auto-injected: bind/form/field; manual: data-lavash-valid override --%>
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">
            Email <span class="text-error">*</span>
          </label>
          <div class="relative">
            <input
              type="text"
              name={@registration[:email].name}
              value={@registration[:email].value || ""}
              data-lavash-valid="email_valid"
              autocomplete="off"
              data-1p-ignore
              class={"input input-bordered w-full pr-10 " <>
                cond do
                  !assigns[:registration_email_show_errors] -> ""
                  @email_valid -> "input-success"
                  true -> "input-error"
                end}
              placeholder="you@example.com"
            />
            <.field_status form={:registration} field={:email} valid={@email_valid} valid_field="email_valid" />
          </div>
          <div class="h-5 mt-1">
            <%!-- Now using extend_errors - custom @ error is merged into registration_email_errors --%>
            <.field_errors form={:registration} field={:email} errors={@registration_email_errors} />
            <.field_success form={:registration} field={:email} valid={@email_valid} valid_field="email_valid" message="Valid email" />
          </div>
        </div>

        <%!-- Age Field - auto-injected: data-lavash-bind, data-lavash-form, data-lavash-field --%>
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">
            Age <span class="text-error">*</span>
          </label>
          <div class="relative">
            <input
              type="number"
              name={@registration[:age].name}
              value={@registration[:age].value || ""}
              autocomplete="off"
              data-1p-ignore
              min="0"
              max="150"
              class={"input input-bordered w-full pr-10 " <>
                cond do
                  !assigns[:registration_age_show_errors] -> ""
                  @registration_age_valid -> "input-success"
                  true -> "input-error"
                end}
              placeholder="18"
            />
            <.field_status form={:registration} field={:age} valid={@registration_age_valid} />
          </div>
          <div class="h-5 mt-1">
            <.field_errors form={:registration} field={:age} errors={@registration_age_errors} />
            <.field_success form={:registration} field={:age} valid={@registration_age_valid} message="Age verified" />
          </div>
        </div>

        <%!-- Submit Button - auto-injected: data-lavash-enabled --%>
        <div class="pt-4">
          <button
            type="submit"
            disabled={not @form_valid}
            data-lavash-enabled="form_valid"
            class={"w-full py-3 px-4 rounded-lg font-semibold transition-colors " <>
              if @form_valid do
                "bg-primary text-primary-content hover:opacity-90"
              else
                "bg-base-300 text-base-content opacity-50 cursor-not-allowed"
              end}
            data-lavash-toggle="form_valid|bg-primary text-primary-content hover:opacity-90|bg-base-300 text-base-content opacity-50 cursor-not-allowed"
          >
            Register
          </button>
        </div>
      </.form>
    <% end %>

    <div class="mt-8 p-4 bg-gray-50 rounded-lg">
      <h3 class="font-semibold text-gray-700 mb-2">How it works</h3>
      <ul class="text-sm text-gray-600 space-y-1">
        <li>• Ash resource with <code class="bg-gray-200 px-1 rounded">constraints</code> (min_length, min, allow_nil?)</li>
        <li>• <code class="bg-gray-200 px-1 rounded">form :registration, Registration</code> auto-generates fields</li>
        <li>• <code class="bg-gray-200 px-1 rounded">registration_*_valid</code> and <code class="bg-gray-200 px-1 rounded">registration_*_errors</code> from constraints</li>
        <li>• Error messages derived from Ash constraint values</li>
        <li>• Client validates instantly, server validates on submit</li>
      </ul>
    </div>

    <div class="mt-4 text-center">
      <a href="/" class="text-blue-600 hover:text-blue-800">
        &larr; Back to Demos
      </a>
    </div>
  </div>
  """
end
