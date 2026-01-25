defmodule Lavash.Template.Compiled do
  @moduledoc """
  Represents a compiled Lavash template with source preservation.

  This struct holds both the compiled HEEx AST and the original source string,
  enabling:

  - Server-side rendering via the compiled HEEx
  - Client-side JS generation for ClientComponent (from source)

  ## Usage

      render fn assigns ->
        ~L\"\"\"
        <div>{@count}</div>
        \"\"\"
      end

  ## Fields

  - `:source` - Original template source string
  - `:compiled` - Compiled HEEx AST (quoted expression)
  - `:context` - Compilation context (`:live_view`, `:component`, `:client_component`)
  - `:file` - Source file path
  - `:line` - Source line number
  """

  defstruct [:source, :compiled, :context, :file, :line]

  @type context :: :live_view | :component | :client_component

  @type t :: %__MODULE__{
          source: String.t(),
          compiled: Macro.t(),
          context: context(),
          file: String.t(),
          line: non_neg_integer()
        }
end

defmodule Lavash.Render do
  @moduledoc """
  A render function declaration.

  Created by the `render fn assigns -> ... end` macro.

  ## Fields

  - `:name` - Atom identifying the render variant
  - `:template` - The template function AST or compiled struct
  """

  defstruct [:name, :template, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          template: Lavash.Template.Compiled.t()
        }
end
