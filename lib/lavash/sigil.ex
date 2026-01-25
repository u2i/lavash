defmodule Lavash.Sigil do
  @moduledoc """
  Unified `~L` sigil for Lavash-enhanced HEEx templates.

  The `~L` sigil works like `~H` but automatically:
  - Injects `data-lavash-*` attributes based on DSL declarations
  - Injects `__lavash_client_bindings__` for nested component binding propagation
  - Works with both legacy `render fn assigns -> ~L\"\"\"...\"\"\" end` and new `render :default do ~L\"\"\"...\"\"\" end` syntax

  ## Context Auto-Detection

  The sigil automatically detects whether it's being used in a LiveView,
  Component, or ClientComponent based on the `@__lavash_module_type__` attribute:

  - `:live_view` - Standard data-lavash-* injection
  - `:component` - Also injects binding propagation for nested components
  - `:client_component` - Source is preserved for JS generation

  ## Usage

      defmodule MyApp.CounterLive do
        use Lavash.LiveView

        state :count, :integer, default: 0, optimistic: true

        render :default do
          ~L\"\"\"
          <div>
            <span>{@count}</span>
            <button phx-click="increment">+</button>
          </div>
          \"\"\"
        end
      end

  ## Opting Out

  To skip auto-injection for a specific element, add `data-lavash-manual`:

      <button phx-click="increment" data-lavash-manual>+</button>
  """

  @doc """
  Handles the `~L` sigil for Lavash-enhanced HEEx templates.

  Returns compiled HEEx content directly (a `%Phoenix.LiveView.Rendered{}` struct).
  The template source is preserved via AST extraction in `RenderMacro.extract_template`
  for use with the `render :name do ~L\"\"\"...\"\"\" end` syntax.
  """
  defmacro sigil_L({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    caller = __CALLER__
    module = caller.module

    # Detect context from module type attribute
    context = detect_context(module)

    # Build metadata for token transformation
    metadata = build_metadata(module, context)

    # Compile with Lavash.TagEngine and token transformer
    compiled = compile_template(template, caller, metadata)

    # Return compiled content directly (not wrapped in struct)
    # The RenderMacro.extract_template function extracts source from AST directly
    compiled
  end

  @doc false
  def detect_context(module) do
    try do
      case Module.get_attribute(module, :__lavash_module_type__) do
        :live_view -> :live_view
        :component -> :component
        :client_component -> :client_component
        nil -> :live_view  # Default fallback
      end
    rescue
      _ -> :live_view
    end
  end

  @doc false
  def build_metadata(module, context) do
    try do
      if Code.ensure_loaded?(module) and function_exported?(module, :__lavash__, 1) do
        Lavash.Template.TokenTransformer.build_metadata(module, context: context)
      else
        get_compile_time_metadata(module, context)
      end
    rescue
      _ -> %{context: context}
    end
  end

  defp compile_template(template, caller, metadata) do
    opts = [
      engine: Lavash.TagEngine,
      file: caller.file,
      line: caller.line + 1,
      caller: caller,
      source: template,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      token_transformer: Lavash.Template.TokenTransformer,
      lavash_metadata: metadata
    ]

    EEx.compile_string(template, opts)
  end

  @doc false
  # Build metadata from module attributes during compilation
  def get_compile_time_metadata(module, context) do
    try do
      # Try to get states from Spark DSL
      states = Spark.Dsl.Extension.get_entities(module, [:states]) || []
      forms = Spark.Dsl.Extension.get_entities(module, [:forms]) || []

      optimistic_fields =
        states
        |> Enum.filter(fn
          %Lavash.State.Field{optimistic: true} -> true
          %Lavash.State.MultiSelect{} -> true
          %Lavash.State.Toggle{} -> true
          _ -> false
        end)
        |> Enum.map(fn
          %Lavash.State.Field{name: name} = field -> {name, field}
          %Lavash.State.MultiSelect{name: name} = ms -> {name, %{name: name, type: {:array, :string}, optimistic: true, from: ms.from}}
          %Lavash.State.Toggle{name: name} = toggle -> {name, %{name: name, type: :boolean, optimistic: true, from: toggle.from}}
        end)
        |> Map.new()

      forms_map =
        forms
        |> Enum.map(fn form ->
          fields =
            try do
              if Code.ensure_loaded?(form.resource) and function_exported?(form.resource, :spark_dsl_config, 0) do
                Ash.Resource.Info.attributes(form.resource) |> Enum.map(& &1.name)
              else
                []
              end
            rescue
              _ -> []
            end

          {form.name, %{resource: form.resource, fields: fields}}
        end)
        |> Map.new()

      # Get actions from Spark
      declared_actions = Spark.Dsl.Extension.get_entities(module, [:actions]) || []
      actions_map =
        declared_actions
        |> Enum.map(fn action -> {action.name, action} end)
        |> Map.new()

      %{
        context: context,
        optimistic_fields: optimistic_fields,
        optimistic_derives: %{},
        calculations: %{},
        forms: forms_map,
        actions: actions_map,
        optimistic_actions: %{}
      }
    rescue
      _ -> %{context: context}
    end
  end
end
