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

    // URL fields that should be synced to the browser URL
    this.urlFields = JSON.parse(this.el.dataset.lavashUrlFields || "[]");

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

    // Clear LiveView's element lock so rapid clicks on the same element work.
    // LiveView sets data-phx-ref-src during click handling to prevent duplicate
    // submissions, but for optimistic updates we want to allow rapid clicks since
    // each click is meaningful (e.g., select then unselect).
    //
    // We clear it synchronously in capture phase (before LiveView's bubble handler),
    // and also schedule a microtask for after LiveView sets it during this click.
    target.removeAttribute("data-phx-ref-src");
    target.removeAttribute("data-phx-ref-lock");

    // Also clear after LiveView's handler sets it (for this click's event to be unlocked for future clicks)
    setTimeout(() => {
      target.removeAttribute("data-phx-ref-src");
      target.removeAttribute("data-phx-ref-lock");
    }, 0);

    // Let the normal phx-click propagate to the server
  },

  handleInput(e) {
    const target = e.target.closest("[data-optimistic-field]");
    if (!target) return;

    // Skip if input is inside a child component (has its own hook)
    // Child components handle their own inputs and sync to parent via syncParentUrl()
    const childHook = target.closest("[data-lavash-state]");
    if (childHook && childHook !== this.el) {
      return;
    }

    const fieldName = target.dataset.optimisticField;
    const value = target.type === "range" || target.type === "number"
      ? Number(target.value)
      : target.value;

    // Directly update state and pending
    this.state[fieldName] = value;
    this.pending[fieldName] = value;

    // Recompute derives and update DOM
    this.recomputeDerives();
    this.updateDOM();

    // Sync URL fields immediately (optimistic URL update)
    this.syncUrl();
  },

  runOptimisticAction(actionName, value) {
    // First check cached functions, then check module registry (for dynamically added component functions)
    let fn = this.fns[actionName];

    if (!fn && this.moduleName) {
      // Check if a component has registered this function dynamically
      const moduleFns = window.Lavash.optimistic[this.moduleName];
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

    if (!fn) return;

    // Bump client version - this will be compared against server version to detect stale patches
    this.clientVersion++;

    // Run the client-side function to get state delta
    try {
      const delta = fn(this.state, value);

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

      // Sync URL fields immediately (optimistic URL update)
      this.syncUrl();

    } catch (err) {
      // Silently ignore client-side errors - server will be source of truth
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
        } catch (err) {
          // Ignore derive computation errors
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

    // Recompute in dependency order
    for (const name of sorted) {
      const fn = this.fns[name];
      if (fn) {
        try {
          const result = fn(this.state);
          this.state[name] = result;
        } catch (err) {
          // Ignore derive computation errors
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
      if (visiting.has(name)) return; // Cycle detected

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
    classElements.forEach(el => {
      const path = el.dataset.optimisticClass;
      const [field, key] = path.split(".");
      const classMap = this.state[field];
      if (classMap && key && classMap[key]) {
        el.className = classMap[key];
      } else if (classMap && !key) {
        // Direct field reference (e.g., "in_stock_chip")
        el.className = classMap;
      }
    });
  },

  // Sync URL fields to browser URL without triggering navigation
  // Uses Elixir-style array params: field[]=val1&field[]=val2
  syncUrl() {
    if (this.urlFields.length === 0) return;

    const url = new URL(window.location.href);

    // Build query string manually to avoid URLSearchParams encoding [] as %5B%5D
    const params = [];

    for (const field of this.urlFields) {
      const value = this.state[field];

      if (Array.isArray(value)) {
        // Elixir-style array params: field[]=val1&field[]=val2
        for (const v of value) {
          params.push(`${encodeURIComponent(field)}[]=${encodeURIComponent(v)}`);
        }
      } else if (value !== null && value !== undefined && value !== "") {
        params.push(`${encodeURIComponent(field)}=${encodeURIComponent(value)}`);
      }
    }

    // Preserve non-lavash params from the current URL
    for (const [key, val] of url.searchParams.entries()) {
      // Skip lavash-managed fields (both scalar and array forms)
      const baseKey = key.replace(/\[\]$/, "");
      if (!this.urlFields.includes(baseKey)) {
        params.push(`${encodeURIComponent(key)}=${encodeURIComponent(val)}`);
      }
    }

    const newSearch = params.length > 0 ? `?${params.join("&")}` : "";
    const newUrl = url.origin + url.pathname + newSearch + url.hash;

    if (newUrl !== window.location.href) {
      window.history.replaceState(window.history.state, "", newUrl);
    }
  },

  // Check if a field has pending sources (for derives)
  hasPendingSources(field) {
    const meta = this.graph[field];
    if (!meta || !meta.deps) return false;

    // Check if any dependency is pending (either directly or transitively)
    for (const dep of meta.deps) {
      if (dep in this.pending) return true;
      // Recursively check if dep is a derive with pending sources
      if (this.hasPendingSources(dep)) return true;
    }
    return false;
  },

  updated() {
    // Server patch arrived - check version to decide whether to accept
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

    if (newServerVersion >= this.clientVersion) {
      // Server version is current or ahead - accept full server state
      this.serverVersion = newServerVersion;
      this.clientVersion = newServerVersion;
      this.state = { ...serverState };
      this.pending = {};
    } else {
      // Server version is stale (from an earlier action) - selectively merge
      // Only accept fields that don't have pending optimistic updates
      // For derives, check if any of their source fields are pending
      for (const [key, serverValue] of Object.entries(serverState)) {
        const isPending = (key in this.pending) || this.hasPendingSources(key);
        if (!isPending) {
          this.state[key] = serverValue;
        }
      }
      // Update server version tracking but keep client version
      this.serverVersion = newServerVersion;
    }

    // Recompute derives based on current state and update DOM
    this.recomputeDerives();
    this.updateDOM();
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick.bind(this), true);
  }
};

export { LavashOptimistic };
