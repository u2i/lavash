defmodule Demo.Todos.Todo do
  @moduledoc """
  A todo item. Kept deliberately minimal — the interesting part is the
  LiveView (`DemoWeb.TodosLive`): the list is a stream-backed lavash
  projection, so it never lives in assigns or client state, and every
  mutation is a predicted per-row DOM operation.
  """
  use Ash.Resource,
    domain: Demo.Todos,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "todos"
    repo(Demo.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :done, :boolean do
      default false
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :done]
    end

    update :toggle do
      accept [:done]
    end

    read :list do
      prepare build(sort: [inserted_at: :asc])
    end
  end
end
