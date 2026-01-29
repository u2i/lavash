defmodule Lavash.ClientComponent.Compiler do
  @moduledoc """
  Compiler for ClientComponent DSL.

  Generates:
  - Client state function from bindings, props, and calculations
  - Server handle_event functions from optimistic_actions
  - JS hook code from template and optimistic_actions
  - Render function from template
  """

  use Spark.Dsl.Extension

  alias Lavash.Component.CompilerHelpers

  @doc false
  defmacro __before_compile__(env) do
    # Get DSL entities from Spark
    bindings = Spark.Dsl.Extension.get_entities(env.module, [:state_fields]) || []
    props = Spark.Dsl.Extension.get_entities(env.module, [:props]) || []
    templates = Spark.Dsl.Extension.get_entities(env.module, [:template]) || []

    # Check for render definitions from the new macro-based approach
    lavash_renders = Module.get_attribute(env.module, :__lavash_renders__) || []

    # Get calculations from Spark DSL entities and convert to tuple format
    # Each Calculate struct has :name and :rx (a Lavash.Rx struct with :source, :ast, :deps)
    spark_calculations = Spark.Dsl.Extension.get_entities(env.module, [:calculations]) || []

    calculations =
      Enum.map(spark_calculations, fn calc ->
        {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps}
      end)

    # Actions are stored as tuples: {name, field, key, run_source, validate_source, max}
    action_tuples = Module.get_attribute(env.module, :__lavash_optimistic_actions__) || []
    actions = Enum.map(action_tuples, fn {name, field, key, run_source, validate_source, max} ->
      %{name: name, field: field, key: key, run_source: run_source, validate_source: validate_source, max: max}
    end)

    # Determine template source: prefer new macro-based render, fall back to DSL template
    {template_source, deprecated_name} =
      case lavash_renders do
        [] ->
          # Fall back to legacy template DSL
          case templates do
            [%{source: source, deprecated_name: deprecated} | _] -> {source, deprecated}
            [%{source: source} | _] -> {source, nil}
            _ -> {nil, nil}
          end

        renders ->
          # New macro-based renders - find :__render_fn__ and extract source
          renders_map = Map.new(renders)
          case Map.get(renders_map, :__render_fn__) do
            nil ->
              {nil, nil}

            escaped_fn ->
              # The escaped function contains the ~L sigil expansion
              # For ClientComponents, ~L returns %Lavash.Template.Compiled{source: "..."}
              # We need to extract the source from the function body AST
              extract_source_from_render_fn(escaped_fn)
          end
      end

    # Emit deprecation warning if client_template was used
    if deprecated_name == :client_template do
      IO.warn(
        "client_template is deprecated, use template instead",
        Macro.Env.stacktrace(env)
      )
    end

    # Build metadata for template transformation
    # Note: We build it manually here since module isn't compiled yet
    optimistic_actions_map =
      action_tuples
      |> Enum.map(fn {name, field, _key, _run, _validate, _max} -> {name, %{field: field}} end)
      |> Map.new()

    # Transform template to inject data-lavash-* attributes
    template_source =
      if template_source do
        metadata = %{
          context: :client_component,
          optimistic_fields: %{},  # ClientComponent uses bindings, not state fields
          optimistic_derives: %{},
          calculations: Enum.map(calculations, fn {name, _, _, _} -> {name, %{optimistic: true}} end) |> Map.new(),
          forms: %{},
          actions: %{},
          optimistic_actions: optimistic_actions_map
        }

        Lavash.Template.Transformer.transform(template_source, env.module,
          context: :client_component,
          metadata: metadata
        )
      else
        nil
      end

    # Generate hook name from module
    module_name = env.module |> Module.split() |> List.last()
    hook_name = ".#{module_name}"
    full_hook_name = "#{inspect(env.module)}.#{module_name}"

    # Generate code
    client_state_fn = generate_client_state(bindings, props)
    calculation_fns = generate_calculations(calculations)
    handle_event_fns = generate_handle_events(actions, bindings)

    # Generate JS and write to colocated hooks directory
    js_code = if template_source do
      generate_js_hook(template_source, calculations, actions, env)
    end

    hook_data = if js_code do
      CompilerHelpers.write_colocated_hook(env, full_hook_name, js_code)
    end

    render_fn = if template_source do
      generate_render(template_source, full_hook_name, env)
    end

    # Pre-escape hook_data before entering quote
    escaped_hook_data = if hook_data, do: Macro.escape(hook_data), else: nil

    # Generate mount and update callbacks
    mount_update_fns = generate_mount_update(bindings)

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

      # Mount and update callbacks for binding resolution
      unquote(mount_update_fns)

      # Client state function
      unquote(client_state_fn)

      # Calculation functions
      unquote(calculation_fns)

      # Handle event functions (from optimistic_actions)
      unquote(handle_event_fns)

      # Render function
      unquote(render_fn)
    end
  end

  # Generate mount and update callbacks for binding resolution
  # Uses shared binding resolution code from CompilerHelpers
  defp generate_mount_update(_bindings) do
    binding_resolution = CompilerHelpers.generate_binding_resolution_code()

    quote do
      # Initialize binding map and version tracking
      def mount(socket) do
        socket =
          socket
          |> Phoenix.Component.assign(:__lavash_binding_map__, %{})
          |> Phoenix.Component.assign(:__lavash_version__, 0)

        {:ok, socket}
      end

      # Resolve bindings from the `bind` prop
      def update(assigns, socket) do
        socket = __resolve_bindings__(assigns, socket)
        {:ok, Phoenix.Component.assign(socket, Map.drop(assigns, [:bind, :__changed__]))}
      end

      # Inject shared binding resolution code
      unquote(binding_resolution)

      # Notify parent about bound field updates
      # Routes to parent Lavash.Component via send_update, or to LiveView via send
      defp __notify_parent_binding__(socket, action, parent_field, value) do
        case socket.assigns[:__lavash_parent_cid__] do
          nil ->
            # No parent CID - send to LiveView process
            send(self(), {action, parent_field, value})

          parent_cid ->
            # Parent is a Lavash.Component - use send_update with CID
            Phoenix.LiveView.send_update(parent_cid, __lavash_binding_update__: {action, parent_field, value})
        end
      end
    end
  end

  # Generate client_state/1 function
  defp generate_client_state(bindings, props) do
    binding_fields = Enum.map(bindings, fn %{name: name} ->
      {name, quote do: Map.get(assigns, unquote(name), nil)}
    end)

    # Only include props with client: true (default) in client state
    # Props with client: false are server-only (e.g., Phoenix.LiveView.JS callbacks)
    client_props = Enum.filter(props, fn prop ->
      Map.get(prop, :client, true) != false
    end)

    prop_fields = Enum.map(client_props, fn %{name: name, default: default} ->
      default_val = Macro.escape(default || nil)
      {name, quote do: Map.get(assigns, unquote(name), unquote(default_val))}
    end)

    all_fields = binding_fields ++ prop_fields

    quote do
      def client_state(assigns) do
        %{unquote_splicing(all_fields)}
      end
    end
  end

  # Generate calculation functions
  defp generate_calculations([]) do
    quote do
      defp __compute_calculations__(state), do: state
      def __calculations__, do: []
    end
  end

  defp generate_calculations(calculations) do
    # Calculations are tuples: {name, source_string, transformed_expr, deps}
    calc_clauses = Enum.map(calculations, fn {name, _source, transformed_expr, _deps} ->
      quote do
        defp __calc__(unquote(name), var!(state)) do
          _ = var!(state)
          unquote(transformed_expr)
        end
      end
    end)

    calc_names = Enum.map(calculations, fn {name, _, _, _} -> name end)

    compute_fn = quote do
      defp __compute_calculations__(state) do
        Enum.reduce(unquote(calc_names), state, fn name, acc ->
          value = __calc__(name, acc)
          Map.put(acc, name, value)
        end)
      end

      def __calculations__ do
        unquote(Macro.escape(calculations))
      end
    end

    {:__block__, [], calc_clauses ++ [compute_fn]}
  end

  # Generate handle_event functions from optimistic_actions
  defp generate_handle_events([], _bindings) do
    quote do
    end
  end

  defp generate_handle_events(actions, _bindings) do
    Enum.map(actions, fn %{name: action_name, field: field, key: key_field, run_source: run_source, validate_source: validate_source, max: max_field} ->
      event_name = "#{action_name}_#{field |> to_string() |> String.trim_trailing("s")}"

      # Handle shorthand run values
      run_fn_ast = case run_source do
        ":remove" -> quote do: fn _item, _value -> :remove end
        ":set" -> quote do: fn _current, value -> value end
        _ -> CompilerHelpers.parse_fn_source(run_source)
      end

      validate_fn_ast = CompilerHelpers.parse_fn_source(validate_source)

      # Build the condition AST based on which checks are needed
      condition_ast = build_condition_ast(validate_fn_ast, max_field)

      # Generate different code paths for key-based vs non-key-based actions
      if key_field do
        # Key-based action: find item by key, apply transformation
        quote do
          def handle_event(unquote(event_name), params, socket) do
            # For key-based actions, "val" is the key value to find the item
            # "arg" is the argument passed to the run function (optional)
            key_value = Map.get(params, "val")
            arg = Map.get(params, "arg", key_value)
            binding_map = socket.assigns[:__lavash_binding_map__] || %{}

            case Map.get(binding_map, unquote(field)) do
              nil ->
                # Not bound - update own assigns
                current = socket.assigns[unquote(field)] || []

                if unquote(condition_ast) do
                  run_fn = unquote(run_fn_ast)

                  # Find item by key and apply transformation
                  new_value = Enum.flat_map(current, fn item ->
                    if Map.get(item, unquote(key_field)) == key_value do
                      case run_fn.(item, arg) do
                        :remove -> []
                        updated -> [updated]
                      end
                    else
                      [item]
                    end
                  end)

                  # Bump version to signal state change to client
                  version = (socket.assigns[:__lavash_version__] || 0) + 1
                  socket = Phoenix.Component.assign(socket, :__lavash_version__, version)
                  {:noreply, Phoenix.Component.assign(socket, unquote(field), new_value)}
                else
                  {:noreply, socket}
                end

              parent_field ->
                # Bound to parent - route to parent component or LiveView
                __notify_parent_binding__(
                  socket,
                  unquote(:"lavash_component_#{action_name}"),
                  parent_field,
                  %{key: key_value, arg: arg}
                )
                {:noreply, socket}
            end
          end
        end
      else
        # Non-key-based action: original behavior
        quote do
          def handle_event(unquote(event_name), params, socket) do
            # Extract value from params (may be nil for toggle actions)
            value = Map.get(params, "val")
            binding_map = socket.assigns[:__lavash_binding_map__] || %{}

            case Map.get(binding_map, unquote(field)) do
              nil ->
                # Not bound - update own assigns
                current = socket.assigns[unquote(field)] || []

                if unquote(condition_ast) do
                  # Call the run function directly
                  run_fn = unquote(run_fn_ast)
                  new_value = run_fn.(current, value)
                  # Bump version to signal state change to client
                  version = (socket.assigns[:__lavash_version__] || 0) + 1
                  socket = Phoenix.Component.assign(socket, :__lavash_version__, version)
                  {:noreply, Phoenix.Component.assign(socket, unquote(field), new_value)}
                else
                  {:noreply, socket}
                end

              parent_field ->
                # Bound to parent - route to parent component or LiveView
                __notify_parent_binding__(socket, unquote(:"lavash_component_#{action_name}"), parent_field, value)
                {:noreply, socket}
            end
          end
        end
      end
    end)
  end

  # Build the validation condition based on what checks are needed
  defp build_condition_ast(nil, nil) do
    # No validation, no max - always proceed
    true
  end

  defp build_condition_ast(validate_fn_ast, nil) when not is_nil(validate_fn_ast) do
    # Only validation check - call the validate fn
    quote do
      validate_fn = unquote(validate_fn_ast)
      validate_fn.(current, value)
    end
  end

  defp build_condition_ast(nil, max_field) when not is_nil(max_field) do
    # Only max check
    quote do
      max_val = socket.assigns[unquote(max_field)]
      max_val == nil or length(current) < max_val
    end
  end

  defp build_condition_ast(validate_fn_ast, max_field) do
    # Both validation and max check
    quote do
      validate_fn = unquote(validate_fn_ast)
      valid? = validate_fn.(current, value)
      max_val = socket.assigns[unquote(max_field)]
      under_max? = max_val == nil or length(current) < max_val
      valid? and under_max?
    end
  end

  # Generate JS hook code
  defp generate_js_hook(template_source, calculations, actions, _env) do
    # Parse template and generate render function
    tree = template_source
    |> Lavash.Template.tokenize()
    |> Lavash.Template.parse()

    render_parts = tree_to_js_parts(tree, %{})
    render_body = "`" <> Enum.join(render_parts, "") <> "`"

    # Generate calculation JS
    # Calculations are tuples: {name, source_string, transformed_expr, deps}
    calc_js = generate_calculation_js(calculations)
    calc_names = Enum.map(calculations, fn {name, _, _, _} -> to_string(name) end)
    calc_names_json = Jason.encode!(calc_names)

    # Generate action JS
    action_js = generate_action_js(actions)

    # Combine into hook
    ~s"""
    // Generated JS hook with client-side rendering
    function humanize(value) {
      return String(value).replace(/_/g, ' ').replace(/^\\w/, c => c.toUpperCase());
    }

    export default {
      mounted() {
        console.log('[ClientComponent] mounted', this.el.id, this.el.dataset.lavashState);
        this.state = JSON.parse(this.el.dataset.lavashState || "{}");
        this.calculations = #{calc_names_json};
        this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");
        console.log('[ClientComponent] bindings:', this.bindings);
        this.pendingCount = 0;
        this.clickHandler = this.handleClick.bind(this);
        this.keydownHandler = this.handleKeydown.bind(this);
        this.inputHandler = this.handleInput.bind(this);
        this.el.addEventListener("click", this.clickHandler, true);
        this.el.addEventListener("keydown", this.keydownHandler, true);
        this.el.addEventListener("input", this.inputHandler, true);
        this.el.__lavash_hook__ = this;
        // Re-render with JS template to ensure data-lavash-* attributes are present
        // Server template may not have all attributes injected
        this.runCalculations();
        this.updateDOM();
        console.log('[ClientComponent] mounted complete, state:', this.state);
      },

      updated() {
        if (this.pendingCount === 0) {
          this.state = JSON.parse(this.el.dataset.lavashState || "{}");
          this.runCalculations();
        }
      },

    #{calc_js}

      runCalculations() {
        for (const name of this.calculations) {
          if (typeof this[name] === 'function') {
            this.state[name] = this[name](this.state);
          }
        }
      },

      render(state) {
        return #{render_body};
      },

      updateDOM() {
        const newHtml = this.render(this.state);
        const temp = document.createElement('div');
        temp.innerHTML = newHtml;
        if (temp.firstElementChild && window.morphdom) {
          const currentChild = this.el.firstElementChild;
          const newChild = temp.firstElementChild;
          if (currentChild && newChild) {
            window.morphdom(currentChild, newChild, {
              onBeforeElUpdated(fromEl, toEl) {
                if (fromEl.hasAttribute('data-lavash-preserve')) {
                  return false;
                }
                return true;
              }
            });
          } else {
            this.el.innerHTML = newHtml;
          }
        } else {
          this.el.innerHTML = newHtml;
        }
      },

      handleInput(e) {
        // Stop input events from propagating to parent hooks
        // This prevents parent LiveView from overwriting state.tags with string input value
        const target = e.target.closest("[data-lavash-state-field]");
        if (target) {
          e.stopPropagation();
        }
      },

      handleKeydown(e) {
        if (e.key !== "Enter") return;
        const input = e.target;
        const action = input.dataset.lavashAction;
        const field = input.dataset.lavashStateField;
        if (action !== "add" || !field) return;

        e.preventDefault();
        e.stopPropagation();
        const value = input.value.trim();
        if (!value) return;

        if (!this.validateAction(action, field, value)) return;

        this.pendingCount++;
        this.applyOptimisticAction(action, field, value);
        this.runCalculations();
        this.updateDOM();
        this.syncParentUrl();

        const newInput = this.el.querySelector(`[data-lavash-action="add"][data-lavash-state-field="${field}"]`);
        if (newInput) newInput.value = "";

        const phxEvent = `${action}_${field.replace(/s$/, '')}`;
        this.pushEventTo(this.el, phxEvent, { val: value }, () => {
          this.pendingCount--;
        });
      },

      handleClick(e) {
        console.log('[ClientComponent] handleClick', e.target);
        const target = e.target.closest("[data-lavash-action]");
        if (!target) {
          console.log('[ClientComponent] no data-lavash-action found');
          return;
        }

        const action = target.dataset.lavashAction;
        const field = target.dataset.lavashStateField;
        const value = target.dataset.lavashValue;
        console.log('[ClientComponent] action:', action, 'field:', field, 'value:', value);

        if (action === "add" && !value) return;

        e.stopPropagation();

        if (!this.validateAction(action, field, value)) {
          console.log('[ClientComponent] validation failed');
          return;
        }

        console.log('[ClientComponent] applying optimistic action');
        this.pendingCount++;
        this.applyOptimisticAction(action, field, value);
        this.runCalculations();
        this.updateDOM();

        // Check if this field is bound to a parent
        const parentField = this.bindings[field];
        if (parentField) {
          // Dispatch a lavash-set event that bubbles up to parent components
          // The parent's LavashOptimistic hook will handle it and sync to server
          // Use the NEW value from state (after applyOptimisticAction), not the click value
          const newValue = this.state[field];
          console.log('[ClientComponent] dispatching lavash-set for bound field', field, '->', parentField, '=', newValue);
          this.el.dispatchEvent(new CustomEvent('lavash-set', {
            bubbles: true,
            detail: { field: parentField, value: newValue }
          }));
          this.pendingCount--;
          return;
        }

        // Not bound - sync to LiveView root and push event
        this.syncParentUrl();

        const phxEvent = target.dataset.phxClick || `${action}_${field.replace(/s$/, '')}`;
        this.pushEventTo(this.el, phxEvent, { val: value }, () => {
          this.pendingCount--;
        });
      },

    #{action_js}

      syncParentUrl() {
        if (Object.keys(this.bindings).length === 0) return;
        const parentRoot = document.getElementById("lavash-optimistic-root");
        if (!parentRoot || !parentRoot.__lavash_hook__) return;
        const parentHook = parentRoot.__lavash_hook__;
        const changedFields = [];
        for (const [localField, parentField] of Object.entries(this.bindings)) {
          const value = this.state[localField];
          if (value !== undefined) {
            parentHook.state[parentField] = value;
            // Mark as pending so parent rejects stale server patches for this field
            // Use SyncedVarStore if available (new architecture), fallback to pending map
            if (parentHook.store) {
              const syncedVar = parentHook.store.get(parentField, value);
              syncedVar.setOptimistic(value);
            } else if (parentHook.pending) {
              parentHook.pending[parentField] = value;
            }
            changedFields.push(parentField);
          }
        }
        // Bump parent's client version so stale server patches are rejected
        if (changedFields.length > 0 && parentHook.clientVersion !== undefined) {
          parentHook.clientVersion++;
        }
        // Recompute parent's derives that depend on the changed fields
        if (changedFields.length > 0 && typeof parentHook.recomputeDerives === 'function') {
          parentHook.recomputeDerives(changedFields);
        }
        // Update parent's DOM to reflect new derived values
        if (typeof parentHook.updateDOM === 'function') {
          parentHook.updateDOM();
        }
        if (typeof parentHook.syncUrl === 'function') {
          parentHook.syncUrl();
        }
      },

      // Called by parent when another sibling updates shared state
      refreshFromParent(parentHook) {
        let changed = false;
        for (const [localField, parentField] of Object.entries(this.bindings)) {
          const parentValue = parentHook.state[parentField];
          if (parentValue !== undefined && parentValue !== this.state[localField]) {
            this.state[localField] = parentValue;
            changed = true;
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
        if (this.keydownHandler) {
          this.el.removeEventListener("keydown", this.keydownHandler, true);
        }
        if (this.inputHandler) {
          this.el.removeEventListener("input", this.inputHandler, true);
        }
      }
    };
    """
  end

  # Generate JS for calculations
  # Calculations are tuples: {name, source_string, transformed_expr, deps}
  defp generate_calculation_js(calculations) do
    CompilerHelpers.generate_calculation_js(calculations)
  end

  # Generate JS for optimistic actions
  defp generate_action_js(actions) do
    action_cases = Enum.map(actions, fn %{name: action_name, field: field, key: key_field, run_source: run_source} ->
      if key_field do
        # Key-based action: find item by key, apply transformation
        run_js = generate_keyed_action_js(run_source, key_field)
        ~s|    if (action === "#{action_name}" && field === "#{field}") {\n#{run_js}\n    }|
      else
        # Non-key-based action: handle shorthands or compile function
        run_js = case run_source do
          ":set" ->
            # :set shorthand - parse value and assign directly
            ~s|this.state.#{field} = value === "true" ? true : value === "false" ? false : value;|
          _ ->
            CompilerHelpers.fn_source_to_js_assignment(run_source, field)
        end
        ~s|    if (action === "#{action_name}" && field === "#{field}") {\n      #{run_js}\n    }|
      end
    end)
    |> Enum.join("\n")

    validate_cases = Enum.map(actions, fn %{name: action_name, field: field, validate_source: validate_source, max: max_field} ->
      conditions = []

      conditions = if validate_source do
        validate_js = CompilerHelpers.fn_source_to_js_bool(validate_source)
        [~s|!(#{validate_js})| | conditions]
      else
        conditions
      end

      conditions = if max_field do
        [~s|(this.state.#{max_field} && current.length >= this.state.#{max_field})| | conditions]
      else
        conditions
      end

      if conditions == [] do
        ""
      else
        condition = Enum.join(conditions, " || ")
        ~s|    if (action === "#{action_name}" && field === "#{field}") {\n      if (#{condition}) return false;\n    }|
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")

    ~s"""
      validateAction(action, field, value, arg) {
        const current = this.state[field];
    #{validate_cases}
        return true;
      },

      applyOptimisticAction(action, field, value, arg) {
        const current = this.state[field];
    #{action_cases}
      },
    """
  end

  # Generate JS for key-based array mutations
  defp generate_keyed_action_js(run_source, key_field) do
    key_str = to_string(key_field)

    if run_source == ":remove" do
      # Shorthand for removal - filter out the item
      ~s|      if (!current) return;
      this.state[field] = current.filter(item => item.#{key_str} !== value);|
    else
      # Transform function - map over items and update matching one
      # Parse the Elixir function and convert to JS
      item_transform_js = CompilerHelpers.fn_source_to_js_item_transform(run_source)
      ~s|      if (!current) return;
      this.state[field] = current.map(item => {
        if (item.#{key_str} === value) {
          const result = #{item_transform_js};
          return result === 'remove' ? null : result;
        }
        return item;
      }).filter(item => item !== null);|
    end
  end

  # Generate render function
  defp generate_render(template_source, full_hook_name, _env) do
    # The wrapper template - compiled at target module's compile time via macro
    wrapper_template = """
    <div
      id={@id}
      phx-hook={@__hook_name__}
      phx-target={@myself}
      data-lavash-state={@__state_json__}
      data-lavash-version={@__version__}
      data-lavash-bindings={@__bindings_json__}
    >
      {@inner_content}
    </div>
    """

    quote do
      # Store template source for __render_inner__ macro
      @__lavash_full_hook_name__ unquote(full_hook_name)
      @__lavash_template_source__ unquote(template_source)
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
        state = client_state(var!(assigns))
        state = __compute_calculations__(state)
        state_json = Jason.encode!(state)

        version = Map.get(var!(assigns), :__lavash_version__, 0)
        # Use client bindings (resolved/flattened) for JS if available, fall back to regular binding map
        client_bindings = Map.get(var!(assigns), :__lavash_client_bindings__)
        binding_map = client_bindings || Map.get(var!(assigns), :__lavash_binding_map__, %{})
        bindings_json = Jason.encode!(binding_map)

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:client_state, state)
          |> Phoenix.Component.assign(:__state_json__, state_json)
          |> Phoenix.Component.assign(:__bindings_json__, bindings_json)
          |> Phoenix.Component.assign(:__hook_name__, @__lavash_full_hook_name__)
          |> Phoenix.Component.assign(:__version__, version)
          |> Phoenix.Component.assign(state)

        inner_content = __render_inner__(var!(assigns))
        var!(assigns) = Phoenix.Component.assign(var!(assigns), :inner_content, inner_content)

        __render_wrapper__(var!(assigns))
      end
    end
  end

  # Delegate to Lavash.Template for tree_to_js_parts
  defp tree_to_js_parts(nodes, ctx) when is_list(nodes) do
    Enum.flat_map(nodes, &node_to_js_parts(&1, ctx))
  end

  defp node_to_js_parts({:text, content}, _ctx) do
    escaped = content
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("${", "\\${")
    [escaped]
  end

  defp node_to_js_parts({:expr, code, _meta}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    ["${#{js_expr}}"]
  end

  defp node_to_js_parts({:element, tag, attrs, children, meta}, ctx) do
    case find_special_attr(attrs, :for) do
      {:for, for_expr} ->
        {var, collection_js} = parse_for_to_js(for_expr)
        attrs_without_for = reject_special_attr(attrs, :for)
        new_ctx = Map.put(ctx, :loop_var, var)
        inner = render_element_wrapped(tag, attrs_without_for, children, meta, new_ctx)
        ["${#{collection_js}.map(#{var} => #{inner}).join('')}"]

      nil ->
        case find_special_attr(attrs, :if) do
          {:if, if_expr} ->
            condition_js = Lavash.Rx.Transpiler.to_js(if_expr)
            attrs_without_if = reject_special_attr(attrs, :if)
            inner = render_element_wrapped(tag, attrs_without_if, children, meta, ctx)
            ["${#{condition_js} ? #{inner} : ''}"]

          nil ->
            render_element_parts(tag, attrs, children, meta, ctx)
        end
    end
  end

  defp node_to_js_parts({:special_attr, _, _, _, _}, _ctx), do: []

  # HTML void elements that cannot have children and must not have closing tags
  @void_elements ~w(area base br col embed hr img input link meta source track wbr)

  defp render_element_parts(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        ["<#{tag}#{attrs_js}>"]
      else
        ["<#{tag}#{attrs_js}></#{tag}>"]
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      ["<#{tag}#{attrs_js}>"] ++ children_parts ++ ["</#{tag}>"]
    end
  end

  defp render_element_wrapped(tag, attrs, children, _meta, ctx) do
    attrs_js = render_attrs_to_js(attrs, ctx)

    if children == [] do
      if tag in @void_elements do
        "`<#{tag}#{attrs_js}>`"
      else
        "`<#{tag}#{attrs_js}></#{tag}>`"
      end
    else
      children_parts = tree_to_js_parts(children, ctx)
      children_js = Enum.join(children_parts, "")
      "`<#{tag}#{attrs_js}>#{children_js}</#{tag}>`"
    end
  end

  defp render_attrs_to_js(attrs, ctx) do
    attrs
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, ":") end)
    |> Enum.map(fn {name, value} -> render_attr_to_js(name, value, ctx) end)
    |> Enum.join("")
  end

  defp render_attr_to_js(name, {:string, value}, _ctx) do
    escaped = value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    " #{name}=\"#{escaped}\""
  end

  defp render_attr_to_js(name, {:expr, code, _}, _ctx) do
    js_expr = Lavash.Rx.Transpiler.to_js(code)
    " #{name}=\"${#{js_expr}}\""
  end

  defp render_attr_to_js(name, {:boolean, true}, _ctx), do: " #{name}"
  defp render_attr_to_js(_name, {:boolean, false}, _ctx), do: ""
  defp render_attr_to_js(_name, _value, _ctx), do: ""

  defp find_special_attr(attrs, type) do
    key = ":#{type}"
    case Enum.find(attrs, fn {name, _} -> name == key end) do
      {^key, {:expr, code, _}} -> {type, code}
      _ -> nil
    end
  end

  defp reject_special_attr(attrs, type) do
    key = ":#{type}"
    Enum.reject(attrs, fn {name, _} -> name == key end)
  end

  defp parse_for_to_js(code) do
    case Code.string_to_quoted(code) do
      {:ok, {:<-, _, [{var, _, _}, collection]}} when is_atom(var) ->
        {to_string(var), Lavash.Rx.Transpiler.to_js(Macro.to_string(collection))}
      _ ->
        {"item", "[]"}
    end
  end

  # Extract template source from render function AST
  # The function looks like: fn assigns -> %Lavash.Template.Compiled{source: "...", ...} end
  defp extract_source_from_render_fn(escaped_fn) do
    case escaped_fn do
      # Match the function structure: fn assigns -> body end
      {:fn, _, [{:->, _, [[{:assigns, _, _}], body]}]} ->
        extract_compiled_source(body)

      # Also handle the case where assigns might have a different context
      {:fn, _, [{:->, _, [[_assigns_var], body]}]} ->
        extract_compiled_source(body)

      _ ->
        {nil, nil}
    end
  end

  # Extract source from the Compiled struct construction in the function body
  defp extract_compiled_source(body) do
    case body do
      # Match the ~L sigil call directly (before macro expansion)
      # The sigil AST is: {:sigil_L, meta, [{:<<>>, _, [template_string]}, modifiers]}
      {:sigil_L, _, [{:<<>>, _, [template_string]}, _modifiers]} when is_binary(template_string) ->
        {template_string, nil}

      # Match: %Lavash.Template.Compiled{source: "...", ...}
      {:%, _, [{:__aliases__, _, [:Lavash, :Template, :Compiled]}, {:%{}, _, fields}]} ->
        case Keyword.get(fields, :source) do
          source when is_binary(source) -> {source, nil}
          _ -> {nil, nil}
        end

      # Match: {:__block__, _, [contents]} - unwrap block and recurse
      {:__block__, _, [inner]} ->
        extract_compiled_source(inner)

      # Match the quote block that sigil_L returns for client components
      # This is the AST of: quote do %Lavash.Template.Compiled{...} end
      {:quote, _, [[do: struct_ast]]} ->
        extract_compiled_source(struct_ast)

      # If it's not a Compiled struct, render fn syntax not compatible with ClientComponent yet
      _ ->
        {nil, nil}
    end
  end
end
