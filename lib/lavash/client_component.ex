defmodule Lavash.ClientComponent do
  @moduledoc """
  A component that renders on both server and client with optimistic updates.

  ClientComponents automatically generate JS hook code from a template at compile time
  and write it to Phoenix's colocated hooks directory.

  ## How It Works

  1. Server renders the full content (buttons, etc.) via HEEx
  2. JS hook intercepts clicks and applies optimistic class updates directly to DOM
  3. When server responds, hook compares versions:
     - If server is caught up: accept LiveView's DOM patch
     - If client is ahead: re-apply optimistic state after patch

  ## Usage

      defmodule MyApp.ChipSet do
        use Lavash.ClientComponent

        bind :selected, {:array, :string}
        prop :values, {:list, :string}, required: true

        # Define the template - generates both HEEx and JS at compile time
        client_template \"""
        <div class="flex flex-wrap gap-2">
          <button
            :for={value <- @values}
            type="button"
            class={if value in @selected, do: @active_class, else: @inactive_class}
            phx-click="toggle"
            phx-value-val={value}
          >
            {humanize(value)}
          </button>
        </div>
        \"""

        def client_state(assigns) do
          %{
            selected: assigns[:selected] || [],
            values: assigns.values,
            active_class: "btn-active",
            inactive_class: "btn-inactive"
          }
        end
      end

  The `client_template` macro generates JS and writes it directly to the
  colocated hooks directory. No need to manually write the script tag!
  """

  use Phoenix.Component

  @doc """
  Converts a value to a human-readable string.
  Replaces underscores with spaces and capitalizes the first letter.
  """
  def humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.capitalize()
  end

  def humanize(value) when is_atom(value), do: humanize(Atom.to_string(value))
  def humanize(value), do: to_string(value)

  defmacro __using__(opts) do
    hook_name = Keyword.get(opts, :hook) || Keyword.get(opts, :hook_name)

    quote do
      use Lavash.LiveComponent
      import Lavash.ClientComponent, only: [client_template: 1, client_container: 1, calculate: 2]
      import Phoenix.Component

      @before_compile Lavash.ClientComponent

      Module.register_attribute(__MODULE__, :client_template_source, accumulate: false)
      Module.register_attribute(__MODULE__, :client_hook_name, accumulate: false)
      Module.register_attribute(__MODULE__, :__lavash_colocated_data__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_calculations__, accumulate: true)
      @client_hook_name unquote(hook_name)

      # Define humanize locally so it's available in templates
      defp humanize(value) when is_binary(value) do
        value
        |> String.replace("_", " ")
        |> String.replace("-", " ")
        |> String.capitalize()
      end

      defp humanize(value) when is_atom(value), do: humanize(Atom.to_string(value))
      defp humanize(value), do: to_string(value)
    end
  end

  @doc """
  Defines the component template that will be compiled to client JS.

  The template is parsed at compile time, JS is generated, and written
  directly to Phoenix's colocated hooks directory.
  """
  defmacro client_template(source) do
    quote do
      @client_template_source unquote(source)
    end
  end

  @doc """
  Defines a calculated field that runs on both server and client.

  The expression is compiled to both Elixir (for server rendering) and JavaScript
  (for optimistic client-side updates). The expression can reference:
  - `@field` - state fields (e.g., `@selected`, `@values`)
  - Common functions: `length/1`, `Enum.count/1`, `Enum.join/2`, `Map.get/2,3`

  ## Example

      # Count of selected items
      calculate :selected_count, length(@selected)

      # Formatted display string
      calculate :selection_text, Enum.join(@selected, ", ")

      # Conditional text
      calculate :status, if(length(@selected) > 0, do: "Selected", else: "None")

  The calculated value is automatically:
  1. Computed server-side and included in assigns
  2. Recomputed client-side after optimistic state changes
  3. Updated in the DOM via `data-optimistic-display` attributes

  ## Usage in template

      <span data-optimistic-display="selected_count">{@selected_count}</span>
  """
  defmacro calculate(name, expr) do
    # Convert the AST to source string before quote (for JS generation)
    # This preserves the original expression like `length(@selected)`
    expr_source = Macro.to_string(expr)

    # Transform @var references in the AST to Map.get(state, :var) for runtime evaluation
    transformed_expr = transform_at_refs(expr)

    quote do
      @__lavash_calculations__ {unquote(name), unquote(expr_source), unquote(Macro.escape(transformed_expr))}
    end
  end

  # Transform @var references to Map.get(state, :var) for runtime evaluation
  defp transform_at_refs({:@, _, [{var_name, _, _}]}) when is_atom(var_name) do
    quote do: Map.get(state, unquote(var_name), nil)
  end

  defp transform_at_refs({form, meta, args}) when is_list(args) do
    {form, meta, Enum.map(args, &transform_at_refs/1)}
  end

  defp transform_at_refs({left, right}) do
    {transform_at_refs(left), transform_at_refs(right)}
  end

  defp transform_at_refs(list) when is_list(list) do
    Enum.map(list, &transform_at_refs/1)
  end

  defp transform_at_refs(other), do: other

  @doc """
  Renders a client component container.
  """
  attr :id, :string, required: true
  attr :hook, :string, required: true
  attr :myself, :any, required: true
  attr :state, :map, required: true
  attr :version, :integer, default: 0
  slot :inner_block, required: true

  def client_container(assigns) do
    state_json = Jason.encode!(assigns.state)
    assigns = assign(assigns, :state_json, state_json)

    ~H"""
    <div
      id={@id}
      phx-hook={@hook}
      phx-target={@myself}
      data-lavash-state={@state_json}
      data-lavash-version={@version}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defmacro __before_compile__(env) do
    template_source = Module.get_attribute(env.module, :client_template_source)
    custom_hook_name = Module.get_attribute(env.module, :client_hook_name)
    calculations = Module.get_attribute(env.module, :__lavash_calculations__) || []

    # Generate hook name from module
    module_name =
      env.module
      |> Module.split()
      |> List.last()

    hook_name = custom_hook_name || ".#{module_name}"
    hook_name_clean = String.trim_leading(hook_name, ".")

    # Full hook name as registered (without Elixir. prefix)
    full_hook_name = "#{inspect(env.module)}.#{hook_name_clean}"

    if template_source do
      # Parse template and generate JS at compile time
      # Pass calculations so we can generate JS for them
      {_heex, js_render_body} = Lavash.Template.compile_template_with_calculations(template_source, calculations)

      # Write the JS directly to the colocated hooks directory
      {_filename, hook_data} = write_colocated_hook(env, hook_name, full_hook_name, js_render_body)

      # Generate the calculation function definitions
      calc_fns = generate_calculation_functions(calculations)

      quote do
        def __hook_name__, do: unquote(hook_name)
        def __full_hook_name__, do: unquote(full_hook_name)
        def __generated_js__, do: unquote(js_render_body)
        def __calculations__, do: unquote(Macro.escape(calculations))

        # Store hook name and template source as module attributes
        @__lavash_full_hook_name__ unquote(full_hook_name)
        @__lavash_template_source__ unquote(template_source)

        # Define __phoenix_macro_components__ so Phoenix's colocated compiler picks up our hooks
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedHook => [unquote(Macro.escape(hook_data))]
          }
        end

        # Generate calculation functions
        unquote(calc_fns)

        # Generate render using defmacro so template compiles in this module's context
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

        def render(var!(assigns)) do
          state = client_state(var!(assigns))

          # Compute calculations and add to state
          state = __compute_calculations__(state)

          state_json = Jason.encode!(state)

          # Get version from assigns (set in mount/update)
          version = Map.get(var!(assigns), :__lavash_version__, 0)

          var!(assigns) =
            var!(assigns)
            |> Phoenix.Component.assign(:client_state, state)
            |> Phoenix.Component.assign(:__state_json__, state_json)
            |> Phoenix.Component.assign(:__hook_name__, @__lavash_full_hook_name__)
            |> Phoenix.Component.assign(:__version__, version)
            # Merge state into assigns so template expressions work
            |> Phoenix.Component.assign(state)

          # Render the inner content
          inner_content = __render_inner__(var!(assigns))

          # Wrap in hook container
          var!(assigns) = Phoenix.Component.assign(var!(assigns), :inner_content, inner_content)

          ~H"""
          <div
            id={@id}
            phx-hook={@__hook_name__}
            phx-target={@myself}
            data-lavash-state={@__state_json__}
            data-lavash-version={@__version__}
          >
            {@inner_content}
          </div>
          """
        end
      end
    else
      quote do
        def __hook_name__, do: unquote(hook_name)
        def __full_hook_name__, do: unquote(full_hook_name)
        def __generated_js__, do: nil
        def __calculations__, do: []
      end
    end
  end

  # Generate Elixir functions for each calculation
  defp generate_calculation_functions([]) do
    # No calculations - just return state unchanged
    quote do
      defp __compute_calculations__(state), do: state
    end
  end

  defp generate_calculation_functions(calculations) do
    calc_clauses =
      Enum.map(calculations, fn {name, _source, expr} ->
        quote do
          defp __calc__(unquote(name), state) do
            # The expression already has Map.get(state, :field) calls from transform_at_refs
            _ = state
            unquote(expr)
          end
        end
      end)

    # Generate the main compute function that runs all calculations
    calc_names = Enum.map(calculations, fn {name, _, _} -> name end)

    compute_fn =
      quote do
        defp __compute_calculations__(state) do
          Enum.reduce(unquote(calc_names), state, fn name, acc ->
            value = __calc__(name, acc)
            Map.put(acc, name, value)
          end)
        end
      end

    # Combine all the generated code
    {:__block__, [], calc_clauses ++ [compute_fn]}
  end

  # Write JS directly to Phoenix's colocated hooks directory
  # Returns {filename, hook_data} for manifest generation
  defp write_colocated_hook(env, _hook_name, full_hook_name, js_code) do
    # Get the target directory from Phoenix config
    target_dir = get_target_dir()
    module_dir = Path.join(target_dir, inspect(env.module))

    # Generate filename with hash for cache busting
    hash = :crypto.hash(:md5, js_code) |> Base.encode32(case: :lower, padding: false)
    filename = "#{env.line}_#{hash}.js"
    full_path = Path.join(module_dir, filename)

    # Ensure directory exists
    File.mkdir_p!(module_dir)

    # Only write if content changed (avoids unnecessary esbuild rebuilds)
    needs_write = case File.read(full_path) do
      {:ok, existing} -> existing != js_code
      {:error, _} -> true
    end

    if needs_write do
      # Clean up old files in this module's directory to avoid stale files
      case File.ls(module_dir) do
        {:ok, files} ->
          for file <- files, file != filename, String.ends_with?(file, ".js") do
            File.rm(Path.join(module_dir, file))
          end
        _ -> :ok
      end

      # Write the new JS file
      File.write!(full_path, js_code)
    end

    # Return the hook data in the format Phoenix expects
    # key must be a string "hooks" not atom :hooks
    hook_data = {filename, %{name: full_hook_name, key: "hooks"}}
    {filename, hook_data}
  end

  defp get_target_dir do
    # Match Phoenix's logic for target directory
    default = Path.join(Mix.Project.build_path(), "phoenix-colocated")
    app = to_string(Mix.Project.config()[:app])

    Application.get_env(:phoenix_live_view, :colocated_js, [])
    |> Keyword.get(:target_directory, default)
    |> Path.join(app)
  end
end
