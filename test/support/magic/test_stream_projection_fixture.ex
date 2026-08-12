defmodule Lavash.Test.Magic.StreamList do
  @moduledoc "Domain for the stream-backed projection fixture (issue #71)."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Lavash.Test.Magic.StreamList.Entry)
  end
end

defmodule Lavash.Test.Magic.StreamList.Entry do
  @moduledoc "Minimal entry resource backing the stream projection fixture."
  use Ash.Resource,
    domain: Lavash.Test.Magic.StreamList,
    data_layer: Ash.DataLayer.Ets

  ets do
    # Shared table: tests seed entries in the test process, the
    # LiveView process reads them.
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :list_id, :string do
      public?(true)
    end

    attribute :body, :string do
      public?(true)
    end

    attribute :count, :integer do
      public?(true)
      default(1)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:list_id, :body, :count])
    end

    update :bump_count do
      accept([:count])
    end

    read :for_list do
      argument(:list_id, :string, allow_nil?: false)
      filter(expr(list_id == ^arg(:list_id)))
    end
  end
end

defmodule Lavash.Test.Magic.StreamListLive do
  @moduledoc """
  Fixture for stream-backed projections (issue #71): the read's rows
  feed a LiveView stream — no list in assigns or client state — and
  the whole projection-op family predicts per-row DOM operations
  confirmed by the same event's stream ops:

  - `append` inserts under the client-minted id
  - `mutate` re-renders the addressed row from its `data-lavash-row`
    payload (or deletes on `:remove`)
  - `remove` drops the row node
  - `upsert` scans rows for a match — conflict re-renders, miss
    inserts
  """
  use Lavash.LiveView

  alias Lavash.Test.Magic.StreamList.Entry

  state :list_id, :string, from: :url

  read :entries, Entry, :for_list do
    argument :list_id, state(:list_id)
    async false

    client_state :items do
      key :id
      fields [:id, :body, :count]
      stream true
    end
  end

  actions do
    action :add, [:body] do
      append :items, :create, rx(%{list_id: @list_id, body: @body})
    end

    action :increment, [:id] do
      mutate :items, :bump_count, rx(%{count: @item.count + 1})
    end

    action :remove, [:id] do
      remove :items
    end

    action :upsert_entry, [:body] do
      upsert :items,
        match: [:body],
        on_conflict: {:bump_count, rx(%{count: @item.count + 1})},
        on_insert: {:create, rx(%{list_id: @list_id, body: @body, count: 1})}
    end
  end

  template do
    ~H"""
    <div>
      <div id="items" phx-update="stream">
        <div :for={{dom_id, row} <- @streams.items} id={dom_id} class="entry">
          <span class="body">{row.body}</span>
          <span class="count">{row.count}</span>
          <button class="inc" phx-click="increment" phx-value-id={row.id}>+</button>
          <button class="del" phx-click="remove" phx-value-id={row.id}>x</button>
        </div>
      </div>
      <button id="add" phx-click="add" phx-value-body="fresh">add</button>
      <button id="upsert" phx-click="upsert_entry" phx-value-body="row 1">upsert existing</button>
      <button id="upsert-new" phx-click="upsert_entry" phx-value-body="brand new">upsert new</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.StreamPrependLive do
  @moduledoc """
  Fixture for streamed projection ordering + pruning (issue #71 phase
  4): `at 0` prepends — the predicted insert and the confirming
  stream op land at the top — and `limit 5` keeps the container
  pruned server-side.
  """
  use Lavash.LiveView

  alias Lavash.Test.Magic.StreamList.Entry

  state :list_id, :string, from: :url

  read :entries, Entry, :for_list do
    argument :list_id, state(:list_id)
    async false

    client_state :items do
      key :id
      fields [:id, :body]
      stream true
      at 0
      limit 5
    end
  end

  actions do
    action :add, [:body] do
      append :items, :create, rx(%{list_id: @list_id, body: @body})
    end
  end

  template do
    ~H"""
    <div>
      <div id="items" phx-update="stream">
        <div :for={{dom_id, row} <- @streams.items} id={dom_id} class="entry">
          <span class="body">{row.body}</span>
        </div>
      </div>
      <button id="add" phx-click="add" phx-value-body="newest">add</button>
    </div>
    """
  end
end
