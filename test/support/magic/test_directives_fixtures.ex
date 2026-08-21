defmodule Lavash.Test.Magic.DomDirectivesLive do
  @moduledoc """
  Fixture exercising each data-lavash-* directive. The template transformer
  auto-injects
  the wrapper spans and class-toggling attrs so we get a real render through
  the lavash template pipeline.
  """
  use Lavash.LiveView

  state :n, :integer, from: :ephemeral, default: 0, optimistic: true
  state :flag, :boolean, from: :ephemeral, default: false, optimistic: true
  state :hidden_flag, :boolean, from: :ephemeral, default: false, optimistic: true
  state :enabled_flag, :boolean, from: :ephemeral, default: true, optimistic: true
  state :items, {:array, :string}, from: :ephemeral, default: ["one", "two"], optimistic: true

  actions do
    action :bump do
      set :n, rx(@n + 1)
    end

    action :toggle_flag do
      set :flag, rx(not @flag)
    end

    action :toggle_hidden do
      set :hidden_flag, rx(not @hidden_flag)
    end

    action :toggle_enabled do
      set :enabled_flag, rx(not @enabled_flag)
    end

    action :toggle_item, [:name] do
      set :items,
          rx(if(@name in @items, do: Enum.reject(@items, &(&1 == @name)), else: [@name | @items]))
    end
  end

  template do
    ~H"""
    <div>
      <!-- {@n} auto-wraps in <span data-lavash-display="n"> -->
      <p>Count: {@n}</p>
      <button id="bump" phx-click="bump">+</button>

      <!-- conditional classes ride reactive attribute derives (pattern 7) -->
      <div
        id="toggle-target"
        class={if @flag, do: "on-class", else: "off-class"}
      >
        {if @flag, do: "ON", else: "OFF"}
      </div>
      <!-- list form: the derive computes a JS array; the client must
           normalize it with Phoenix class-list semantics (flatten,
           drop nil/false, space-join), never comma-join -->
      <div
        id="list-class-target"
        class={["static-class", if(@flag, do: "on-class", else: "off-class")]}
      >
        list
      </div>
      <button id="toggle-flag" phx-click="toggle_flag">Toggle</button>

      <!-- :if={@bool} auto-injects data-lavash-visible -->
      <div id="hidden-section" :if={@hidden_flag}>
        Sometimes visible
      </div>
      <button id="toggle-hidden" phx-click="toggle_hidden">Toggle Hidden</button>

      <!-- disabled={not @bool} auto-injects data-lavash-enabled -->
      <button id="enabled-button" disabled={not @enabled_flag}>
        Maybe Enabled
      </button>
      <button id="toggle-enabled" phx-click="toggle_enabled">Toggle Enabled</button>

      <!-- class={if val in @list, do: A, else: B} auto-injects data-lavash-member -->
      <div id="chip-one" class={if "one" in @items, do: "selected", else: "unselected"}>one</div>
      <div id="chip-two" class={if "two" in @items, do: "selected", else: "unselected"}>two</div>
      <div id="chip-three" class={if "three" in @items, do: "selected", else: "unselected"}>three</div>
      <button id="toggle-three" phx-click="toggle_item" phx-value-name="three">Toggle 3</button>
      <button id="toggle-one" phx-click="toggle_item" phx-value-name="one">Toggle 1</button>
    </div>
    """
  end
end
