defmodule Lavash do
  @moduledoc """
  Lavash - A declarative state management layer for Phoenix LiveView.

  Lavash provides an Ash-inspired DSL for managing LiveView state with:

  - **URL State**: Bidirectionally synced with URL params
  - **Ephemeral State**: Socket-only state, lost on disconnect
  - **Derived State**: Computed values with dependency tracking
  - **Assigns**: Projection of state into template assigns
  - **Actions**: State transformers triggered by events

  ## Example

      defmodule MyApp.ProfileLive do
        use Lavash.LiveView

        state do
          url do
            field :user_id, :integer, required: true
            field :tab, :string, default: "overview"
          end

          ephemeral do
            field :editing, :boolean, default: false
          end
        end

        derived do
          field :user, depends_on: [:user_id], async: true, compute: &load_user/1
        end

        assigns do
          assign :user
          assign :tab
        end

        actions do
          action :change_tab, params: [:tab] do
            set :tab, & &1.params.tab
          end
        end

        defp load_user(%{user_id: id}), do: MyApp.Accounts.get_user!(id)

        def render(assigns) do
          ~H\"\"\"
          <div>...</div>
          \"\"\"
        end
      end

  ## Imperative API

  For cases where declarative actions don't fit (like form submissions with
  async results), use the imperative API in `handle_event`:

      def handle_event("save", %{"product" => params}, socket) do
        socket = Lavash.set(socket, :form_data, params)
        changeset = Lavash.get(socket, :changeset)

        case Ash.update(changeset) do
          {:ok, _} -> {:noreply, push_navigate(socket, to: ~p"/products")}
          {:error, _} -> {:noreply, Lavash.set(socket, :submitting, false)}
        end
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
    state = LSocket.state(socket)
    derived = LSocket.derived(socket)

    # Check derived first, then state
    case Map.fetch(derived, field) do
      {:ok, value} -> value
      :error -> Map.get(state, field)
    end
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
    |> Lavash.Graph.recompute_dirty(module)
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
