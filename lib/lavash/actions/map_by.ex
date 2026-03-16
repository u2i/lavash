defmodule Lavash.Actions.MapBy do
  @moduledoc """
  Maps over an array field, finding items by a key field and applying a transformation.

  Used for key-based array mutations like updating a specific cart item's quantity.

  ## Examples

      # Increment quantity of item with matching id
      map_by :items, :id, rx(%{@item | quantity: @item.quantity + 1})

      # Remove item (return :remove to filter it out)
      map_by :items, :id, rx(:remove)

      # Conditional: decrement or remove if quantity reaches 0
      map_by :items, :id, rx(
        if @item.quantity <= 1, do: :remove, else: %{@item | quantity: @item.quantity - 1}
      )

  The `@item` variable references the matched item in the rx() expression.
  The key value comes from the action's params (phx-value-id="abc").
  """
  defstruct [
    :field,
    :key,
    :transform,
    :source,
    :deps,
    __spark_metadata__: nil
  ]
end
