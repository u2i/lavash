defmodule Lavash.SparkHeex do
  @moduledoc """
  Spike: a Spark DSL extension that treats HEEx templates as a first-class
  DSL element, not as opaque sigil contents inside a function body.

  See Lavash.SparkHeex.Dsl and `Lavash.SparkHeex.TemplateMacro` for the
  moving parts. The spike write-up lives at the top of this file:

  ## Why

  Lavash's original approach wrapped the template in a function literal whose
  body was an opaque sigil. The DSL didn't know what was inside the sigil until
  a separate transformer walked the AST and extracted the string. That meant
  DSL-level analysis (e.g. "is `@count` a declared state field?") couldn't
  happen at DSL build time.

  This spike introduces a `template do ... end` section. The body holds a
  single `~H"..."` sigil; the macro extracts the source string at parse time
  and persists it onto the Spark DSL state, where Spark transformers can
  inspect it alongside the declared `state` entities.

  ## Approach trade-offs

  Elixir's parser cannot natively accept `<button>...</button>` inside a
  `do` block (it parses `<` and `>` as operators). The four options were:

  1. Sigil (`~H"..."`) — works with stock Elixir parser, no fork needed.
  2. Custom block delimiter via tokenizer hook — would need a Spark/Elixir
     parser fork.
  3. Heredoc string argument to a macro — works but feels less native.
  4. Fork Spark to add an HTML tokenizer hook — biggest scope, out of spike
     budget.

  This spike picks (1). The payoff being demonstrated is **not** the
  surface syntax — it's that the template is a first-class Spark entity
  that transformers can validate against the rest of the DSL state at DSL
  build time.

  ## Example

      defmodule MyComponent do
        use Lavash.SparkHeex

        state :count, :integer, default: 0

        template do
          ~H\"\"\"
          <button>Count: {@count}</button>
          \"\"\"
        end
      end

      MyComponent.render(%{count: 5})
      # => %Phoenix.LiveView.Rendered{...}  rendering "Count: 5"

  Validation happens at compile time: if the template references `@bogus`,
  Spark raises a `DslError` from inside its transformer pipeline.
  """

  use Spark.Dsl, default_extensions: [extensions: [Lavash.SparkHeex.Dsl]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      import Lavash.SparkHeex.TemplateMacro, only: [template: 1]
    end
  end
end
