defmodule Lavash.Parity.Lavash.CounterComponent do
  @moduledoc """
  Lavash DSL expression of `Lavash.Parity.Vanilla.CounterComponent`.

  Same observable behaviour: own `:count` state, receives `:label`
  from parent, handles its own events targeted to `@myself`.
  Different declaration shape: `use Lavash.Component` with
  `state`/`prop`/`actions`/`template` blocks instead of vanilla's
  `mount`/`update`/`handle_event`/`render` callbacks.

  `phx-target={@myself}` is auto-injected on `phx-*` attributes
  inside a component template (no need to write it explicitly).
  """
  use Lavash.Component

  state :count, :integer, from: :ephemeral, default: 0, optimistic: true

  prop :label, :string, default: ""

  actions do
    action :inc do
      set :count, rx(@count + 1)
    end

    action :reset do
      set :count, 0
    end
  end

  template do
    # Lavash wraps the component in its own `<div id={@id} ...>` for
    # the optimistic JS hook. We use a different DOM id inside so
    # the parity test's `#comp-a` selectors still work — they match
    # the outer wrapper, and `.label`/`.count`/`button` find content
    # inside.
    ~H"""
    <div class="counter-component">
      <p class="label">{@label}</p>
      <p class="count">{@count}</p>
      <button phx-click="inc">+1</button>
      <button phx-click="reset">reset</button>
    </div>
    """
  end
end

defmodule Lavash.Parity.Lavash.LiveComponentLive do
  @moduledoc """
  Host LiveView for the lavash side. Mirrors the vanilla shape
  but uses `<.lavash_component>` to host the children — that
  helper handles binding propagation in addition to vanilla's
  pass-through prop flow.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :parent_label_a, :string, default: "A", optimistic: true

  actions do
    action :toggle_label_a do
      set :parent_label_a, rx(if @parent_label_a == "A", do: "A!", else: "A")
    end
  end

  template do
    ~H"""
    <div id="live-component-lavash">
      <button id="toggle-label-a" phx-click="toggle_label_a">toggle A label</button>

      <.lavash_component
        module={Lavash.Parity.Lavash.CounterComponent}
        id="comp-a"
        label={@parent_label_a}
      />

      <.lavash_component
        module={Lavash.Parity.Lavash.CounterComponent}
        id="comp-b"
        label="B"
      />
    </div>
    """
  end
end
