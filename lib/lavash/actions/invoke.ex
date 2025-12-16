defmodule Lavash.Actions.Invoke do
  @moduledoc """
  Invokes an action on a child Lavash component.

  This allows parent LiveViews/components to imperatively trigger actions
  on child components, following the pattern common in native mobile frameworks.

  The child component must have the action defined in its actions block.

  ## Example

      # Parent LiveView
      actions do
        action :edit_product, [:product_id] do
          invoke "product-edit-modal", :open,
            module: DemoWeb.ProductEditModal,
            params: [product_id: param(:product_id)]
        end
      end

      # Child Component
      defmodule ProductEditModal do
        use Lavash.Component

        input :product_id, :integer, from: :ephemeral, default: nil
        input :open, :boolean, from: :ephemeral, default: false

        actions do
          action :open, [:product_id] do
            set :product_id, param(:product_id)
            set :open, true
          end
        end
      end
  """
  defstruct [:target, :action, :module, :params, __spark_metadata__: nil]
end
