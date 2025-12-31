defmodule Lavash.LiveComponent.Compiler do
  @moduledoc """
  Compile-time code generation for LiveComponent.

  Generates:
  - JS hook using SyncedVar for per-field optimistic tracking
  - Mount/update callbacks for binding resolution
  - Handle event functions for optimistic actions
  """

  alias Lavash.Component.CompilerHelpers

  defmacro __before_compile__(env) do
    synced_fields = Spark.Dsl.Extension.get_entities(env.module, [:synced_fields]) || []
    props = Spark.Dsl.Extension.get_entities(env.module, [:props]) || []
    templates = Spark.Dsl.Extension.get_entities(env.module, [:template]) || []

    # Calculations are stored as 4-tuples: {name, source, transformed_ast, deps}
    calculations = Module.get_attribute(env.module, :__lavash_calculations__) || []

    # Actions are stored as 5-tuples: {name, field, run_source, validate_source, max}
    action_tuples = Module.get_attribute(env.module, :__lavash_optimistic_actions__) || []
    actions = Enum.map(action_tuples, fn {name, field, run_source, validate_source, max} ->
      %{name: name, field: field, run_source: run_source, validate_source: validate_source, max: max}
    end)

    # Get template source (if provided via DSL)
    template_source = case templates do
      [%{source: source} | _] -> source
      _ -> nil
    end

    # Generate hook name from module
    module_name = env.module |> Module.split() |> List.last()
    hook_name = ".#{module_name}"
    full_hook_name = "#{inspect(env.module)}.#{module_name}"

    # Generate JS hook code
    js_code = generate_js_hook(synced_fields, calculations, actions)

    # Write to colocated hooks directory
    hook_data = CompilerHelpers.write_colocated_hook(env, full_hook_name, js_code)

    # Pre-escape hook_data before entering quote
    escaped_hook_data = if hook_data, do: Macro.escape(hook_data), else: nil

    # Generate mount/update callbacks
    mount_update_fns = generate_mount_update(synced_fields, props, calculations)

    # Generate handle_event functions
    handle_event_fns = generate_handle_events(actions, synced_fields)

    # Generate calculation functions for server-side
    calculation_fns = generate_server_calculations(calculations)

    # Generate render function if template is provided
    render_fn = if template_source do
      generate_render(template_source, full_hook_name, calculations, actions, synced_fields, env)
    end

    quote do
      # Hook metadata
      def __hook_name__, do: unquote(hook_name)
      def __full_hook_name__, do: unquote(full_hook_name)
      def __generated_js__, do: unquote(js_code)

      # Phoenix colocated hooks integration
      if unquote(escaped_hook_data) do
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedHook => [unquote(escaped_hook_data)]
          }
        end
      end

      # Mount and update callbacks
      unquote(mount_update_fns)

      # Server-side calculations
      unquote(calculation_fns)

      # Handle event functions
      unquote(handle_event_fns)

      # Render function (if template provided)
      unquote(render_fn)
    end
  end

  # Generate the JS hook code using SyncedVar
  defp generate_js_hook(synced_fields, calculations, actions) do
    field_names = Enum.map(synced_fields, & &1.name)
    field_names_json = Jason.encode!(Enum.map(field_names, &to_string/1))

    calc_js = generate_calculation_js(calculations)
    action_js = generate_action_js(actions)

    ~s"""
    // Generated LiveComponent hook using SyncedVar
    // Each synced field gets its own SyncedVar for granular pending tracking

    export default {
      mounted() {
        const SyncedVar = window.Lavash?.SyncedVar;
        if (!SyncedVar) {
          console.error("SyncedVar not found. Make sure synced_var.js is loaded.");
          return;
        }

        // Parse initial state
        const initialState = JSON.parse(this.el.dataset.syncedState || "{}");
        this.state = { ...initialState };

        // Create SyncedVar for each synced field
        this.fields = {};
        const fieldNames = #{field_names_json};
        for (const name of fieldNames) {
          this.fields[name] = new SyncedVar(initialState[name], (newVal, oldVal, source) => {
            this.state[name] = newVal;
            if (source === 'optimistic') {
              this.runCalculations();
              this.updateDOM();
            }
          });
        }

        // Bindings to parent
        this.bindings = JSON.parse(this.el.dataset.syncedBindings || "{}");

        // Store reference for parent access
        this.el.__lavash_hook__ = this;

        // Event handlers
        this.clickHandler = this.handleClick.bind(this);
        this.el.addEventListener("click", this.clickHandler, true);
      },

    #{calc_js}

      runCalculations() {
        // Re-run all calculations based on current state
    #{generate_run_calculations(calculations)}
      },

    #{action_js}

      handleClick(e) {
        const target = e.target.closest("[data-synced-action]");
        if (!target) return;

        e.stopPropagation();

        const action = target.dataset.syncedAction;
        const field = target.dataset.syncedField;
        const value = target.dataset.syncedValue;

        if (!this.fields[field]) return;

        // Compute new value
        const currentValue = this.fields[field].value;
        const newValue = this.computeAction(action, field, currentValue, value);

        if (newValue === currentValue) return;

        // Optimistic update via SyncedVar
        this.fields[field].setOptimistic(newValue);

        // Sync to parent if bound
        this.syncToParent(field, newValue);

        // Push event to server
        this.pushEventTo(this.el, "synced_action", {
          action: action,
          field: field,
          current_value: currentValue
        });
      },

      computeAction(action, field, currentValue, actionValue) {
        // Generated action handlers
    #{generate_compute_action_cases(actions)}
        return currentValue;
      },

      syncToParent(field, value) {
        const parentField = this.bindings[field];
        if (!parentField) return;

        const parentRoot = document.getElementById("lavash-optimistic-root");
        if (!parentRoot || !parentRoot.__lavash_hook__) return;

        const parentHook = parentRoot.__lavash_hook__;
        parentHook.state[parentField] = value;
        if (parentHook.pending) {
          parentHook.pending[parentField] = value;
        }
        if (parentHook.clientVersion !== undefined) {
          parentHook.clientVersion++;
        }
        if (typeof parentHook.recomputeDerives === 'function') {
          parentHook.recomputeDerives([parentField]);
        }
        if (typeof parentHook.updateDOM === 'function') {
          parentHook.updateDOM();
        }
        if (typeof parentHook.syncUrl === 'function') {
          parentHook.syncUrl();
        }
      },

      updateDOM() {
        // Update elements with data-synced-text
        this.el.querySelectorAll("[data-synced-text]").forEach(el => {
          const field = el.dataset.syncedText;
          const value = this.state[field];
          if (value !== undefined) {
            el.textContent = String(value);
          }
        });

        // Update elements with data-synced-class
        this.el.querySelectorAll("[data-synced-class]").forEach(el => {
          const field = el.dataset.syncedClass;
          const value = this.state[field];
          if (value !== undefined) {
            el.className = String(value);
          }
        });

        // Update elements with data-synced-attr-*
        this.el.querySelectorAll("[data-synced-attr]").forEach(el => {
          const mapping = el.dataset.syncedAttr;
          const [attr, field] = mapping.split(":");
          const value = this.state[field];
          if (value !== undefined) {
            el.setAttribute(attr, String(value));
          }
        });
      },

      updated() {
        // Server sent a patch - use SyncedVar.serverSet for each field
        const serverState = JSON.parse(this.el.dataset.syncedState || "{}");

        for (const [field, serverValue] of Object.entries(serverState)) {
          if (this.fields[field]) {
            // SyncedVar decides whether to accept based on pending state
            this.fields[field].serverSet(serverValue);
          } else {
            // Non-synced field (calculation result) - just update
            this.state[field] = serverValue;
          }
        }

        this.runCalculations();
        this.updateDOM();
      },

      // Called by parent when a sibling updates shared state
      refreshFromParent(parentHook) {
        let changed = false;
        for (const [localField, parentField] of Object.entries(this.bindings)) {
          const parentValue = parentHook.state[parentField];
          if (parentValue !== undefined && this.fields[localField]) {
            if (parentValue !== this.fields[localField].value) {
              this.fields[localField].setOptimistic(parentValue);
              changed = true;
            }
          }
        }
        if (changed) {
          this.runCalculations();
          this.updateDOM();
        }
      },

      destroyed() {
        if (this.clickHandler) {
          this.el.removeEventListener("click", this.clickHandler, true);
        }
      }
    };
    """
  end

  defp generate_calculation_js(calculations) do
    CompilerHelpers.generate_calculation_js(calculations)
  end

  defp generate_run_calculations(calculations) do
    calculations
    |> Enum.map(fn {name, _source, _ast, _deps} ->
      "    this.state.#{name} = this.#{name}(this.state);"
    end)
    |> Enum.join("\n")
  end

  defp generate_action_js(_actions) do
    # Action handling is in computeAction
    ""
  end

  defp generate_compute_action_cases(actions) do
    actions
    |> Enum.map(fn %{name: name, field: field, run_source: run_source} ->
      # Convert Elixir fn to JS
      js_fn = fn_source_to_js(run_source)
      ~s|    if (action === "#{name}" && field === "#{field}") {\n      #{js_fn}\n    }|
    end)
    |> Enum.join("\n")
  end

  defp fn_source_to_js(source) do
    CompilerHelpers.fn_source_to_js_return(source)
  end

  defp generate_mount_update(synced_fields, props, calculations) do
    synced_names = Enum.map(synced_fields, & &1.name)
    prop_defaults = Enum.map(props, fn p -> {p.name, p.default} end)
    calc_names = Enum.map(calculations, fn {name, _, _, _} -> name end)

    quote do
      def mount(socket) do
        {:ok, Phoenix.Component.assign(socket, :__lavash_version__, 0)}
      end

      def update(assigns, socket) do
        # Resolve bindings
        binding_map =
          case Map.get(assigns, :bind) do
            nil -> %{}
            bindings when is_list(bindings) -> Map.new(bindings)
          end

        socket = Phoenix.Component.assign(socket, :__binding_map__, binding_map)

        # Apply prop defaults
        socket =
          Enum.reduce(unquote(Macro.escape(prop_defaults)), socket, fn {name, default}, sock ->
            value = Map.get(assigns, name, default)
            Phoenix.Component.assign(sock, name, value)
          end)

        # Apply synced field values from assigns
        socket =
          Enum.reduce(unquote(synced_names), socket, fn name, sock ->
            if Map.has_key?(assigns, name) do
              Phoenix.Component.assign(sock, name, Map.get(assigns, name))
            else
              sock
            end
          end)

        # Run server-side calculations
        socket = run_server_calculations(socket)

        # Build state JSON for client (synced fields + calculation results)
        state =
          unquote(synced_names)
          |> Enum.map(fn name -> {to_string(name), socket.assigns[name]} end)
          |> Map.new()

        # Add calculation results to state
        state =
          Enum.reduce(unquote(calc_names), state, fn name, acc ->
            Map.put(acc, to_string(name), socket.assigns[name])
          end)

        socket =
          socket
          |> Phoenix.Component.assign(:__hook_name__, __full_hook_name__())
          |> Phoenix.Component.assign(:__state_json__, Jason.encode!(state))
          |> Phoenix.Component.assign(:__bindings_json__, Jason.encode!(Map.new(binding_map, fn {k, v} -> {to_string(k), to_string(v)} end)))

        # Pass through other assigns
        socket =
          Enum.reduce(assigns, socket, fn
            {:bind, _}, sock -> sock
            {:__changed__, _}, sock -> sock
            {key, _}, sock when key in unquote(synced_names) -> sock
            {key, value}, sock -> Phoenix.Component.assign(sock, key, value)
          end)

        {:ok, socket}
      end
    end
  end

  defp generate_server_calculations(calculations) do
    calc_clauses =
      Enum.map(calculations, fn {name, _source, ast, _deps} ->
        # The ast is already transformed to use Map.get(state, :field)
        # We need to adapt it to use socket.assigns instead
        socket_ast = transform_state_to_assigns(ast)
        quote do
          socket = Phoenix.Component.assign(socket, unquote(name), unquote(socket_ast))
        end
      end)

    quote do
      defp run_server_calculations(socket) do
        state = socket.assigns
        unquote_splicing(calc_clauses)
        socket
      end
    end
  end

  # Transform Map.get(state, :field) to socket.assigns[:field]
  defp transform_state_to_assigns(ast) do
    Macro.prewalk(ast, fn
      {{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [{:state, _, nil}, field, nil]} ->
        quote do: socket.assigns[unquote(field)]
      other ->
        other
    end)
  end

  defp generate_handle_events(actions, _synced_fields) do
    action_clauses =
      Enum.map(actions, fn %{name: name, field: field, run_source: run_source} ->
        # Parse the run function source to AST
        run_fn_ast = CompilerHelpers.parse_fn_source(run_source)

        quote do
          def handle_event(
                "synced_action",
                %{"action" => unquote(to_string(name)), "field" => unquote(to_string(field)), "current_value" => _current_value},
                socket
              ) do
            # Get current value from socket (may differ from client's current_value due to race)
            current = socket.assigns[unquote(field)]

            # Apply the action
            run_fn = unquote(run_fn_ast)
            new_value = run_fn.(current, nil)

            # Update socket
            socket = Phoenix.Component.assign(socket, unquote(field), new_value)

            # Re-run calculations
            socket = run_server_calculations(socket)

            # Notify parent if bound
            case socket.assigns[:__binding_map__][unquote(field)] do
              nil -> :ok
              parent_field -> send(self(), {:lavash_component_delta, parent_field, new_value})
            end

            {:noreply, socket}
          end
        end
      end)

    quote do
      unquote_splicing(action_clauses)
    end
  end

  # Generate render function from template
  defp generate_render(template_source, full_hook_name, calculations, actions, synced_fields, _env) do
    # Transform template to inject data-synced-* attributes
    transformed_template =
      Lavash.LiveComponent.TemplateTransformer.transform(
        template_source,
        calculations,
        actions,
        synced_fields
      )

    # Wrapper template that adds the hook container
    wrapper_template = """
    <div
      id={@id}
      phx-hook={@__hook_name__}
      phx-target={@myself}
      data-synced-state={@__state_json__}
      data-synced-bindings={@__bindings_json__}
    >
      {@inner_content}
    </div>
    """

    quote do
      # Store template sources for __render_inner__ macro
      @__lavash_full_hook_name__ unquote(full_hook_name)
      @__lavash_template_source__ unquote(transformed_template)
      @__lavash_wrapper_template__ unquote(wrapper_template)

      @doc false
      defmacro __render_inner__(assigns_var) do
        template = Module.get_attribute(__MODULE__, :__lavash_template_source__)

        opts = [
          engine: Phoenix.LiveView.TagEngine,
          caller: __CALLER__,
          source: template,
          tag_handler: Phoenix.LiveView.HTMLEngine
        ]

        ast = EEx.compile_string(template, opts)

        quote do
          var!(assigns) = unquote(assigns_var)
          unquote(ast)
        end
      end

      @doc false
      defmacro __render_wrapper__(assigns_var) do
        template = Module.get_attribute(__MODULE__, :__lavash_wrapper_template__)

        opts = [
          engine: Phoenix.LiveView.TagEngine,
          caller: __CALLER__,
          source: template,
          tag_handler: Phoenix.LiveView.HTMLEngine
        ]

        ast = EEx.compile_string(template, opts)

        quote do
          var!(assigns) = unquote(assigns_var)
          unquote(ast)
        end
      end

      def render(var!(assigns)) do
        inner_content = __render_inner__(var!(assigns))
        var!(assigns) = Phoenix.Component.assign(var!(assigns), :inner_content, inner_content)
        __render_wrapper__(var!(assigns))
      end
    end
  end
end
