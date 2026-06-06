defmodule Lavash do
  @moduledoc """
  Reactive state management for Phoenix LiveView.

  Lavash is two things in one package:

  - A **DSL** (`Lavash.LiveView`, `Lavash.Component`) for declaring state,
    computed values, forms, actions, and overlays, with a `template do ~H end`
    block that auto-injects the client-side machinery for optimistic updates.
  - A **reactive engine** (`Lavash.Reactive`, `Lavash.LiveView.Explicit`)
    that powers the DSL but is also usable directly from a plain
    `Phoenix.LiveView` when you want the dependency graph without the rest.

  See the README for a full guide. The minimal DSL example:

      defmodule MyAppWeb.ProfileLive do
        use Lavash.LiveView

        state :user_id, :integer, from: :url, required: true
        state :tab, :string, from: :url, default: "overview"
        state :editing, :boolean, default: false

        read :user, MyApp.Accounts.User do
          id state(:user_id)
        end

        actions do
          action :change_tab, [:tab] do
            set :tab, rx(@tab)
          end
        end

        template do
          ~H\"\"\"
          <div>...</div>
          \"\"\"
        end
      end

  ## Imperative API

  Inside a handler, when the declarative pipeline doesn't fit, use the
  imperative helpers:

      def handle_event("save", %{"product" => params}, socket) do
        socket =
          socket
          |> Lavash.set(:form_data, params)
          |> Lavash.set(:submitting, true)
          |> Lavash.finalize(__MODULE__)

        # derived fields are now recomputed and assigns projected
        {:noreply, socket}
      end
  """

  alias Lavash.Socket, as: LSocket

  @doc """
  Gets a state or derived value from the socket.

  ## Examples

      changeset = Lavash.get(socket, :changeset)
      form_data = Lavash.get(socket, :form_data)
  """
  def get(socket, field) when is_atom(field) do
    socket.assigns[field]
  end

  @doc """
  Sets a state field value. This is for use in `handle_event` callbacks
  when you need imperative control.

  Note: This does NOT automatically recompute derived fields or project assigns.
  Call `Lavash.finalize/2` after all updates to trigger recomputation.

  ## Examples

      socket = Lavash.set(socket, :form_data, params)
      socket = Lavash.set(socket, :submitting, true)
      socket = Lavash.finalize(socket, __MODULE__)
  """
  def set(socket, field, value) when is_atom(field) do
    LSocket.put_state(socket, field, value)
  end

  @doc """
  Updates a state field using a function.

  ## Examples

      socket = Lavash.update(socket, :count, &(&1 + 1))
  """
  def update(socket, field, fun) when is_atom(field) and is_function(fun, 1) do
    current = get(socket, field)
    set(socket, field, fun.(current))
  end

  @doc """
  Finalizes state changes by recomputing dirty derived fields and projecting assigns.
  Call this after using `set/3` or `update/3` in a `handle_event`.

  ## Examples

      def handle_event("save", params, socket) do
        socket =
          socket
          |> Lavash.set(:form_data, params)
          |> Lavash.set(:submitting, true)
          |> Lavash.finalize(__MODULE__)

        # Now derived fields are recomputed and assigns are projected
        {:noreply, socket}
      end
  """
  def finalize(socket, module) do
    socket
    |> Lavash.Reactive.recompute()
    |> Lavash.Assigns.project(module)
  end

  @doc """
  Gets the full state map (not including derived).
  """
  def state(socket) do
    LSocket.state(socket)
  end

  @doc """
  Gets the full derived state map.
  """
  def derived(socket) do
    LSocket.derived(socket)
  end
end
