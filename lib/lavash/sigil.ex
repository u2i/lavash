defmodule Lavash.Sigil do
  @moduledoc """
  Provides the `~L` sigil for Lavash-enhanced HEEx templates.

  The `~L` sigil works like `~H` but automatically injects `data-lavash-*` attributes
  based on the module's DSL declarations.

  ## Usage

      defmodule MyApp.CounterLive do
        use Lavash.LiveView
        import Lavash.Sigil  # Add this import

        state :count, :integer, from: :url, default: 0, optimistic: true

        actions do
          action :increment do
            update :count, &(&1 + 1)
          end
        end

        def render(assigns) do
          ~L\"\"\"
          <div>
            <span>{@count}</span>
            <button phx-click="increment">+</button>
          </div>
          \"\"\"
        end
      end

  The `~L` sigil will automatically add:
  - `data-lavash-display="count"` to the span (since it contains `{@count}`)
  - `data-lavash-action="increment"` to the button (since `increment` is a declared action)

  ## How It Works

  The sigil stores the template source, then at render time the module's
  `__before_compile__` transforms it with full metadata access.

  For simpler use cases, the sigil can also work directly if the module
  already has the `__lavash__/1` function available.

  ## Opting Out

  To skip auto-injection for a specific element, add `data-lavash-manual`:

      <button phx-click="increment" data-lavash-manual>+</button>

  Or use the regular `~H` sigil for the entire template.
  """

  @doc """
  Handles the `~L` sigil for Lavash-enhanced HEEx templates.

  Uses Lavash.TagEngine with token transformer for unified processing.
  This approach handles both data-lavash-* attributes on HTML elements
  and __lavash_client_bindings__ on component calls at the token level.
  """
  defmacro sigil_L({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    caller = __CALLER__
    module = caller.module

    # Get metadata for token transformation
    metadata =
      try do
        if Code.ensure_loaded?(module) and function_exported?(module, :__lavash__, 1) do
          Lavash.Template.TokenTransformer.build_metadata(module, context: :live_view)
        else
          case get_compile_time_metadata(module) do
            nil -> %{context: :live_view}
            m -> m
          end
        end
      rescue
        _ -> %{context: :live_view}
      end

    # Compile with Lavash.TagEngine and token transformer
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
  # This is a best-effort approach since not all metadata may be available
  def get_compile_time_metadata(module) do
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
        context: :live_view,
        optimistic_fields: optimistic_fields,
        optimistic_derives: %{},
        calculations: %{},
        forms: forms_map,
        actions: actions_map,
        optimistic_actions: %{}
      }
    rescue
      _ -> nil
    end
  end
end
