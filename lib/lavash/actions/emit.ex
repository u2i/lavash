defmodule Lavash.Actions.Emit do
  @moduledoc """
  Emits a value update for a bound prop.

  When the parent uses `bind:prop_name={:parent_field}`, the component can
  emit changes using `emit :prop_name, value`. This sends an update event
  to the parent which then updates its state.

  This follows Vue's v-model pattern where the child emits `update:propName`
  events.

  ## Example

      # Parent
      <.lavash_component
        module={Modal}
        id="modal"
        bind:product_id={:editing_product_id}
      />

      # Component
      prop :product_id, :integer

      actions do
        action :close do
          emit :product_id, nil  # Parent's editing_product_id becomes nil
        end
      end
  """
  defstruct [:prop, :value, __spark_metadata__: nil]
end
