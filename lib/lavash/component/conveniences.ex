defmodule Lavash.Component.Conveniences do
  @moduledoc """
  Convenience macros for common component patterns.

  These macros expand into state declarations and optimistic actions,
  providing a simpler syntax for common use cases like toggles and multi-selects.

  ## Toggle

  The `toggle` macro creates a boolean state field with a toggle action:

      # Instead of:
      state :active, :boolean
      optimistic_action :toggle, :active, run: fn v, _ -> !v end

      # Write:
      toggle :active

  ## Multi-Select

  The `multi_select` macro creates an array state field with a toggle-in-list action:

      # Instead of:
      state :selected, {:array, :string}
      optimistic_action :toggle, :selected,
        run: fn list, val ->
          if val in list, do: List.delete(list, val), else: list ++ [val]
        end

      # Write:
      multi_select :selected, [:option1, :option2, :option3]

  """

  @doc """
  Creates a boolean toggle state with an auto-generated toggle action.

  ## Options

  - `:default` - Default value (default: `false`)
  - `:from` - Storage location (default: `:parent` for components)

  ## Example

      toggle :active
      toggle :expanded, default: true

  Expands to:

      state :active, :boolean, default: false
      optimistic_action :toggle_active, :active, run: fn v, _ -> !v end
  """
  defmacro toggle(name, opts \\ []) do
    default = Keyword.get(opts, :default, false)
    action_name = :"toggle_#{name}"

    quote do
      # Register the state field
      @__lavash_toggle_states__ {unquote(name), unquote(default)}

      # Register the optimistic action
      @__lavash_optimistic_actions__ {
        unquote(action_name),
        unquote(name),
        "fn value, _ -> !value end",
        nil,
        nil
      }
    end
  end

  @doc """
  Creates an array state for multiple selection with a toggle action.

  ## Options

  - `:default` - Default selected values (default: `[]`)
  - `:from` - Storage location (default: `:parent` for components)

  ## Example

      multi_select :tags, [:red, :green, :blue]
      multi_select :sizes, [:small, :medium, :large], default: [:medium]

  Expands to:

      state :tags, {:array, :any}, default: []
      optimistic_action :toggle_tags, :tags,
        run: fn list, val ->
          if val in list, do: Enum.reject(list, &(&1 == val)), else: list ++ [val]
        end
  """
  defmacro multi_select(name, _values, opts \\ []) do
    default = Keyword.get(opts, :default, [])
    action_name = :"toggle_#{name}"

    quote do
      # Register the state field
      @__lavash_multi_select_states__ {unquote(name), unquote(Macro.escape(default))}

      # Register the optimistic action
      @__lavash_optimistic_actions__ {
        unquote(action_name),
        unquote(name),
        "fn list, val -> if val in list, do: Enum.reject(list, &(&1 == val)), else: list ++ [val] end",
        nil,
        nil
      }
    end
  end
end
