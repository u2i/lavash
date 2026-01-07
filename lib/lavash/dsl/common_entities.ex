defmodule Lavash.Dsl.CommonEntities do
  @moduledoc """
  Shared DSL entity definitions used by both Lavash.Dsl (LiveView) and Lavash.Component.Dsl.

  This module provides common entity definitions to reduce duplication between the two DSLs.
  Each DSL imports the entities it needs and may extend schemas with runtime-specific options.
  """

  # ============================================
  # Base State Schema
  # ============================================

  @doc """
  Base schema fields shared by all state entities.

  LiveView extends this with: :url from option, setter, encode, decode, required
  Component uses this with: :socket/:ephemeral from option only
  """
  def base_state_schema do
    [
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
      default: [
        type: :any,
        doc: "Default value when not present"
      ],
      optimistic: [
        type: :boolean,
        default: false,
        doc: "Enable optimistic updates with version tracking"
      ],
      animated: [
        type: {:or, [:boolean, :keyword_list]},
        default: false,
        doc: """
        Enable animated state transitions with phase tracking.

        Options (when keyword list):
        - `async: :field_name` - coordinate with async data loading
        - `preserve_dom: true` - keep DOM alive during exit animation
        - `duration: 200` - fallback timeout in ms
        """
      ]
    ]
  end

  # ============================================
  # Read Argument Entity
  # ============================================

  @doc """
  Argument entity for read and derive blocks.
  """
  def read_argument_entity do
    %Spark.Dsl.Entity{
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
          doc:
            "The source: state(:field), prop(:field), or result(:derive). If omitted, uses state(name)."
        ],
        transform: [
          type: {:fun, 1},
          doc: "Optional transform function applied to the value before passing to action"
        ]
      ]
    }
  end

  @doc """
  Argument entity for derive blocks.
  """
  def derive_argument_entity do
    %Spark.Dsl.Entity{
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
            "The source: state(:field), prop(:field), or result(:derive_name). Defaults to state(name) if omitted."
        ],
        transform: [
          type: {:fun, 1},
          doc: "Optional transform function applied to the value before passing to run"
        ]
      ]
    }
  end

  # ============================================
  # Action Sub-Entities (shared between LiveView and Component)
  # ============================================

  @doc """
  Set entity for actions - assigns a value to a state field.
  """
  def set_entity do
    %Spark.Dsl.Entity{
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
  end

  @doc """
  Update entity for actions - transforms a state field value.
  """
  def update_entity do
    %Spark.Dsl.Entity{
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
  end

  @doc """
  Effect entity for actions - runs a side effect function.
  """
  def effect_entity do
    %Spark.Dsl.Entity{
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
  end

  @doc """
  Submit entity for actions - submits a form.
  """
  def submit_entity do
    %Spark.Dsl.Entity{
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
          doc: "Action to trigger after successful submission"
        ],
        on_error: [
          type: :atom,
          doc: "Action to trigger on submission error"
        ]
      ]
    }
  end

  # ============================================
  # Base Form Schema
  # ============================================

  @doc """
  Base schema for form entities.
  """
  def base_form_schema do
    [
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
  end

  # ============================================
  # Base Derive Schema
  # ============================================

  @doc """
  Base schema for derive entities.
  """
  def base_derive_schema do
    [
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
  end

  # ============================================
  # Base Calculate Schema
  # ============================================

  @doc """
  Base schema for calculate entities.
  """
  def base_calculate_schema do
    [
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
  end

  # ============================================
  # Base Action Schema
  # ============================================

  @doc """
  Base schema for action entities.
  """
  def base_action_schema do
    [
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
        doc: "Guard conditions - derived boolean fields that must be true"
      ]
    ]
  end
end
