defmodule Lavash.TemplateMacroTest do
  @moduledoc """
  Tests for the `template do ~H"..." end` template-declaration shape, which
  is additive backward-compatible alongside the existing
  `render fn assigns -> ~L"..." end` shape.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  # ============================================================
  # Fixtures: two components with identical template bodies but
  # different template-declaration shapes.
  # ============================================================

  defmodule TemplateShapeComponent do
    @moduledoc false
    use Lavash.Component

    prop :label, :string, default: "Count"
    state :count, :integer, from: :ephemeral, default: 0, optimistic: true

    template do
      ~H"""
      <div id={@id}>
        <span id={"#{@id}-label"}>{@label}</span>
        <span id={"#{@id}-count"}>{@count}</span>
      </div>
      """
    end
  end

  defmodule RenderShapeComponent do
    @moduledoc false
    use Lavash.Component

    prop :label, :string, default: "Count"
    state :count, :integer, from: :ephemeral, default: 0, optimistic: true

    render fn assigns ->
      ~L"""
      <div id={@id}>
        <span id={"#{@id}-label"}>{@label}</span>
        <span id={"#{@id}-count"}>{@count}</span>
      </div>
      """
    end
  end

  # ============================================================
  # Persisted DSL state
  # ============================================================

  describe "captured template source survives the lavash pipeline" do
    test "template do ~H end captures source onto :lavash_template_source" do
      source = Spark.Dsl.Extension.get_persisted(TemplateShapeComponent, :lavash_template_source)
      assert is_binary(source)

      assert source =~ ~s|<span id={"#{"\#{@id}"}-count"}>{@count}</span>| or
               source =~ "{@count}"

      assert source =~ "{@label}"
    end

    test "tokenization runs (tokens persisted)" do
      parsed = Spark.Dsl.Extension.get_persisted(TemplateShapeComponent, :lavash_template_tokens)
      assert %Phoenix.LiveView.TagEngine.Parser{nodes: nodes} = parsed
      assert is_list(nodes) and nodes != []
    end

    test "produces the same source as the equivalent render fn / ~L shape" do
      template_source =
        Spark.Dsl.Extension.get_persisted(TemplateShapeComponent, :lavash_template_source)

      render_source =
        Spark.Dsl.Extension.get_persisted(RenderShapeComponent, :lavash_template_source)

      assert template_source == render_source
    end
  end

  # ============================================================
  # Compiled render function existence + shape
  # ============================================================

  describe "compiled render function" do
    test "both shapes export a render/1 function" do
      assert function_exported?(TemplateShapeComponent, :render, 1)
      assert function_exported?(RenderShapeComponent, :render, 1)
    end

    test "calling render/1 produces the same HTML output as the legacy shape" do
      t_html = render_component(TemplateShapeComponent, id: "x", label: "Hello", count: 7)
      r_html = render_component(RenderShapeComponent, id: "x", label: "Hello", count: 7)

      # Both shapes wrap with the same lavash optimistic envelope; the
      # rendered bodies should match exactly.
      assert t_html == r_html
      assert t_html =~ ~s|<span id="x-label">Hello</span>|
      assert t_html =~ ~s|data-lavash-display="count">7</span>|
    end
  end

  # ============================================================
  # Compile-time conflicts
  # ============================================================

  describe "compile-time enforcement" do
    test "using both template/1 and render/1 in the same module raises" do
      src = """
      defmodule Lavash.TemplateMacroTest.BothShapes do
        use Lavash.Component

        state :count, :integer, from: :ephemeral, default: 0

        render fn assigns ->
          ~L\"\"\"
          <div>{@count}</div>
          \"\"\"
        end

        template do
          ~H\"\"\"
          <div>{@count}</div>
          \"\"\"
        end
      end
      """

      assert_raise CompileError, ~r/Cannot use both `template do/, fn ->
        Code.compile_string(src, "nofile")
      end
    end

    test "template do ... end without a ~H sigil raises a clear compile error" do
      src = """
      defmodule Lavash.TemplateMacroTest.NoSigil do
        use Lavash.Component

        template do
          "just a string"
        end
      end
      """

      assert_raise CompileError, ~r/must contain a single ~H sigil/, fn ->
        Code.compile_string(src, "nofile")
      end
    end
  end

  # ============================================================
  # data-lavash-* injection still happens for the new shape
  # ============================================================

  defmodule OptimisticTemplateShapeComponent do
    @moduledoc false
    use Lavash.Component

    state :count, :integer, from: :ephemeral, default: 0, optimistic: true

    actions do
      action :inc do
        set :count, rx(@count + 1)
      end
    end

    template do
      ~H"""
      <div id={@id}>
        <span id={"#{@id}-count"}>{@count}</span>
        <button phx-click="inc" phx-target={@myself}>+</button>
      </div>
      """
    end
  end

  describe "lavash pipeline still runs for the new shape" do
    test "optimistic field injects data-lavash-display wrapper" do
      html = render_component(OptimisticTemplateShapeComponent, id: "y", count: 3)

      # The token transformer auto-wraps bare `{@count}` in a span
      # carrying data-lavash-display="count" — this is the lavash pipeline
      # processing the source captured by the new template/1 macro.
      assert html =~ ~s|data-lavash-display="count"|
    end
  end

  # ============================================================
  # LiveView (not just Component) also accepts the new shape
  # ============================================================

  defmodule LiveViewTemplateShape do
    @moduledoc false
    use Lavash.LiveView

    state :count, :integer, default: 0, optimistic: true

    template do
      ~H"""
      <div>Count: {@count}</div>
      """
    end
  end

  describe "Lavash.LiveView" do
    test "accepts the new template do ~H end shape" do
      source = Spark.Dsl.Extension.get_persisted(LiveViewTemplateShape, :lavash_template_source)
      assert source =~ "Count: {@count}"
      assert function_exported?(LiveViewTemplateShape, :render, 1)
    end
  end

  # ============================================================
  # template_loading do ~H end (overlay loading-state shape)
  # ============================================================

  defmodule TemplateLoadingModal do
    @moduledoc false
    use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

    state :open, :any, from: :ephemeral, default: nil, optimistic: true

    modal do
      open_field :open
      async_assign :thing
      max_width :md
    end

    template do
      ~H"""
      <div id={"#{@id}-content"}>loaded</div>
      """
    end

    template_loading do
      ~H"""
      <div id={"#{@id}-loading"} class="animate-pulse">loading…</div>
      """
    end
  end

  defmodule RenderLoadingModal do
    @moduledoc false
    use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

    state :open, :any, from: :ephemeral, default: nil, optimistic: true

    modal do
      open_field :open
      async_assign :thing
      max_width :md
    end

    render fn assigns ->
      ~L"""
      <div id={"#{@id}-content"}>loaded</div>
      """
    end

    render_loading fn assigns ->
      ~L"""
      <div id={"#{@id}-loading"} class="animate-pulse">loading…</div>
      """
    end
  end

  describe "template_loading do ~H end" do
    test "both the template and render_loading shapes compile and export render/1" do
      assert function_exported?(TemplateLoadingModal, :render, 1)
      assert function_exported?(RenderLoadingModal, :render, 1)
    end

    test "the loading template is persisted on the modal render config" do
      # GenerateRender stores the loading fn under :modal_render_loading_template.
      # The template_loading do ~H end shape must populate it just like
      # render_loading fn assigns -> ~L"..." end does.
      t_loading =
        Spark.Dsl.Extension.get_persisted(
          TemplateLoadingModal,
          :modal_render_loading_template
        )

      r_loading =
        Spark.Dsl.Extension.get_persisted(
          RenderLoadingModal,
          :modal_render_loading_template
        )

      assert match?({:render_ast, _}, t_loading)
      assert match?({:render_ast, _}, r_loading)
    end

    test "using both template_loading/1 and render_loading/1 in the same module raises" do
      src = """
      defmodule Lavash.TemplateMacroTest.BothLoadingShapes do
        use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

        state :open, :any, from: :ephemeral, default: nil

        modal do
          open_field :open
          async_assign :thing
        end

        template do
          ~H\"\"\"
          <div>loaded</div>
          \"\"\"
        end

        render_loading fn assigns ->
          ~L\"\"\"
          <div>loading</div>
          \"\"\"
        end

        template_loading do
          ~H\"\"\"
          <div>loading</div>
          \"\"\"
        end
      end
      """

      assert_raise CompileError, ~r/Cannot use both `template_loading do/, fn ->
        Code.compile_string(src, "nofile")
      end
    end
  end
end
