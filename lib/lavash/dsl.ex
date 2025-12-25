defmodule Lavash.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash LiveViews.

  Provides declarative state management with Reactor-inspired syntax:
  - `state` - mutable state from external sources (URL, socket, ephemeral)
  - `read` - async load an Ash resource by ID
  - `form` - create an AshPhoenix.Form from a resource
  - `derive` - custom computed values
  - `actions` - state transformers

  All declared fields are automatically projected as assigns.

  ## State

  State fields are mutable state from external sources:

      state :product_id, :integer, from: :url
      state :form_params, :map, from: :ephemeral, default: %{}

  ## Read

  Load an Ash resource by ID (async by default):

      read :product, Product do
        id state(:product_id)
      end

  ## Form

  Create an AshPhoenix.Form that auto-detects create vs update:

      form :form, Product do
        data result(:product)
      end

  Form params are implicit - `:form_params` is auto-created and bound to `phx-change` events.
  You can override with explicit params if needed: `params state(:custom_params)`

  ## Example

      defmodule MyApp.ProductEditLive do
        use Lavash.LiveView

        state :product_id, :integer, from: :url

        read :product, Product do
          id state(:product_id)
        end

        form :form, Product do
          data result(:product)
        end

        actions do
          action :save do
            submit :form
            navigate "/products"
          end
        end
      end
  """

  # ============================================
  # State - mutable state fields
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
        doc: "The type: :string, :integer, :boolean, :float, :map, :any, etc."
      ],
      from: [
        type: {:in, [:url, :socket, :ephemeral]},
        default: :ephemeral,
        doc:
          "Storage location: :url (synced with URL), :socket (survives reconnects), :ephemeral (default)"
      ],
      default: [
        type: :any,
        doc: "Default value when not present"
      ],
      required: [
        type: :boolean,
        default: false,
        doc: "Whether this field must be present (for URL state)"
      ],
      encode: [
        type: {:fun, 1},
        doc: "Custom encoder function for URL serialization"
      ],
      decode: [
        type: {:fun, 1},
        doc: "Custom decoder function from URL params"
      ],
      setter: [
        type: :boolean,
        default: false,
        doc: "Auto-generate a set_<name> action that sets this field from params.value"
      ],
      optimistic: [
        type: :boolean,
        default: false,
        doc: """
        Enable optimistic updates with version tracking (socket fields only).
        When true, client-side state changes are applied immediately while the
        server request is in flight. Stale responses are automatically ignored.
        Useful for UI state like modal open/close that needs to feel instant.
        """
      ]
    ]
  }

  # ============================================
  # Multi-select - convenience for array state with toggle action
  # ============================================

  @multi_select_entity %Spark.Dsl.Entity{
    name: :multi_select,
    target: Lavash.MultiSelect,
    args: [:name, :values],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the multi-select field"
      ],
      values: [
        type: {:list, :string},
        required: true,
        doc: "The list of possible values"
      ],
      from: [
        type: {:in, [:url, :socket, :ephemeral]},
        default: :ephemeral,
        doc: "Storage location: :url, :socket, or :ephemeral"
      ],
      default: [
        type: {:list, :string},
        default: [],
        doc: "Default selected values"
      ],
      labels: [
        type: {:map, :string, :string},
        default: %{},
        doc: "Map of value to display label, e.g. %{\"medium_dark\" => \"Med-Dark\"}"
      ],
      chip_class: [
        type: :keyword_list,
        doc: """
        Custom chip class configuration. Keyword list with:
        - base: base classes for all chips
        - active: classes when selected
        - inactive: classes when not selected
        """
      ]
    ]
  }

  # ============================================
  # Toggle - convenience for boolean state with toggle action
  # ============================================

  @toggle_entity %Spark.Dsl.Entity{
    name: :toggle,
    target: Lavash.Toggle,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the toggle field"
      ],
      from: [
        type: {:in, [:url, :socket, :ephemeral]},
        default: :ephemeral,
        doc: "Storage location: :url, :socket, or :ephemeral"
      ],
      default: [
        type: :boolean,
        default: false,
        doc: "Default value"
      ],
      label: [
        type: :string,
        doc: "Display label for the toggle"
      ],
      chip_class: [
        type: :keyword_list,
        doc: "Custom chip class configuration (same as multi_select)"
      ]
    ]
  }

  @states_section %Spark.Dsl.Section{
    name: :states,
    top_level?: true,
    describe: "Mutable state from external sources (URL, socket, ephemeral).",
    entities: [@state_entity, @multi_select_entity, @toggle_entity]
  }

  # ============================================
  # Read - async resource loading
  # ============================================

  @read_argument_entity %Spark.Dsl.Entity{
    name: :argument,
    target: Lavash.Read.Argument,
    args: [:name, {:optional, :source}],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The action argument name to override"
      ],
      source: [
        type: :any,
        doc: "The source: state(:field) or result(:derive). If omitted, uses state(name)."
      ],
      transform: [
        type: {:fun, 1},
        doc: "Optional transform function applied to the value before passing to action"
      ]
    ]
  }

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
        doc: "The ID source for get-by-id reads: state(:field) or result(:derive)"
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
      invalidate: [
        type: {:in, [:pubsub]},
        doc: """
        Enable fine-grained PubSub invalidation for this read.
        When set to :pubsub, uses the resource's `notify_on` configuration
        to subscribe to combination topics based on current filter values.

        Example: invalidate :pubsub
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
    args: [:name, {:optional, :source}],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the argument (key in the deps map passed to run)"
      ],
      source: [
        type: :any,
        doc:
          "The source: state(:field) or result(:derive_name). Defaults to state(name) if omitted."
      ],
      transform: [
        type: {:fun, 1},
        doc: "Optional transform function applied to the value before passing to run"
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
        doc: "Whether this computation is async (returns loading/ok/error states)"
      ],
      reads: [
        type: {:list, :atom},
        default: [],
        doc:
          "Ash resources this derive reads from. Used for automatic invalidation when these resources are mutated."
      ],
      run: [
        type: {:fun, 2},
        doc: "Function that computes the value: fn %{arg1: val1, ...}, context -> result end"
      ],
      optimistic: [
        type: :boolean,
        default: false,
        doc: """
        Include this derive in optimistic state for client-side computation.
        When true, this field will be included in the optimistic state passed to the
        client hook, allowing client-side JavaScript to recompute the value immediately.
        """
      ]
    ]
  }

  @derives_section %Spark.Dsl.Section{
    name: :derives,
    top_level?: true,
    describe: "Derived values computed from state or other derivations.",
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
        doc: "Side effect function receiving current state"
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
        doc: "The form field to submit (must be a derived AshPhoenix.Form)"
      ],
      on_success: [
        type: :atom,
        doc: "Action to trigger after successful submission (for post-submit state changes)"
      ],
      on_error: [
        type: :atom,
        doc: "Action to trigger on submission error"
      ]
    ]
  }

  @navigate_entity %Spark.Dsl.Entity{
    name: :navigate,
    target: Lavash.Actions.Navigate,
    args: [:to],
    schema: [
      to: [
        type: :string,
        required: true,
        doc: "The URL to navigate to"
      ]
    ]
  }

  @flash_entity %Spark.Dsl.Entity{
    name: :flash,
    target: Lavash.Actions.Flash,
    args: [:kind, :message],
    schema: [
      kind: [
        type: :atom,
        required: true,
        doc: "Flash kind (:info, :error, etc.)"
      ],
      message: [
        type: :string,
        required: true,
        doc: "The flash message"
      ]
    ]
  }

  @invoke_entity %Spark.Dsl.Entity{
    name: :invoke,
    target: Lavash.Actions.Invoke,
    args: [:target, :action],
    schema: [
      target: [
        type: {:or, [:atom, :string]},
        required: true,
        doc: "The component ID to invoke the action on"
      ],
      action: [
        type: :atom,
        required: true,
        doc: "The action name to invoke"
      ],
      module: [
        type: :atom,
        required: true,
        doc: "The component module"
      ],
      params: [
        type: :keyword_list,
        default: [],
        doc: "Parameters to pass to the action"
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
      navigates: [@navigate_entity],
      flashes: [@flash_entity],
      invokes: [@invoke_entity]
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The action name (used in handle_event)"
      ],
      params: [
        type: {:list, :atom},
        default: [],
        doc: "Expected params from the event"
      ],
      when: [
        type: {:list, :atom},
        default: [],
        doc: "Guard conditions - derived boolean fields that must be true"
      ]
    ]
  }

  @actions_section %Spark.Dsl.Section{
    name: :actions,
    describe: "Actions transform state in response to events.",
    entities: [@action_entity]
  }

  # ============================================
  # Extension setup
  # ============================================

  use Spark.Dsl.Extension,
    sections: [
      @states_section,
      @reads_section,
      @forms_section,
      @derives_section,
      @actions_section
    ],
    transformers: [],
    imports: [Phoenix.Component, Lavash.DslHelpers]
end
