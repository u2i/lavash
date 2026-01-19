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
  import Lavash.LiveView.Helpers, only: [field_errors: 1, error_summary: 1]

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

  # Using render fn with ~H sigil with shorthand form field syntax
  #
  # field={@form[:field]} expands to:
  # - name={@form[:field].name}
  # - value={@form[:field].value || ""}
  # - data-lavash-bind="form_params.field"
  # - data-lavash-form="form"
  # - data-lavash-field="field"
  # - data-lavash-valid="form_field_valid"
  #
  # Override any of these by specifying them explicitly after the shorthand.
  render fn assigns ->
    ~H"""
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

          <%!-- Name Field - shorthand: data-lavash-form-field injects name, value, bind, form, field, valid --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Name <span class="text-error">*</span>
            </label>
            <div class="relative">
              <input
                type="text"
                field={@registration[:name]}
                autocomplete="off"
                data-1p-ignore
                class={"input input-bordered w-full pr-10 " <>
                  if assigns[:registration_name_show_errors] && !@registration_name_valid, do: "input-error", else: ""}
                placeholder="Enter your name"
              />
            </div>
            <div class="h-5 mt-1">
              <.field_errors form={:registration} field={:name} errors={@registration_name_errors} />
            </div>
          </div>

          <%!-- Email Field - shorthand + manual override for custom validation --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Email <span class="text-error">*</span>
            </label>
            <div class="relative">
              <input
                type="text"
                field={@registration[:email]}
                data-lavash-valid="email_valid"
                autocomplete="off"
                data-1p-ignore
                class={"input input-bordered w-full pr-10 " <>
                  if assigns[:registration_email_show_errors] && !@email_valid, do: "input-error", else: ""}
                placeholder="you@example.com"
              />
            </div>
            <div class="h-5 mt-1">
              <%!-- Now using extend_errors - custom @ error is merged into registration_email_errors --%>
              <.field_errors form={:registration} field={:email} errors={@registration_email_errors} />
            </div>
          </div>

          <%!-- Age Field - shorthand for all form bindings --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Age <span class="text-error">*</span>
            </label>
            <div class="relative">
              <input
                type="number"
                field={@registration[:age]}
                autocomplete="off"
                data-1p-ignore
                min="0"
                max="150"
                class={"input input-bordered w-full pr-10 " <>
                  if assigns[:registration_age_show_errors] && !@registration_age_valid, do: "input-error", else: ""}
                placeholder="18"
              />
            </div>
            <div class="h-5 mt-1">
              <.field_errors form={:registration} field={:age} errors={@registration_age_errors} />
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
end
