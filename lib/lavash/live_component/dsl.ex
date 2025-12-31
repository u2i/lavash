defmodule Lavash.LiveComponent.Dsl do
  @moduledoc """
  Spark DSL extension for Lavash LiveComponents.

  LiveComponents use SyncedVar for per-field optimistic state tracking.
  Unlike ClientComponent, they don't re-render HTML - they update individual
  values in a static DOM structure.
  """

  # ============================================
  # Synced - fields that sync to parent state
  # ============================================

  @synced_entity %Spark.Dsl.Entity{
    name: :synced,
    target: Lavash.LiveComponent.Synced,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The local name for this synced field"
      ],
      type: [
        type: :any,
        required: true,
        doc: "The type of the synced field"
      ]
    ]
  }

  @synced_section %Spark.Dsl.Section{
    name: :synced_fields,
    top_level?: true,
    describe: "Synced fields connect component-local names to parent state fields.",
    entities: [@synced_entity]
  }

  # ============================================
  # Props - read-only from parent
  # ============================================

  @prop_entity %Spark.Dsl.Entity{
    name: :prop,
    target: Lavash.LiveComponent.Prop,
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
  # Optimistic Actions
  # ============================================

  @optimistic_action_entity %Spark.Dsl.Entity{
    name: :optimistic_action,
    target: Lavash.LiveComponent.OptimisticAction,
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
    target: Lavash.LiveComponent.Template,
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
      @synced_section,
      @props_section,
      @optimistic_actions_section,
      @template_section
    ],
    imports: [Lavash.Optimistic.Macros]
end

# Entity structs
defmodule Lavash.LiveComponent.Synced do
  defstruct [:name, :type, __spark_metadata__: nil]
end

defmodule Lavash.LiveComponent.Prop do
  defstruct [:name, :type, :required, :default, __spark_metadata__: nil]
end

defmodule Lavash.LiveComponent.OptimisticAction do
  defstruct [:name, :field, :run, :run_source, __spark_metadata__: nil]
end

defmodule Lavash.LiveComponent.Template do
  defstruct [:source, __spark_metadata__: nil]
end
