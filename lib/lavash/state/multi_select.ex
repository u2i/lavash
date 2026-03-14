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

      calculate :roast_chips, rx(build_chips(@roast, ["light", "medium", "dark"]))

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

      calculate :in_stock_chip, rx(chip_class(@in_stock))

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
