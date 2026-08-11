defmodule Lavash.Test.Magic.CounterComponent do
  @moduledoc """
  Test fixture: Simple counter component with props and state.
  """
  use Lavash.Component

  prop :initial_count, :integer, default: 0
  prop :step, :integer, default: 1

  state :count, :integer, from: :ephemeral, default: 0

  calculate :doubled, rx((@count || 0) * 2)

  actions do
    action :increment do
      set :count, rx((@count || 0) + 1)
    end

    action :decrement do
      set :count, rx((@count || 0) - 1)
    end

    action :reset do
      set :count, 0
    end
  end

  # Override mount to set initial count from props
  def mount(socket) do
    {:ok, socket}
  end

  # Issue #20 regression guard: attr/slot function components must work
  # directly inside a `use Lavash.Component` module without an explicit
  # `use Phoenix.Component` (do not add one).
  attr :label, :string, required: true
  slot :inner_block, required: true

  def labeled_box(assigns) do
    ~H"""
    <div class="labeled-box" data-label={@label}>{render_slot(@inner_block)}</div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.labeled_box label="count-box">
        <span id={"#{@id}-count"}>{@count}</span>
      </.labeled_box>
      <span id={"#{@id}-doubled"}>{@doubled}</span>
      <button id={"#{@id}-inc"} phx-click="increment" phx-target={@myself}>+</button>
      <button id={"#{@id}-dec"} phx-click="decrement" phx-target={@myself}>-</button>
      <button id={"#{@id}-reset"} phx-click="reset" phx-target={@myself}>Reset</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.DerivedPropsComponent do
  @moduledoc """
  Test fixture: Component with derived state from props.
  """
  use Lavash.Component

  prop :value, :integer, required: true
  prop :multiplier, :integer, default: 2

  calculate :computed, rx(@value * @multiplier)

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <span id={"#{@id}-value"}>{@value}</span>
      <span id={"#{@id}-multiplier"}>{@multiplier}</span>
      <span id={"#{@id}-computed"}>{@computed}</span>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ComponentHostLive do
  @moduledoc """
  Test fixture: LiveView that hosts test components.
  """
  use Lavash.LiveView

  state :counter_value, :integer, from: :ephemeral, default: 5

  actions do
    action :set_value, [:value] do
      set :counter_value, &String.to_integer(&1.params.value)
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={Lavash.Test.Magic.CounterComponent}
        id="counter"
        initial_count={@counter_value}
      />
      <.live_component
        module={Lavash.Test.Magic.DerivedPropsComponent}
        id="derived"
        value={@counter_value}
      />
      <button id="set-10" phx-click="set_value" phx-value-value="10">Set 10</button>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ModalComponent do
  @moduledoc """
  Test fixture: Modal component that tracks render calls.

  Uses a named process to track whether the render function was called,
  allowing tests to verify render is not called when modal is closed.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :item_id
  end

  actions do
    action :open, [:id] do
      set :item_id, & &1.params.id
    end
  end

  template do
    ~H"""
    <.render_probe item_id={@item_id} />
    <div id="modal-content">
      <h2>Editing item {@item_id}</h2>
      <button phx-click="close" phx-target={@myself}>Close</button>
    </div>
    """
  end

  # Emits a message to the test process whenever the template renders, so
  # the render-optimization tests can observe that render/1 ran (and with
  # which item_id). Renders nothing. A function component is used because
  # `template do ~H end` holds only the template — the side effect runs
  # exactly when the body renders, preserving the original semantics.
  # No `attr` schema: the @on_definition hook that backs `attr` doesn't
  # reach plain defs in a Lavash.Component module (see issue #20), and
  # this internal probe doesn't need validation.
  def render_probe(assigns) do
    if test_pid = Process.whereis(:modal_test_pid) do
      send(test_pid, {:modal_rendered, assigns.item_id})
    end

    ~H""
  end
end

