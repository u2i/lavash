defmodule DemoWeb.FormValidationDemoLive do
  @moduledoc """
  Demo showcasing client-side form validation using Lavash calculations.

  This demonstrates:
  - Path-based reactivity with @params["field"] syntax
  - Client-side validation via rx() calculations
  - Real-time validation feedback without server round-trips
  - Form submission with optimistic UX
  """
  use Lavash.LiveView
  import Lavash.Rx

  # Form params are implicitly optimistic - they flow to the client automatically
  state :params, :map, from: :ephemeral, default: %{}, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  # Validations using path-based reactivity
  # These calculations run on both server and client

  # Name validation
  calculate :name_value, rx(@params["name"] || "")
  calculate :name_empty, rx(is_nil(@params["name"]) or String.length(String.trim(@params["name"] || "")) == 0)
  calculate :name_too_short, rx(not is_nil(@params["name"]) and String.length(String.trim(@params["name"] || "")) > 0 and String.length(String.trim(@params["name"] || "")) < 2)
  calculate :name_valid, rx(String.length(String.trim(@params["name"] || "")) >= 2)

  # Email validation (simple pattern)
  calculate :email_value, rx(@params["email"] || "")
  calculate :email_empty, rx(is_nil(@params["email"]) or String.length(String.trim(@params["email"] || "")) == 0)
  calculate :email_invalid, rx(
    not is_nil(@params["email"]) and
    String.length(String.trim(@params["email"] || "")) > 0 and
    not String.contains?(@params["email"] || "", "@")
  )
  calculate :email_valid, rx(String.contains?(@params["email"] || "", "@"))

  # Age validation (must be 18+)
  calculate :age_value, rx(@params["age"] || "")
  calculate :age_empty, rx(is_nil(@params["age"]) or String.length(String.trim(@params["age"] || "")) == 0)
  calculate :age_number, rx(
    if is_nil(@params["age"]) or String.length(String.trim(@params["age"] || "")) == 0,
      do: nil,
      else: String.to_integer(@params["age"] || "0")
  )
  calculate :age_under_18, rx(
    not is_nil(@params["age"]) and
    String.length(String.trim(@params["age"] || "")) > 0 and
    String.to_integer(@params["age"] || "0") < 18
  )
  calculate :age_valid, rx(
    not is_nil(@params["age"]) and
    String.length(String.trim(@params["age"] || "")) > 0 and
    String.to_integer(@params["age"] || "0") >= 18
  )

  # Overall form validity
  calculate :form_valid, rx(@name_valid and @email_valid and @age_valid)
  calculate :has_any_input, rx(
    String.length(String.trim(@params["name"] || "")) > 0 or
    String.length(String.trim(@params["email"] || "")) > 0 or
    String.length(String.trim(@params["age"] || "")) > 0
  )
  calculate :show_error_hint, rx(@has_any_input and not @form_valid)

  actions do
    action :update_field, [:field, :value] do
      # This action updates a single field in the params map
      # The client-side version will be auto-generated
    end

    action :submit_form do
      set :submitted, true
    end

    action :reset_form do
      set :params, %{}
      set :submitted, false
    end
  end

  @impl true
  def handle_event("update_field", input_params, socket) do
    # phx-change sends the input name/value as params directly
    # Merge all input values into our params map
    params = Map.merge(socket.assigns.params, input_params)
    {:noreply, assign(socket, :params, params)}
  end

  @impl true
  def handle_event("submit_form", _params, socket) do
    if socket.assigns.form_valid do
      {:noreply, assign(socket, :submitted, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reset_form", _params, socket) do
    {:noreply, assign(socket, params: %{}, submitted: false)}
  end

  def render(assigns) do
    ~H"""
    <div id="form-validation-demo" class="max-w-lg mx-auto mt-10 p-6 bg-white rounded-lg shadow-lg">
      <h1 class="text-2xl font-bold text-center mb-2">Client-Side Form Validation</h1>
      <p class="text-gray-500 text-center mb-6 text-sm">
        Validation runs instantly on the client via transpiled Elixir calculations
      </p>

      <%= if @submitted do %>
        <div class="bg-green-50 border border-green-200 rounded-lg p-6 text-center">
          <div class="text-green-600 text-5xl mb-4">✓</div>
          <h2 class="text-xl font-semibold text-green-800 mb-2">Form Submitted!</h2>
          <div class="text-gray-600 space-y-1">
            <p><strong>Name:</strong> {@params["name"]}</p>
            <p><strong>Email:</strong> {@params["email"]}</p>
            <p><strong>Age:</strong> {@params["age"]}</p>
          </div>
          <button
            phx-click="reset_form"
            class="mt-4 px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700"
          >
            Start Over
          </button>
        </div>
      <% else %>
        <form phx-submit="submit_form" class="space-y-6">
          <%!-- Name Field --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Name <span class="text-red-500">*</span>
            </label>
            <input
              type="text"
              name="name"
              value={@params["name"] || ""}
              phx-change="update_field"
              phx-value-field="name"
              data-synced="params.name"
              autocomplete="off"
              data-1p-ignore
              class={"w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 " <>
                cond do
                  @name_valid -> "border-green-300 focus:ring-green-500"
                  @name_empty -> "border-gray-300 focus:ring-blue-500"
                  true -> "border-red-300 focus:ring-red-500"
                end}
              placeholder="Enter your name"
            />
            <div class="h-5 mt-1">
              <p class={"text-red-500 text-sm " <> if(@name_too_short, do: "", else: "hidden")} data-optimistic-visible="name_too_short">
                Name must be at least 2 characters
              </p>
              <p class={"text-green-500 text-sm " <> if(@name_valid, do: "", else: "hidden")} data-optimistic-visible="name_valid">
                ✓ Looks good!
              </p>
            </div>
          </div>

          <%!-- Email Field --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Email <span class="text-red-500">*</span>
            </label>
            <input
              type="text"
              name="email"
              value={@params["email"] || ""}
              phx-change="update_field"
              phx-value-field="email"
              data-synced="params.email"
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
              <p class={"text-red-500 text-sm " <> if(@email_invalid, do: "", else: "hidden")} data-optimistic-visible="email_invalid">
                Please enter a valid email address
              </p>
              <p class={"text-green-500 text-sm " <> if(@email_valid, do: "", else: "hidden")} data-optimistic-visible="email_valid">
                ✓ Valid email
              </p>
            </div>
          </div>

          <%!-- Age Field --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Age <span class="text-red-500">*</span>
            </label>
            <input
              type="number"
              name="age"
              value={@params["age"] || ""}
              phx-change="update_field"
              phx-value-field="age"
              data-synced="params.age"
              autocomplete="off"
              data-1p-ignore
              min="0"
              max="150"
              class={"w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 " <>
                cond do
                  @age_valid -> "border-green-300 focus:ring-green-500"
                  @age_empty -> "border-gray-300 focus:ring-blue-500"
                  true -> "border-red-300 focus:ring-red-500"
                end}
              placeholder="18"
            />
            <div class="h-5 mt-1">
              <p class={"text-red-500 text-sm " <> if(@age_under_18, do: "", else: "hidden")} data-optimistic-visible="age_under_18">
                You must be 18 or older
              </p>
              <p class={"text-green-500 text-sm " <> if(@age_valid, do: "", else: "hidden")} data-optimistic-visible="age_valid">
                ✓ Age verified
              </p>
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
              Submit Registration
            </button>
            <p class={"text-center text-sm text-gray-500 mt-2 " <> if(@has_any_input and not @form_valid, do: "", else: "hidden")} data-optimistic-visible="show_error_hint">
              Please fix the errors above to continue
            </p>
          </div>
        </form>
      <% end %>

      <div class="mt-8 p-4 bg-gray-50 rounded-lg">
        <h3 class="font-semibold text-gray-700 mb-2">How it works</h3>
        <ul class="text-sm text-gray-600 space-y-1">
          <li>• Validations defined as <code class="bg-gray-200 px-1 rounded">calculate :name, rx(...)</code></li>
          <li>• <code class="bg-gray-200 px-1 rounded">rx()</code> expressions are transpiled to JavaScript</li>
          <li>• Path deps like <code class="bg-gray-200 px-1 rounded">@params["name"]</code> track nested state</li>
          <li>• Validation runs client-side on every keystroke</li>
          <li>• Same validation logic runs server-side for security</li>
        </ul>
      </div>

      <div class="mt-4 text-center">
        <a href="/" class="text-blue-600 hover:text-blue-800">
          &larr; Back to Demos
        </a>
      </div>

      <script :type={Phoenix.LiveView.ColocatedJS} name="optimistic">
        // Client-side functions for optimistic form updates
        export default {
          // Action: update a field in the params map
          update_field(state, value, params) {
            const field = params?.field;
            if (!field) return {};
            return {
              params: { ...state.params, [field]: value }
            };
          },

          // Action: submit the form
          submit_form(state) {
            // Only submit if valid (client-side check)
            const nameValid = (state.params?.name || '').trim().length >= 2;
            const emailValid = (state.params?.email || '').includes('@');
            const ageValid = parseInt(state.params?.age || '0', 10) >= 18;
            if (nameValid && emailValid && ageValid) {
              return { submitted: true };
            }
            return {};
          },

          // Action: reset the form
          reset_form(state) {
            return { params: {}, submitted: false };
          },

          // Derive: name_value
          name_value(state) {
            return state.params?.name || '';
          },

          // Derive: name_empty
          name_empty(state) {
            return !state.params?.name || (state.params?.name || '').trim().length === 0;
          },

          // Derive: name_too_short
          name_too_short(state) {
            const name = (state.params?.name || '').trim();
            return name.length > 0 && name.length < 2;
          },

          // Derive: name_valid
          name_valid(state) {
            return (state.params?.name || '').trim().length >= 2;
          },

          // Derive: email_value
          email_value(state) {
            return state.params?.email || '';
          },

          // Derive: email_empty
          email_empty(state) {
            return !state.params?.email || (state.params?.email || '').trim().length === 0;
          },

          // Derive: email_invalid
          email_invalid(state) {
            const email = (state.params?.email || '').trim();
            return email.length > 0 && !email.includes('@');
          },

          // Derive: email_valid
          email_valid(state) {
            return (state.params?.email || '').includes('@');
          },

          // Derive: age_value
          age_value(state) {
            return state.params?.age || '';
          },

          // Derive: age_empty
          age_empty(state) {
            return !state.params?.age || (state.params?.age || '').trim().length === 0;
          },

          // Derive: age_number
          age_number(state) {
            const age = (state.params?.age || '').trim();
            return age.length === 0 ? null : parseInt(age, 10);
          },

          // Derive: age_under_18
          age_under_18(state) {
            const age = (state.params?.age || '').trim();
            return age.length > 0 && parseInt(age, 10) < 18;
          },

          // Derive: age_valid
          age_valid(state) {
            const age = (state.params?.age || '').trim();
            return age.length > 0 && parseInt(age, 10) >= 18;
          },

          // Derive: form_valid
          form_valid(state) {
            const nameValid = (state.params?.name || '').trim().length >= 2;
            const emailValid = (state.params?.email || '').includes('@');
            const ageValid = parseInt(state.params?.age || '0', 10) >= 18;
            return nameValid && emailValid && ageValid;
          },

          // Derive: has_any_input
          has_any_input(state) {
            return (state.params?.name || '').trim().length > 0 ||
                   (state.params?.email || '').trim().length > 0 ||
                   (state.params?.age || '').trim().length > 0;
          },

          // Derive: show_error_hint
          show_error_hint(state) {
            return state.has_any_input && !state.form_valid;
          },

          // Metadata
          __derives__: [
            "name_value", "name_empty", "name_too_short", "name_valid",
            "email_value", "email_empty", "email_invalid", "email_valid",
            "age_value", "age_empty", "age_number", "age_under_18", "age_valid",
            "form_valid", "has_any_input", "show_error_hint"
          ],
          __fields__: ["params", "submitted"],
          __graph__: {
            "name_value": { "deps": ["params"] },
            "name_empty": { "deps": ["params"] },
            "name_too_short": { "deps": ["params"] },
            "name_valid": { "deps": ["params"] },
            "email_value": { "deps": ["params"] },
            "email_empty": { "deps": ["params"] },
            "email_invalid": { "deps": ["params"] },
            "email_valid": { "deps": ["params"] },
            "age_value": { "deps": ["params"] },
            "age_empty": { "deps": ["params"] },
            "age_number": { "deps": ["params"] },
            "age_under_18": { "deps": ["params"] },
            "age_valid": { "deps": ["params"] },
            "form_valid": { "deps": ["name_valid", "email_valid", "age_valid"] },
            "has_any_input": { "deps": ["params"] },
            "show_error_hint": { "deps": ["has_any_input", "form_valid"] }
          }
        };
      </script>
    </div>
    """
  end
end
