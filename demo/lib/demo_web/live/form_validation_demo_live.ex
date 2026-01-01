defmodule DemoWeb.FormValidationDemoLive do
  @moduledoc """
  Demo showcasing Ash form validation with client-side optimistic updates.

  This demonstrates:
  - Ash form DSL with `form :registration, Demo.Forms.Registration`
  - Client-side validation via `rx()` calculations (transpiled to JS)
  - Real-time validation feedback without server round-trips
  - Form submission to Ash resource with ETS data layer
  """
  use Lavash.LiveView
  import Lavash.Rx

  alias Demo.Forms.Registration

  # Form params - Lavash automatically populates this from form events
  # The form DSL expects :<form_name>_params state field
  state :registration_params, :map, from: :ephemeral, default: %{}, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  # Ash form for server-side validation and submission
  form :registration, Registration do
    create :register
  end

  # Client-side validations using rx() - transpiled to JavaScript
  # These mirror the Ash resource validations for instant feedback

  # Name validation (min 2 chars - matches Ash constraint)
  calculate :name_value, rx(@registration_params["name"] || "")
  calculate :name_empty, rx(is_nil(@registration_params["name"]) or String.length(String.trim(@registration_params["name"] || "")) == 0)
  calculate :name_too_short, rx(not is_nil(@registration_params["name"]) and String.length(String.trim(@registration_params["name"] || "")) > 0 and String.length(String.trim(@registration_params["name"] || "")) < 2)
  calculate :name_valid, rx(String.length(String.trim(@registration_params["name"] || "")) >= 2)

  # Email validation (must contain @ - matches Ash validation)
  calculate :email_value, rx(@registration_params["email"] || "")
  calculate :email_empty, rx(is_nil(@registration_params["email"]) or String.length(String.trim(@registration_params["email"] || "")) == 0)
  calculate :email_invalid, rx(
    not is_nil(@registration_params["email"]) and
    String.length(String.trim(@registration_params["email"] || "")) > 0 and
    not String.contains?(@registration_params["email"] || "", "@")
  )
  calculate :email_valid, rx(String.contains?(@registration_params["email"] || "", "@"))

  # Age validation (must be 18+ - matches Ash constraint)
  calculate :age_value, rx(@registration_params["age"] || "")
  calculate :age_empty, rx(is_nil(@registration_params["age"]) or String.length(String.trim(@registration_params["age"] || "")) == 0)
  calculate :age_number, rx(
    if is_nil(@registration_params["age"]) or String.length(String.trim(@registration_params["age"] || "")) == 0,
      do: nil,
      else: String.to_integer(@registration_params["age"] || "0")
  )
  calculate :age_under_18, rx(
    not is_nil(@registration_params["age"]) and
    String.length(String.trim(@registration_params["age"] || "")) > 0 and
    String.to_integer(@registration_params["age"] || "0") < 18
  )
  calculate :age_valid, rx(
    not is_nil(@registration_params["age"]) and
    String.length(String.trim(@registration_params["age"] || "")) > 0 and
    String.to_integer(@registration_params["age"] || "0") >= 18
  )

  # Overall form validity
  calculate :form_valid, rx(@name_valid and @email_valid and @age_valid)
  calculate :has_any_input, rx(
    String.length(String.trim(@registration_params["name"] || "")) > 0 or
    String.length(String.trim(@registration_params["email"] || "")) > 0 or
    String.length(String.trim(@registration_params["age"] || "")) > 0
  )
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

  # Note: No manual handle_event needed!
  # Lavash runtime handles:
  # - "validate" events: apply_form_bindings updates :registration_params automatically
  # - "save" event: triggers the :save action which runs `submit :registration`
  # - "reset" event: triggers the :reset action

  def render(assigns) do
    ~H"""
    <div id="form-validation-demo" class="max-w-lg mx-auto mt-10 p-6 bg-white rounded-lg shadow-lg">
      <h1 class="text-2xl font-bold text-center mb-2">Ash Form Validation</h1>
      <p class="text-gray-500 text-center mb-6 text-sm">
        Ash resource validations + client-side rx() calculations
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
        <.form for={@registration} phx-change="validate" phx-submit="save" class="space-y-6">
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
              <%!-- Ash validation errors --%>
              <.field_errors :if={@registration[:name].errors != []} errors={@registration[:name].errors} />
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
              <p class={"text-red-500 text-sm " <> if(@email_invalid, do: "", else: "hidden")} data-optimistic-visible="email_invalid">
                Please enter a valid email address
              </p>
              <p class={"text-green-500 text-sm " <> if(@email_valid, do: "", else: "hidden")} data-optimistic-visible="email_valid">
                ✓ Valid email
              </p>
              <.field_errors :if={@registration[:email].errors != []} errors={@registration[:email].errors} />
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
              <.field_errors :if={@registration[:age].errors != []} errors={@registration[:age].errors} />
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
          <li>• Ash resource with <code class="bg-gray-200 px-1 rounded">constraints</code> and <code class="bg-gray-200 px-1 rounded">validations</code></li>
          <li>• <code class="bg-gray-200 px-1 rounded">form :registration, Registration</code> creates AshPhoenix.Form</li>
          <li>• <code class="bg-gray-200 px-1 rounded">rx()</code> calculations mirror Ash validations for client-side</li>
          <li>• Client validates instantly, server validates on submit</li>
          <li>• ETS data layer - forms stored in memory (not persisted)</li>
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

  defp field_errors(assigns) do
    ~H"""
    <span :for={error <- @errors} class="text-red-500 text-sm">
      {translate_error(error)}
    </span>
    """
  end

  defp translate_error({msg, opts}) when is_list(opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp translate_error({msg, _opts}), do: to_string(msg)
  defp translate_error(msg) when is_binary(msg), do: msg
end
