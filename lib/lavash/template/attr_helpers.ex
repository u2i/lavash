defmodule Lavash.Template.AttrHelpers do
  @moduledoc """
  Small helpers for manipulating the attribute list shape that
  `Lavash.TagEngine` produces.

  Attributes come as tuples of `{name, value, meta}` where `value`
  is `{:string, content, meta}` | `{:expr, code, meta}` | `nil`.
  Spread attrs use `{:root, value, meta}` and have no string name —
  the helpers below treat those as pass-through (they only check
  named attrs).

  ## Why a separate module

  Extracted from the original 800-line `Lavash.Template.TokenTransformer`
  so the new single-purpose sub-transformers can share the helpers
  without anyone owning a dependency on the old monolith.
  """

  @doc """
  Returns true if any non-`:root` attribute matches `name`.
  """
  def has_attr?(attrs, name) do
    Enum.any?(attrs, fn
      {^name, _value, _meta} -> true
      _ -> false
    end)
  end

  @doc """
  Returns the value tuple for the named attribute, or nil if missing.
  """
  def get_attr_value(attrs, name) do
    case Enum.find(attrs, fn
           {^name, _value, _meta} -> true
           _ -> false
         end) do
      {_name, value, _meta} -> value
      nil -> nil
    end
  end

  @doc """
  Removes any attribute matching `name`. Spread attrs are kept.
  """
  def reject_attr(attrs, name) do
    Enum.reject(attrs, fn
      {^name, _value, _meta} -> true
      _ -> false
    end)
  end

  @doc """
  Appends `{name, value, meta}` to `attrs` unless an attribute by
  that name already exists. Used to inject `data-lavash-*` attrs
  without overwriting any the user wrote by hand.

  `value` can be `{:string, "foo"}` (gets default meta wrapped) or
  `{:expr, "@foo"}` (gets passed through with meta).
  """
  def add_attr_if_missing(attrs, name, value) do
    if has_attr?(attrs, name) do
      attrs
    else
      attr_meta = %{line: 1, column: 1}
      value_with_meta = wrap_value_with_meta(value, attr_meta)
      attrs ++ [{name, value_with_meta, attr_meta}]
    end
  end

  defp wrap_value_with_meta({:string, value}, _meta) do
    {:string, value, %{delimiter: ?", line: 1, column: 1}}
  end

  defp wrap_value_with_meta({:expr, value}, meta), do: {:expr, value, meta}
  defp wrap_value_with_meta(value, _meta), do: value
end
