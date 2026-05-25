defmodule Lavash.Transformers.ValidateTemplateTest do
  @moduledoc """
  Compile-time validation of template-level references (phx-click,
  phx-submit, etc.) against declared actions on the module.

  Each test compiles a tiny `use Lavash.LiveView` module with a
  `template do ~H\"...\" end` block and asserts the validator either
  raises a `Spark.Error.DslError` (typo / undeclared action) or
  doesn't (happy path / intentionally dynamic value).

  ValidateTemplate runs AFTER AnalyzeTemplate (which collects the
  `phx-*` references) — so the `template do` form is required for
  the validator to see anything. Modules using `def render` (no
  template block) skip validation entirely; that's an intentional
  limitation noted in the validator's moduledoc.
  """
  use ExUnit.Case, async: false

  defp compile!(name, body) do
    source = """
    defmodule #{name} do
      use Lavash.LiveView
      #{body}
    end
    """

    Code.compile_string(source, "nofile")
  rescue
    e -> e
  end

  defp assert_raises_dsl_error(name, body, message_match) do
    err = compile!(name, body)
    assert %Spark.Error.DslError{} = err, "expected DslError, got: #{inspect(err)}"
    assert err.message =~ message_match, "got: #{err.message}"
  end

  defp assert_compiles(name, body) do
    result = compile!(name, body)

    assert is_list(result),
           "expected compile success (list of {Module, beam} pairs), got: #{inspect(result)}"
  end

  describe "phx-click with undeclared action" do
    test "raises with the typo'd action name" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadClick,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :increment do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click=\"incremnt\">+</button>
          \"\"\"
        end
        """,
        "phx-event references undeclared action `incremnt`"
      )
    end

    test "suggests the closest declared action" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadClickSuggest,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :increment do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click=\"incremnt\">+</button>
          \"\"\"
        end
        """,
        "Did you mean `increment`?"
      )
    end
  end

  describe "phx-click with declared action" do
    test "compiles cleanly" do
      assert_compiles(
        Lavash.Validate.TplGoodClick,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :increment do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click=\"increment\">+</button>
          \"\"\"
        end
        """
      )
    end
  end

  describe "phx-click with auto-generated setter from optimistic: true" do
    test "compiles cleanly" do
      # `optimistic: true` auto-generates a `set_<name>` action; the
      # template can reference it.
      assert_compiles(
        Lavash.Validate.TplAutoSetter,
        """
        state :search, :string, default: \"\", optimistic: true

        template do
          ~H\"\"\"
          <button phx-click=\"set_search\" phx-value-value=\"hello\">set</button>
          \"\"\"
        end
        """
      )
    end
  end

  describe "phx-click with dynamic expression" do
    test "skips validation (JS.dispatch / @var)" do
      # Dynamic value — we can't statically know if it resolves to a
      # server action or a JS command. Skip rather than false-positive.
      assert_compiles(
        Lavash.Validate.TplDynamicClick,
        """
        alias Phoenix.LiveView.JS

        actions do
          action :noop do
            set :x, 0
          end
        end

        state :x, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <button phx-click={JS.dispatch(\"some-event\")}>dispatch</button>
          \"\"\"
        end
        """
      )
    end
  end

  describe "phx-submit / phx-change" do
    test "all phx-* event attrs are validated" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadSubmit,
        """
        state :x, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <form phx-submit=\"sav\"><input /></form>
          \"\"\"
        end
        """,
        "phx-event references undeclared action `sav`"
      )
    end
  end

  describe "phx-click on a component" do
    test "is not validated (binds to a prop, not an event)" do
      # phx-click on a function/live component is a prop value, not a
      # server event reference. Don't validate it; the component will
      # check its own attrs against its own DSL.
      assert_compiles(
        Lavash.Validate.TplComponentClick,
        """
        state :x, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <.link phx-click=\"not_a_real_action\">click</.link>
          \"\"\"
        end
        """
      )
    end
  end
end
