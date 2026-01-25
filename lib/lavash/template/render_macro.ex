defmodule Lavash.Template.RenderMacro do
  @moduledoc """
  Macro for defining named render functions in Lavash LiveViews and Components.

  This macro captures `render :name do ~L\"\"\"...\"\"\" end` definitions and stores
  them in a module attribute for later processing by the compiler.

  ## Usage

      render :default do
        ~L\"\"\"
        <div>{@count}</div>
        \"\"\"
      end

      render :loading do
        ~L\"\"\"
        <div>Loading...</div>
        \"\"\"
      end

  The `:default` render is used as the main `render/1` function.
  Other named renders can be called via `render_loading(assigns)`, etc.
  """

  @doc """
  Defines a named render function.

  The `do` block should contain a `~L` sigil that returns a
  `%Lavash.Template.Compiled{}` struct.

  ## Examples

      render :default do
        ~L\"\"\"
        <div>
          <span>{@count}</span>
          <button phx-click="increment">+</button>
        </div>
        \"\"\"
      end

      render :empty do
        ~L\"\"\"
        <p>No items found</p>
        \"\"\"
      end
  """
  defmacro render(name, do: block) when is_atom(name) do
    # Extract template source from ~L sigil if present
    {source, compiled} = extract_template(block, __CALLER__)

    quote do
      @__lavash_renders__ {unquote(name), %{source: unquote(source), compiled: unquote(Macro.escape(compiled))}}
    end
  end

  # Alternative inline syntax without do block
  @doc false
  defmacro render(name, template) when is_atom(name) do
    {source, compiled} = extract_template(template, __CALLER__)

    quote do
      @__lavash_renders__ {unquote(name), %{source: unquote(source), compiled: unquote(Macro.escape(compiled))}}
    end
  end

  @doc """
  Legacy function-based render syntax.

  Supports `render fn assigns -> ~H\"\"\"...\"\"\" end`

  For the legacy syntax, we define the module attribute directly using
  the function value, since macros receive the quoted form.
  """
  defmacro render(render_fn) do
    # render_fn is already the quoted AST of the function expression
    # We need to escape it so it can be stored in a module attribute as data
    # then unescaped when used in the compiler
    escaped_ast = Macro.escape(render_fn)

    quote do
      @__lavash_renders__ {:__legacy_fn__, unquote(escaped_ast)}
    end
  end

  # Extract template source from ~L sigil call
  defp extract_template({:sigil_L, _, [{:<<>>, _, [source]}, _]}, _caller) when is_binary(source) do
    {source, nil}
  end

  defp extract_template({:<<>>, _, [source]}, _caller) when is_binary(source) do
    {source, nil}
  end

  defp extract_template(block, _caller) do
    # For other expressions, just store nil source and the block
    {nil, block}
  end
end
