defmodule Lavash.Read do
  @moduledoc """
  A read step that loads an Ash resource.

  Supports two modes:

  ## Get by ID (single record)

      read :product, Product do
        id state(:product_id)
      end

  ## Query with auto-mapped arguments

      # Auto-maps state fields to action arguments by name
      read :products, Product, :list

      # With explicit overrides
      read :products, Product, :list do
        argument :category, transform: &(if &1 == "", do: nil, else: &1)
      end

  Action arguments are auto-wired to matching state fields. Use `argument` entities
  to override the source or apply transforms.
  """

  defstruct [
    :name,
    :resource,
    :id,
    :action,
    :async,
    :as_options,
    :invalidate,
    arguments: [],
    client_states: [],
    __spark_metadata__: nil
  ]
end

defmodule Lavash.Read.ClientState do
  @moduledoc """
  A client-state projection of a read's result list.

  Declares that a query read's records should be projected into a
  JSON-safe list of maps and shipped to the client as optimistic
  state. The projected field is a **derive** on the server (always
  recomputed from the read — never mutated by actions) and mutable
  optimistic state on the client (`mutate`/`remove`/`append` predictions apply to it
  instantly; the next server push of the re-read confirms or
  corrects them).

      read :cart_items, CartItem, :for_cart do
        argument :cart_id, prop(:cart_id)
        async false
        invalidate :pubsub

        client_state :items do
          key :id
          fields [:id, :quantity, :unit_price, product: [:id, :name]]
        end
      end

  ## Limitations

  - The backing read must be a **query** read (list result) with
    `async false` — the projection ships in the initial render.
  - `fields` is an allowlist: atoms for the resource's own
    attributes, `assoc: [...]` keyword tails for one level of
    loaded relationships. Values are wire-encoded (Decimal →
    string, atom → string, Date/DateTime → ISO 8601).
  - The projected field is read-only on the server: `set` cannot
    target it, and there is no auto-generated setter. Durable
    mutation means writing the resource (in `pre_run`, so the
    same event's cascade re-reads and confirms the client's
    prediction) and broadcasting invalidation for other sessions.
  """

  defstruct [
    :name,
    key: :id,
    fields: [],
    stream: false,
    __spark_metadata__: nil
  ]
end

defmodule Lavash.Read.Argument do
  @moduledoc """
  An argument override for a read action.

  Used to customize how state maps to action arguments:
  - Override the source (e.g., map a differently-named state field)
  - Apply a transform function
  """

  defstruct [
    :name,
    :source,
    :transform,
    __spark_metadata__: nil
  ]
end
