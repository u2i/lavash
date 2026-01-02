defmodule Lavash.Optimistic do
  @moduledoc """
  Optimistic updates for Lavash LiveViews.

  > #### Deprecated {: .warning}
  >
  > This module provides an alternative API that is not actively used.
  > The main implementation uses `LavashOptimistic` hook with separate data attributes
  > (`data-lavash-state`, `data-lavash-version`, etc.). See `Lavash.LiveView.Runtime`
  > for the active implementation.

  This module provides infrastructure for running actions and derives on the client
  before server confirmation, giving instant UI feedback.

  ## How It Works

  When you mark state fields and derives with `optimistic: true`, Lavash automatically:

  1. **Generates JavaScript** from your DSL action declarations (see `Lavash.Optimistic.JsGenerator`)
  2. **Injects state** into the page as a data attribute for the hook to read
  3. **Wraps your render** to include the optimistic hook infrastructure

  ## Usage

  1. Mark state and derives with `optimistic: true`:

      ```elixir
      state :count, :integer, from: :url, default: 0, optimistic: true

      derive :doubled do
        optimistic true
        argument :count, state(:count)
        run fn %{count: c}, _ -> c * 2 end
      end
      ```

  2. Add data attributes to your template. Use the `<.o>` helper for display elements:

      ```elixir
      import Lavash.LiveView.Helpers

      # Trigger optimistic action on click
      <button phx-click="increment" data-lavash-action="increment">+</button>

      # Display optimistic state (use <.o> to avoid field/value duplication)
      <.o field={:count} value={@count} />

      # Or use raw data attribute
      <div data-lavash-display="count">{@count}</div>

      # Optimistic input binding
      <input data-lavash-bind="multiplier" phx-change="set_multiplier" />
      ```

  3. Register the hook in your `app.js`:

      ```javascript
      import { LavashOptimistic } from "./lavash_optimistic";
      let liveSocket = new LiveSocket("/live", Socket, {
        hooks: { LavashOptimistic }
      });
      ```

  ## Auto-Generated vs Custom Functions

  Simple actions (containing only `set` and `update` operations) are automatically
  converted to JavaScript. For complex derives, provide JavaScript implementations
  via ColocatedJS and register them:

      ```javascript
      import optimistic from "phoenix-colocated/demo/DemoWeb.CounterLive/optimistic";
      window.Lavash.optimistic["DemoWeb.CounterLive"] = optimistic;
      ```

  See `Lavash.Optimistic.JsGenerator` for details on what gets auto-generated.
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
        // Find elements with data-lavash-display and update their text content
        this.el.querySelectorAll("[data-lavash-display]").forEach(el => {
          const field = el.dataset.lavashDisplay;
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
