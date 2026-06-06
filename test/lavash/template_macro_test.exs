defmodule Lavash.TemplateMacroTest do
  @moduledoc """
  Tests for the `template do ~H"..." end` / `template_loading do ~H"..." end`
  template-declaration macros.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

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
  end

  # ============================================================
  # Compiled render function
  # ============================================================

  describe "compiled render function" do
    test "exports a render/1 function" do
      assert function_exported?(TemplateShapeComponent, :render, 1)
    end

    test "calling render/1 renders the template body" do
      html = render_component(TemplateShapeComponent, id: "x", label: "Hello", count: 7)

      assert html =~ ~s|<span id="x-label">Hello</span>|
      assert html =~ ~s|data-lavash-display="count">7</span>|
    end
  end

  # ============================================================
  # Compile-time enforcement
  # ============================================================

  describe "compile-time enforcement" do
    test "using both template do ... end and def render/1 raises" do
      src = """
      defmodule Lavash.TemplateMacroTest.BothShapes do
        use Lavash.LiveView

        state :count, :integer, default: 0

        template do
          ~H\"\"\"
          <div>{@count}</div>
          \"\"\"
        end

        def render(assigns) do
          ~H\"\"\"
          <div>{@count}</div>
          \"\"\"
        end
      end
      """

      # The guard fires inside a Spark transformer, which wraps the
      # CompileError as a RuntimeError carrying the same message.
      assert_raise RuntimeError, ~r/Cannot define both `template do/, fn ->
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
  # data-lavash-* injection happens for the template shape
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

  describe "lavash pipeline runs for the template shape" do
    test "optimistic field injects data-lavash-display wrapper" do
      html = render_component(OptimisticTemplateShapeComponent, id: "y", count: 3)

      # The token transformer auto-wraps bare `{@count}` in a span
      # carrying data-lavash-display="count" — the lavash pipeline
      # processing the source captured by the template/1 macro.
      assert html =~ ~s|data-lavash-display="count"|
    end
  end

  # ============================================================
  # LiveView (not just Component) accepts the shape
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
    test "accepts the template do ~H end shape" do
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

  describe "template_loading do ~H end" do
    test "the modal compiles and exports render/1" do
      assert function_exported?(TemplateLoadingModal, :render, 1)
    end

    test "the loading template is tokenized into its own persisted slot" do
      source = Spark.Dsl.Extension.get_persisted(TemplateLoadingModal, :lavash_loading_source)
      tokens = Spark.Dsl.Extension.get_persisted(TemplateLoadingModal, :lavash_loading_tokens)

      assert source =~ "loading…"
      assert %Phoenix.LiveView.TagEngine.Parser{} = tokens
    end

    test "the loading template is persisted on the modal render config" do
      loading =
        Spark.Dsl.Extension.get_persisted(
          TemplateLoadingModal,
          :modal_render_loading_template
        )

      assert match?({:render_ast, _}, loading)
    end

    test "declaring template_loading more than once raises" do
      src = """
      defmodule Lavash.TemplateMacroTest.DoubleLoading do
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

        template_loading do
          ~H\"\"\"
          <div>loading a</div>
          \"\"\"
        end

        template_loading do
          ~H\"\"\"
          <div>loading b</div>
          \"\"\"
        end
      end
      """

      assert_raise CompileError, ~r/loading template/, fn ->
        Code.compile_string(src, "nofile")
      end
    end
  end
end
