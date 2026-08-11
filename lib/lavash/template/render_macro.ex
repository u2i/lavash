defmodule Lavash.Template.RenderMacro do
  @moduledoc """
  Macros for declaring templates in Lavash LiveViews and Components.

  `template do ~H\"\"\"...\"\"\" end` captures the template source and stores it on
  a module attribute for the Lavash compile pipeline. `template_loading do ... end`
  declares the loading-state body for overlays (modals, flyovers).

  ## Usage

      template do
        ~H\"\"\"
        <div>{@count}</div>
        \"\"\"
      end
  """

  @doc """
  Declares a component/LiveView template using a `do` block containing a `~H` sigil.

  The template source feeds the Lavash compile pipeline (`TokenizeTemplate` →
  `AnalyzeTemplate` → `ExtractColocatedJs` → `CompileComponent/CompileLiveView`).

  ## Example

      template do
        ~H\"\"\"
        <button phx-click="inc">Count: {@count}</button>
        \"\"\"
      end

  ## Limitations

  - The `do` block must contain a single `~H` sigil literal. No interpolation in
    the sigil delimiters, no surrounding code in the block.
  - For an overlay loading-state render, pair this with `template_loading do ... end`.
  - A module must not declare both `template do ... end` and `def render/1`.
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
    # Register the source on `@__lavash_renders__` under `:__render_fn__` as a
    # tagged tuple that `TokenizeTemplate` recognizes.
    quote do
      if List.keymember?(@__lavash_renders__ || [], :__render_fn__, 0) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description: "`template do ~H\"...\" end` declared more than once."
      end

      @__lavash_renders__ {:__render_fn__,
                           {:__lavash_template_source__, unquote(source), unquote(line)}}
    end
  end

  @doc """
  Declares the loading-state template using a `do` block containing a `~H` sigil.

  The `template do ... end` companion for overlays (modals, flyovers) — the body
  is shown while the overlay's `async_assign` is still loading.

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
  - A module may declare at most one `template_loading do ... end`.
  """
  defmacro template_loading(do: block) do
    {source, line} = extract_heex_source!(block, __CALLER__)
    __build_loading_attr__(source, line)
  end

  @doc false
  # Shared expansion used by both `Lavash.Template.RenderMacro.template_loading/1`
  # and the component-side re-export `Lavash.Component.RenderImport.template_loading/1`.
  #
  # Stores the loading template as the same tagged source tuple `template/1` uses
  # for `:__render_fn__`, so `TokenizeTemplate` tokenizes the loading body into
  # `:lavash_loading_tokens`/`:lavash_loading_source` and the overlay render
  # generators compile it through the identical token pipeline as the main render.
  def __build_loading_attr__(source, line) do
    quote do
      if List.keymember?(@__lavash_renders__ || [], :__loading_fn__, 0) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description:
            ~s(`template_loading do ~H"..." end` declared more than once. ) <>
              "A module may declare at most one loading template."
      end

      @__lavash_renders__ {:__loading_fn__,
                           {:__lavash_template_source__, unquote(source), unquote(line)}}
    end
  end

  @doc """
  Declares an overlay's trigger template using a `do` block containing a `~H` sigil.

  Overlay components (modals, flyovers) render their `template do` inside the
  panel chrome. The trigger template renders **outside** it, in normal page
  flow, wrapped in a button that opens the overlay optimistically and carries
  the dialog ARIA wiring (`aria-haspopup`, `aria-expanded`, `aria-controls`).
  This lets one component own its trigger, badge, and panel — parents just
  place the component.

  ## Example

      template_trigger do
        ~H\"\"\"
        <span class="btn btn-ghost">Cart ({@item_count})\</span>
        \"\"\"
      end

  ## Limitations

  - Same single-`~H`-sigil-literal rule as `template/1`.
  - The content is wrapped in a `<button>` — keep it non-interactive
    (spans, icons, badges), not nested buttons or links.
  - The generated open dispatches the overlay's open with `true`; overlays
    whose open field needs a value (e.g. an id) still open via actions.
  - Only meaningful on overlay components; a module may declare at most one.
  """
  defmacro template_trigger(do: block) do
    {source, line} = extract_heex_source!(block, __CALLER__)
    __build_trigger_attr__(source, line)
  end

  @doc false
  # Shared expansion used by both `template_trigger/1` and the component-side
  # re-export `Lavash.Component.RenderImport.template_trigger/1`.
  def __build_trigger_attr__(source, line) do
    quote do
      if List.keymember?(@__lavash_renders__ || [], :__trigger_fn__, 0) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description:
            ~s(`template_trigger do ~H"..." end` declared more than once. ) <>
              "A module may declare at most one trigger template."
      end

      @__lavash_renders__ {:__trigger_fn__,
                           {:__lavash_template_source__, unquote(source), unquote(line)}}
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
