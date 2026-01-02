defmodule Lavash.ClientComponent.Dsl do
  @moduledoc """
  Spark DSL extension for Lavash ClientComponents.

  ClientComponents are optimistic UI components that render on both server and client.
  They generate JS hook code from templates at compile time.

  ## State Declaration

  Use `state` to declare fields that sync to parent state:

      state :tags, {:array, :string}
      state :active, :boolean

  The `bind` keyword is also supported for backwards compatibility.

  ## Example

      defmodule MyApp.TagEditor do
        use Lavash.ClientComponent

        # State connects to parent state (new syntax)
        state :tags, {:array, :string}

        # Props from parent (read-only)
        prop :placeholder, :string, default: "Add tag..."
        prop :max_tags, :integer

        # Calculations run on both client and server
        calculate :can_add, @max_tags == nil or length(@tags) < @max_tags
        calculate :tag_count, length(@tags)

        # Optimistic actions generate both client JS and server handlers
        optimistic_action :add, :tags,
          run: fn tags, tag -> tags ++ [tag] end,
          validate: fn tags, tag -> tag not in tags end,
          max: :max_tags

        optimistic_action :remove, :tags,
          run: fn tags, tag -> Enum.reject(tags, &(&1 == tag)) end

        # Template compiles to both HEEx and JS render function
        client_template \"\"\"
        <div>
          <span :for={tag <- @tags}>
            {tag}
            <button data-lavash-action="remove" data-lavash-state-field="tags" data-lavash-value={tag}>×</button>
          </span>
          <input :if={@can_add} data-lavash-action="add" data-lavash-state-field="tags" />
        </div>
        \"\"\"
      end
  """

  # ============================================
  # State - connect to parent state
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

  # Legacy `bind` entity (backwards compatibility)
  @bind_entity %Spark.Dsl.Entity{
    name: :bind,
    target: Lavash.Component.State,
    args: [:name, :type],
    schema: @state_schema
  }

  @state_section %Spark.Dsl.Section{
    name: :state_fields,
    top_level?: true,
    describe: "State fields connect component-local names to parent state fields.",
    entities: [@state_entity, @bind_entity]
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
  # Optimistic Actions - generate client + server handlers
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
        doc: "The state field this action operates on"
      ],
      run: [
        type: {:fun, 2},
        required: true,
        doc: """
        Function that transforms the field value.
        Receives (current_value, action_value) and returns new_value.
        Compiled to both Elixir and JavaScript.

        Example: fn tags, tag -> tags ++ [tag] end
        """
      ],
      run_source: [
        type: :string,
        doc: "Auto-generated source string for JS compilation."
      ],
      validate: [
        type: {:fun, 2},
        doc: """
        Optional validation function.
        Receives (current_value, action_value) and returns boolean.
        If false, action is skipped.

        Example: fn tags, tag -> tag not in tags end
        """
      ],
      validate_source: [
        type: :string,
        doc: "Auto-generated source string for JS compilation."
      ],
      max: [
        type: :atom,
        doc: "Optional prop/state field containing max length limit"
      ]
    ]
  }

  @optimistic_actions_section %Spark.Dsl.Section{
    name: :optimistic_actions,
    # top_level? is false - we use a custom macro from Lavash.ClientComponent.Macros
    # that captures the source code for JS compilation
    top_level?: false,
    describe: """
    Optimistic actions define state transformations that run on both client and server.

    The `run` function is compiled to both Elixir (for server) and JavaScript (for client),
    ensuring consistent behavior. The function receives the current field value and the
    action value, returning the new field value.

    Example:
        optimistic_action :add, :tags,
          run: fn tags, tag -> tags ++ [tag] end,
          validate: fn tags, tag -> tag not in tags end,
          max: :max_tags

        optimistic_action :remove, :tags,
          run: fn tags, tag -> Enum.reject(tags, & &1 == tag) end
    """,
    entities: [@optimistic_action_entity]
  }

  # ============================================
  # Template - compiles to HEEx + JS
  # ============================================

  @template_entity %Spark.Dsl.Entity{
    name: :template,
    describe: """
    Declares the HEEx template for this ClientComponent.

    The template is compiled to both HEEx (for server-side rendering) and JavaScript
    (for client-side optimistic updates). The framework generates the render/1 function
    automatically.

    ## Example

        template \"""
        <div>
          <span :for={tag <- @tags}>{tag}</span>
          <input data-lavash-action="add" />
        </div>
        \"""
    """,
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

  # Deprecated: Use `template` instead
  @client_template_entity %Spark.Dsl.Entity{
    name: :client_template,
    target: Lavash.Component.Template,
    args: [:source],
    schema: [
      source: [
        type: :string,
        required: true,
        doc: "The HEEx template source (deprecated: use `template` instead)"
      ],
      deprecated_name: [
        type: :atom,
        default: :client_template,
        hide: true,
        doc: "Internal: tracks deprecated entity name"
      ]
    ]
  }

  @template_section %Spark.Dsl.Section{
    name: :template,
    top_level?: true,
    describe: "The component template, compiled to both HEEx and JS.",
    entities: [@template_entity, @client_template_entity]
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
defmodule Lavash.ClientComponent.Bind do
  @moduledoc "Deprecated: Use Lavash.Component.State instead."
  defstruct [:name, :type, :from, :default, __spark_metadata__: nil]
end
