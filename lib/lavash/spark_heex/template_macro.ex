defmodule Lavash.SparkHeex.TemplateMacro do
  @moduledoc """
  The `template do ~H"..."  end` macro.

  Captures the raw HEEx source string out of the `~H` sigil node inside the
  block and stashes it on a module attribute. A Spark transformer
  (`Lavash.SparkHeex.Transformers.IngestTemplate`) later copies that string
  into the persistent DSL state so other transformers can analyze it.
  """

  defmacro template(do: block) do
    {source, line} = extract_heex_source!(block, __CALLER__)

    quote do
      Module.register_attribute(__MODULE__, :__lavash_heex_template__, persist: false)
      @__lavash_heex_template__ {unquote(source), unquote(line)}
    end
  end

  # Walks the AST of the `do` block looking for the first ~H sigil node.
  defp extract_heex_source!(block, caller) do
    found =
      Macro.prewalk(block, nil, fn
        {:sigil_H, meta, [{:<<>>, _, [source]}, _modifiers]} = node, nil
        when is_binary(source) ->
          {node, {source, meta[:line] || caller.line}}

        node, acc ->
          {node, acc}
      end)

    case found do
      {_, {source, line}} ->
        {source, line}

      _ ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "Lavash.SparkHeex `template do ... end` must contain a single ~H sigil " <>
              "(no interpolation in the sigil delimiters). Got: " <>
              Macro.to_string(block)
    end
  end
end
