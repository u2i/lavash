defmodule Lavash.Optimistic do
  @moduledoc """
  Optimistic updates for Lavash LiveViews.

  This module provides infrastructure for running actions and derives on the client
  before server confirmation, giving instant UI feedback.

  ## Usage

  1. Add the hook to your LiveView's root element:

      <div id="counter" phx-hook="Lavash.Optimistic" data-lavash-optimistic={Jason.encode!(optimistic_config())}>
        ...
      </div>

  2. Define client-side functions using ColocatedJS:

      <script :type={Phoenix.LiveView.ColocatedJS} name="optimistic">
        export const increment = (state) => ({ ...state, count: state.count + 1 });
        export const doubled = ({count, multiplier}) => count * multiplier;
      </script>

  3. Register the functions in app.js:

      import optimistic from "phoenix-colocated/demo/DemoWeb.CounterLive/optimistic";
      window.Lavash = window.Lavash || {};
      window.Lavash.optimistic = window.Lavash.optimistic || {};
      window.Lavash.optimistic["DemoWeb.CounterLive"] = optimistic;

  4. Configure actions with `client:` option:

      action :increment, optimistic: true do
        update :count, &(&1 + 1)
        client :increment
      end

  The hook will:
  - Intercept the event before sending to server
  - Run the client-side function to compute new state
  - Update the DOM immediately
  - Push to server for confirmation
  - Ignore stale responses using version tracking
  """

  use Phoenix.Component

  @doc """
  Renders the Lavash.Optimistic hook wrapper.

  This component wraps your LiveView content and provides the hook
  that manages optimistic state updates.

  ## Example

      <.optimistic_root module={__MODULE__} state={@count} derives={%{doubled: @doubled}}>
        <div>{@count}</div>
        <button phx-click="increment">+</button>
      </.optimistic_root>
  """
  attr :id, :string, required: true
  attr :module, :atom, required: true, doc: "The LiveView module for looking up optimistic functions"
  attr :state, :map, required: true, doc: "Current state map"
  attr :derives, :map, default: %{}, doc: "Current derived values"
  slot :inner_block, required: true

  def optimistic_root(assigns) do
    config = %{
      module: to_string(assigns.module),
      state: assigns.state,
      derives: assigns.derives
    }

    assigns = assign(assigns, :config, config)

    ~H"""
    <div id={@id} phx-hook="Lavash.Optimistic" data-lavash-config={Jason.encode!(@config)}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The JavaScript hook for optimistic updates.

  This is exposed as a colocated hook that should be merged into your LiveSocket hooks.
  """
  def hook_js do
    """
    const LavashOptimistic = {
      mounted() {
        this.config = JSON.parse(this.el.dataset.lavashConfig || "{}");
        this.state = this.config.state || {};
        this.derives = this.config.derives || {};
        this.version = 0;
        this.confirmedVersion = 0;

        // Get the optimistic functions for this module
        const moduleName = this.config.module;
        this.fns = window.Lavash?.optimistic?.[moduleName] || {};

        console.log("[Lavash.Optimistic] Mounted:", moduleName, "fns:", Object.keys(this.fns));

        // Store reference globally for event interception
        this.el._lavashOptimistic = this;
      },

      beforeUpdate() {
        // Store current config before update
        this._prevConfig = this.config;
      },

      updated() {
        const newConfig = JSON.parse(this.el.dataset.lavashConfig || "{}");

        // Only accept server state if we have no pending operations
        if (this.confirmedVersion === this.version) {
          this.state = newConfig.state || {};
          this.derives = newConfig.derives || {};
        }

        this.config = newConfig;
      },

      // Run an optimistic action
      runAction(actionName, params = {}) {
        const fn = this.fns[actionName];
        if (!fn) {
          console.warn(`[Lavash.Optimistic] No client function for action: ${actionName}`);
          return null;
        }

        this.version++;
        const v = this.version;

        // Compute new state optimistically
        const newState = fn(this.state, params);
        this.state = { ...this.state, ...newState };

        // Recompute derives
        this.recomputeDerives();

        // Update DOM
        this.updateDOM();

        return v;
      },

      // Recompute all derives using client functions
      recomputeDerives() {
        for (const [name, _value] of Object.entries(this.derives)) {
          const fn = this.fns[name];
          if (fn) {
            try {
              this.derives[name] = fn(this.state);
            } catch (e) {
              console.error(`[Lavash.Optimistic] Error computing derive ${name}:`, e);
            }
          }
        }
      },

      // Update DOM elements that display state/derives
      updateDOM() {
        // Find elements with data-lavash-field and update their text content
        this.el.querySelectorAll("[data-lavash-field]").forEach(el => {
          const field = el.dataset.lavashField;
          const value = this.state[field] ?? this.derives[field];
          if (value !== undefined) {
            el.textContent = value;
          }
        });
      },

      // Confirm a version (called when server responds)
      confirm(version) {
        if (version === this.version) {
          this.confirmedVersion = version;
        }
      }
    };

    export { LavashOptimistic };
    """
  end
end
