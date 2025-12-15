defmodule Lavash.Dsl do
  @moduledoc """
  The Spark DSL extension for Lavash LiveViews.

  Provides declarative state management with Reactor-inspired syntax:
  - `input` - mutable state from external sources (URL, socket, ephemeral)
  - `read` - async load an Ash resource by ID
  - `form` - create an AshPhoenix.Form from a resource
  - `derive` - custom computed values
  - `actions` - state transformers

  All declared fields are automatically projected as assigns.

  ## Inputs

  Inputs are mutable state from external sources:

      input :product_id, :integer, from: :url
      input :form_params, :map, from: :ephemeral, default: %{}

  ## Read

  Load an Ash resource by ID (async by default):

      read :product, Product do
        id input(:product_id)
      end

  ## Form

  Create an AshPhoenix.Form that auto-detects create vs update:

      form :form, Product do
        data result(:product)
        params input(:form_params)
      end

  ## Example

      defmodule MyApp.ProductEditLive do
        use Lavash.LiveView

        input :product_id, :integer, from: :url
        input :form_params, :map, from: :ephemeral, default: %{}

        read :product, Product do
          id input(:product_id)
        end

        form :form, Product do
          data result(:product)
          params input(:form_params)
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
  # Input - mutable state fields
  # ============================================

  @input_entity %Spark.Dsl.Entity{
    name: :input,
    target: Lavash.Input,
    args: [:name, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the input field"
      ],
      type: [
        type: :any,
        required: true,
        doc: "The type: :string, :integer, :boolean, :float, :map, :any, etc."
      ],
      from: [
        type: {:in, [:url, :socket, :ephemeral]},
        default: :ephemeral,
        doc: "Storage location: :url (synced with URL), :socket (survives reconnects), :ephemeral (default)"
      ],
      default: [
        type: :any,
        doc: "Default value when not present"
      ],
      required: [
        type: :boolean,
        default: false,
        doc: "Whether this field must be present (for URL inputs)"
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

  @inputs_section %Spark.Dsl.Section{
    name: :inputs,
    top_level?: true,
    describe: "Mutable state inputs from external sources (URL, socket, ephemeral).",
    entities: [@input_entity]
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
        doc: "The ID source: input(:field) or result(:derive)"
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
        doc: "The params source: input(:form_params). Defaults to implicit :name_params."
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
        doc: "The source: input(:field) or result(:derive_name)"
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
      run: [
        type: {:fun, 2},
        doc: "Function that computes the value: fn %{arg1: val1, ...}, context -> result end"
      ]
    ]
  }

  @derives_section %Spark.Dsl.Section{
    name: :derives,
    top_level?: true,
    describe: "Derived values computed from inputs or other derivations.",
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
      flashes: [@flash_entity]
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
    sections: [@inputs_section, @reads_section, @forms_section, @derives_section, @actions_section],
    imports: [Phoenix.Component, Lavash.DslHelpers]
end
