defmodule Lavash.LiveComponent do
  @moduledoc """
  A LiveComponent that can bind to parent Lavash state.

  Components using `use Lavash.LiveComponent` can declare bindings to parent
  state fields, allowing them to read and write parent state directly.

  ## Example

      defmodule MyApp.Components.ChipSet do
        use Lavash.LiveComponent

        # Declare what this component binds to
        bind :selected, {:array, :string}

        # Props passed from parent
        prop :values, {:list, :string}, required: true
        prop :labels, :map, default: %{}

        def render(assigns) do
          ~H'''
          <div class="flex gap-2">
            <button
              :for={v <- @values}
              class={chip_class(v in @selected)}
              phx-click="toggle"
              phx-value-val={v}
              phx-target={@myself}
            >
              {Map.get(@labels, v, humanize(v))}
            </button>
          </div>
          '''
        end

        # Component handles its own events
        def handle_event("toggle", %{"val" => val}, socket) do
          selected = socket.assigns.selected
          new_selected = if val in selected,
            do: List.delete(selected, val),
            else: [val | selected]

          # This updates the bound parent state
          {:noreply, update_binding(socket, :selected, new_selected)}
        end
      end

  ## Usage in parent

      # In parent LiveView DSL:
      state :roast, {:array, :string}, from: :url, default: []

      # In parent template:
      <.live_component
        module={MyApp.Components.ChipSet}
        id="roast-filter"
        bind={[selected: :roast]}
        values={["light", "medium", "dark"]}
      />
  """

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveComponent

      Module.register_attribute(__MODULE__, :lavash_bindings, accumulate: true)
      Module.register_attribute(__MODULE__, :lavash_props, accumulate: true)

      @before_compile Lavash.LiveComponent

      # Import all macros and helpers
      import Lavash.LiveComponent
    end
  end

  @doc """
  Declares a binding slot for this component.

  Bindings connect component-local names to parent state fields.
  The actual field name is provided at render time via the `bind` prop.
  """
  defmacro bind(name, type) do
    quote do
      @lavash_bindings {unquote(name), unquote(Macro.escape(type))}
    end
  end

  @doc """
  Declares a prop for this component.
  """
  defmacro prop(name, type, opts \\ []) do
    quote do
      @lavash_props {unquote(name), unquote(Macro.escape(type)), unquote(opts)}
    end
  end

  @doc """
  Defines a template with a colocated hook that generates JS render functions.

  At compile time, this macro:
  1. Parses the template source to extract structure
  2. Generates a JS render function that creates DOM elements
  3. Emits both HEEx and a colocated hook script

  The hook name must be a compile-time literal string.

  ## Example

      optimistic_template ".ChipSetHook" do
        \"""
        <div class="flex gap-2">
          <button
            :for={v <- @values}
            phx-click="toggle"
            phx-value-val={v}
            class={if v in @selected, do: @active_class, else: @inactive_class}
          >
            {Map.get(@labels, v, v)}
          </button>
        </div>
        \"""
      end
  """
  defmacro optimistic_template(hook_name, do: template_source) when is_binary(hook_name) do
    # At compile time, parse the template and generate JS
    {heex_source, js_render_fn} = Lavash.Template.compile_template(template_source)

    quote do
      # The colocated hook with generated render function
      @doc false
      def __lavash_colocated_hook__ do
        {unquote(hook_name), unquote(js_render_fn)}
      end

      def render(var!(assigns)) do
        # Include the colocated hook script tag in the output
        hook_name = unquote(hook_name)
        js_code = unquote(js_render_fn)

        # Inject the script tag and render the template
        import Phoenix.Component, only: [sigil_H: 2]

        ~H"""
        <script :type={Phoenix.LiveView.ColocatedHook} name={unquote(hook_name)}>
        <%= raw(unquote(js_render_fn)) %>
        </script>
        """ <> sigil_H(unquote(heex_source), [])
      end
    end
  end

  defmacro __before_compile__(env) do
    bindings = Module.get_attribute(env.module, :lavash_bindings) || []
    props = Module.get_attribute(env.module, :lavash_props) || []

    quote do
      def __lavash_bindings__, do: unquote(Macro.escape(bindings))
      def __lavash_props__, do: unquote(Macro.escape(props))

      # Override mount to set up bindings and version tracking
      def mount(socket) do
        socket =
          socket
          |> assign(:__lavash_binding_map__, %{})
          |> assign(:__lavash_version__, 0)

        {:ok, socket}
      end

      defoverridable mount: 1

      # Override update to handle binding resolution
      def update(assigns, socket) do
        socket = resolve_bindings(assigns, socket)
        {:ok, assign(socket, Map.drop(assigns, [:bind, :__changed__]))}
      end

      defoverridable update: 2

      defp resolve_bindings(assigns, socket) do
        case Map.get(assigns, :bind) do
          nil ->
            socket

          bindings when is_list(bindings) ->
            # Build a map of local_name -> parent_field
            binding_map =
              Enum.into(bindings, %{}, fn {local, parent} ->
                {local, parent}
              end)

            # Store the binding map for later use in update_binding
            socket = assign(socket, :__lavash_binding_map__, binding_map)

            # Sync parent's optimistic version when bound
            # This ensures the component's version tracks the parent's version
            # so that optimistic updates work correctly across parent/child
            socket =
              case Map.get(assigns, :__lavash_parent_version__) do
                nil -> socket
                parent_version -> assign(socket, :__lavash_version__, parent_version)
              end

            # For each binding, look up the parent's current value
            # The parent passes these as regular assigns
            Enum.reduce(bindings, socket, fn {local, parent}, sock ->
              # Parent should have passed the current value as the local name
              value = Map.get(assigns, local)
              assign(sock, local, value)
            end)
        end
      end
    end
  end

  @doc """
  Updates a bound value, which propagates to the parent's state.

  This sends a message to the parent LiveView to update the bound state field.
  """
  def update_binding(socket, local_name, new_value) do
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, local_name) do
      nil ->
        # Not a bound field, just update locally
        Phoenix.Component.assign(socket, local_name, new_value)

      parent_field ->
        # Update locally immediately for responsiveness
        socket = Phoenix.Component.assign(socket, local_name, new_value)

        # Send delta to parent via the existing component event mechanism
        send(self(), {:lavash_component_delta, parent_field, new_value})

        socket
    end
  end

  @doc """
  Sends an event to the parent LiveView to be handled as a Lavash action.
  """
  def notify_parent(event, params \\ %{}) do
    send(self(), {:lavash_component_event, event, params})
  end

  @doc """
  Bumps the optimistic version counter.

  Call this in handle_event before sending updates to the parent.
  The version is rendered in `data-lavash-version` and compared by the
  client-side hook to detect and discard stale server updates.
  """
  def bump_version(socket) do
    current = socket.assigns[:__lavash_version__] || 0
    Phoenix.Component.assign(socket, :__lavash_version__, current + 1)
  end
end
