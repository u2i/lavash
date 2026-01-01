defmodule DemoWeb.FormValidationDemoLive do
  @moduledoc """
  Demo showcasing Ash form validation with client-side optimistic updates.

  This demonstrates:
  - Ash form DSL with `form :registration, Demo.Forms.Registration`
  - Auto-generated client-side validation from Ash resource constraints
  - Auto-generated error messages from Ash constraints
  - Real-time validation feedback without server round-trips
  - Form submission to Ash resource with ETS data layer

  The `form` DSL automatically generates:
  - `registration_name_valid`, `registration_email_valid`, `registration_age_valid`
  - `registration_name_errors`, `registration_email_errors`, `registration_age_errors`
  - `registration_valid`, `registration_errors` (combined)
  These are derived from Ash resource constraints (min_length, min, allow_nil?, etc.)
  """
  use Lavash.LiveView
  import Lavash.Rx
  import Lavash.LiveView.Helpers, only: [field_errors: 1, field_success: 1]

  alias Demo.Forms.Registration

  # Form params - Lavash automatically populates this from form events
  state :registration_params, :map, from: :ephemeral, default: %{}, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  # Ash form for server-side validation and submission
  # Auto-generates: registration_*_valid, registration_*_errors from Ash constraints
  form :registration, Registration do
    create :register
  end

  # Email needs custom validation for @ symbol (not in Ash constraints)
  calculate :email_has_at, rx(String.contains?(@registration_params["email"] || "", "@"))
  calculate :email_valid, rx(@registration_email_valid and @email_has_at)
  # Show custom @ error only when touched/submitted AND invalid
  calculate :email_at_error_visible, rx(
    @registration_email_show_errors and not @email_empty and not @email_has_at
  )

  # For visual feedback: determine if fields are empty vs invalid
  calculate :name_empty, rx(
    is_nil(@registration_params["name"]) or
    String.length(String.trim(@registration_params["name"] || "")) == 0
  )
  calculate :email_empty, rx(
    is_nil(@registration_params["email"]) or
    String.length(String.trim(@registration_params["email"] || "")) == 0
  )
  calculate :age_empty, rx(
    is_nil(@registration_params["age"]) or
    String.length(String.trim(@registration_params["age"] || "")) == 0
  )

  # Form validity - uses custom email_valid
  calculate :form_valid, rx(@registration_name_valid and @email_valid and @registration_age_valid)
  calculate :has_any_input, rx(not @name_empty or not @email_empty or not @age_empty)
  calculate :show_error_hint, rx(@has_any_input and not @form_valid)

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

  def render(assigns) do
    ~H"""
    <div id="form-validation-demo" class="max-w-lg mx-auto mt-10 p-6 bg-white rounded-lg shadow-lg">
      <h1 class="text-2xl font-bold text-center mb-2">Ash Form Validation</h1>
      <p class="text-gray-500 text-center mb-6 text-sm">
        Auto-generated validation from Ash resource constraints
      </p>

      <%= if @submitted do %>
        <div class="bg-green-50 border border-green-200 rounded-lg p-6 text-center">
          <div class="text-green-600 text-5xl mb-4">✓</div>
          <h2 class="text-xl font-semibold text-green-800 mb-2">Registration Complete!</h2>
          <div class="text-gray-600 space-y-1">
            <p><strong>Name:</strong> {@registration_params["name"]}</p>
            <p><strong>Email:</strong> {@registration_params["email"]}</p>
            <p><strong>Age:</strong> {@registration_params["age"]}</p>
          </div>
          <button
            phx-click="reset"
            class="mt-4 px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700"
          >
            Start Over
          </button>
        </div>
      <% else %>
        <.form for={@registration} phx-submit="save" class="space-y-6">
          <%!-- Name Field --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Name <span class="text-red-500">*</span>
            </label>
            <input
              type="text"
              name={@registration[:name].name}
              value={@registration[:name].value || ""}
              data-synced="registration_params.name"
              autocomplete="off"
              data-1p-ignore
              class={"w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 " <>
                cond do
                  @registration_name_valid -> "border-green-300 focus:ring-green-500"
                  @name_empty -> "border-gray-300 focus:ring-blue-500"
                  true -> "border-red-300 focus:ring-red-500"
                end}
              placeholder="Enter your name"
            />
            <div class="h-5 mt-1">
              <.field_errors form={:registration} field={:name} errors={@registration_name_errors} />
              <.field_success form={:registration} field={:name} valid={@registration_name_valid} />
            </div>
          </div>

          <%!-- Email Field --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Email <span class="text-red-500">*</span>
            </label>
            <input
              type="text"
              name={@registration[:email].name}
              value={@registration[:email].value || ""}
              data-synced="registration_params.email"
              autocomplete="off"
              data-1p-ignore
              class={"w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 " <>
                cond do
                  @email_valid -> "border-green-300 focus:ring-green-500"
                  @email_empty -> "border-gray-300 focus:ring-blue-500"
                  true -> "border-red-300 focus:ring-red-500"
                end}
              placeholder="you@example.com"
            />
            <div class="h-5 mt-1">
              <%!-- Custom error for email format (not from Ash) - respects touched state --%>
              <p class="text-red-500 text-sm hidden" data-optimistic-visible="email_at_error_visible">
                Must contain @
              </p>
              <%!-- Show Ash errors only when @ is present (custom error takes precedence) --%>
              <.field_errors :if={@email_has_at or @email_empty} form={:registration} field={:email} errors={@registration_email_errors} />
              <.field_success form={:registration} field={:email} valid={@email_valid} valid_field="email_valid" message="Valid email" />
            </div>
          </div>

          <%!-- Age Field --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Age <span class="text-red-500">*</span>
            </label>
            <input
              type="number"
              name={@registration[:age].name}
              value={@registration[:age].value || ""}
              data-synced="registration_params.age"
              autocomplete="off"
              data-1p-ignore
              min="0"
              max="150"
              class={"w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 " <>
                cond do
                  @registration_age_valid -> "border-green-300 focus:ring-green-500"
                  @age_empty -> "border-gray-300 focus:ring-blue-500"
                  true -> "border-red-300 focus:ring-red-500"
                end}
              placeholder="18"
            />
            <div class="h-5 mt-1">
              <.field_errors form={:registration} field={:age} errors={@registration_age_errors} />
              <.field_success form={:registration} field={:age} valid={@registration_age_valid} message="Age verified" />
            </div>
          </div>

          <%!-- Submit Button --%>
          <div class="pt-4">
            <button
              type="submit"
              disabled={not @form_valid}
              data-optimistic-enabled="form_valid"
              class={"w-full py-3 px-4 rounded-lg font-semibold transition-colors " <>
                if @form_valid do
                  "bg-blue-600 text-white hover:bg-blue-700 cursor-pointer"
                else
                  "bg-gray-300 text-gray-500 cursor-not-allowed"
                end}
              data-optimistic-class-toggle="form_valid:bg-blue-600 text-white hover:bg-blue-700 cursor-pointer:bg-gray-300 text-gray-500 cursor-not-allowed"
            >
              Register
            </button>
            <p class={"text-center text-sm text-gray-500 mt-2 " <> if(@has_any_input and not @form_valid, do: "", else: "hidden")} data-optimistic-visible="show_error_hint">
              Please fix the errors above to continue
            </p>
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
