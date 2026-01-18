defmodule Lavash.Component.State do
  @moduledoc """
  A state field that connects component state to parent state.

  This is the unified state entity used by both LiveComponent and ClientComponent.
  State fields are bound to parent LiveView state and can be modified through
  optimistic actions.

  ## Fields

  - `:name` - The atom name of the state field
  - `:type` - The type specification (e.g., `:boolean`, `{:array, :string}`)
  - `:from` - Storage location (`:parent` for components, default)
  - `:default` - Default value if not provided

  ## Usage

  In LiveComponent or ClientComponent:

      state :tags, {:array, :string}
      state :active, :boolean, default: false

  The state field will be bound to the parent's state of the same name
  via the `bind` prop.
  """
  defstruct [:name, :type, :from, :default, __spark_metadata__: nil]
end

defmodule Lavash.Component.Prop do
  @moduledoc """
  A prop passed from the parent component.

  Props are read-only values that a component receives from its parent.
  They cannot be modified by the component itself.

  ## Fields

  - `:name` - The atom name of the prop
  - `:type` - The type specification (e.g., `:string`, `{:array, :string}`)
  - `:required` - Whether the prop must be provided (default: false)
  - `:default` - Default value if not provided
  - `:client` - Whether to include in client state JSON (default: true)
  """
  defstruct [:name, :type, :required, :default, client: true, __spark_metadata__: nil]
end

defmodule Lavash.Component.Template do
  @moduledoc """
  A component template that compiles to both HEEx and JS.

  The template source is parsed and transformed during compilation
  to generate both server-side HEEx rendering and client-side
  JavaScript for optimistic updates.
  """
  defstruct [:source, :deprecated_name, __spark_metadata__: nil]
end

defmodule Lavash.Component.Calculate do
  @moduledoc """
  A calculated field computed from state using a reactive expression.

  Calculations use `rx()` to capture expressions that reference state via
  `@field` syntax. By default, they are transpiled to JavaScript for
  client-side optimistic updates.

  ## Fields

  - `:name` - The atom name of the calculated field
  - `:rx` - A `Lavash.Rx` struct containing the expression
  - `:optimistic` - Whether to transpile to JS (default: true, auto-set to false if not transpilable)
  - `:async` - Whether to compute asynchronously (default: false)
  - `:reads` - Ash resources to watch for PubSub invalidation (default: [])

  ## Usage

      # Simple reactive calculation - transpiles to JS
      calculate :tag_count, rx(length(@tags))
      calculate :can_add, rx(@max == nil or length(@items) < @max)

      # Server-only (explicit or auto-detected)
      calculate :server_only, rx(complex_fn(@data)), optimistic: false

      # Async calculation - returns AsyncResult (loading/ok/error)
      calculate :factorial, rx(compute_factorial(@n)), async: true

      # With resource invalidation
      calculate :product_count, rx(length(@products)), reads: [Product]
  """
  defstruct [:name, :rx, optimistic: true, async: false, reads: [], __spark_metadata__: nil]
end

defmodule Lavash.ExtendErrors do
  @moduledoc """
  Extends auto-generated form field errors with custom error checks.

  Used to add custom validation rules beyond what Ash resource constraints provide.
  The custom errors are merged with Ash-generated errors and visibility is handled
  automatically via the field's show_errors state.

  ## Fields

  - `:field` - The field errors to extend (e.g., :registration_email_errors)
  - `:errors` - List of {condition_rx, message} tuples

  ## Usage

      extend_errors :registration_email_errors do
        error rx(not String.contains?(@registration_params["email"] || "", "@")), "Must contain @"
      end

  This merges the custom error with the auto-generated Ash errors when the condition
  is true (i.e., when the field is invalid).
  """
  defstruct [:field, errors: [], __spark_metadata__: nil]
end

defmodule Lavash.ExtendErrors.Error do
  @moduledoc """
  A single custom error check within extend_errors.

  ## Fields

  - `:condition` - A Lavash.Rx struct that evaluates to true when the error should show
  - `:message` - The error message string
  """
  defstruct [:condition, :message, __spark_metadata__: nil]
end

defmodule Lavash.Component.OptimisticAction do
  @moduledoc """
  An optimistic action that generates both client JS and server handlers.

  Optimistic actions define state transformations that run on both client
  and server. The `run` function is compiled to both Elixir and JavaScript,
  ensuring consistent behavior.

  ## Fields

  - `:name` - The action name (used for event routing)
  - `:field` - The state field this action operates on
  - `:key` - For array-of-objects: the field used to identify items (e.g., :id)
  - `:run` - Function that transforms the field value (or `:remove` atom)
  - `:run_source` - Source string for JS compilation
  - `:validate` - Optional validation function
  - `:validate_source` - Source string for JS validation
  - `:max` - Optional prop/state field containing max length limit
  """
  defstruct [:name, :field, :key, :run, :run_source, :validate, :validate_source, :max, __spark_metadata__: nil]
end
