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

    // Version tracking for stale patch rejection
    // Client version starts at server version and bumps on each optimistic action
    this.serverVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    this.clientVersion = this.serverVersion;

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

    // Expose hook instance on element for onBeforeElUpdated access
    this.el.__lavash_hook__ = this;

    console.log("[LavashOptimistic] Mounted with state:", this.state);
    console.log("[LavashOptimistic] Module:", this.moduleName);
    console.log("[LavashOptimistic] Version:", this.clientVersion);
    console.log("[LavashOptimistic] Available functions:", Object.keys(this.fns));
    console.log("[LavashOptimistic] Derives:", this.deriveNames);

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
          this.graph = fnObj.__graph__ || {};
        } else {
          this.fns = {};
          this.deriveNames = [];
          this.fieldNames = [];
          this.graph = {};
        }
      } catch (e) {
        console.error("[LavashOptimistic] Error parsing generated functions:", e);
        this.fns = {};
        this.deriveNames = [];
        this.fieldNames = [];
        this.graph = {};
      }
    } else {
      this.fns = {};
      this.deriveNames = [];
      this.fieldNames = [];
      this.graph = {};
    }

    // Execute any component-generated optimistic scripts (LiveView doesn't auto-execute inline scripts)
    this.executeComponentScripts();
  },

  executeComponentScripts() {
    // Find all script tags with id ending in "-optimistic" (component-generated)
    const scripts = this.el.querySelectorAll('script[id$="-optimistic"]');
    scripts.forEach(script => {
      // Skip the main functions script
      if (script.id === "lavash-optimistic-fns") return;

      try {
        // Execute the script content (it's an IIFE that registers functions)
        new Function(script.textContent)();
        console.log(`[LavashOptimistic] Executed component script: ${script.id}`);
      } catch (e) {
        console.error(`[LavashOptimistic] Error executing component script ${script.id}:`, e);
      }
    });

    // After executing component scripts, merge any registered functions into our local state
    this.mergeRegisteredFunctions();
  },

  mergeRegisteredFunctions() {
    if (!this.moduleName) return;

    const moduleFns = window.Lavash.optimistic[this.moduleName];
    if (!moduleFns) return;

    // Merge functions
    for (const [name, fn] of Object.entries(moduleFns)) {
      if (typeof fn === 'function' && !this.fns[name]) {
        this.fns[name] = fn;
        console.log(`[LavashOptimistic] Merged function: ${name}`);
      }
    }

    // Merge derives
    if (moduleFns.__derives__) {
      for (const d of moduleFns.__derives__) {
        if (!this.deriveNames.includes(d)) {
          this.deriveNames.push(d);
        }
        // Add to graph if not present (component derives depend on their state field)
        if (!this.graph[d]) {
          // Infer dependency from derive name pattern (e.g., "roast_chips" depends on "roast")
          const match = d.match(/^(.+)_chips?$/);
          if (match) {
            this.graph[d] = { deps: [match[1]] };
            console.log(`[LavashOptimistic] Added to graph: ${d} -> deps: [${match[1]}]`);
          }
        }
      }
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
    // First check cached functions, then check module registry (for dynamically added component functions)
    let fn = this.fns[actionName];

    if (!fn && this.moduleName) {
      // Check if a component has registered this function dynamically
      const moduleFns = window.Lavash.optimistic[this.moduleName];
      console.log(`[LavashOptimistic] Checking module registry for ${actionName}:`, moduleFns, Object.keys(moduleFns || {}));
      if (moduleFns && moduleFns[actionName]) {
        fn = moduleFns[actionName];
        // Cache it for future use
        this.fns[actionName] = fn;
        // Also check for associated derives
        if (moduleFns.__derives__) {
          for (const d of moduleFns.__derives__) {
            if (!this.deriveNames.includes(d)) {
              this.deriveNames.push(d);
            }
            if (moduleFns[d] && !this.fns[d]) {
              this.fns[d] = moduleFns[d];
            }
          }
        }
      }
    }

    if (!fn) {
      console.log(`[LavashOptimistic] No client function for "${actionName}", letting server handle it`);
      return;
    }

    // Bump client version - this will be compared against server version to detect stale patches
    this.clientVersion++;
    console.log(`[LavashOptimistic] Running optimistic action: ${actionName} (v${this.clientVersion})`, value ? `with value: ${value}` : "");

    // Run the client-side function to get state delta
    try {
      const delta = fn(this.state, value);
      console.log(`[LavashOptimistic] State delta:`, delta);

      // Apply delta to state and track pending fields
      const changedFields = [];
      for (const [key, val] of Object.entries(delta)) {
        this.state[key] = val;
        this.pending[key] = val;
        changedFields.push(key);
      }

      // Recompute derives affected by the changed fields
      this.recomputeDerives(changedFields);

      // Update the DOM immediately
      this.updateDOM();

    } catch (err) {
      console.error(`[LavashOptimistic] Error in action ${actionName}:`, err);
    }
  },

  recomputeDerives(changedFields = null) {
    // Use graph-based recomputation if available
    if (Object.keys(this.graph).length > 0) {
      this.recomputeGraph(changedFields);
    } else {
      // Fallback to simple iteration for backwards compatibility
      this.recomputeDerivesSimple();
    }
  },

  // Simple derive recomputation (legacy mode)
  recomputeDerivesSimple() {
    for (const [name, fn] of Object.entries(this.fns)) {
      if (this.deriveNames.includes(name) || name.endsWith("_derive")) {
        try {
          const result = fn(this.state);
          this.state[name] = result;
          console.log(`[LavashOptimistic] Derive ${name} =`, result);
        } catch (err) {
          console.error(`[LavashOptimistic] Error computing derive ${name}:`, err);
        }
      }
    }
  },

  // Graph-based derive recomputation
  recomputeGraph(changedFields = null) {
    // Find all derives affected by changed fields
    const affected = this.findAffectedDerives(changedFields);

    // Topologically sort affected derives
    const sorted = this.topologicalSort(affected);

    console.log(`[LavashOptimistic] Recomputing graph: changed=${JSON.stringify(changedFields)}, affected=${JSON.stringify(affected)}, sorted=${JSON.stringify(sorted)}`);

    // Recompute in dependency order
    for (const name of sorted) {
      const fn = this.fns[name];
      if (fn) {
        try {
          const result = fn(this.state);
          this.state[name] = result;
          console.log(`[LavashOptimistic] Derive ${name} =`, result);
        } catch (err) {
          console.error(`[LavashOptimistic] Error computing derive ${name}:`, err);
        }
      }
    }
  },

  // Find all derives affected by changed fields (transitive)
  findAffectedDerives(changedFields) {
    // If no specific fields, recompute all
    if (!changedFields) {
      return Object.keys(this.graph);
    }

    const affected = new Set();
    const queue = [...changedFields];

    while (queue.length > 0) {
      const field = queue.shift();

      // Find derives that depend on this field
      for (const [deriveName, meta] of Object.entries(this.graph)) {
        if (meta.deps && meta.deps.includes(field) && !affected.has(deriveName)) {
          affected.add(deriveName);
          // This derive's output might affect other derives
          queue.push(deriveName);
        }
      }
    }

    return Array.from(affected);
  },

  // Topological sort of derive names based on dependencies
  topologicalSort(deriveNames) {
    const result = [];
    const visited = new Set();
    const visiting = new Set(); // For cycle detection

    const visit = (name) => {
      if (visited.has(name)) return;
      if (visiting.has(name)) {
        console.warn(`[LavashOptimistic] Cycle detected at ${name}`);
        return;
      }

      visiting.add(name);

      // Visit dependencies first
      const meta = this.graph[name];
      if (meta && meta.deps) {
        for (const dep of meta.deps) {
          // Only visit if dep is also a derive we're computing
          if (deriveNames.includes(dep)) {
            visit(dep);
          }
        }
      }

      visiting.delete(name);
      visited.add(name);
      result.push(name);
    };

    for (const name of deriveNames) {
      visit(name);
    }

    return result;
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
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);

    console.log(`[LavashOptimistic] updated() - server v${newServerVersion}, client v${this.clientVersion}`);

    // Check if server has caught up to our version
    const serverCaughtUp = newServerVersion >= this.clientVersion;

    if (serverCaughtUp) {
      // Server caught up - accept all server state, clear pending
      this.serverVersion = newServerVersion;
      this.state = { ...serverState };
      this.pending = {};
      console.log(`[LavashOptimistic] Server caught up (v${newServerVersion}), accepting all state`);
    } else {
      // Server is stale - keep our optimistic state, but update non-pending fields
      console.log(`[LavashOptimistic] Server stale (v${newServerVersion} < v${this.clientVersion}), keeping optimistic state`);

      for (const [key, serverValue] of Object.entries(serverState)) {
        if (!(key in this.pending)) {
          // No pending update for this field - accept server value
          this.state[key] = serverValue;
        }
      }
    }

    // Recompute derives based on current state
    this.recomputeDerives();

    // Always update DOM after server update to reapply optimistic-controlled classes
    // (server doesn't know about client-side derives like roast_chips)
    this.updateDOM();
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick.bind(this), true);
  }
};

export { LavashOptimistic };
