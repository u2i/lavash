defmodule Lavash.Template.RenderMacro do
  @moduledoc """
  Macro for defining render functions in Lavash LiveViews and Components.

  This macro captures `render fn assigns -> ~L\"\"\"...\"\"\" end` definitions and stores
  them in a module attribute for later processing by the compiler.

  ## Usage

      render fn assigns ->
        ~L\"\"\"
        <div>{@count}</div>
        \"\"\"
      end

  The function receives assigns and must return HEEx content via the `~L` sigil.
  """

  @doc """
  Defines a render function.

  The function receives `assigns` and should return HEEx content via `~L` sigil.

  ## Examples

      render fn assigns ->
        ~L\"\"\"
        <div>
          <span>{@count}</span>
          <button phx-click="increment">+</button>
        </div>
        \"\"\"
      end
  """
  defmacro render(render_fn) do
    # render_fn is already the quoted AST of the function expression
    # We need to escape it so it can be stored in a module attribute as data
    # then unescaped when used in the compiler
    escaped_ast = Macro.escape(render_fn)

    quote do
      @__lavash_renders__ {:__render_fn__, unquote(escaped_ast)}
    end
  end

  @doc """
  Defines a loading render function for overlays (modals, flyovers).

  ## Examples

      render_loading fn assigns ->
        ~L\"\"\"
        <div class="animate-pulse">Loading...</div>
        \"\"\"
      end
  """
  defmacro render_loading(render_fn) do
    escaped_ast = Macro.escape(render_fn)

    quote do
      @__lavash_renders__ {:__loading_fn__, unquote(escaped_ast)}
    end
  end

  @doc """
  Declares a component/LiveView template using a `do` block containing a `~H` sigil.

  This is an alternative shape to `render fn assigns -> ~L\"\"\"...\"\"\" end`. Both
  shapes feed into the same Lavash compile pipeline (`TokenizeTemplate` →
  `AnalyzeTemplate` → `ExtractColocatedJs` → `CompileComponent/CompileLiveView`) and
  produce the same compiled output for the same template body.

  ## Example

      template do
        ~H\"\"\"
        <button phx-click="inc">Count: {@count}</button>
        \"\"\"
      end

  ## Limitations

  - The `do` block must contain a single `~H` sigil literal. No interpolation in
    the sigil delimiters, no surrounding code in the block.
  - For an overlay loading-state render, pair this with `template_loading do ... end`
    (the `template`-shaped companion to `render_loading fn ... end`).
  - A module must not declare both `template do ... end` and `render fn ... end`.
    Doing so raises a compile error.
  """
  defmacro template(do: block) do
    {source, line} = extract_heex_source!(block, __CALLER__)
    __build_template_attr__(source, line)
  end

  @doc false
  # Shared expansion used by both `Lavash.Template.RenderMacro.template/1`
  # and the component-side re-export `Lavash.Component.RenderImport.template/1`.
  def __build_template_attr__(source, line) do
    # Register on the same `@__lavash_renders__` attribute so the downstream
    # pipeline finds a `:__render_fn__` entry. We embed the source in a tagged
    # tuple that `TokenizeTemplate.extract_compiled_source_and_line/1` recognizes.
    quote do
      if List.keymember?(@__lavash_renders__ || [], :__render_fn__, 0) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description:
            ~s(Cannot use both `template do ~H"..." end` and `render fn assigns -> ~L"..." end` ) <>
              "in the same module. Pick one template-declaration shape."
      end

      @__lavash_renders__ {:__render_fn__,
                           {:__lavash_template_source__, unquote(source), unquote(line)}}
    end
  end

  @doc """
  Declares the loading-state template using a `do` block containing a `~H` sigil.

  The `template do ... end` companion for overlays (modals, flyovers). Mirrors
  `render_loading fn assigns -> ~L\"\"\"...\"\"\" end` exactly — the body is shown
  while the overlay's `async_assign` is still loading.

  ## Example

      template do
        ~H\"\"\"
        <div>{@product.name}</div>
        \"\"\"
      end

      template_loading do
        ~H\"\"\"
        <div class="animate-pulse">Loading…</div>
        \"\"\"
      end

  ## Limitations

  - Same single-`~H`-sigil-literal rule as `template/1` (no interpolation in the
    sigil delimiters, no surrounding code in the block).
  - A module must not declare both `template_loading do ... end` and
    `render_loading fn ... end`. Doing so raises a compile error.
  """
  defmacro template_loading(do: block) do
    {source, line} = extract_heex_source!(block, __CALLER__)
    __build_loading_attr__(source, line)
  end

  @doc false
  # Shared expansion used by both `Lavash.Template.RenderMacro.template_loading/1`
  # and the component-side re-export `Lavash.Component.RenderImport.template_loading/1`.
  #
  # The overlay render generator consumes `:__loading_fn__` as an escaped `fn`
  # AST (it does NOT run the token pipeline on the loading template — see
  # `Lavash.Overlay.Modal.RenderGenerator.generate_render_fn_code/5`). So we
  # synthesize the same shape `render_loading fn assigns -> ~L"..." end`
  # produces: an escaped `fn assigns -> ~L<source> end`. Using `~L` routes it
  # through the identical sigil expansion the `fn` form uses.
  def __build_loading_attr__(source, line) do
    sigil_ast =
      {:sigil_L, [line: line], [{:<<>>, [line: line], [source]}, []]}

    fn_ast =
      {:fn, [line: line], [{:->, [line: line], [[{:assigns, [line: line], nil}], sigil_ast]}]}

    escaped_fn = Macro.escape(fn_ast)

    quote do
      if List.keymember?(@__lavash_renders__ || [], :__loading_fn__, 0) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description:
            ~s(Cannot use both `template_loading do ~H"..." end` and ) <>
              ~s(`render_loading fn assigns -> ~L"..." end` in the same module. ) <>
              "Pick one template-declaration shape."
      end

      @__lavash_renders__ {:__loading_fn__, unquote(escaped_fn)}
    end
  end

  @doc false
  # Public so `Lavash.Component.RenderImport.template/1` can re-use the same
  # ~H-extraction logic.
  def __extract_heex_source__!(block, caller), do: extract_heex_source!(block, caller)

  # Walks the AST of the `do` block looking for the first ~H sigil literal node.
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
            "`template do ... end` must contain a single ~H sigil literal " <>
              "(no interpolation in the sigil delimiters). Got: " <>
              Macro.to_string(block)
    end
  end
end
