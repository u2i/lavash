defmodule Lavash.Component.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash Components.

  Components have the same capabilities as LiveViews:
  - `prop` - passed from parent (read-only)
  - `state` - internal state (socket or ephemeral)
  - `read` - async load an Ash resource by ID
  - `form` - create an AshPhoenix.Form from a resource
  - `calculate` - reactive computed value via rx()
  - `actions` - state transformers (set, run, update, effect, submit)

  All declared fields are automatically projected as assigns.

  Example:
      defmodule MyApp.ProductEditModal do
        use Lavash.Component

        alias MyApp.Catalog.Product

        prop :product_id, :integer

        state :submitting, :boolean, default: false

        read :product, Product do
          id prop(:product_id)
        end

        form :edit_form, Product do
          data result(:product)
        end

        actions do
          action :save do
            set :submitting, true
            submit :edit_form, on_success: :save_success, on_error: :save_failed
          end

          action :save_success do
            set :submitting, false
          end

          action :save_failed do
            set :submitting, false
          end
        end
      end
  """

  alias Lavash.Dsl.CommonEntities

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
  # State - internal mutable state
  # ============================================

  # Component state uses base schema + from option (no URL support)
  @state_schema CommonEntities.base_state_schema() ++
                  [
                    from: [
                      type: {:one_of, [:socket, :ephemeral]},
                      default: :ephemeral,
                      doc:
                        "Where to store: :socket (survives reconnects) or :ephemeral (socket only)"
                    ]
                  ]

  @state_entity %Spark.Dsl.Entity{
    name: :state,
    target: Lavash.State.Field,
    args: [:name, :type],
    schema: @state_schema
  }

  @states_section %Spark.Dsl.Section{
    name: :states,
    top_level?: true,
    describe: "Internal mutable state (socket or ephemeral).",
    entities: [@state_entity]
  }

  # ============================================
  # Read - async resource loading
  # ============================================

  @read_argument_entity CommonEntities.read_argument_entity()

  @read_entity %Spark.Dsl.Entity{
    name: :read,
    target: Lavash.Read,
    args: [:name, :resource, {:optional, :action}],
    entities: [
      arguments: [@read_argument_entity]
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the read result"
      ],
      resource: [
        type: :atom,
        required: true,
        doc: "The Ash resource module to load"
      ],
      action: [
        type: :atom,
        doc: "The read action to use. Defaults to :read for get-by-id."
      ],
      id: [
        type: :any,
        doc: "The ID source for get-by-id: prop(:field), state(:field), or result(:derive)"
      ],
      async: [
        type: :boolean,
        default: true,
        doc: "Whether to load asynchronously"
      ],
      as_options: [
        type: :keyword_list,
        doc: """
        Transform results into dropdown options format [{label, value}, ...].
        Specify label: :field_name and value: :field_name (default :id).
        Example: as_options label: :name, value: :id
        """
      ],
      invalidate_on: [
        type: {:list, :atom},
        doc: """
        List of resource attributes to watch for fine-grained invalidation.
        When a record's attribute changes, this read will refresh if filtering
        by that attribute. Broadcasts to both old and new values to handle
        both additions and removals.

        Example: invalidate_on [:category_id, :in_stock]
        """
      ]
    ]
  }

  @reads_section %Spark.Dsl.Section{
    name: :reads,
    top_level?: true,
    describe: "Async Ash resource loading. Auto-maps state fields to action arguments by name.",
    entities: [@read_entity]
  }

  # ============================================
  # Form - AshPhoenix.Form creation
  # ============================================

  @form_entity %Spark.Dsl.Entity{
    name: :form,
    target: Lavash.Form.Step,
    args: [:name, :resource],
    schema: CommonEntities.base_form_schema()
  }

  @forms_section %Spark.Dsl.Section{
    name: :forms,
    top_level?: true,
    describe: "AshPhoenix.Form creation with auto create/update detection.",
    entities: [@form_entity]
  }

  # ============================================
  # Actions - state transformers
  # ============================================

  # Use shared action sub-entities
  @set_entity CommonEntities.set_entity()
  @pre_run_entity CommonEntities.pre_run_entity()
  @run_entity CommonEntities.run_entity()
  @map_by_entity CommonEntities.map_by_entity()
  @effect_entity CommonEntities.effect_entity()
  @submit_entity CommonEntities.submit_entity()

  @action_entity %Spark.Dsl.Entity{
    name: :action,
    target: Lavash.Actions.Action,
    args: [:name, {:optional, :params}, {:optional, :when}],
    entities: [
      sets: [@set_entity],
      pre_runs: [@pre_run_entity],
      runs: [@run_entity],
      map_bys: [@map_by_entity],
      effects: [@effect_entity],
      submits: [@submit_entity]
    ],
    schema: CommonEntities.base_action_schema()
  }

  @actions_section %Spark.Dsl.Section{
    name: :actions,
    describe: "Actions transform internal state in response to events.",
    entities: [@action_entity]
  }

  # ============================================
  # Calculate - reactive computed values
  # ============================================

  @calculate_entity %Spark.Dsl.Entity{
    name: :calculate,
    describe: """
    Declares a calculated field computed from state using a reactive expression.

    Uses `rx()` to capture the expression, which is then transpiled to
    JavaScript for client-side optimistic updates.

    ## Examples

        calculate :is_open, rx(@product_id != nil)
        calculate :tag_count, rx(length(@tags))
    """,
    target: Lavash.Component.Calculate,
    args: [:name, :rx],
    schema: CommonEntities.base_calculate_schema()
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
  # Extension setup
  # ============================================

  use Spark.Dsl.Extension,
    sections: [
      @props_section,
      @states_section,
      @reads_section,
      @forms_section,
      @calculations_section,
      @actions_section
    ],
    transformers: [
      Lavash.Optimistic.Transformers.ExpandAnimatedStates,
      Lavash.Optimistic.Transformers.ExpandDefrx,
      Lavash.Transformers.ExpandFields,
      Lavash.Transformers.ValidateDsl,
      Lavash.Component.Transformers.TokenizeTemplate,
      Lavash.Component.Transformers.AnalyzeTemplate,
      Lavash.Optimistic.Transformers.AnalyzeOptimisticTemplate,
      Lavash.Transformers.ValidateTemplate,
      Lavash.Optimistic.Transformers.ExtractColocatedJs,
      Lavash.Component.Transformers.CompileComponent
    ],
    imports: [
      Phoenix.Component,
      Lavash.DslHelpers,
      Lavash.Rx,
      Lavash.Component.RenderImport
    ]
end
