/**
 * LavashOptimistic Hook
 *
 * Provides client-side optimistic updates for Lavash LiveViews.
 *
 * Usage:
 * 1. Add phx-hook="LavashOptimistic" to your root element
 * 2. Add data-lavash-state={Jason.encode!(state)} with current state
 * 3. Add data-optimistic="actionName" to buttons/elements
 * 4. Define client-side functions in ColocatedJS
 * 5. Register the functions via window.Lavash.optimistic[moduleName]
 */

// Registry for optimistic function modules
window.Lavash = window.Lavash || {};
window.Lavash.optimistic = window.Lavash.optimistic || {};

// Helper to register optimistic functions for a module
window.Lavash.registerOptimistic = function(moduleName, fns) {
  window.Lavash.optimistic[moduleName] = fns;
};

const LavashOptimistic = {
  mounted() {
    this.state = JSON.parse(this.el.dataset.lavashState || "{}");
    // Track which fields have pending optimistic updates (field -> expected value)
    this.pending = {};

    // Try to find the optimistic functions for this module
    this.moduleName = this.el.dataset.lavashModule || null;
    this.fns = this.moduleName ? (window.Lavash.optimistic[this.moduleName] || {}) : {};

    console.log("[LavashOptimistic] Mounted with state:", this.state);
    console.log("[LavashOptimistic] Module:", this.moduleName, "Functions:", Object.keys(this.fns));

    // Intercept clicks on elements with data-optimistic
    this.el.addEventListener("click", this.handleClick.bind(this), true);
    // Intercept input/change on elements with data-optimistic-field
    this.el.addEventListener("input", this.handleInput.bind(this), true);
  },

  handleClick(e) {
    const target = e.target.closest("[data-optimistic]");
    if (!target) return;

    const actionName = target.dataset.optimistic;
    const value = target.dataset.optimisticValue;
    this.runOptimisticAction(actionName, value);
  },

  handleInput(e) {
    const target = e.target.closest("[data-optimistic-field]");
    if (!target) return;

    const fieldName = target.dataset.optimisticField;
    const value = target.type === "range" || target.type === "number"
      ? Number(target.value)
      : target.value;

    console.log(`[LavashOptimistic] Input field ${fieldName} = ${value}`);

    // Directly update state and pending
    this.state[fieldName] = value;
    this.pending[fieldName] = value;

    // Recompute derives and update DOM
    this.recomputeDerives();
    this.updateDOM();
  },

  runOptimisticAction(actionName, value) {
    const fn = this.fns[actionName];

    if (!fn) {
      console.log(`[LavashOptimistic] No client function for "${actionName}", letting server handle it`);
      return;
    }

    console.log(`[LavashOptimistic] Running optimistic action: ${actionName}`, value ? `with value: ${value}` : "");

    // Run the client-side function to get state delta
    try {
      const delta = fn(this.state, value);
      console.log(`[LavashOptimistic] State delta:`, delta);

      // Apply delta to state and track pending fields
      for (const [key, value] of Object.entries(delta)) {
        this.state[key] = value;
        this.pending[key] = value;
      }

      // Recompute derives
      this.recomputeDerives();

      // Update the DOM immediately
      this.updateDOM();

    } catch (err) {
      console.error(`[LavashOptimistic] Error in action ${actionName}:`, err);
    }
  },

  recomputeDerives() {
    // Look for derive functions and recompute them
    // These are functions that compute a value from state (not actions that return deltas)
    const deriveNames = ["doubled", "fact"];
    for (const [name, fn] of Object.entries(this.fns)) {
      if (deriveNames.includes(name) || name.endsWith("_derive")) {
        try {
          const result = fn(this.state);
          // If result is not an object or doesn't look like a state delta, it's a derive
          if (typeof result !== "object" || result === null) {
            this.state[name] = result;
          }
        } catch (err) {
          console.error(`[LavashOptimistic] Error computing derive ${name}:`, err);
        }
      }
    }
  },

  updateDOM() {
    // Update count display
    const countEl = document.getElementById("count-display");
    if (countEl && this.state.count !== undefined) {
      countEl.textContent = this.state.count;
    }

    // Update count in factorial label
    const factCountEl = document.getElementById("fact-count-display");
    if (factCountEl && this.state.count !== undefined) {
      factCountEl.textContent = this.state.count;
    }

    // Update multiplier display
    const multiplierEl = document.getElementById("multiplier-display");
    if (multiplierEl && this.state.multiplier !== undefined) {
      multiplierEl.textContent = this.state.multiplier;
    }

    // Update doubled display
    const doubledEl = document.getElementById("doubled-display");
    if (doubledEl && this.state.doubled !== undefined) {
      doubledEl.textContent = this.state.doubled;
    }

    // Update fact display
    const factEl = document.getElementById("fact-display");
    if (factEl && this.state.fact !== undefined) {
      factEl.textContent = this.state.fact;
    }

    console.log("[LavashOptimistic] DOM updated with state:", this.state);
  },

  updated() {
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

    console.log("[LavashOptimistic] Server state:", serverState, "Pending:", this.pending);

    // For each field, decide whether to accept server value or keep optimistic value
    for (const [key, serverValue] of Object.entries(serverState)) {
      if (key in this.pending) {
        // We have a pending optimistic value for this field
        if (serverValue === this.pending[key]) {
          // Server caught up to our expected value - clear pending
          delete this.pending[key];
          this.state[key] = serverValue;
          console.log(`[LavashOptimistic] ${key}: server caught up (${serverValue})`);
        } else {
          // Server is stale for this field - keep our optimistic value
          console.log(`[LavashOptimistic] ${key}: server stale (got ${serverValue}, expected ${this.pending[key]})`);
        }
      } else {
        // No pending update for this field - accept server value
        this.state[key] = serverValue;
      }
    }

    // Recompute derives based on current state
    this.recomputeDerives();

    // Update DOM if we still have pending values
    if (Object.keys(this.pending).length > 0) {
      this.updateDOM();
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick.bind(this), true);
  }
};

export { LavashOptimistic };
