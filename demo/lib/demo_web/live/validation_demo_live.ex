defmodule DemoWeb.ValidationDemoLive do
  @moduledoc """
  Demo showcasing client-side vs server-side validation.

  Demonstrates two error sources working together:

  1. **Client errors** (instant): Transpiled from Ash resource constraints
     - username: required, 3-20 characters
     - email: required
     - password: required, min 8 characters

  2. **Server errors** (after debounced round-trip): From custom Ash validations
     - email: format validation via `Demo.Validations.EmailFormat` module
     - Cannot be transpiled to JS, so runs on server only

  Server errors are stored in `account_server_errors` state and merged into
  the `_errors` derives alongside client constraint errors.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [field_errors: 1, error_summary: 1]

  alias Demo.Forms.Account

  state :account_params, :map, from: :ephemeral, default: %{}, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  form :account, Account do
    create :create_account
  end

  calculate :form_valid, rx(@account_username_valid and @account_email_valid and @account_password_valid)

  actions do
    action :save do
      submit :account, on_success: :on_saved, on_error: :on_error
    end

    action :on_saved do
      set :submitted, true
    end

    action :on_error do
      # Server errors stored in account_server_errors, merged into _errors derives
    end

    action :reset do
      set :account_params, %{}
      set :submitted, false
    end
  end

  render fn assigns ->
    ~L"""
    <div id="validation-demo" class="max-w-lg mx-auto mt-10 p-6 bg-white rounded-lg shadow-lg">
      <h1 class="text-2xl font-bold text-center mb-2">Client + Server Validation</h1>
      <p class="text-gray-500 text-center mb-6 text-sm">
        Client errors appear instantly. Server errors appear after a brief round-trip.
      </p>

      <%= if @submitted do %>
        <div class="alert alert-success flex-col text-center">
          <div class="text-5xl mb-4">&#10003;</div>
          <h2 class="text-xl font-semibold mb-2">Account Created!</h2>
          <div class="space-y-1">
            <p><strong>Username:</strong> {@account_params["username"]}</p>
            <p><strong>Email:</strong> {@account_params["email"]}</p>
          </div>
          <button phx-click="reset" class="btn btn-success mt-4">
            Start Over
          </button>
        </div>
      <% else %>
        <.form for={@account} phx-submit="save" class="space-y-6">
          <.error_summary form={:account} />

          <%!-- Username: client-evaluable (required, min 3, max 20) --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Username <span class="text-error">*</span>
            </label>
            <input
              type="text"
              field={@account[:username]}
              autocomplete="off"
              data-1p-ignore
              class="input input-bordered w-full"
              placeholder="3-20 characters"
            />
            <div class="h-5 mt-1">
              <.field_errors form={:account} field={:username} errors={@account_username_errors} />
            </div>
            <p class="text-xs text-gray-400 mt-0.5">
              Client-side: required, 3-20 chars
            </p>
          </div>

          <%!-- Email: client (required) + server-only (format check) --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Email <span class="text-error">*</span>
            </label>
            <input
              type="text"
              field={@account[:email]}
              autocomplete="off"
              data-1p-ignore
              class="input input-bordered w-full"
              placeholder="you@example.com"
            />
            <div class="h-5 mt-1">
              <.field_errors form={:account} field={:email} errors={@account_email_errors} />
            </div>
            <p class="text-xs text-gray-400 mt-0.5">
              Client-side: required &mdash; Server-side: email format
            </p>
          </div>

          <%!-- Password: client-evaluable (required, min 8) --%>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Password <span class="text-error">*</span>
            </label>
            <input
              type="password"
              field={@account[:password]}
              autocomplete="off"
              data-1p-ignore
              class="input input-bordered w-full"
              placeholder="At least 8 characters"
            />
            <div class="h-5 mt-1">
              <.field_errors form={:account} field={:password} errors={@account_password_errors} />
            </div>
            <p class="text-xs text-gray-400 mt-0.5">
              Client-side: required, min 8 chars
            </p>
          </div>

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
              Create Account
            </button>
          </div>
        </.form>
      <% end %>

      <div class="mt-8 p-4 bg-gray-50 rounded-lg">
        <h3 class="font-semibold text-gray-700 mb-2">How it works</h3>
        <ul class="text-sm text-gray-600 space-y-2">
          <li>
            <strong class="text-blue-600">Client errors</strong> &mdash;
            Transpiled from Ash <code class="bg-gray-200 px-1 rounded">constraints</code>
            (min_length, max_length, allow_nil?). Evaluated instantly in JS.
          </li>
          <li>
            <strong class="text-purple-600">Server errors</strong> &mdash;
            From custom Ash <code class="bg-gray-200 px-1 rounded">validations</code>
            that can't be transpiled (e.g. regex module, DB lookups). Arrive after debounced server round-trip.
          </li>
          <li>
            Both error sources are merged into the same
            <code class="bg-gray-200 px-1 rounded">_errors</code> derive.
            JS owns display; server re-renders don't wipe error state.
          </li>
        </ul>
      </div>

      <div class="mt-4 p-4 bg-blue-50 rounded-lg">
        <h3 class="font-semibold text-blue-700 mb-2">Try it</h3>
        <ol class="text-sm text-blue-600 space-y-1 list-decimal list-inside">
          <li>Type "ab" in username &mdash; instant "must be at least 3 characters"</li>
          <li>Type "notanemail" in email &mdash; server error "must be a valid email address" after brief delay</li>
          <li>Type "short" in password &mdash; instant "must be at least 8 characters"</li>
          <li>Fix all fields and submit &mdash; account created</li>
        </ol>
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
