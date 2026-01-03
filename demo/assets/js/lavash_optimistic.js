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
 * 2. Add data-lavash-action="actionName" to buttons/elements
 * 3. Add data-lavash-display="fieldName" to elements that display state
 * 4. Add data-lavash-bind="fieldName" or data-lavash-bind="field.path" for input bindings
 * 5. (Optional) Define custom client-side functions via ColocatedJS for complex logic
 *
 * Data Attributes Reference:
 *
 * Root Hook Configuration (set on the hook root element):
 * - data-lavash-module: LiveView module name for function lookup
 * - data-lavash-state: JSON-encoded initial state
 * - data-lavash-version: Server state version for stale patch detection
 * - data-lavash-url-fields: JSON array of fields to sync to URL
 * - data-lavash-bindings: JSON map of local->parent field bindings (ClientComponents)
 *
 * User-Facing Attributes (used in templates):
 * - data-lavash-bind: Sync input value to state (e.g., "registration_params.name")
 * - data-lavash-form: Explicit form name for validation (avoids regex parsing)
 * - data-lavash-field: Explicit form field name for validation (avoids regex parsing)
 * - data-lavash-state-field: State field for ClientComponent actions (e.g., "tags", "selected")
 * - data-lavash-valid: Override which state field to check for validity
 * - data-lavash-action: Trigger optimistic action on click
 * - data-lavash-value: Value to pass to action
 * - data-lavash-display: Display state value as text content
 * - data-lavash-visible: Show/hide element based on boolean state (toggles "hidden" class)
 * - data-lavash-enabled: Enable/disable element based on boolean state
 * - data-lavash-toggle: Toggle classes based on boolean (format: "field|trueClasses|falseClasses")
 * - data-lavash-class: Apply class from state map (e.g., "roast_chips.light")
 * - data-lavash-errors: Container for field error messages
 * - data-lavash-error-summary: Container for form error summary
 * - data-lavash-success: Success indicator (shown when valid and touched)
 * - data-lavash-status: Field status indicator (✓/✗)
 * - data-lavash-show-errors: Override which show_errors field to check for visibility
 * - data-lavash-preserve: Prevent morphdom from updating this element
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
    // Maps field path -> { touched: boolean, serverErrors: [], validationRequestId: number }
    this.fieldState = {};

    // Form submitted state (for showing all errors)
    this.formSubmitted = false;

    // Server validation debounce timers: field path -> timeout ID
    this.validationTimers = {};

    // Incremented for each validation request, used to detect stale responses
    this.validationRequestId = 0;

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

    // Intercept clicks on elements with data-lavash-action
    this.el.addEventListener("click", this.handleClick.bind(this), true);

    // Intercept input/change on elements with data-lavash-bind
    this.el.addEventListener("input", this.handleInput.bind(this), true);

    // Track blur events for touched state
    this.el.addEventListener("blur", this.handleBlur.bind(this), true);

    // Track form submit for formSubmitted state
    this.el.addEventListener("submit", this.handleFormSubmit.bind(this), true);

    // Listen for server validation responses
    this.handleEvent("validation_result", (payload) => this.handleValidationResult(payload));
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
    // Load functions from the registry (populated by colocated JS imports in app.js)
    // Functions are keyed by module name (e.g., "DemoWeb.CheckoutDemoLive")
    const fnObj = this.moduleName ? (window.Lavash.optimistic[this.moduleName] || {}) : {};

    this.fns = fnObj;
    this.deriveNames = fnObj.__derives__ || [];
    this.fieldNames = fnObj.__fields__ || [];
    this.graph = fnObj.__graph__ || {};

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
    const target = e.target.closest("[data-lavash-action]");
    if (!target) return;

    const actionName = target.dataset.lavashAction;
    const value = target.dataset.lavashValue;

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
    // Track touched state when user leaves a bound field
    const target = e.target.closest("[data-lavash-bind]");
    if (!target) return;

    const fieldPath = target.dataset.lavashBind;
    if (!fieldPath) return;

    // Mark field as touched
    if (!this.fieldState[fieldPath]) {
      this.fieldState[fieldPath] = { serverErrors: [] };
    }
    this.fieldState[fieldPath].touched = true;

    // Get form/field from explicit attributes or derive from path
    const { formName, fieldName } = this.getFormField(target, fieldPath);
    if (!formName || !fieldName) return;

    // Update show_errors state
    this.updateShowErrors(fieldPath, formName, fieldName);

    // Recompute derives that depend on show_errors
    const showErrorsKey = `${formName}_${fieldName}_show_errors`;
    this.recomputeDerives([showErrorsKey]);

    // Trigger server validation if client validation passes
    this.triggerServerValidation(fieldPath, formName, fieldName, /* immediate */ true);

    this.updateDOM();
  },

  /**
   * Get form name and field name from explicit attributes or derive from field path.
   * Explicit attributes (data-lavash-form, data-lavash-field) take precedence.
   *
   * @param {HTMLElement} el - The input element
   * @param {string} fieldPath - e.g., "registration_params.name"
   * @returns {{ formName: string|null, fieldName: string|null }}
   */
  getFormField(el, fieldPath) {
    // Prefer explicit attributes
    const explicitForm = el.dataset.lavashForm;
    const explicitField = el.dataset.lavashField;

    if (explicitForm && explicitField) {
      return { formName: explicitForm, fieldName: explicitField };
    }

    // Fall back to deriving from path (e.g., "registration_params.name")
    const parts = fieldPath.split(".");
    if (parts.length >= 2) {
      const paramsField = parts[0];
      const fieldName = explicitField || parts.slice(1).join("_");
      const formName = explicitForm || paramsField.replace(/_params$/, "");
      return { formName, fieldName };
    }

    return { formName: null, fieldName: null };
  },

  handleFormSubmit(e) {
    // Mark form as submitted - this shows all errors
    this.formSubmitted = true;

    // Mark all fields as touched
    for (const path of Object.keys(this.fieldState)) {
      this.fieldState[path].touched = true;
    }

    // Collect all bound inputs and mark them as touched
    const boundInputs = this.el.querySelectorAll("[data-lavash-bind]");
    const inputElements = [];
    boundInputs.forEach(input => {
      const fieldPath = input.dataset.lavashBind;
      if (fieldPath) {
        if (!this.fieldState[fieldPath]) {
          this.fieldState[fieldPath] = { serverErrors: [] };
        }
        this.fieldState[fieldPath].touched = true;

        const { formName, fieldName } = this.getFormField(input, fieldPath);
        if (formName && fieldName) {
          this.updateShowErrors(fieldPath, formName, fieldName);
        }
        inputElements.push({ input, fieldPath, formName, fieldName });
      }
    });

    this.updateDOM();

    // Check if form is valid - if not, prevent submission and focus first invalid field
    for (const { input, fieldPath, formName, fieldName } of inputElements) {
      if (!formName || !fieldName) continue;

      const validField = `${formName}_${fieldName}_valid`;
      const clientValid = this.state[validField] ?? true;
      const serverErrors = this.fieldState[fieldPath]?.serverErrors || [];

      // Field is invalid if client validation fails or has server errors
      if (!clientValid || serverErrors.length > 0) {
        // Focus this field and prevent form submission
        e.preventDefault();
        input.focus();

        // Scroll error summary into view if present
        const errorSummary = this.el.querySelector("[data-lavash-error-summary]");
        if (errorSummary) {
          errorSummary.scrollIntoView({ behavior: "smooth", block: "nearest" });
        }

        return;
      }
    }
  },

  /**
   * Trigger server-side validation for a field.
   * Only sends if client validation passes.
   *
   * @param {string} fieldPath - e.g., "registration_params.name"
   * @param {string} formName - e.g., "registration"
   * @param {string} fieldName - e.g., "name"
   * @param {boolean} immediate - if true, skip debounce (used for blur)
   */
  triggerServerValidation(fieldPath, formName, fieldName, immediate = false) {
    // Check if client validation passes for this field
    const validField = `${formName}_${fieldName}_valid`;
    const clientValid = this.state[validField] ?? true;

    if (!clientValid) {
      // Client validation failed, don't bother server
      // Clear any pending timer
      if (this.validationTimers[fieldPath]) {
        clearTimeout(this.validationTimers[fieldPath]);
        delete this.validationTimers[fieldPath];
      }
      return;
    }

    // Clear any pending timer for this field
    if (this.validationTimers[fieldPath]) {
      clearTimeout(this.validationTimers[fieldPath]);
    }

    const sendValidation = () => {
      // Increment request ID to track staleness
      this.validationRequestId++;
      const requestId = this.validationRequestId;

      // Store the request ID for this field to detect stale responses
      if (!this.fieldState[fieldPath]) {
        this.fieldState[fieldPath] = { serverErrors: [] };
      }
      this.fieldState[fieldPath].validationRequestId = requestId;

      // Send validation event to server
      // The event name follows convention: validate_<form>
      const params = this.state[`${formName}_params`] || {};
      this.pushEvent(`validate_${formName}`, {
        field: fieldName,
        value: params[fieldName],
        _validation_request_id: requestId
      });
    };

    if (immediate) {
      sendValidation();
    } else {
      // Debounce for 500ms when typing
      this.validationTimers[fieldPath] = setTimeout(sendValidation, 500);
    }
  },

  /**
   * Handle server validation response.
   * Ignores stale responses based on request ID.
   *
   * @param {Object} payload - { form: string, field: string, errors: string[], _validation_request_id: number }
   */
  handleValidationResult(payload) {
    const { form: formName, field: fieldName, errors, _validation_request_id: requestId } = payload;
    const paramsField = `${formName}_params`;
    const fieldPath = `${paramsField}.${fieldName}`;

    // Check if this response is stale
    const fieldState = this.fieldState[fieldPath];
    if (fieldState && fieldState.validationRequestId !== undefined) {
      if (requestId < fieldState.validationRequestId) {
        // Stale response - ignore it
        return;
      }
    }

    // Store server errors
    if (!this.fieldState[fieldPath]) {
      this.fieldState[fieldPath] = { serverErrors: [] };
    }
    this.fieldState[fieldPath].serverErrors = errors || [];

    // Update DOM to show server errors
    this.updateDOM();
  },

  /**
   * Update *_show_errors state for a field based on touched/submitted status.
   *
   * @param {string} fieldPath - e.g., "registration_params.name"
   * @param {string} formName - e.g., "registration"
   * @param {string} fieldName - e.g., "name"
   */
  updateShowErrors(fieldPath, formName, fieldName) {
    // Compute show_errors: touched || formSubmitted
    const touched = this.fieldState[fieldPath]?.touched || false;
    const showErrors = touched || this.formSubmitted;

    // Update state
    const showErrorsKey = `${formName}_${fieldName}_show_errors`;
    this.state[showErrorsKey] = showErrors;
  },

  handleInput(e) {
    const target = e.target.closest("[data-lavash-bind]");
    if (!target) {
      return;
    }

    // Skip if input is inside a child component (has its own hook)
    // Child components handle their own inputs and sync to parent via syncParentUrl()
    const childHook = target.closest("[data-lavash-state]");
    if (childHook && childHook !== this.el) {
      return;
    }

    const fieldPath = target.dataset.lavashBind;
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

    // Clear server errors on edit (user is fixing the issue)
    if (this.fieldState[fieldPath]) {
      this.fieldState[fieldPath].serverErrors = [];
    }

    // Determine root field for derive recomputation
    const dotIndex = fieldPath.indexOf(".");
    const rootField = dotIndex > 0 ? fieldPath.substring(0, dotIndex) : fieldPath;

    // Recompute derives affected by the root field
    this.recomputeDerives([rootField]);

    this.updateDOM();

    // Sync URL fields immediately (optimistic URL update)
    this.syncUrl();

    // Schedule debounced server validation (if field is touched or form submitted)
    const { formName, fieldName } = this.getFormField(target, fieldPath);
    if (formName && fieldName) {
      // Only trigger server validation if field is already touched or form was submitted
      const touched = this.fieldState[fieldPath]?.touched || false;
      if (touched || this.formSubmitted) {
        this.triggerServerValidation(fieldPath, formName, fieldName, /* immediate */ false);
      }
    }
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
          // Silently ignore derive computation errors
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
    // Update all elements with data-lavash-display attribute (text content)
    const displayElements = this.el.querySelectorAll("[data-lavash-display]");
    displayElements.forEach(el => {
      const fieldName = el.dataset.lavashDisplay;
      const value = this.state[fieldName];
      if (value !== undefined) {
        el.textContent = value;
      }
    });

    // Update all elements with data-lavash-visible attribute (show/hide based on boolean)
    const visibleElements = this.el.querySelectorAll("[data-lavash-visible]");
    visibleElements.forEach(el => {
      const fieldName = el.dataset.lavashVisible;
      const value = this.state[fieldName];
      if (value) {
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Update all elements with data-lavash-enabled attribute (enable/disable based on boolean)
    const enabledElements = this.el.querySelectorAll("[data-lavash-enabled]");
    enabledElements.forEach(el => {
      const fieldName = el.dataset.lavashEnabled;
      const value = this.state[fieldName];
      el.disabled = !value;
    });

    // Update all elements with data-lavash-toggle attribute
    // Format: "fieldName|trueClasses|falseClasses" (uses | to avoid conflict with Tailwind's :)
    const classToggleElements = this.el.querySelectorAll("[data-lavash-toggle]");
    classToggleElements.forEach(el => {
      const spec = el.dataset.lavashToggle;
      const [fieldName, trueClasses, falseClasses] = spec.split("|");
      const value = this.state[fieldName];

      // Remove all managed classes first
      const allClasses = (trueClasses + " " + falseClasses).split(/\s+/).filter(c => c);
      el.classList.remove(...allClasses);

      // Add the appropriate classes
      const classesToAdd = (value ? trueClasses : falseClasses).split(/\s+/).filter(c => c);
      el.classList.add(...classesToAdd);
    });

    // Update all elements with data-lavash-class attribute (class from map)
    // Format: data-lavash-class="roast_chips.light" means state.roast_chips["light"]
    const classElements = this.el.querySelectorAll("[data-lavash-class]");
    classElements.forEach(el => {
      const path = el.dataset.lavashClass;
      const [field, key] = path.split(".");
      const classMap = this.state[field];
      if (classMap && key && classMap[key]) {
        el.className = classMap[key];
      } else if (classMap && !key) {
        // Direct field reference (e.g., "in_stock_chip")
        el.className = classMap;
      }
    });

    // Update all elements with data-lavash-errors attribute
    // Only show errors if the corresponding show_errors field is true (touched || submitted)
    const errorElements = this.el.querySelectorAll("[data-lavash-errors]");
    errorElements.forEach(el => {
      const errorsField = el.dataset.lavashErrors; // e.g., "registration_name_errors"
      const clientErrors = this.state[errorsField] || [];

      // Use explicit form/field if provided, otherwise derive from errors field name
      const explicitForm = el.dataset.lavashForm;
      const explicitField = el.dataset.lavashField;

      let formName, fieldName;
      if (explicitForm && explicitField) {
        formName = explicitForm;
        fieldName = explicitField;
      } else {
        // Derive from errors field name: "registration_name_errors" -> form=registration, field=name
        const match = errorsField.match(/^(.+)_(.+)_errors$/);
        if (match) {
          [, formName, fieldName] = match;
        }
      }

      const showErrorsField = el.dataset.lavashShowErrors || `${formName}_${fieldName}_show_errors`;
      const showErrors = this.state[showErrorsField] ?? false;

      // Get server errors for this field
      let serverErrors = [];
      if (formName && fieldName) {
        const fieldPath = `${formName}_params.${fieldName}`;
        serverErrors = this.fieldState[fieldPath]?.serverErrors || [];
      }

      // Combine client and server errors (client errors first, deduplicated)
      const allErrors = [...clientErrors];
      for (const err of serverErrors) {
        if (!allErrors.includes(err)) {
          allErrors.push(err);
        }
      }

      // Clear existing error content
      el.innerHTML = "";

      // Only render errors if showErrors is true and there are errors
      if (showErrors && allErrors.length > 0) {
        allErrors.forEach(error => {
          const p = document.createElement("p");
          p.className = "text-error text-sm";
          p.textContent = error;
          el.appendChild(p);
        });
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Update error summary element (shows all errors when form is submitted)
    const errorSummaryElements = this.el.querySelectorAll("[data-lavash-error-summary]");
    errorSummaryElements.forEach(el => {
      const formName = el.dataset.lavashErrorSummary; // e.g., "registration"

      // Only show if form has been submitted
      if (!this.formSubmitted) {
        el.classList.add("hidden");
        el.innerHTML = "";
        return;
      }

      // Collect all errors for this form
      const allErrors = [];

      // Find all error fields for this form
      for (const key of Object.keys(this.state)) {
        if (key.startsWith(`${formName}_`) && key.endsWith("_errors")) {
          const fieldErrors = this.state[key] || [];
          const fieldName = key.replace(`${formName}_`, "").replace(/_errors$/, "");

          // Also check for server errors
          const fieldPath = `${formName}_params.${fieldName}`;
          const serverErrors = this.fieldState[fieldPath]?.serverErrors || [];

          // Combine and dedupe
          const combined = [...fieldErrors];
          for (const err of serverErrors) {
            if (!combined.includes(err)) {
              combined.push(err);
            }
          }

          if (combined.length > 0) {
            allErrors.push({ field: fieldName, errors: combined });
          }
        }
      }

      // Clear and rebuild content
      el.innerHTML = "";

      if (allErrors.length > 0) {
        const title = document.createElement("p");
        title.className = "font-semibold text-red-700 mb-2";
        title.textContent = "Please fix the following errors:";
        el.appendChild(title);

        const ul = document.createElement("ul");
        ul.className = "list-disc list-inside space-y-1";

        for (const { field, errors } of allErrors) {
          for (const error of errors) {
            const li = document.createElement("li");
            li.textContent = `${this.humanizeFieldName(field)}: ${error}`;
            ul.appendChild(li);
          }
        }

        el.appendChild(ul);
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Update success indicators - only show if touched/submitted AND valid AND no server errors
    const successElements = this.el.querySelectorAll("[data-lavash-success]");
    successElements.forEach(el => {
      const validField = el.dataset.lavashSuccess; // e.g., "registration_name_valid" or "email_valid"
      const isValid = this.state[validField] ?? false;

      // Use explicit form/field if provided
      const explicitForm = el.dataset.lavashForm;
      const explicitField = el.dataset.lavashField;

      // Use explicit show_errors field if provided, otherwise derive
      const showErrorsField = el.dataset.lavashShowErrors ||
        (explicitForm && explicitField ? `${explicitForm}_${explicitField}_show_errors` : validField.replace(/_valid$/, "_show_errors"));
      const showErrors = this.state[showErrorsField] ?? false;

      // Check for server errors
      let hasServerErrors = false;
      if (explicitForm && explicitField) {
        const fieldPath = `${explicitForm}_params.${explicitField}`;
        hasServerErrors = (this.fieldState[fieldPath]?.serverErrors || []).length > 0;
      } else {
        // Derive from validField: "registration_name_valid" -> form=registration, field=name
        const formFieldMatch = validField.match(/^(.+)_(.+)_valid$/);
        if (formFieldMatch) {
          const [, formName, fieldName] = formFieldMatch;
          const fieldPath = `${formName}_params.${fieldName}`;
          hasServerErrors = (this.fieldState[fieldPath]?.serverErrors || []).length > 0;
        }
      }

      // Show success only if touched/submitted AND valid AND no server errors
      if (showErrors && isValid && !hasServerErrors) {
        el.classList.remove("hidden");
      } else {
        el.classList.add("hidden");
      }
    });

    // Update field status indicators (✓ valid, ✗ invalid, empty neutral)
    const statusElements = this.el.querySelectorAll("[data-lavash-status]");
    statusElements.forEach(el => {
      const validField = el.dataset.lavashStatus; // e.g., "registration_name_valid"

      // Use explicit form/field if provided
      const explicitForm = el.dataset.lavashForm;
      const explicitField = el.dataset.lavashField;

      const showErrorsField = el.dataset.lavashShowErrors ||
        (explicitForm && explicitField ? `${explicitForm}_${explicitField}_show_errors` : validField.replace(/_valid$/, "_show_errors"));

      const isValid = this.state[validField] ?? true;
      const showErrors = this.state[showErrorsField] ?? false;

      // Check for server errors
      let hasServerErrors = false;
      if (explicitForm && explicitField) {
        const fieldPath = `${explicitForm}_params.${explicitField}`;
        hasServerErrors = (this.fieldState[fieldPath]?.serverErrors || []).length > 0;
      } else {
        const formFieldMatch = validField.match(/^(.+)_(.+)_valid$/);
        if (formFieldMatch) {
          const [, formName, fieldName] = formFieldMatch;
          const fieldPath = `${formName}_params.${fieldName}`;
          hasServerErrors = (this.fieldState[fieldPath]?.serverErrors || []).length > 0;
        }
      }

      // Only show status if field has been touched/submitted
      if (!showErrors) {
        el.textContent = "";
        el.className = el.className.replace(/text-(green|red)-\d+/g, "").trim();
      } else if (isValid && !hasServerErrors) {
        el.textContent = "✓";
        el.className = el.className.replace(/text-(green|red)-\d+/g, "").trim() + " text-green-500";
      } else {
        el.textContent = "✗";
        el.className = el.className.replace(/text-(green|red)-\d+/g, "").trim() + " text-red-500";
      }
    });

    // Update input border colors based on validation state
    // Find all bound inputs and update their border/ring classes
    const boundInputs = this.el.querySelectorAll("[data-lavash-bind]");
    boundInputs.forEach(input => {
      const fieldPath = input.dataset.lavashBind; // e.g., "registration_params.name"

      // Get form/field from explicit attributes or derive from path
      const { formName, fieldName } = this.getFormField(input, fieldPath);
      if (!formName || !fieldName) return;

      // Check show_errors state
      const showErrorsField = `${formName}_${fieldName}_show_errors`;
      const showErrors = this.state[showErrorsField] ?? false;

      // Check validity - use custom valid field if specified, otherwise standard
      const customValidField = input.dataset.lavashValid;
      const validField = customValidField || `${formName}_${fieldName}_valid`;
      const isValid = this.state[validField] ?? true;

      // Check for server errors
      const hasServerErrors = (this.fieldState[fieldPath]?.serverErrors || []).length > 0;

      // Remove existing validation state classes (DaisyUI semantic + Tailwind fallback)
      const validationClasses = [
        // DaisyUI semantic classes
        "input-success", "input-error",
        // Tailwind fallback classes
        "border-gray-300", "border-green-300", "border-red-300",
        "focus:ring-blue-500", "focus:ring-green-500", "focus:ring-red-500"
      ];
      validationClasses.forEach(c => input.classList.remove(c));

      // Apply appropriate classes based on state
      if (!showErrors) {
        // Neutral state - no validation classes
      } else if (isValid && !hasServerErrors) {
        // Valid state - use DaisyUI semantic class
        input.classList.add("input-success");
      } else {
        // Invalid state - use DaisyUI semantic class
        input.classList.add("input-error");
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

  // Convert snake_case field name to Title Case
  humanizeFieldName(name) {
    return name
      .split("_")
      .map(word => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" ");
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
      activeEl.matches("[data-lavash-bind]");

    if (inputHasFocus) {
      const fieldPath = activeEl.dataset.lavashBind;
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
