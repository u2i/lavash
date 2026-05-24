defmodule Lavash.TestDomDirectivesLive do
  @moduledoc """
  Fixture exercising each data-lavash-* directive. The ~L sigil auto-injects
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

  render fn assigns ->
    ~L"""
    <div>
      <!-- data-lavash-display: bare {@n} should be auto-wrapped -->
      <p>Count: {@n}</p>
      <button id="bump" phx-click="bump">+</button>

      <!-- data-lavash-toggle for boolean field -->
      <div
        id="toggle-target"
        data-lavash-toggle={"flag|on-class|off-class"}
        class={if @flag, do: "on-class", else: "off-class"}
      >
        {if @flag, do: "ON", else: "OFF"}
      </div>
      <button id="toggle-flag" phx-click="toggle_flag">Toggle</button>

      <!-- data-lavash-visible -->
      <div id="hidden-section" data-lavash-visible="hidden_flag" class={if @hidden_flag, do: nil, else: "hidden"}>
        Sometimes visible
      </div>
      <button id="toggle-hidden" phx-click="toggle_hidden">Toggle Hidden</button>

      <!-- data-lavash-enabled -->
      <button
        id="enabled-button"
        data-lavash-enabled="enabled_flag"
        disabled={not @enabled_flag}
      >
        Maybe Enabled
      </button>
      <button id="toggle-enabled" phx-click="toggle_enabled">Toggle Enabled</button>

      <!-- data-lavash-member: classes per array membership -->
      <div id="chip-one"
        data-lavash-member={"items|selected|unselected"}
        class={if "one" in @items, do: "selected", else: "unselected"}
      >one</div>
      <div id="chip-two"
        data-lavash-member={"items|selected|unselected"}
        class={if "two" in @items, do: "selected", else: "unselected"}
      >two</div>
      <div id="chip-three"
        data-lavash-member={"items|selected|unselected"}
        class={if "three" in @items, do: "selected", else: "unselected"}
      >three</div>
      <button id="toggle-three" phx-click="toggle_item" phx-value-name="three">Toggle 3</button>
      <button id="toggle-one" phx-click="toggle_item" phx-value-name="one">Toggle 1</button>
    </div>
    """
  end
end
