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
 * 4. Add data-synced="fieldName" or data-synced="field.path" for input bindings
 * 5. (Optional) Define custom client-side functions via ColocatedJS for complex logic
 */

import { SyncedVar, SyncedVarStore } from "./synced_var.js";

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

    // SyncedVarStore for flattened path-based state management
    // Each leaf path (e.g., "params.name") gets its own SyncedVar
    this.store = new SyncedVarStore();

    // Version tracking for stale patch rejection
    // Client version starts at server version and bumps on each optimistic action
    this.serverVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    this.clientVersion = this.serverVersion;

    // Try to find the optimistic functions for this module
    this.moduleName = this.el.dataset.lavashModule || null;

    // URL fields that should be synced to the browser URL
    this.urlFields = JSON.parse(this.el.dataset.lavashUrlFields || "[]");

    // Form field state tracking (client-side only)
    // Maps field path -> { touched: boolean }
    this.fieldState = {};

    // Form submitted state (for showing all errors)
    this.formSubmitted = false;

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

    // Intercept input/change on elements with data-optimistic-field or data-synced
    this.el.addEventListener("input", this.handleInput.bind(this), true);

    // Track blur events for touched state
    this.el.addEventListener("blur", this.handleBlur.bind(this), true);

    // Track form submit for formSubmitted state
    this.el.addEventListener("submit", this.handleFormSubmit.bind(this), true);
  },

  /**
   * Get pending count for onBeforeElUpdated DOM preservation check.
   * NOTE: This must be a method (not a getter) because Phoenix LiveView's
   * ViewHook constructor iterates over object properties with for...in
   * and evaluates all values including getters. At that point, this.store
   * is undefined, which would cause an error.
   */
  getPendingCount() {
    return this.store ? this.store.getPendingPaths().length : 0;
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

  handleBlur(e) {
    // Track touched state when user leaves a synced field
    const target = e.target.closest("[data-synced], [data-optimistic-field], [data-optimistic-input]");
    if (!target) return;

    const fieldPath = target.dataset.synced || target.dataset.optimisticField || target.dataset.optimisticInput;
    if (!fieldPath) return;

    // Mark field as touched
    if (!this.fieldState[fieldPath]) {
      this.fieldState[fieldPath] = {};
    }
    this.fieldState[fieldPath].touched = true;

    // Update show_errors state
    this.updateShowErrors(fieldPath);

    // Recompute derives that depend on show_errors (e.g., email_at_error_visible)
    const parts = fieldPath.split(".");
    if (parts.length >= 2) {
      const paramsField = parts[0];
      const fieldName = parts.slice(1).join("_");
      const formName = paramsField.replace(/_params$/, "");
      const showErrorsKey = `${formName}_${fieldName}_show_errors`;
      this.recomputeDerives([showErrorsKey]);
    }

    this.updateDOM();
  },

  handleFormSubmit(e) {
    // Mark form as submitted - this shows all errors
    this.formSubmitted = true;

    // Mark all fields as touched
    for (const path of Object.keys(this.fieldState)) {
      this.fieldState[path].touched = true;
    }

    // Also mark fields from synced inputs that may not have been touched
    const syncedInputs = this.el.querySelectorAll("[data-synced], [data-optimistic-field], [data-optimistic-input]");
    syncedInputs.forEach(input => {
      const fieldPath = input.dataset.synced || input.dataset.optimisticField || input.dataset.optimisticInput;
      if (fieldPath) {
        if (!this.fieldState[fieldPath]) {
          this.fieldState[fieldPath] = {};
        }
        this.fieldState[fieldPath].touched = true;
        this.updateShowErrors(fieldPath);
      }
    });

    this.updateDOM();
  },

  /**
   * Update *_show_errors state for a field based on touched/submitted status.
   */
  updateShowErrors(fieldPath) {
    // Extract form name and field name from path like "registration_params.name"
    // The show_errors field would be "registration_name_show_errors"
    const parts = fieldPath.split(".");
    if (parts.length < 2) return;

    const paramsField = parts[0]; // e.g., "registration_params"
    const fieldName = parts.slice(1).join("_"); // e.g., "name" or "nested_field"

    // Derive form name from params field (remove "_params" suffix)
    const formName = paramsField.replace(/_params$/, "");

    // Compute show_errors: touched || formSubmitted
    const touched = this.fieldState[fieldPath]?.touched || false;
    const showErrors = touched || this.formSubmitted;

    // Update state
    const showErrorsKey = `${formName}_${fieldName}_show_errors`;
    this.state[showErrorsKey] = showErrors;
  },

  handleInput(e) {
    // Support data-synced (preferred), data-optimistic-field, and data-optimistic-input
    const target = e.target.closest("[data-synced], [data-optimistic-field], [data-optimistic-input]");
    if (!target) return;

    // Skip if input is inside a child component (has its own hook)
    // Child components handle their own inputs and sync to parent via syncParentUrl()
    const childHook = target.closest("[data-lavash-state]");
    if (childHook && childHook !== this.el) {
      return;
    }

    // Get the field path from data-synced (preferred) or legacy attributes
    const fieldPath = target.dataset.synced || target.dataset.optimisticField || target.dataset.optimisticInput;
    // For form inputs, keep as string to match Elixir params behavior
    const value = target.value;

    // Get or create a SyncedVar for this path (for version/pending tracking)
    // Use undefined as initial value - will be set properly on first setOptimistic
    const syncedVar = this.store.get(fieldPath);

    // Mark as optimistically updated (this bumps version for pending tracking)
    syncedVar.setOptimistic(value);

    // Update state - this is the source of truth for derives
    this.setStateAtPath(fieldPath, value);

    // Bump client version for stale patch rejection
    this.clientVersion++;

    // Determine root field for derive recomputation
    const dotIndex = fieldPath.indexOf(".");
    const rootField = dotIndex > 0 ? fieldPath.substring(0, dotIndex) : fieldPath;

    // Recompute derives affected by the root field
    this.recomputeDerives([rootField]);

    this.updateDOM();

    // Sync URL fields immediately (optimistic URL update)
    this.syncUrl();
  },

  /**
   * Set a value in state at a dotted path.
   */
  setStateAtPath(path, value) {
    const parts = path.split(".");
    if (parts.length === 1) {
      this.state[path] = value;
      return;
    }

    // Navigate to parent, creating intermediates as needed
    let current = this.state;
    for (let i = 0; i < parts.length - 1; i++) {
      const part = parts[i];
      if (!(part in current) || typeof current[part] !== "object") {
        current[part] = {};
      }
      current = current[part];
    }
    current[parts[parts.length - 1]] = value;
  },

  /**
   * Get a value from state at a dotted path.
   */
  getStateAtPath(path) {
    const parts = path.split(".");
    let current = this.state;
    for (const part of parts) {
      if (current == null || typeof current !== "object") return undefined;
      current = current[part];
    }
    return current;
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

      // Apply delta to state and track in SyncedVarStore
      const changedFields = [];
      for (const [key, val] of Object.entries(delta)) {
        this.state[key] = val;
        // Create/update SyncedVar for this field
        const syncedVar = this.store.get(key, val, (newVal) => {
          this.state[key] = newVal;
        });
        syncedVar.setOptimistic(val);
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
          console.error("[Lavash] Error computing", name, err);
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

    // Update all elements with data-optimistic-visible attribute (show/hide based on boolean)
    const visibleElements = this.el.querySelectorAll("[data-optimistic-visible]");
    visibleElements.forEach(el => {
      const fieldName = el.dataset.optimisticVisible;
      const value = this.state[fieldName];
      if (value) {
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Update all elements with data-optimistic-enabled attribute (enable/disable based on boolean)
    const enabledElements = this.el.querySelectorAll("[data-optimistic-enabled]");
    enabledElements.forEach(el => {
      const fieldName = el.dataset.optimisticEnabled;
      const value = this.state[fieldName];
      el.disabled = !value;
    });

    // Update all elements with data-optimistic-class-toggle attribute
    // Format: "fieldName:trueClasses:falseClasses"
    const classToggleElements = this.el.querySelectorAll("[data-optimistic-class-toggle]");
    classToggleElements.forEach(el => {
      const spec = el.dataset.optimisticClassToggle;
      const [fieldName, trueClasses, falseClasses] = spec.split(":");
      const value = this.state[fieldName];

      // Remove all managed classes first
      const allClasses = (trueClasses + " " + falseClasses).split(/\s+/).filter(c => c);
      el.classList.remove(...allClasses);

      // Add the appropriate classes
      const classesToAdd = (value ? trueClasses : falseClasses).split(/\s+/).filter(c => c);
      el.classList.add(...classesToAdd);
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

    // Update all elements with data-optimistic-errors attribute
    // Only show errors if the corresponding show_errors field is true (touched || submitted)
    const errorElements = this.el.querySelectorAll("[data-optimistic-errors]");
    errorElements.forEach(el => {
      const errorsField = el.dataset.optimisticErrors; // e.g., "registration_name_errors"
      const errors = this.state[errorsField] || [];

      // Derive show_errors field name from errors field
      // "registration_name_errors" -> "registration_name_show_errors"
      const showErrorsField = errorsField.replace(/_errors$/, "_show_errors");
      const showErrors = this.state[showErrorsField] ?? false;

      // Clear existing error content
      el.innerHTML = "";

      // Only render errors if showErrors is true and there are errors
      if (showErrors && errors.length > 0) {
        errors.forEach(error => {
          const p = document.createElement("p");
          p.className = "text-red-500 text-sm";
          p.textContent = error;
          el.appendChild(p);
        });
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Update success indicators - only show if field is touched/submitted AND valid
    const successElements = this.el.querySelectorAll("[data-optimistic-success]");
    successElements.forEach(el => {
      const validField = el.dataset.optimisticSuccess; // e.g., "registration_name_valid" or "email_valid"
      const isValid = this.state[validField] ?? false;

      // Use explicit show_errors field if provided, otherwise derive from valid field
      const showErrorsField = el.dataset.optimisticShowErrors ||
        validField.replace(/_valid$/, "_show_errors");
      const showErrors = this.state[showErrorsField] ?? false;

      // Show success only if touched/submitted AND valid
      if (showErrors && isValid) {
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Notify bound children to refresh from parent state
    this.notifyChildren();
  },

  notifyChildren() {
    // Find all child hooks that bind to this parent
    const children = this.el.querySelectorAll("[phx-hook]");
    children.forEach(el => {
      const hook = el.__lavash_hook__;
      if (hook?.refreshFromParent) {
        hook.refreshFromParent(this);
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

    const pendingPaths = this.store.getPendingPaths();

    // Check if any dependency is pending (either directly or transitively)
    for (const dep of meta.deps) {
      // Check if dep or any nested path under it is pending
      if (pendingPaths.some(p => p === dep || p.startsWith(dep + "."))) return true;
      // Recursively check if dep is a derive with pending sources
      if (this.hasPendingSources(dep)) return true;
    }
    return false;
  },

  updated() {
    // Server patch arrived - check version to decide whether to accept
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

    // Update SyncedVars from server state (flattened paths)
    // serverUpdate only updates vars that are not pending
    this.store.serverUpdate(serverState);

    // Also update our state object for fields without pending changes
    const pendingPaths = new Set(this.store.getPendingPaths());
    this.mergeServerState(serverState, "", pendingPaths);

    // Update version tracking
    if (newServerVersion >= this.clientVersion) {
      this.serverVersion = newServerVersion;
      this.clientVersion = newServerVersion;
    } else {
      this.serverVersion = newServerVersion;
    }

    // Recompute derives based on current state
    this.recomputeDerives();

    // Update DOM after server patch
    this.updateDOM();

    // If input is focused, restore optimistic value if server morphed it away
    const activeEl = document.activeElement;
    const inputHasFocus = activeEl &&
      this.el.contains(activeEl) &&
      (activeEl.matches("[data-synced], [data-optimistic-input], [data-optimistic-field]"));

    if (inputHasFocus) {
      const fieldPath = activeEl.dataset.synced || activeEl.dataset.optimisticInput || activeEl.dataset.optimisticField;
      if (fieldPath && this.store.has(fieldPath)) {
        const val = this.store.getValue(fieldPath);
        if (val !== undefined && activeEl.value !== val) {
          activeEl.value = val;
        }
      }
    }
  },

  /**
   * Merge server state into this.state, skipping paths that are pending.
   */
  mergeServerState(obj, prefix, pendingPaths) {
    for (const [key, value] of Object.entries(obj)) {
      const path = prefix ? `${prefix}.${key}` : key;

      // Check if this exact path or any child path is pending
      const hasPendingChild = [...pendingPaths].some(p => p === path || p.startsWith(path + "."));

      if (value !== null && typeof value === "object" && !Array.isArray(value)) {
        // Recurse into nested objects
        this.mergeServerState(value, path, pendingPaths);
      } else if (!hasPendingChild) {
        // Leaf value with no pending - update state
        this.setStateAtPath(path, value);
      }
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick.bind(this), true);
    this.el.removeEventListener("input", this.handleInput.bind(this), true);
    this.el.removeEventListener("blur", this.handleBlur.bind(this), true);
    this.el.removeEventListener("submit", this.handleFormSubmit.bind(this), true);
  }
};

export { LavashOptimistic };
