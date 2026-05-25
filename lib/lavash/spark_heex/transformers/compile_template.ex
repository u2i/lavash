defmodule Lavash.SparkHeex.Transformers.CompileTemplate do
  @moduledoc """
  Compiles the HEEx template source into a `render/1` function on the
  using module. The function takes an assigns map and returns a
  `%Phoenix.LiveView.Rendered{}`, identical in shape to what `~H` produces
  inside a regular Phoenix.Component.

  Also defines `__lavash_heex_template_source__/0` so tests/introspection
  can see the captured source.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(Lavash.SparkHeex.Transformers.ValidateTemplate), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    case Transformer.get_persisted(dsl_state, :heex_template) do
      nil ->
        {:ok, dsl_state}

      {source, line} ->
        module = Transformer.get_persisted(dsl_state, :module)
        defaults = state_defaults(dsl_state)

        # Compile the HEEx source into a quoted expression that, when
        # evaluated in a function with `assigns` in scope, produces a
        # %Phoenix.LiveView.Rendered{}.
        env = %Macro.Env{module: module, file: module_file(module), line: line}

        compiled =
          Phoenix.LiveView.TagEngine.compile(source,
            file: env.file,
            line: line,
            caller: env,
            indentation: 0,
            tag_handler: Phoenix.LiveView.HTMLEngine
          )

        # Phoenix's TagEngine.compile expects an `assigns` variable in scope
        # (it raises if not). We pass it through quote/unquote with the
        # same hygiene context as the compiled AST by using a non-hygienic
        # binding via `var!/1`.
        quoted =
          quote do
            @doc false
            def __lavash_heex_template_source__, do: unquote(source)

            @doc false
            def __lavash_heex_state_defaults__, do: unquote(Macro.escape(defaults))

            @doc """
            Render this component with the given assigns map. Missing
            assigns fall back to the declared state defaults.
            """
            def render(var!(assigns)) when is_map(var!(assigns)) do
              var!(assigns) =
                Map.merge(__lavash_heex_state_defaults__(), var!(assigns))

              unquote(compiled)
            end
          end

        {:ok, Transformer.eval(dsl_state, [], quoted)}
    end
  end

  defp state_defaults(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:states])
    |> Enum.into(%{}, fn s -> {s.name, s.default} end)
  end

  defp module_file(module) do
    case module.module_info(:compile)[:source] do
      nil -> "nofile"
      source -> List.to_string(source)
    end
  rescue
    _ -> "nofile"
  end
end
