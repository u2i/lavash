/**
 * LavashOptimistic Hook
 *
 * Provides client-side optimistic updates for Lavash LiveViews.
 *
 * This hook automatically reads generated optimistic functions from the DSL.
 * No manual registration required - functions are injected as JSON in the page.
 *
 * Usage:
 * 1. Add `optimistic: true` to state/derive declarations in your LiveView
 * 2. Add data-optimistic="actionName" to buttons/elements
 * 3. Add data-optimistic-display="fieldName" to elements that display state
 * 4. (Optional) Define custom client-side functions via ColocatedJS for complex logic
 */

// Registry for optimistic function modules (for custom overrides)
window.Lavash = window.Lavash || {};
window.Lavash.optimistic = window.Lavash.optimistic || {};

// Helper to register custom optimistic functions for a module
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

    // Load generated functions from inline JSON script tag
    this.loadGeneratedFunctions();

    // Merge with any custom registered functions (custom overrides generated)
    const customFns = this.moduleName ? (window.Lavash.optimistic[this.moduleName] || {}) : {};
    this.fns = { ...this.fns, ...customFns };

    // Also check for derive names from custom fns
    if (!this.deriveNames || this.deriveNames.length === 0) {
      // Infer derives from function names that match known patterns
      this.deriveNames = Object.keys(this.fns).filter(k =>
        k.endsWith("_chips") || k.endsWith("_chip") || k === "doubled" || k === "fact"
      );
    }

    console.log("[LavashOptimistic] Mounted with state:", this.state);
    console.log("[LavashOptimistic] Module:", this.moduleName);
    console.log("[LavashOptimistic] Available functions:", Object.keys(this.fns));
    console.log("[LavashOptimistic] Derives:", this.deriveNames);
    console.log("[LavashOptimistic] window.Lavash.optimistic:", window.Lavash?.optimistic);

    // Intercept clicks on elements with data-optimistic
    this.el.addEventListener("click", this.handleClick.bind(this), true);
    // Intercept input/change on elements with data-optimistic-field
    this.el.addEventListener("input", this.handleInput.bind(this), true);
  },

  loadGeneratedFunctions() {
    // Look for the generated functions script tag
    const scriptEl = this.el.querySelector("#lavash-optimistic-fns");
    if (scriptEl) {
      try {
        // Parse the JSON and eval to get functions
        // The content is a JS object literal, so we need to eval it
        const fnCode = scriptEl.textContent.trim();
        if (fnCode) {
          // Use Function constructor to evaluate the object literal
          const fnObj = new Function(`return ${fnCode}`)();
          this.fns = fnObj;
          this.deriveNames = fnObj.__derives__ || [];
          this.fieldNames = fnObj.__fields__ || [];
        } else {
          this.fns = {};
          this.deriveNames = [];
          this.fieldNames = [];
        }
      } catch (e) {
        console.error("[LavashOptimistic] Error parsing generated functions:", e);
        this.fns = {};
        this.deriveNames = [];
        this.fieldNames = [];
      }
    } else {
      this.fns = {};
      this.deriveNames = [];
      this.fieldNames = [];
    }
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
    // Look for derive functions and recompute them using metadata from DSL
    // this.deriveNames is populated from __derives__ in the generated functions
    for (const [name, fn] of Object.entries(this.fns)) {
      if (this.deriveNames.includes(name) || name.endsWith("_derive")) {
        try {
          const result = fn(this.state);
          // Store the derive result directly - derives always produce a value
          this.state[name] = result;
          console.log(`[LavashOptimistic] Derive ${name} =`, result);
        } catch (err) {
          console.error(`[LavashOptimistic] Error computing derive ${name}:`, err);
        }
      }
    }
  },

  updateDOM() {
    // Update all elements with data-optimistic-display attribute (text content)
    const displayElements = this.el.querySelectorAll("[data-optimistic-display]");
    displayElements.forEach(el => {
      const fieldName = el.dataset.optimisticDisplay;
      const value = this.state[fieldName];
      if (value !== undefined) {
        el.textContent = value;
      }
    });

    // Update all elements with data-optimistic-class attribute (class from map)
    // Format: data-optimistic-class="roast_chips.light" means state.roast_chips["light"]
    const classElements = this.el.querySelectorAll("[data-optimistic-class]");
    console.log(`[LavashOptimistic] Found ${classElements.length} class elements to update`);
    classElements.forEach(el => {
      const path = el.dataset.optimisticClass;
      const [field, key] = path.split(".");
      const classMap = this.state[field];
      console.log(`[LavashOptimistic] Class update: ${path} -> field=${field}, key=${key}, classMap=`, classMap);
      if (classMap && key && classMap[key]) {
        console.log(`[LavashOptimistic] Setting class on element to:`, classMap[key]);
        el.className = classMap[key];
      } else if (classMap && !key) {
        // Direct field reference (e.g., "in_stock_chip")
        console.log(`[LavashOptimistic] Setting direct class to:`, classMap);
        el.className = classMap;
      }
    });

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
