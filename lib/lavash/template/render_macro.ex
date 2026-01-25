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
end
