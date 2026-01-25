defmodule Lavash.Template.Compiled do
  @moduledoc """
  Represents a compiled Lavash template with source preservation.

  This struct is returned by the `~L` sigil and consumed by the `render` DSL.
  It contains both the compiled HEEx AST and the original source string,
  enabling:

  - Server-side rendering via the compiled HEEx
  - Client-side JS generation for ClientComponent (from source)
  - Named render variants (`:default`, `:loading`, etc.)

  ## Usage

  The `~L` sigil automatically creates this struct:

      render :default do
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
  A named render function declaration.

  Created by the `render :name do ... end` DSL entity.

  ## Fields

  - `:name` - Atom identifying the render variant (e.g., `:default`, `:loading`)
  - `:template` - The `Lavash.Template.Compiled` struct containing source and compiled HEEx
  """

  defstruct [:name, :template, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          template: Lavash.Template.Compiled.t()
        }
end
