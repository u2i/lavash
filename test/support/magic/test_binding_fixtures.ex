defmodule Lavash.Test.Magic.BindingChildComponent do
  @moduledoc """
  Test fixture: child component that reads and writes a field bound from its
  parent. Used by Lavash.Integration.BindingsTest.
  """
  use Lavash.Component

  state :n, :integer, from: :ephemeral, default: 0, optimistic: true

  actions do
    action :bump do
      set :n, rx(@n + 1)
    end
  end

  render fn assigns ->
    ~L"""
    <div id={"child-" <> @id}>
      <span id={"child-#{@id}-n"}>{@n}</span>
      <button id={"child-#{@id}-bump"} phx-click="bump" phx-target={@myself}>+</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.BindingMiddleComponent do
  @moduledoc """
  Middle component for testing 3-level binding chains.

  Has its own field `:m` and re-binds it down to a grandchild's `:n` field, so
  parent <-> middle <-> grandchild all stay in sync.
  """
  use Lavash.Component
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :m, :integer, from: :ephemeral, default: 0, optimistic: true

  render fn assigns ->
    ~L"""
    <div id={"middle-" <> @id}>
      <span id={"middle-#{@id}-m"}>{@m}</span>
      <.lavash_component
        module={Lavash.Test.Magic.BindingChildComponent}
        id={"#{@id}-grandchild"}
        bind={[n: :m]}
        myself={@myself}
      />
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.BindingDirectHostLive do
  @moduledoc """
  LiveView -> child binding. Parent owns :parent_count; child reads/writes it
  via bind=[n: :parent_count].
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :parent_count, :integer, from: :ephemeral, default: 0, optimistic: true

  render fn assigns ->
    ~L"""
    <div>
      <span id="parent-count">{@parent_count}</span>
      <.lavash_component
        module={Lavash.Test.Magic.BindingChildComponent}
        id="direct"
        bind={[n: :parent_count]}
      />
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.BindingNestedHostLive do
  @moduledoc """
  LiveView -> middle -> grandchild binding chain. Verifies a write at the
  grandchild propagates through the middle component up to the LiveView.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :root_count, :integer, from: :ephemeral, default: 0, optimistic: true

  render fn assigns ->
    ~L"""
    <div>
      <span id="root-count">{@root_count}</span>
      <.lavash_component
        module={Lavash.Test.Magic.BindingMiddleComponent}
        id="middle"
        bind={[m: :root_count]}
      />
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.BindingSiblingsHostLive do
  @moduledoc """
  Two children bound to the same parent field. Each child's write should be
  reflected in the other.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :shared, :integer, from: :ephemeral, default: 0, optimistic: true

  render fn assigns ->
    ~L"""
    <div>
      <span id="shared">{@shared}</span>
      <.lavash_component
        module={Lavash.Test.Magic.BindingChildComponent}
        id="a"
        bind={[n: :shared]}
      />
      <.lavash_component
        module={Lavash.Test.Magic.BindingChildComponent}
        id="b"
        bind={[n: :shared]}
      />
    </div>
    """
  end
end
