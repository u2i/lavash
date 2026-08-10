defmodule Lavash.Test.Magic.StackedModalA do
  @moduledoc "First (bottom) modal for the stacking/a11y fixture."
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :open
  end

  actions do
    action :open do
      set :open, true
    end
  end

  template do
    ~H"""
    <div id="modal-a-content" class="p-4">
      <h2 id="modal-a-title">Modal A</h2>
      <button id="a-first">First A</button>
      <button id="a-last">Last A</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.StackedModalB do
  @moduledoc "Second (top) modal for the stacking/a11y fixture."
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :open
  end

  actions do
    action :open do
      set :open, true
    end
  end

  template do
    ~H"""
    <div id="modal-b-content" class="p-4">
      <h2 id="modal-b-title">Modal B</h2>
      <button id="b-only">Only B</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.StackedModalsHostLive do
  @moduledoc """
  Fixture for overlay a11y (issue #29): two independently-opened
  modals, so e2e can verify focus moves in/out, Tab is trapped in
  the topmost panel, and Escape closes only the topmost overlay.
  """
  use Lavash.LiveView

  actions do
    action :open_a do
      invoke "stack-modal-a", :open, module: Lavash.Test.Magic.StackedModalA
    end

    action :open_b do
      invoke "stack-modal-b", :open, module: Lavash.Test.Magic.StackedModalB
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <button id="open-a" phx-click="open_a">Open A</button>
      <button id="open-b" phx-click="open_b">Open B</button>
      <.live_component module={Lavash.Test.Magic.StackedModalA} id="stack-modal-a" />
      <.live_component module={Lavash.Test.Magic.StackedModalB} id="stack-modal-b" />
    </div>
    """
  end
end
