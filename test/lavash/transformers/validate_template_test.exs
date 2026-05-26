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

  describe "phx-value-* against action params" do
    test "declared param passes" do
      assert_compiles(
        Lavash.Validate.TplGoodPhxValue,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :bump_by, [:amount] do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click="bump_by" phx-value-amount="5">+5</button>
          \"\"\"
        end
        """
      )
    end

    test "undeclared param raises with declared params shown" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadPhxValue,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :bump_by, [:amount] do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click="bump_by" phx-value-amout="5">+5</button>
          \"\"\"
        end
        """,
        "`phx-value-amout` references an undeclared param"
      )
    end

    test "undeclared param suggests closest declared param" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadPhxValueSuggest,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :bump_by, [:amount] do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click="bump_by" phx-value-amout="5">+5</button>
          \"\"\"
        end
        """,
        "Did you mean `phx-value-amount`?"
      )
    end

    test "action with no params raises on any phx-value-*" do
      assert_raises_dsl_error(
        Lavash.Validate.TplNoParams,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :increment do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click="increment" phx-value-foo="x">+</button>
          \"\"\"
        end
        """,
        "Action `increment` declares no params."
      )
    end

    test "auto-setter accepts phx-value-value" do
      assert_compiles(
        Lavash.Validate.TplAutoSetterValue,
        """
        state :search, :string, default: "", optimistic: true

        template do
          ~H\"\"\"
          <button phx-click="set_search" phx-value-value="hello">set</button>
          \"\"\"
        end
        """
      )
    end

    test "auto-setter rejects other phx-value keys" do
      assert_raises_dsl_error(
        Lavash.Validate.TplAutoSetterBadValue,
        """
        state :search, :string, default: "", optimistic: true

        template do
          ~H\"\"\"
          <button phx-click="set_search" phx-value-payload="hello">set</button>
          \"\"\"
        end
        """,
        "`phx-value-payload` references an undeclared param"
      )
    end

    test "multiple declared params, all referenced — compiles" do
      assert_compiles(
        Lavash.Validate.TplMultipleParams,
        """
        state :count, :integer, default: 0, optimistic: true

        actions do
          action :bump_by, [:amount, :reason] do
            set :count, rx(@count + 1)
          end
        end

        template do
          ~H\"\"\"
          <button phx-click="bump_by" phx-value-amount="5" phx-value-reason="user">+</button>
          \"\"\"
        end
        """
      )
    end
  end

  describe "@name assign references" do
    test "declared state field passes" do
      assert_compiles(
        Lavash.Validate.TplGoodAssign,
        """
        state :count, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <p>{@count}</p>
          \"\"\"
        end
        """
      )
    end

    test "typo'd assign raises with suggestion" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadAssign,
        """
        state :count, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <p>{@cout}</p>
          \"\"\"
        end
        """,
        "`@cout` references an undeclared assign"
      )
    end

    test "typo suggests closest declared state" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadAssignSuggest,
        """
        state :count, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <p>{@cout}</p>
          \"\"\"
        end
        """,
        "Did you mean `@count`?"
      )
    end

    test "@flash passes (Phoenix-injected)" do
      assert_compiles(
        Lavash.Validate.TplFlash,
        """
        template do
          ~H\"\"\"
          <p>{@flash[:info]}</p>
          \"\"\"
        end
        """
      )
    end

    test "@socket passes (Phoenix-injected)" do
      assert_compiles(
        Lavash.Validate.TplSocket,
        """
        template do
          ~H\"\"\"
          <p>{inspect(@socket.assigns)}</p>
          \"\"\"
        end
        """
      )
    end

    test "?-suffix state field works (e.g. @is_admin?)" do
      assert_compiles(
        Lavash.Validate.TplPredicate,
        """
        state :is_admin?, :boolean, default: true, optimistic: true

        template do
          ~H\"\"\"
          <p>{to_string(@is_admin?)}</p>
          \"\"\"
        end
        """
      )
    end

    test "from: :assigns state passes" do
      assert_compiles(
        Lavash.Validate.TplFromAssigns,
        """
        state :current_user, :map, from: :assigns, default: nil

        template do
          ~H\"\"\"
          <p>{inspect(@current_user)}</p>
          \"\"\"
        end
        """
      )
    end

    test "@-ref inside :if attr is validated" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadIfRef,
        """
        state :open, :boolean, default: false, optimistic: true

        template do
          ~H\"\"\"
          <div :if={@opn}>hidden</div>
          \"\"\"
        end
        """,
        "`@opn` references an undeclared assign"
      )
    end

    test "@-ref inside :for source expression is validated" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadForSource,
        """
        state :items, {:array, :string}, default: [], optimistic: true

        template do
          ~H\"\"\"
          <span :for={item <- @itms}>{item}</span>
          \"\"\"
        end
        """,
        "`@itms` references an undeclared assign"
      )
    end

    test "bare loop variable (no @-prefix) is ignored" do
      # `item` is a local Elixir binding from :for — not an assign.
      # The validator should NOT flag it; the Elixir compiler will
      # catch undefined-variable errors.
      assert_compiles(
        Lavash.Validate.TplLoopVar,
        """
        state :items, {:array, :string}, default: [], optimistic: true

        template do
          ~H\"\"\"
          <span :for={item <- @items}>{item}</span>
          \"\"\"
        end
        """
      )
    end

    test "<%= eex %> blocks are validated" do
      assert_raises_dsl_error(
        Lavash.Validate.TplBadEex,
        """
        state :count, :integer, default: 0, optimistic: true

        template do
          ~H\"\"\"
          <%= if @count > 0 do %>positive<% end %>
          <%= @cout %>
          \"\"\"
        end
        """,
        "`@cout` references an undeclared assign"
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
