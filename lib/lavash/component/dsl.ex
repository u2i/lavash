defmodule Lavash.Component.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash Components.

  Similar to Lavash.Dsl but for LiveComponents:
  - `prop` - passed from parent (read-only)
  - `input` - internal state (socket or ephemeral)
  - `derive` - computed from props and state
  - `actions` - state transformers

  All declared fields are automatically projected as assigns.

  Example:
      defmodule MyApp.ProductCard do
        use Lavash.Component

        prop :product, :map, required: true
        prop :on_click, :any

        input :expanded, :boolean, from: :ephemeral, default: false

        derive :display_price do
          argument :product, input(:product)
          run fn %{product: p}, _ -> format_price(p.price) end
        end

        actions do
          action :toggle_expand do
            update :expanded, &(!&1)
          end
        end
      end
  """

  # ============================================
  # Props - passed from parent
  # ============================================

  @prop_entity %Spark.Dsl.Entity{
    name: :prop,
    target: Lavash.Component.Prop,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the prop"
      ],
      type: [
        type: :any,
        required: true,
        doc: "The type of the prop"
      ],
      required: [
        type: :boolean,
        default: false,
        doc: "Whether this prop is required"
      ],
      default: [
        type: :any,
        doc: "Default value if not provided"
      ]
    ]
  }

  @props_section %Spark.Dsl.Section{
    name: :props,
    top_level?: true,
    describe: "Props passed from the parent. Read-only from the component's perspective.",
    entities: [@prop_entity]
  }

  # ============================================
  # Input - internal mutable state
  # ============================================

  @input_entity %Spark.Dsl.Entity{
    name: :input,
    target: Lavash.Input,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the input field"
      ],
      type: [
        type: :any,
        required: true,
        doc: "The type of the field"
      ],
      from: [
        type: {:one_of, [:socket, :ephemeral]},
        default: :ephemeral,
        doc: "Where to store: :socket (survives reconnects) or :ephemeral (socket only)"
      ],
      default: [
        type: :any,
        doc: "Default value when not present"
      ]
    ]
  }

  @inputs_section %Spark.Dsl.Section{
    name: :inputs,
    top_level?: true,
    describe: "Internal mutable state (socket or ephemeral).",
    entities: [@input_entity]
  }

  # ============================================
  # Derive - computed values
  # ============================================

  @argument_entity %Spark.Dsl.Entity{
    name: :argument,
    target: Lavash.Argument,
    args: [:name, :source],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the argument (key in the deps map passed to run)"
      ],
      source: [
        type: :any,
        required: true,
        doc: "The source: input(:field) or result(:derive_name)"
      ]
    ]
  }

  @derive_entity %Spark.Dsl.Entity{
    name: :derive,
    target: Lavash.Derived.Field,
    args: [:name],
    entities: [
      arguments: [@argument_entity]
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the derived field"
      ],
      async: [
        type: :boolean,
        default: false,
        doc: "Whether this computation is async"
      ],
      run: [
        type: {:fun, 2},
        doc: "Function that computes the value: fn %{arg1: val1, ...}, context -> result end"
      ]
    ]
  }

  @derives_section %Spark.Dsl.Section{
    name: :derives,
    top_level?: true,
    describe: "Derived values computed from props and internal state.",
    entities: [@derive_entity]
  }

  # ============================================
  # Actions - state transformers
  # ============================================

  @set_entity %Spark.Dsl.Entity{
    name: :set,
    target: Lavash.Actions.Set,
    args: [:field, :value],
    schema: [
      field: [
        type: :atom,
        required: true,
        doc: "The field to set"
      ],
      value: [
        type: :any,
        required: true,
        doc: "The value or function to set"
      ]
    ]
  }

  @update_entity %Spark.Dsl.Entity{
    name: :update,
    target: Lavash.Actions.Update,
    args: [:field, :fun],
    schema: [
      field: [
        type: :atom,
        required: true,
        doc: "The field to update"
      ],
      fun: [
        type: {:fun, 1},
        required: true,
        doc: "Function that transforms the current value"
      ]
    ]
  }

  @effect_entity %Spark.Dsl.Entity{
    name: :effect,
    target: Lavash.Actions.Effect,
    args: [:fun],
    schema: [
      fun: [
        type: {:fun, 1},
        required: true,
        doc: "Side effect function"
      ]
    ]
  }

  @action_entity %Spark.Dsl.Entity{
    name: :action,
    target: Lavash.Actions.Action,
    args: [:name, {:optional, :params}, {:optional, :when}],
    entities: [
      sets: [@set_entity],
      updates: [@update_entity],
      effects: [@effect_entity]
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The action name"
      ],
      params: [
        type: {:list, :atom},
        default: [],
        doc: "Expected params from the event"
      ],
      when: [
        type: {:list, :atom},
        default: [],
        doc: "Guard conditions"
      ]
    ]
  }

  @actions_section %Spark.Dsl.Section{
    name: :actions,
    describe: "Actions transform internal state in response to events.",
    entities: [@action_entity]
  }

  # ============================================
  # Extension setup
  # ============================================

  use Spark.Dsl.Extension,
    sections: [@props_section, @inputs_section, @derives_section, @actions_section],
    imports: [Phoenix.Component, Lavash.DslHelpers]
end
