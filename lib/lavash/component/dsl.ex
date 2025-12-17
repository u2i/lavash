defmodule Lavash.Component.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash Components.

  Components have the same capabilities as LiveViews:
  - `prop` - passed from parent (read-only)
  - `state` - internal state (socket or ephemeral)
  - `read` - async load an Ash resource by ID
  - `form` - create an AshPhoenix.Form from a resource
  - `derive` - computed from props, state, and results
  - `actions` - state transformers with submit and notify_parent

  All declared fields are automatically projected as assigns.

  Example:
      defmodule MyApp.ProductEditModal do
        use Lavash.Component

        alias MyApp.Catalog.Product

        # Props from parent
        prop :product_id, :integer
        prop :on_close, :string, required: true
        prop :on_saved, :string, required: true

        # Internal state
        state :submitting, :boolean, from: :ephemeral, default: false

        # Load the product when product_id is set
        read :product, Product do
          id prop(:product_id)
        end

        # Form for editing
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
            notify_parent :on_saved
          end

          action :save_failed do
            set :submitting, false
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
  # State - internal mutable state
  # ============================================

  @state_entity %Spark.Dsl.Entity{
    name: :state,
    target: Lavash.StateField,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the state field"
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

  @states_section %Spark.Dsl.Section{
    name: :states,
    top_level?: true,
    describe: "Internal mutable state (socket or ephemeral).",
    entities: [@state_entity]
  }

  # ============================================
  # Read - async resource loading
  # ============================================

  @read_entity %Spark.Dsl.Entity{
    name: :read,
    target: Lavash.Read,
    args: [:name, :resource],
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
      id: [
        type: :any,
        required: true,
        doc: "The ID source: prop(:field), state(:field), or result(:derive)"
      ],
      action: [
        type: :atom,
        default: :read,
        doc: "The read action to use"
      ],
      async: [
        type: :boolean,
        default: true,
        doc: "Whether to load asynchronously"
      ]
    ]
  }

  @reads_section %Spark.Dsl.Section{
    name: :reads,
    top_level?: true,
    describe: "Async resource loading by ID.",
    entities: [@read_entity]
  }

  # ============================================
  # Form - AshPhoenix.Form creation
  # ============================================

  @form_entity %Spark.Dsl.Entity{
    name: :form,
    target: Lavash.FormStep,
    args: [:name, :resource],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the form"
      ],
      resource: [
        type: :atom,
        required: true,
        doc: "The Ash resource module"
      ],
      data: [
        type: :any,
        doc: "The record source: result(:read_name). If nil, creates a create form."
      ],
      params: [
        type: :any,
        doc: "The params source: state(:form_params). Defaults to implicit :name_params."
      ],
      create: [
        type: :atom,
        default: :create,
        doc: "The create action name"
      ],
      update: [
        type: :atom,
        default: :update,
        doc: "The update action name"
      ]
    ]
  }

  @forms_section %Spark.Dsl.Section{
    name: :forms,
    top_level?: true,
    describe: "AshPhoenix.Form creation with auto create/update detection.",
    entities: [@form_entity]
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
        doc: "The source: state(:field) or result(:derive_name)"
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

  @submit_entity %Spark.Dsl.Entity{
    name: :submit,
    target: Lavash.Actions.Submit,
    args: [:field],
    schema: [
      field: [
        type: :atom,
        required: true,
        doc: "The form field to submit (must be a form)"
      ],
      on_success: [
        type: :atom,
        doc: "Action to trigger after successful submission"
      ],
      on_error: [
        type: :atom,
        doc: "Action to trigger on submission error"
      ]
    ]
  }

  @notify_parent_entity %Spark.Dsl.Entity{
    name: :notify_parent,
    target: Lavash.Actions.NotifyParent,
    args: [:event],
    schema: [
      event: [
        type: :any,
        required: true,
        doc: "The event to send to parent - can be a string (prop name) or atom (literal event)"
      ]
    ]
  }

  @emit_entity %Spark.Dsl.Entity{
    name: :emit,
    target: Lavash.Actions.Emit,
    args: [:prop, :value],
    schema: [
      prop: [
        type: :atom,
        required: true,
        doc: "The prop name to emit an update for"
      ],
      value: [
        type: :any,
        required: true,
        doc: "The new value to emit (can be a literal or a function)"
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
      effects: [@effect_entity],
      submits: [@submit_entity],
      notify_parents: [@notify_parent_entity],
      emits: [@emit_entity]
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
    sections: [@props_section, @states_section, @reads_section, @forms_section, @derives_section, @actions_section],
    imports: [Phoenix.Component, Lavash.DslHelpers]
end
