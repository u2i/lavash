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

  alias Lavash.Dsl.CommonEntities

  # ============================================
  # State - mutable state fields
  # ============================================

  # LiveView state uses base schema + URL-specific options
  @state_schema CommonEntities.base_state_schema() ++
                  [
                    from: [
                      type: {:in, [:url, :socket, :ephemeral]},
                      default: :ephemeral,
                      doc:
                        "Storage location: :url (synced with URL), :socket (survives reconnects), :ephemeral (default)"
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
                    ]
                  ]

  @state_entity %Spark.Dsl.Entity{
    name: :state,
    target: Lavash.State.Field,
    args: [:name, :type],
    schema: @state_schema
  }

  # ============================================
  # Multi-select - convenience for array state with toggle action
  # ============================================

  @multi_select_entity %Spark.Dsl.Entity{
    name: :multi_select,
    target: Lavash.State.MultiSelect,
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
    target: Lavash.State.Toggle,
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

  # LiveView form extends base schema with skip_constraints
  @form_schema CommonEntities.base_form_schema() ++
                 [
                   skip_constraints: [
                     type: {:list, :atom},
                     default: [],
                     doc: """
                     Fields to skip constraint-based validation for in client-side optimistic updates.
                     Use when you want to handle validation entirely via extend_errors with custom logic.
                     The Ash resource constraints still apply server-side.

                     Example: skip_constraints [:card_number, :expiry, :cvv]
                     """
                   ]
                 ]

  @form_entity %Spark.Dsl.Entity{
    name: :form,
    target: Lavash.Form.Step,
    args: [:name, :resource],
    schema: @form_schema
  }

  @forms_section %Spark.Dsl.Section{
    name: :forms,
    top_level?: true,
    describe: "AshPhoenix.Form creation with auto create/update detection.",
    entities: [@form_entity]
  }

  # ============================================
  # Extend Errors - custom error extensions for form fields
  # ============================================

  @error_entity %Spark.Dsl.Entity{
    name: :error,
    target: Lavash.ExtendErrors.Error,
    args: [:condition, :message],
    schema: [
      condition: [
        type: {:struct, Lavash.Rx},
        required: true,
        doc: "Reactive expression that evaluates to true when the error should show"
      ],
      message: [
        type: {:or, [:string, {:struct, Lavash.Rx}]},
        required: true,
        doc: """
        The error message to display. Can be a static string or a dynamic rx() expression.

        Static message:
            error rx(@value < 0), "Must be positive"

        Dynamic message based on state:
            error rx(@cvv_length != 3), rx(if(@is_amex, do: "Amex requires 4 digits", else: "Must be 3 digits"))
        """
      ]
    ]
  }

  @extend_errors_entity %Spark.Dsl.Entity{
    name: :extend_errors,
    describe: """
    Extends auto-generated form field errors with custom validation checks.

    Use this to add validation rules beyond what Ash resource constraints provide.
    Custom errors are merged with Ash-generated errors and visibility is handled
    automatically based on the field's touched/submitted state.

    ## Examples

        extend_errors :registration_email_errors do
          error rx(not String.contains?(@registration_params["email"] || "", "@")), "Must contain @"
        end

    Multiple errors can be added:

        extend_errors :registration_password_errors do
          error rx(not String.match?(@registration_params["password"] || "", ~r/[A-Z]/)), "Must contain uppercase"
          error rx(not String.match?(@registration_params["password"] || "", ~r/[0-9]/)), "Must contain number"
        end
    """,
    target: Lavash.ExtendErrors,
    args: [:field],
    entities: [
      errors: [@error_entity]
    ],
    schema: [
      field: [
        type: :atom,
        required: true,
        doc: "The errors field to extend (e.g., :registration_email_errors)"
      ]
    ]
  }

  @extend_errors_section %Spark.Dsl.Section{
    name: :extend_errors_declarations,
    top_level?: true,
    describe: "Custom error extensions for form fields beyond Ash constraints.",
    entities: [@extend_errors_entity]
  }

  # ============================================
  # Calculate - reactive computed values (expression form)
  # ============================================

  # LiveView calculate uses base schema (which now includes async and reads)
  @calculate_schema CommonEntities.base_calculate_schema()

  @calculate_entity %Spark.Dsl.Entity{
    name: :calculate,
    describe: """
    Declares a calculated field computed from state using a reactive expression.

    Uses `rx()` to capture the expression, which is then transpiled to
    JavaScript for client-side optimistic updates. If the expression can't
    be transpiled, it falls back to server-only computation.

    ## Examples

        # Simple reactive calculation - transpiles to JS
        calculate :tag_count, rx(length(@tags))
        calculate :doubled, rx(@count * 2)

        # Server-only (explicit or auto-detected if not transpilable)
        calculate :complex, rx(my_helper(@data)), optimistic: false

        # Async calculation - returns AsyncResult (loading/ok/error)
        calculate :factorial, rx(compute_factorial(@n)), async: true

        # With resource invalidation
        calculate :total, rx(sum_items(@items)), reads: [Item]
    """,
    target: Lavash.Component.Calculate,
    args: [:name, :rx],
    schema: @calculate_schema
  }

  @calculations_section %Spark.Dsl.Section{
    name: :calculations,
    top_level?: true,
    describe: """
    Calculated fields derived from state using reactive expressions.

    Use `rx()` to wrap expressions that reference state via `@field` syntax.
    Calculations are automatically recomputed when their dependencies change
    and can be transpiled to JavaScript for optimistic client-side updates.
    """,
    entities: [@calculate_entity]
  }

  # ============================================
  # Derive - computed values (block form, server-only)
  # ============================================

  @argument_entity CommonEntities.derive_argument_entity()

  # LiveView derive extends base schema with reads and optimistic options
  @derive_schema CommonEntities.base_derive_schema() ++
                   [
                     reads: [
                       type: {:list, :atom},
                       default: [],
                       doc:
                         "Ash resources this derive reads from. Used for automatic invalidation when these resources are mutated."
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

  @derive_entity %Spark.Dsl.Entity{
    name: :derive,
    target: Lavash.Derived.Field,
    args: [:name],
    entities: [
      arguments: [@argument_entity]
    ],
    schema: @derive_schema
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

  @set_entity CommonEntities.set_entity()
  @run_entity CommonEntities.run_entity()
  @update_entity CommonEntities.update_entity()
  @effect_entity CommonEntities.effect_entity()
  @submit_entity CommonEntities.submit_entity()

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
      runs: [@run_entity],
      updates: [@update_entity],
      effects: [@effect_entity],
      submits: [@submit_entity],
      navigates: [@navigate_entity],
      flashes: [@flash_entity],
      invokes: [@invoke_entity]
    ],
    schema: CommonEntities.base_action_schema()
  }

  @actions_section %Spark.Dsl.Section{
    name: :actions,
    describe: "Actions transform state in response to events.",
    entities: [@action_entity]
  }

  # ============================================
  # Render - HEEx template function for render/1
  # ============================================

  @render_entity %Spark.Dsl.Entity{
    name: :render,
    describe: """
    Declares the render function for this LiveView.

    When using `render`, the framework generates the `render/1` callback automatically.
    You cannot define your own `render/1` when using this DSL.

    ## Example

        defmodule MyApp.CounterLive do
          use Lavash.LiveView

          state :count, :integer, from: :url, default: 0, optimistic: true

          actions do
            action :increment do
              set :count, rx(@count + 1)
            end
          end

          render fn assigns ->
            ~H\"""
            <div>
              <span>{@count}</span>
              <button phx-click="increment">+</button>
            </div>
            \"""
          end
        end
    """,
    target: Lavash.Component.Render,
    args: [:template],
    schema: [
      template: [
        type: {:fun, 1},
        required: true,
        doc: "Function (assigns) -> HEEx"
      ]
    ]
  }

  @render_section %Spark.Dsl.Section{
    name: :render_section,
    top_level?: true,
    describe: "Render function for the LiveView.",
    entities: [@render_entity]
  }

  # ============================================
  # Extension setup
  # ============================================

  use Spark.Dsl.Extension,
    sections: [
      @states_section,
      @reads_section,
      @forms_section,
      @extend_errors_section,
      @calculations_section,
      @derives_section,
      @actions_section,
      @render_section
    ],
    transformers: [
      Lavash.Transformers.DeprecateDerive,
      Lavash.Optimistic.ExpandAnimatedStates,
      Lavash.Optimistic.DefrxExpander,
      Lavash.Optimistic.ColocatedTransformer
    ],
    imports: [Phoenix.Component, Lavash.DslHelpers, Lavash.Rx, Lavash.Sigil]
end