defmodule Lavash.Test.Magic.ModalHostLive do
  @moduledoc """
  Test fixture: LiveView that hosts the test modal component.
  """
  use Lavash.LiveView

  actions do
    action :open_modal, [:id] do
      invoke "test-modal", :open,
        module: Lavash.Test.Magic.ModalComponent,
        params: [id: {:param, :id}]
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <button id="open-modal" phx-click="open_modal" phx-value-id="123">Open Modal</button>
      <.live_component
        module={Lavash.Test.Magic.ModalComponent}
        id="test-modal"
      />
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ModalSsrHostLive do
  @moduledoc """
  Test fixture: host whose modal open state comes from the URL, so
  visiting `?modal_item=42` server-renders the modal already open.
  Exercises the mount-time seed path (issue #30): the open value must
  arrive confirmed (no pending window) and must not replay the enter
  animation.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :modal_item, :string, from: :url, default: nil

  def render(assigns) do
    ~H"""
    <div>
      <.lavash_component
        module={Lavash.Test.Magic.ModalComponent}
        id="test-modal"
        item_id={@modal_item}
        bind={[item_id: :modal_item]}
      />
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ModalNoCloseComponent do
  @moduledoc """
  Test fixture: modal with `close_on_escape false` and
  `close_on_backdrop false`.

  Regression fixture for the render-generator bug where persisted
  `false` was discarded via `persisted || true`, making both options
  impossible to turn off (issue #24).
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :item_id
    close_on_escape false
    close_on_backdrop false
  end

  actions do
    action :open, [:id] do
      set :item_id, & &1.params.id
    end
  end

  template do
    ~H"""
    <div id="modal-no-close-content">
      <h2>Item {@item_id}</h2>
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ModalNoCloseHostLive do
  @moduledoc """
  Test fixture: LiveView hosting the no-close modal component.
  """
  use Lavash.LiveView

  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={Lavash.Test.Magic.ModalNoCloseComponent}
        id="test-modal-no-close"
      />
    </div>
    """
  end
end

defmodule Lavash.Test.Magic.ModalAsyncComponent do
  @moduledoc """
  Test fixture: modal whose content depends on an async derived value.

  Used to exercise the SyncedVar phase machine's loading branch —
  entering -> loading (async not ready) -> visible (async resolved).
  The async calc sleeps 200ms which is longer than the modal's 200ms
  entering animation, so we reliably hit the loading phase between
  the entering animation completing and the async data arriving.
  """
  use Lavash.Component, extensions: [Lavash.Overlay.Modal.Dsl]

  modal do
    open_field :item_id
    async_assign :item
  end

  calculate :item, rx(slow_load(@item_id)), async: true, optimistic: false

  def slow_load(nil), do: nil

  def slow_load(id) do
    Process.sleep(200)
    "Loaded item #{id}"
  end

  actions do
    action :open, [:id] do
      set :item_id, & &1.params.id
    end
  end

  template do
    ~H"""
    <div id="modal-async-content">
      <p id="modal-async-body">{@item}</p>
      <button phx-click="close" phx-target={@myself}>Close</button>
    </div>
    """
  end

  template_loading do
    ~H"""
    <div id="modal-async-loading">Loading item…</div>
    """
  end
end

defmodule Lavash.Test.Magic.ModalAsyncHostLive do
  @moduledoc """
  Test fixture: LiveView that hosts the async-content modal. Used to
  observe the modal phase machine's loading-phase branch under
  simulated latency.
  """
  use Lavash.LiveView

  actions do
    action :open_modal, [:id] do
      invoke "test-async-modal", :open,
        module: Lavash.Test.Magic.ModalAsyncComponent,
        params: [id: {:param, :id}]
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <button id="open-modal" phx-click="open_modal" phx-value-id="42">Open Modal</button>
      <.live_component
        module={Lavash.Test.Magic.ModalAsyncComponent}
        id="test-async-modal"
      />
    </div>
    """
  end
end
