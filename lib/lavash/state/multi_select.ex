defmodule Lavash.State.MultiSelect do
  @moduledoc """
  Represents a multi-select field declaration in the Lavash DSL.

  A multi-select is a convenience macro that generates:
  - A state field of type `{:array, :string}` with `optimistic: true`
  - A toggle action that adds/removes values from the array
  - A chip derive that computes CSS classes for each value

  ## Example

      multi_select :roast, ["light", "medium", "dark"], from: :url

  Generates equivalent to:

      state :roast, {:array, :string}, from: :url, default: [], optimistic: true

      derive :roast_chips do
        optimistic true
        argument :roast, state(:roast)
        run fn %{roast: selected}, _ ->
          Map.new(["light", "medium", "dark"], fn v -> {v, chip_class(v in selected)} end)
        end
      end

      action :toggle_roast, [:val] do
        set :roast, &toggle_in_list(&1.state.roast, &1.params.val)
      end
  """

  defstruct [
    :name,
    :values,
    :from,
    :default,
    :labels,
    :chip_class,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          values: [String.t()],
          from: :url | :socket | :ephemeral,
          default: [String.t()],
          labels: %{String.t() => String.t()},
          chip_class: keyword() | nil,
          __spark_metadata__: any()
        }
end

defmodule Lavash.State.Toggle do
  @moduledoc """
  Represents a boolean toggle field declaration in the Lavash DSL.

  A toggle is a convenience macro that generates:
  - A state field of type `:boolean` with `optimistic: true`
  - A toggle action that flips the boolean value
  - A chip derive that computes CSS class based on active state

  ## Example

      toggle :in_stock, from: :url

  Generates equivalent to:

      state :in_stock, :boolean, from: :url, default: false, optimistic: true

      derive :in_stock_chip do
        optimistic true
        argument :in_stock, state(:in_stock)
        run fn %{in_stock: active}, _ -> chip_class(active) end
      end

      action :toggle_in_stock do
        update :in_stock, &(not &1)
      end
  """

  defstruct [
    :name,
    :from,
    :default,
    :label,
    :chip_class,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          from: :url | :socket | :ephemeral,
          default: boolean(),
          label: String.t() | nil,
          chip_class: keyword() | nil,
          __spark_metadata__: any()
        }
end
