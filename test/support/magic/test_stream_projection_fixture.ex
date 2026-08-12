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
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:list_id, :body])
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
  `append` predicts a per-row DOM insert under the client-minted id,
  confirmed by the same event's `stream_insert` of the written record.
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
      <button id="add" phx-click="add" phx-value-body="fresh">add</button>
    </div>
    """
  end
end
