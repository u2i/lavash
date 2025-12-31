defmodule Lavash.LiveComponent.Dsl do
  @moduledoc """
  Spark DSL extension for Lavash LiveComponents.

  LiveComponents use SyncedVar for per-field optimistic state tracking.
  Unlike ClientComponent, they don't re-render HTML - they update individual
  values in a static DOM structure.

  ## State Declaration

  Use `state` to declare fields that sync to parent state:

      state :value, :boolean
      state :tags, {:array, :string}

  The `synced` keyword is also supported for backwards compatibility.
  """

  # ============================================
  # State - fields that sync to parent state
  # (unified naming across component types)
  # ============================================

  @state_schema [
    name: [
      type: :atom,
      required: true,
      doc: "The local name for this state field"
    ],
    type: [
      type: :any,
      required: true,
      doc: "The type of the state field"
    ],
    from: [
      type: {:in, [:parent]},
      default: :parent,
      doc: "Storage location (always :parent for components)"
    ],
    default: [
      type: :any,
      doc: "Default value if not provided by parent"
    ]
  ]

  # New unified `state` entity
  @state_entity %Spark.Dsl.Entity{
    name: :state,
    target: Lavash.Component.State,
    args: [:name, :type],
    schema: @state_schema
  }

  # Legacy `synced` entity (backwards compatibility)
  @synced_entity %Spark.Dsl.Entity{
    name: :synced,
    target: Lavash.Component.State,
    args: [:name, :type],
    schema: @state_schema
  }

  @state_section %Spark.Dsl.Section{
    name: :state_fields,
    top_level?: true,
    describe: "State fields connect component-local names to parent state fields.",
    entities: [@state_entity, @synced_entity]
  }

  # ============================================
  # Props - read-only from parent
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
  # Calculate - reactive computed values
  # ============================================

  @calculate_entity %Spark.Dsl.Entity{
    name: :calculate,
    describe: """
    Declares a calculated field computed from state.

    Uses `rx()` to capture the expression, which is then transpiled to
    JavaScript for client-side optimistic updates.

    ## Examples

        calculate :tag_count, rx(length(@tags))
        calculate :can_add, rx(@max == nil or length(@items) < @max)
        calculate :doubled, rx(@count * 2)

    For server-only calculations that can't be transpiled:

        calculate :complex, rx(some_function(@data)), optimistic: false
    """,
    target: Lavash.Component.Calculate,
    args: [:name, :rx],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the calculated field"
      ],
      rx: [
        type: {:struct, Lavash.Rx},
        required: true,
        doc: "The reactive expression wrapped in rx()"
      ],
      optimistic: [
        type: :boolean,
        default: true,
        doc: """
        Whether to transpile to JavaScript for client-side updates.
        Set to false for expressions that can't be transpiled.
        """
      ]
    ]
  }

  @calculations_section %Spark.Dsl.Section{
    name: :calculations,
    top_level?: true,
    describe: """
    Calculated fields derived from state using reactive expressions.

    Use `rx()` to wrap expressions that reference state via `@field` syntax.
    Calculations are automatically recomputed when their dependencies change.
    """,
    entities: [@calculate_entity]
  }

  # ============================================
  # Optimistic Actions
  # ============================================

  @optimistic_action_entity %Spark.Dsl.Entity{
    name: :optimistic_action,
    target: Lavash.Component.OptimisticAction,
    args: [:name, :field],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The action name (used for event routing)"
      ],
      field: [
        type: :atom,
        required: true,
        doc: "The synced field this action operates on"
      ],
      run: [
        type: {:fun, 2},
        required: true,
        doc: """
        Function that transforms the field value.
        Receives (current_value, action_value) and returns new_value.
        """
      ],
      run_source: [
        type: :string,
        doc: "Auto-generated source string for JS compilation."
      ]
    ]
  }

  @optimistic_actions_section %Spark.Dsl.Section{
    name: :optimistic_actions,
    top_level?: false,
    describe: "Optimistic actions define state transformations.",
    entities: [@optimistic_action_entity]
  }

  # ============================================
  # Template - compiles to HEEx + JS
  # ============================================

  @template_entity %Spark.Dsl.Entity{
    name: :client_template,
    target: Lavash.Component.Template,
    args: [:source],
    schema: [
      source: [
        type: :string,
        required: true,
        doc: "The HEEx template source"
      ]
    ]
  }

  @template_section %Spark.Dsl.Section{
    name: :template,
    top_level?: true,
    describe: "The component template, compiled to both HEEx and JS with auto-generated data-synced-* attributes.",
    entities: [@template_entity]
  }

  # ============================================
  # Extension setup
  # ============================================

  use Spark.Dsl.Extension,
    sections: [
      @state_section,
      @props_section,
      @calculations_section,
      @optimistic_actions_section,
      @template_section
    ],
    imports: [Lavash.Rx, Lavash.Optimistic.ActionMacro]
end

# Backwards compatibility alias
defmodule Lavash.LiveComponent.Synced do
  @moduledoc "Deprecated: Use Lavash.Component.State instead."
  defstruct [:name, :type, :from, :default, __spark_metadata__: nil]
end
