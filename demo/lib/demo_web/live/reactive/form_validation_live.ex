defmodule DemoWeb.Reactive.FormValidationLive do
  @moduledoc """
  Form validation with `Lavash.LiveView.Explicit` — the non-DSL
  counterpart to `DemoWeb.Dsl.FormValidationDemoLive`.

  Same rules as the DSL demo (mirroring `Demo.Forms.Registration`'s
  constraints: name >= 2 chars, email with `@`, age >= 18) and the
  same Ash submit — but the error derives are hand-written `rx()`
  expressions in a `reactive do` block instead of being generated
  from the resource by the `form` DSL, and validation feedback takes
  a server round-trip (no optimistic JS without the DSL).
  """
  use Lavash.LiveView.Explicit

  alias Demo.Forms.Registration

  reactive do
    state :params, %{}
    state :submitted, false
    derive :name_errors, rx(validate_name(@params["name"] || ""))
    derive :email_errors, rx(validate_email(@params["email"] || ""))
    derive :age_errors, rx(validate_age(@params["age"] || ""))
    derive :form_valid, rx(@name_errors == [] and @email_errors == [] and @age_errors == [])
  end

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = super(params, session, socket)
    {:ok, assign(socket, attempted: false, server_errors: [])}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"registration" => params}, socket) do
    {:noreply, put_state(socket, :params, params)}
  end

  def handle_event("save", %{"registration" => params}, socket) do
    socket = put_state(socket, :params, params)

    if socket.assigns.form_valid do
      case Registration
           |> Ash.Changeset.for_create(:register, params)
           |> Ash.create() do
        {:ok, _registration} ->
          {:noreply, put_state(socket, :submitted, true)}

        {:error, error} ->
          {:noreply, assign(socket, server_errors: Enum.map(error.errors, &Exception.message/1))}
      end
    else
      {:noreply, assign(socket, attempted: true)}
    end
  end

  def handle_event("reset", _, socket) do
    socket =
      socket
      |> put_state(:params, %{})
      |> put_state(:submitted, false)
      |> assign(attempted: false, server_errors: [])

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto mt-10 p-6 card bg-base-100 shadow-lg">
      <h1 class="text-2xl font-bold text-center mb-2">Reactive Form Validation</h1>
      <p class="text-base-content/60 text-center mb-6 text-sm">
        Hand-written error derives in a <code class="bg-base-200 px-1 rounded">reactive</code>
        block — no DSL
      </p>

      <%= if @submitted do %>
        <div class="alert alert-success flex-col text-center">
          <div class="text-5xl mb-4">&#10003;</div>
          <h2 class="text-xl font-semibold mb-2">Registration Complete!</h2>
          <div class="space-y-1">
            <p><strong>Name:</strong> {@params["name"]}</p>
            <p><strong>Email:</strong> {@params["email"]}</p>
            <p><strong>Age:</strong> {@params["age"]}</p>
          </div>
          <button phx-click="reset" class="btn btn-success mt-4">Start Over</button>
        </div>
      <% else %>
        <form id="registration-form" phx-change="validate" phx-submit="save" class="space-y-6">
          <div :if={@server_errors != []} class="alert alert-error text-sm flex-col items-start">
            <p :for={error <- @server_errors}>{error}</p>
          </div>

          <.field
            label="Name"
            name="registration[name]"
            type="text"
            value={@params["name"]}
            placeholder="Enter your name"
            errors={@name_errors}
            show={@attempted or @params["name"] != nil}
          />

          <.field
            label="Email"
            name="registration[email]"
            type="text"
            value={@params["email"]}
            placeholder="you@example.com"
            errors={@email_errors}
            show={@attempted or @params["email"] != nil}
          />

          <.field
            label="Age"
            name="registration[age]"
            type="number"
            value={@params["age"]}
            placeholder="18"
            errors={@age_errors}
            show={@attempted or @params["age"] != nil}
          />

          <div class="pt-4">
            <button
              type="submit"
              class={[
                "w-full py-3 px-4 rounded-lg font-semibold transition-colors",
                if(@form_valid,
                  do: "bg-primary text-primary-content hover:opacity-90",
                  else: "bg-base-300 text-base-content"
                )
              ]}
            >
              Register
            </button>
          </div>
        </form>
      <% end %>

      <div class="mt-8 p-4 bg-base-200 rounded-lg">
        <h3 class="font-semibold mb-2">How it works</h3>
        <ul class="text-sm text-base-content/70 space-y-1">
          <li>
            &bull; <code class="bg-base-300 px-1 rounded">state :params</code> holds raw form input
          </li>
          <li>
            &bull; Error lists are plain <code class="bg-base-300 px-1 rounded">rx()</code>
            derives calling public validator functions
          </li>
          <li>
            &bull; <code class="bg-base-300 px-1 rounded">form_valid</code>
            derives from the error derives — recomputed only when they change
          </li>
          <li>&bull; Submit still goes through the Ash resource for authoritative validation</li>
          <li>
            &bull; Compare: <a href="/dsl/form-validation" class="link">DSL version</a>
            generates all of this from resource constraints, validated client-side
          </li>
        </ul>
      </div>

      <div class="mt-4 text-center">
        <a href="/" class="link text-sm">&larr; All demos</a>
      </div>
    </div>
    """
  end

  defp field(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium mb-1">
        {@label} <span class="text-error">*</span>
      </label>
      <input
        type={@type}
        name={@name}
        value={@value}
        autocomplete="off"
        data-1p-ignore
        placeholder={@placeholder}
        class={[
          "input input-bordered w-full",
          @show && @errors != [] && "input-error"
        ]}
      />
      <div class="h-5 mt-1">
        <p :if={@show and @errors != []} class="text-sm text-error">
          {Enum.join(@errors, ", ")}
        </p>
      </div>
    </div>
    """
  end

  # Public: rx() compute functions are compiled outside the module's
  # private scope, so validators referenced from rx must be public.

  def validate_name(name) do
    cond do
      String.trim(name) == "" -> ["is required"]
      String.length(String.trim(name)) < 2 -> ["must be at least 2 characters"]
      true -> []
    end
  end

  def validate_email(email) do
    cond do
      String.trim(email) == "" -> ["is required"]
      not String.contains?(email, "@") -> ["must contain @"]
      true -> []
    end
  end

  def validate_age(age) do
    trimmed = String.trim(age)

    cond do
      trimmed == "" -> ["is required"]
      not match?({_, ""}, Integer.parse(trimmed)) -> ["must be a number"]
      elem(Integer.parse(trimmed), 0) < 18 -> ["must be at least 18"]
      elem(Integer.parse(trimmed), 0) > 150 -> ["must be at most 150"]
      true -> []
    end
  end
end
