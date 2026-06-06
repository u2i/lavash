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
                      type: {:in, [:url, :socket, :session, :ephemeral, :assigns]},
                      default: :ephemeral,
                      doc:
                        "Storage location: :url (synced with URL), :socket (survives reconnects), :session (hydrated once from the Plug session at mount), :assigns (hydrated once from socket.assigns at mount — for values an on_mount put there, e.g. @current_user), :ephemeral (default)"
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
                      doc:
                        "Auto-generate a set_<name> action that sets this field from params.value"
                    ],
                    url_name: [
                      type: :string,
                      doc: """
                      URL/query-string key for `from: :url` fields.

                      Defaults to the field name as a string. Set this when the
                      query-string key needs to differ from the field name —
                      e.g. `state :subject_handle, :string, from: :url, url_name: "subject"`
                      hydrates from `?subject=alice`.
                      """
                    ],
                    session_key: [
                      type: :string,
                      doc: """
                      Session map key for `from: :session` fields.

                      Defaults to the field name as a string. Set this when the
                      session key needs to differ from the field name —
                      e.g. `state :handle, :string, from: :session, session_key: "user_handle"`
                      hydrates from `session["user_handle"]`.

                      Session fields are read once at mount and then behave
                      like ephemeral state for the rest of the LiveView's
                      life — the Plug session isn't reread.
                      """
                    ],
                    assigns_key: [
                      type: :atom,
                      doc: """
                      Source assign key for `from: :assigns` fields.

                      Defaults to the field name. Set this when the assigns
                      key on the socket differs from the lavash field name —
                      e.g. `state :user, :map, from: :assigns, assigns_key: :current_user`
                      hydrates from `socket.assigns.current_user`.

                      `from: :assigns` reads the named socket assign at mount
                      time (after any `on_mount` hooks have run, so the assigns
                      are present). One-way read: the field is not synced back
                      to socket.assigns if it mutates.
                      """
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

  @states_section %Spark.Dsl.Section{
    name: :states,
    top_level?: true,
    describe: "Mutable state from external sources (URL, socket, ephemeral).",
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
  # Actions - state transformers
  # ============================================

  @set_entity CommonEntities.set_entity()
  @pre_run_entity CommonEntities.pre_run_entity()
  @run_entity CommonEntities.run_entity()
  @map_by_entity CommonEntities.map_by_entity()
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

  @push_patch_entity %Spark.Dsl.Entity{
    name: :push_patch,
    target: Lavash.Actions.PushPatch,
    args: [:to],
    schema: [
      to: [
        type: :string,
        required: true,
        doc: "The URL to patch to (no remount; handle_params re-runs)"
      ]
    ]
  }

  @redirect_entity %Spark.Dsl.Entity{
    name: :redirect,
    target: Lavash.Actions.Redirect,
    args: [:to],
    schema: [
      to: [
        type: :string,
        required: true,
        doc: "The URL to redirect to (full-page reload)"
      ]
    ]
  }

  @push_event_entity %Spark.Dsl.Entity{
    name: :push_event,
    target: Lavash.Actions.PushEvent,
    args: [:name, :payload],
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "The client-side event name a JS hook will receive"
      ],
      payload: [
        # Accept any term — literal maps OR maps containing rx(...) values.
        # Validation of rx values happens at the per-key level at runtime.
        type: :any,
        required: true,
        doc: "Payload sent to the client (literal map, may contain rx() values)"
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
      pre_runs: [@pre_run_entity],
      runs: [@run_entity],
      map_bys: [@map_by_entity],
      effects: [@effect_entity],
      submits: [@submit_entity],
      navigates: [@navigate_entity],
      push_patches: [@push_patch_entity],
      redirects: [@redirect_entity],
      push_events: [@push_event_entity],
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
  # Extension setup
  # ============================================

  # Note: the template is handled by Lavash.Template.RenderMacro instead of a
  # Spark DSL entity. This enables `template do ~H"..." end` without Spark
  # entity conflicts.

  use Spark.Dsl.Extension,
    sections: [
      @states_section,
      @reads_section,
      @forms_section,
      @extend_errors_section,
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
      Lavash.LiveView.Transformers.CompileLiveView
    ],
    imports: [
      Phoenix.Component,
      Lavash.DslHelpers,
      Lavash.Rx,
      Lavash.Template.RenderMacro,
      Lavash.Lifecycle.MessagesMacro,
      Lavash.Lifecycle.AsyncMacro,
      Lavash.Lifecycle.MountMacro,
      Lavash.Lifecycle.OnMountImport,
      Lavash.Components.ComponentsMacro
    ]
end
