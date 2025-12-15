defmodule Lavash.Component.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash Components.

  Similar to Lavash.Dsl but for LiveComponents:
  - Props (from parent, read-only)
  - Socket state (survives reconnects, namespaced by component ID)
  - Ephemeral state (lost on reconnect)
  - Derived state
  - Actions

  All declared fields are automatically projected as assigns.
  """

  # Props - passed from parent
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
    describe: "Props passed from the parent. Read-only from the component's perspective.",
    entities: [@prop_entity]
  }

  # Socket state - survives reconnects
  @socket_field %Spark.Dsl.Entity{
    name: :field,
    target: Lavash.State.SocketField,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the field"
      ],
      type: [
        type: :any,
        required: true,
        doc: "The type of the field"
      ],
      default: [
        type: :any,
        doc: "Default value for this field"
      ]
    ]
  }

  # Ephemeral state - lost on reconnect
  @ephemeral_field %Spark.Dsl.Entity{
    name: :field,
    target: Lavash.State.EphemeralField,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the field"
      ],
      type: [
        type: :any,
        required: true,
        doc: "The type of the field"
      ],
      default: [
        type: :any,
        doc: "Default value for this field"
      ]
    ]
  }

  @socket_section %Spark.Dsl.Section{
    name: :socket,
    describe: "Socket state. Survives reconnects via JS sync, namespaced by component ID.",
    entities: [@socket_field]
  }

  @ephemeral_section %Spark.Dsl.Section{
    name: :ephemeral,
    describe: "Ephemeral state. Lost on reconnect.",
    entities: [@ephemeral_field]
  }

  @state_section %Spark.Dsl.Section{
    name: :state,
    describe: "Define the internal state for this component.",
    sections: [@socket_section, @ephemeral_section]
  }

  # Derived state
  @derived_field %Spark.Dsl.Entity{
    name: :field,
    target: Lavash.Derived.Field,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the derived field"
      ],
      depends_on: [
        type: {:list, :atom},
        required: true,
        doc: "List of props/state/derived fields this depends on"
      ],
      async: [
        type: :boolean,
        default: false,
        doc: "Whether this computation is async"
      ],
      compute: [
        type: {:fun, 1},
        required: true,
        doc: "Function that computes the derived value"
      ]
    ]
  }

  @derived_section %Spark.Dsl.Section{
    name: :derived,
    describe: "Derived state computed from props and internal state.",
    entities: [@derived_field]
  }

  # Actions
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

  use Spark.Dsl.Extension,
    sections: [@props_section, @state_section, @derived_section, @actions_section],
    imports: [Phoenix.Component]
end
