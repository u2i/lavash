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
            <button data-optimistic="remove" data-optimistic-field="tags" data-optimistic-value={tag}>×</button>
          </span>
          <input :if={@can_add} data-optimistic="add" data-optimistic-field="tags" />
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
  # Calculations - run on both client and server
  # ============================================

  # Note: calculate is handled separately via a macro, not Spark DSL,
  # because it requires AST quoting which Spark doesn't natively support.

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
    describe: "The component template, compiled to both HEEx and JS.",
    entities: [@template_entity]
  }

  # ============================================
  # Extension setup
  # ============================================

  use Spark.Dsl.Extension,
    sections: [
      @state_section,
      @props_section,
      @optimistic_actions_section,
      @template_section
    ],
    imports: [Lavash.Optimistic.Macros]
end

# Backwards compatibility alias
defmodule Lavash.ClientComponent.Bind do
  @moduledoc "Deprecated: Use Lavash.Component.State instead."
  defstruct [:name, :type, :from, :default, __spark_metadata__: nil]
end
