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

  Strictly layer-1/2 keys: name, type, default. Storage-source keys
  (`from:`, `setter:`, `encode:`, `decode:`, etc.) are appended by
  the LiveView and Component DSLs at their layer-2 build sites.
  Layer-4 keys (`optimistic:`, `animated:`) come from
  `Lavash.Optimistic.SchemaExtension.state_schema/0` and are
  concatenated alongside.

  This split is the layering carving from
  `docs/ARCHITECTURE.md` punchlist item #3: the base DSL surface
  shouldn't advertise optimism keys when the user hasn't opted in
  to layer 4.
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
      ]
    ] ++ Lavash.Optimistic.SchemaExtension.state_schema()
  end

  # ============================================
  # Read Argument Entity
  # ============================================

  @doc """
  Client-state projection entity for query reads.

  Projects the read's record list into a JSON-safe list of maps
  shipped to the client as optimistic state. See
  `Lavash.Read.ClientState` for semantics and limitations.
  """
  def client_state_entity do
    %Spark.Dsl.Entity{
      name: :client_state,
      target: Lavash.Read.ClientState,
      args: [:name],
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: "The client state field name the projected list is exposed as"
        ],
        key: [
          type: :atom,
          default: :id,
          doc: "The identity field `mutate`/`remove` use to address individual entries"
        ],
        fields: [
          type: {:list, :any},
          required: true,
          doc: """
          Allowlist of fields to project. Atoms name the resource's own
          attributes; keyword tails project one level of loaded
          relationships: `fields [:id, :quantity, product: [:id, :name]]`.
          """
        ]
      ]
    }
  end

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

  # ============================================
  # Action Sub-Entities (shared between LiveView and Component)
  # ============================================

  @doc """
  Set entity for actions - assigns a value to a state field.

  The value can use `@field` syntax to reference state fields and params,
  aligned with template syntax:

      action :increment do
        set :count, @count + 1
      end

      action :add_item do
        params [:name]
        set :items, @items ++ [@name]
      end

  The expression is captured at compile time and can be transpiled to JavaScript
  for optimistic client-side updates.
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
          doc: """
          The value to set. Can be:
          - A literal value: `set :count, 0`
          - An rx() expression with @field syntax: `set :count, rx(@count + 1)`
          - A function (server-only escape hatch): `set :count, &(&1.params.value)`

          Using rx() is preferred as it enables both server-side evaluation
          and JavaScript transpilation for optimistic updates.

          Example with rx():
              action :increment do
                set :count, rx(@count + 1)
              end

              action :add_item do
                params [:name]
                set :items, rx(@items ++ [@name])
              end
          """
        ]
      ]
    }
  end

  @doc """
  PreRun entity for actions — pre-cascade socket-shaped run.

  Runs BEFORE the reactive cascade. Use when you need imperative
  Elixir to compute a state value that downstream calcs depend on:

      action :submit do
        pre_run fn socket ->
          # Imperative validation / preprocessing before mutation
          if socket.assigns.form_valid? do
            socket
            |> Lavash.Socket.put_state(:submitted, true)
            |> Lavash.Socket.put_state(:submitted_at, DateTime.utc_now())
          else
            socket
          end
        end
      end

  After the body returns, the action runtime extracts
  `socket.assigns.__changed__` to populate lavash's dirty set, so
  the cascade sees what changed and recomputes precisely. So you
  can use raw `Phoenix.Component.assign/3` if you prefer — the
  cascade will still see the write.

  For most state mutation, prefer the declarative `set :foo, rx(...)`.
  """
  def pre_run_entity do
    %Spark.Dsl.Entity{
      name: :pre_run,
      target: Lavash.Actions.PreRun,
      args: [:fun],
      schema: [
        fun: [
          type: :quoted,
          required: true,
          doc:
            "Function `fn socket -> socket end`. Runs pre-cascade. " <>
              "Use for imperative state mutation; cascade settles after."
        ]
      ]
    }
  end

  @doc """
  Run entity for actions — post-cascade socket-shaped run.

  Runs AFTER the reactive cascade. Reads settled state; can do
  socket-level LV ops or external side effects:

      action :send do
        run fn socket ->
          new_msg = %{id: next_id(), summary: socket.assigns.summary}
          Phoenix.LiveView.stream_insert(socket, :messages, new_msg)
        end
      end

  Use for socket-level LV ops (`stream_insert/4`, `allow_upload/3`,
  `consume_uploaded_entries/3`, `cancel_upload/3`) or anything that
  needs the post-cascade view.

  Writes from `run` land in assigns and `__changed__` is updated
  for Phoenix's render diff. BUT lavash does NOT re-fire the
  cascade — calcs depending on what `run` wrote are stale until
  the next event. If you need a derived value of a write, write it
  in `pre_run` instead.
  """
  def run_entity do
    %Spark.Dsl.Entity{
      name: :run,
      target: Lavash.Actions.Run,
      args: [:fun],
      schema: [
        fun: [
          type: :quoted,
          required: true,
          doc:
            "Function `fn socket -> socket end`. Runs post-cascade. " <>
              "Use for socket-level LV ops or side effects that need settled state."
        ]
      ]
    }
  end

  @doc """
  Mutate entity for actions — keyed mutation of a client_state
  projection row, declared once and evaluated on both sides. See
  `Lavash.Actions.Mutate`.
  """
  def mutate_entity do
    %Spark.Dsl.Entity{
      name: :mutate,
      target: Lavash.Actions.Mutate,
      args: [:field, :action, :transform],
      schema: [
        field: [
          type: :atom,
          required: true,
          doc: "The client_state projection field to mutate"
        ],
        action: [
          type: :atom,
          required: true,
          doc: "The Ash update action driven by the transform's params map"
        ],
        transform: [
          type: {:struct, Lavash.Rx},
          required: true,
          doc: """
          `rx()` expression over `@item` (the matched row) returning a
          params map or `:remove`. Client-side the result merges into the
          projected row (the prediction); server-side it drives the Ash
          action on the authoritative record (`:remove` destroys it).

          Example: `mutate :items, :update_quantity, rx(%{quantity: @item.quantity + 1})`
          """
        ]
      ]
    }
  end

  @doc """
  Remove entity for actions — keyed removal of a client_state
  projection row. See `Lavash.Actions.Remove`.
  """
  def remove_entity do
    %Spark.Dsl.Entity{
      name: :remove,
      target: Lavash.Actions.Remove,
      args: [:field],
      schema: [
        field: [
          type: :atom,
          required: true,
          doc: "The client_state projection field to remove from"
        ],
        action: [
          type: :atom,
          doc: "The Ash destroy action to use (defaults to the primary destroy)"
        ]
      ]
    }
  end

  @doc """
  Append entity for actions — optimistic insert into a client_state
  projection. See `Lavash.Actions.Append`.
  """
  def append_entity do
    %Spark.Dsl.Entity{
      name: :append,
      target: Lavash.Actions.Append,
      args: [:field, :action, :transform],
      schema: [
        field: [
          type: :atom,
          required: true,
          doc: "The client_state projection field to append to"
        ],
        action: [
          type: :atom,
          required: true,
          doc: "The Ash create action driven by the transform's attribute map"
        ],
        transform: [
          type: {:struct, Lavash.Rx},
          required: true,
          doc: """
          `rx()` expression over state fields and action params returning the
          new row's attribute map. Client-side the result (plus a temp key)
          becomes a provisional row; server-side it is filtered to the create
          action's accepted attributes and drives `Ash.create`.

          Example: `append :items, :add, rx(%{cart_id: @cart_id, name: @name, quantity: 1})`
          """
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
      ],
      skip_constraints: [
        type: {:list, :atom},
        default: [],
        doc: """
        Fields to skip constraint-based validation for in client-side optimistic updates.
        Use when a field is populated programmatically (e.g., session_id injected at save time)
        or when you want to handle validation entirely via extend_errors with custom logic.
        The Ash resource constraints still apply server-side.

        Example: skip_constraints [:session_id]
        """
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
      # `optimistic:` is a layer-4 concern — it lives in
      # `Lavash.Optimistic.SchemaExtension.calculate_schema/0` and is
      # appended below so the layers compose into one schema. See
      # docs/ARCHITECTURE.md punchlist item #3.
      async: [
        type: :boolean,
        default: false,
        doc: """
        Whether to compute asynchronously. When true, spawns a Task and
        returns a Phoenix.LiveView.AsyncResult (loading/ok/error states).
        Async calculations are always server-only (optimistic is ignored).
        """
      ],
      reads: [
        type: {:list, :atom},
        default: [],
        doc: """
        Ash resources this calculation depends on for PubSub invalidation.
        When any of these resources change, the calculation is recomputed.
        """
      ]
    ] ++ Lavash.Optimistic.SchemaExtension.calculate_schema()
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
      reads: [
        type: {:list, :atom},
        default: [],
        doc: """
        Reserved for the optimistic-JS transpile path (see #119). Today
        this is a no-op — `set :field, rx(...)` already declares its
        own reads via the `rx` expression. Will be repointed at
        `pre_run` bodies once the transpiler is updated.
        """
      ],
      when: [
        type: {:list, :atom},
        default: [],
        doc: "Guard conditions - derived boolean fields that must be true"
      ]
    ]
  end
end
