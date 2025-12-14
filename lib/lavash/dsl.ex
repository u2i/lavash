defmodule Lavash.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash LiveViews.

  Provides declarative state management with:
  - URL-backed state (bidirectional sync)
  - Ephemeral state (socket-only)
  - Derived state (computed with dependency tracking)
  - Assigns (projection to templates)
  - Actions (state transformers)
  """

  @url_field %Spark.Dsl.Entity{
    name: :field,
    target: Lavash.State.UrlField,
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
        doc: "The type of the field (:string, :integer, :boolean, :map, {:array, type})"
      ],
      default: [
        type: :any,
        doc: "Default value when not present in URL"
      ],
      required: [
        type: :boolean,
        default: false,
        doc: "Whether this field must be present in URL params"
      ],
      encode: [
        type: {:fun, 1},
        doc: "Custom encoder function for URL serialization"
      ],
      decode: [
        type: {:fun, 1},
        doc: "Custom decoder function from URL params"
      ]
    ]
  }

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

  @url_section %Spark.Dsl.Section{
    name: :url,
    describe: "URL-backed state fields. These are bidirectionally synced with URL params.",
    entities: [@url_field]
  }

  @ephemeral_section %Spark.Dsl.Section{
    name: :ephemeral,
    describe: "Ephemeral state fields. These live only in the socket and are lost on disconnect.",
    entities: [@ephemeral_field]
  }

  @socket_section %Spark.Dsl.Section{
    name: :socket,
    describe: "Socket state fields. Survive reconnects via JS sync but lost on page refresh. Not in URL.",
    entities: [@socket_field]
  }

  @state_section %Spark.Dsl.Section{
    name: :state,
    describe: "Define the state sources for this LiveView.",
    sections: [@url_section, @socket_section, @ephemeral_section]
  }

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
        doc: "List of state/derived fields this depends on"
      ],
      async: [
        type: :boolean,
        default: false,
        doc: "Whether this computation is async (returns loading/ok/error states)"
      ],
      compute: [
        type: {:fun, 1},
        required: true,
        doc: "Function that computes the derived value from dependencies"
      ]
    ]
  }

  @derived_section %Spark.Dsl.Section{
    name: :derived,
    describe: "Derived state computed from other state with dependency tracking.",
    entities: [@derived_field]
  }

  @assign_entity %Spark.Dsl.Entity{
    name: :assign,
    target: Lavash.Assigns.Assign,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The assign name (available in templates)"
      ],
      from: [
        type: {:list, :atom},
        doc: "Source fields to derive from. If not provided, passes through field of same name."
      ],
      transform: [
        type: {:fun, 1},
        doc: "Transform function applied to source(s)"
      ]
    ]
  }

  @assigns_section %Spark.Dsl.Section{
    name: :assigns,
    describe: "Projection of state/derived into socket assigns for templates.",
    entities: [@assign_entity]
  }

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

  use Spark.Dsl.Extension,
    sections: [@state_section, @derived_section, @assigns_section, @actions_section],
    imports: [Phoenix.Component]
end
