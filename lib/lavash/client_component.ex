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
      import Lavash.ClientComponent, only: [client_template: 1, client_container: 1]
      import Phoenix.Component

      @before_compile Lavash.ClientComponent

      Module.register_attribute(__MODULE__, :client_template_source, accumulate: false)
      Module.register_attribute(__MODULE__, :client_hook_name, accumulate: false)
      Module.register_attribute(__MODULE__, :__lavash_colocated_data__, accumulate: true)
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
      {_heex, js_render_body} = Lavash.Template.compile_template(template_source)

      # Write the JS directly to the colocated hooks directory
      {_filename, hook_data} = write_colocated_hook(env, hook_name, full_hook_name, js_render_body)

      quote do
        def __hook_name__, do: unquote(hook_name)
        def __full_hook_name__, do: unquote(full_hook_name)
        def __generated_js__, do: unquote(js_render_body)

        # Store hook name and template source as module attributes
        @__lavash_full_hook_name__ unquote(full_hook_name)
        @__lavash_template_source__ unquote(template_source)

        # Define __phoenix_macro_components__ so Phoenix's colocated compiler picks up our hooks
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedHook => [unquote(Macro.escape(hook_data))]
          }
        end

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
          state_json = Jason.encode!(state)

          var!(assigns) =
            var!(assigns)
            |> Phoenix.Component.assign(:client_state, state)
            |> Phoenix.Component.assign(:__state_json__, state_json)
            |> Phoenix.Component.assign(:__hook_name__, @__lavash_full_hook_name__)
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
            data-lavash-version={0}
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
      end
    end
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

    # Ensure directory exists
    File.mkdir_p!(module_dir)

    # Write the JS file
    File.write!(Path.join(module_dir, filename), js_code)

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
