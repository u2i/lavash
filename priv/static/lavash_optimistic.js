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
 * - data-lavash-status: Field status indicator (✗ when invalid)
 * - data-lavash-show-errors: Override which show_errors field to check for visibility
 * - data-lavash-preserve: Prevent morphdom from updating this element
 */

import { SyncedVarStore } from "./synced_var.js";
import { syncStateToUrl } from "./url_sync.js";

// Registry for optimistic function modules (for custom overrides)
window.Lavash = window.Lavash || {};
window.Lavash.optimistic = window.Lavash.optimistic || {};

// Registry for preserving client-only state across hook remounts
// Keys are element IDs, values contain fieldState and submittedForms
const _preservedClientState = new Map();

// Helper to register custom optimistic functions for a module
window.Lavash.registerOptimistic = function(moduleName, fns) {
  window.Lavash.optimistic[moduleName] = fns;
};

const LavashOptimistic = {
  mounted() {
    // Parse state from server
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

    // Bindings map: local field -> parent field (for parent-to-child propagation)
    // When parent state changes, we update our local state and animate
    this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");

    // Form field state tracking (client-side only)
    // Maps field path -> { touched: boolean }
    // Restore from preserved state if this is a remount
    const preservedState = _preservedClientState.get(this.el.id);
    if (preservedState) {
      this.fieldState = preservedState.fieldState || {};
      this.submittedForms = preservedState.submittedForms || new Set();
      _preservedClientState.delete(this.el.id);
    } else {
      this.fieldState = {};
      // Per-form submitted state: Set of form IDs that have been submitted
      // This prevents a child component's form submit from affecting parent forms
      this.submittedForms = new Set();
    }

    // Server validation debounce timers: field path -> timeout ID
    this.validationTimers = {};

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

    // Check if this is a component
    this.isComponent = this.el.hasAttribute("data-lavash-component");

    // Intercept clicks on elements with data-lavash-action
    this.el.addEventListener("click", this.handleClick.bind(this), true);

    // Intercept input/change on elements with data-lavash-bind
    // Listen for both: "input" fires on text keystroke, "change" fires on select/checkbox
    this.el.addEventListener("input", this.handleInput.bind(this), true);
    this.el.addEventListener("change", this.handleInput.bind(this), true);

    // Track blur events for touched state
    this.el.addEventListener("blur", this.handleBlur.bind(this), true);

    // Track form submit for formSubmitted state
    this.el.addEventListener("submit", this.handleFormSubmit.bind(this), true);

    // Handle lavash-set events from child ClientComponents
    // This allows nested components to set bound state on parent components
    // Use bubbling mode (not capture) so the closest ancestor hook handles it first
    this.el.addEventListener("lavash-set", this.handleLavashSet.bind(this), false);

    // Install global DOM callback for input preservation (only once globally)
    this._installGlobalDomCallback();

    // Initialize form params from DOM values (for prepopulated/default values)
    // This ensures validation works correctly for fields with defaults
    this.initializeFormParamsFromDOM();

    // Initialize animated state managers
    this.initAnimatedFields();
  },

  /**
   * Initialize animated fields from __animated__ metadata.
   * Registers animation configs on the store so any future store.get()
   * for these paths automatically creates animated SyncedVars.
   * Also creates delegates and event listeners for overlay types.
   *
   * this.animatedStates maps field -> { config, delegate }
   * The SyncedVar is lazily created in the store via store.get().
   */
  initAnimatedFields() {
    this.animatedStates = {};

    let animatedConfigs = this.fns.__animated__ || [];
    if (animatedConfigs.length === 0 && this.el.dataset.lavashAnimated) {
      try {
        animatedConfigs = JSON.parse(this.el.dataset.lavashAnimated);
      } catch (e) {
        console.warn("[LavashOptimistic] Failed to parse data-lavash-animated:", e);
      }
    }

    for (const config of animatedConfigs) {
      const field = config.field;

      // Register animated config on store — any store.get() for this field
      // will create an animated SyncedVar with phase machine built in
      this.store.registerAnimated(field, {
        animated: { duration: config.duration || 200, async: config.async || null },
        onPhaseChange: (phase) => {
          if (this.state) {
            this.state[config.phaseField] = phase;
            this.recomputeDerives?.([config.phaseField]);
            this.updateDOM?.();
          }
        },
      });

      // Create delegate based on overlay type
      let delegate = null;
      let chromeEl = null;

      if (config.type === "modal" || config.type === "flyover") {
        const OverlayAnimator = window.Lavash?.OverlayAnimator;
        if (OverlayAnimator) {
          const wrapperId = this.el.id;
          const componentId = wrapperId.replace(/^lavash-/, "");
          const chromeId = `${componentId}-${config.type}`;
          chromeEl = document.getElementById(chromeId);

          if (chromeEl) {
            const overlayOpts = {
              type: config.type,
              duration: config.duration || 200,
              openField: config.field,
              js: this.js()
            };
            if (config.type === "flyover") {
              overlayOpts.slideFrom = chromeEl.dataset.slideFrom || 'right';
            }
            delegate = new OverlayAnimator(chromeEl, overlayOpts);

            const mainContentId = `${chromeId}-main_content`;
            const mainContentInnerId = `${chromeId}-main_content_inner`;
            this._registerModalContentIds(mainContentId, mainContentInnerId, field);
          } else {
            console.warn(`[LavashOptimistic] Chrome element #${chromeId} not found for animated field ${field}`);
          }
        } else {
          console.warn(`[LavashOptimistic] OverlayAnimator not found for type:${config.type} field`);
        }
      }

      this.animatedStates[field] = { config, delegate };

      // Eagerly create the SyncedVar so the delegate gets attached
      const currentValue = this.state[field] ?? null;
      const syncedVar = this.store.get(field, currentValue, {
        onChange: (newVal) => { this.state[field] = newVal; },
      });
      if (delegate) syncedVar.setDelegate(delegate);
      if (currentValue != null) syncedVar.setOptimistic(currentValue);

      // Set up open/close event listeners on chrome element
      if (chromeEl) {
        this._modalEventListeners = this._modalEventListeners || [];
        const setterAction = `set_${field}`;

        const openHandler = (e) => {
          const openValue = e.detail?.[field] ?? e.detail?.open ?? e.detail?.value ?? true;
          const sv = this.store.get(field);
          sv.set(openValue, (p, cb) => {
            this.pushEventTo(chromeEl, setterAction, { ...p, value: openValue }, cb);
          });
        };

        const closeHandler = () => {
          const sv = this.store.get(field);
          sv.set(null, (p, cb) => {
            this.pushEventTo(chromeEl, setterAction, { ...p, value: null }, cb);
          });
        };

        chromeEl.addEventListener("open-panel", openHandler);
        chromeEl.addEventListener("close-panel", closeHandler);
        this._modalEventListeners.push({ el: chromeEl, open: openHandler, close: closeHandler });
      }
    }
  },

  /**
   * Get an animated state manager by field name.
   */
  getAnimatedState(field) {
    return this.animatedStates?.[field];
  },

  /**
   * Check if any animated fields are currently animating.
   */
  isAnyAnimating() {
    if (!this.animatedStates) return false;
    return Object.keys(this.animatedStates).some(
      field => this.store.get(field).isAnimating()
    );
  },

  /**
   * Initialize form params from DOM values for prepopulated/default fields.
   * This ensures validation works correctly for fields that have defaults
   * (e.g., a country select defaulting to "United States").
   *
   * Without this, form_params starts empty and validation fails because
   * state.form_params?.["country"] is undefined even though the input shows a value.
   */
  initializeFormParamsFromDOM() {
    const boundInputs = this.el.querySelectorAll("[data-lavash-bind]");
    let initialized = false;

    console.debug(`[initFormParams] Found ${boundInputs.length} bound inputs`);

    boundInputs.forEach(input => {
      const fieldPath = input.dataset.lavashBind;

      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(input)) {
        console.debug(`[initFormParams] Skipping (child hook): ${fieldPath}`);
        return;
      }

      // Skip elements inside hidden containers (e.g., closed modals)
      // Walk up the DOM tree to check for hidden ancestors
      if (this.isInsideHiddenContainer(input)) {
        console.debug(`[initFormParams] Skipping (hidden container): ${fieldPath}`);
        return;
      }

      // Only handle form params paths (e.g., "address_form_params.country")
      if (!fieldPath || !fieldPath.includes("_params.")) {
        console.debug(`[initFormParams] Skipping (not params): ${fieldPath}`);
        return;
      }

      const dotIndex = fieldPath.indexOf(".");
      if (dotIndex === -1) return;

      const paramsField = fieldPath.substring(0, dotIndex);  // e.g., "address_form_params"
      const field = fieldPath.substring(dotIndex + 1);        // e.g., "country"

      // Skip if this params field was just cleared by the server
      // This prevents re-reading stale DOM values before LiveView patches them
      if (this._clearedParamsFields && this._clearedParamsFields.has(paramsField)) {
        console.debug(`[initFormParams] Skipping (params cleared by server): ${fieldPath}`);
        return;
      }

      // Get current input value
      const currentValue = input.value;

      console.debug(`[initFormParams] ${fieldPath}: value="${currentValue}", existing=${this.state[paramsField]?.[field]}`);

      // Only set if input has a non-empty value and state doesn't have it yet
      if (currentValue != null && currentValue !== "") {
        this.state[paramsField] = this.state[paramsField] || {};
        if (this.state[paramsField][field] === undefined) {
          this.state[paramsField][field] = currentValue;
          initialized = true;
          console.debug(`[initFormParams] Initialized ${paramsField}.${field} = "${currentValue}"`);
        }
      }
    });

    // If we initialized any params, recompute derives so validation reflects correct state
    if (initialized) {
      console.debug(`[initFormParams] Recomputing derives...`);
      this.recomputeDerives();
    }
  },

  /**
   * Register overlay content element IDs for ghost detection.
   * This is called when creating OverlayAnimator delegates.
   */
  _registerModalContentIds(contentId, innerId, field) {
    // Store mapping from content ID to this hook and field
    window.__lavashModalContentRegistry = window.__lavashModalContentRegistry || {};
    window.__lavashModalContentRegistry[contentId] = {
      hook: this,
      field: field,
      innerId: innerId
    };

  },

  /**
   * Install global onBeforeElUpdated callback for ghost detection and input preservation.
   * Only installs once globally across all LavashOptimistic instances.
   */
  _installGlobalDomCallback() {
    if (window.__lavashOptimisticDomCallbackInstalled) return;
    window.__lavashOptimisticDomCallbackInstalled = true;

    const original = this.liveSocket.domCallbacks.onBeforeElUpdated;
    this.liveSocket.domCallbacks.onBeforeElUpdated = (fromEl, toEl) => {
      // Preserve input values and validation classes for form fields with data-lavash-bind
      // This runs before morphdom patches the DOM, so we can prevent value/class overwrites
      if (fromEl.hasAttribute && fromEl.hasAttribute("data-lavash-bind")) {
        // Skip updating a focused select/input — user is actively interacting
        if (fromEl === document.activeElement) {
          return false;
        }

        const fieldPath = fromEl.getAttribute("data-lavash-bind");
        // Find the LavashOptimistic hook that owns this input
        const hookEl = fromEl.closest("[phx-hook='LavashOptimistic']");
        const hook = hookEl?.__lavash_hook__;

        if (hook && hook.store && hook.store.isPending(fieldPath)) {
          // Input has pending changes - preserve the current value
          const pendingValue = hook.store.getValue(fieldPath);
          if (pendingValue !== undefined) {
            toEl.value = pendingValue;
          }
        }

        // For inputs inside child LiveComponents, the parent hook may not
        // track the SyncedVar. Preserve the DOM value over the server value
        // when the user has modified the input (value differs from server).
        if (fromEl.value !== toEl.value) {
          const isInsideChildComponent = fromEl.closest("[data-phx-component]") !== null;
          if (isInsideChildComponent) {
            toEl.value = fromEl.value;
          }
        }
      }

      // Apply client state to elements when server data is stale (dependencies have pending changes)
      // This ensures morphdom applies the CLIENT's computed value, not the server's stale value
      const hookEl = fromEl.closest("[phx-hook='LavashOptimistic']");
      const hook = hookEl?.__lavash_hook__;

      if (hook && hook.hasPendingSources && hook.state) {
        // Check each attribute type and apply client state if stale
        const fieldName = fromEl.getAttribute('data-lavash-enabled');
        if (fieldName && hook.hasPendingSources(fieldName)) {
          const enabled = hook.state[fieldName] === true;
          toEl.disabled = !enabled;
          if (enabled) {
            toEl.classList.remove('btn-disabled', 'opacity-60', 'cursor-not-allowed');
          } else {
            toEl.classList.add('opacity-60', 'cursor-not-allowed');
          }
          console.debug(`[LavashOptimistic] onBeforeElUpdated: Applied client state for data-lavash-enabled="${fieldName}" (enabled=${enabled})`);
        }

        const visibleField = fromEl.getAttribute('data-lavash-visible');
        if (visibleField && hook.hasPendingSources(visibleField)) {
          const visible = hook.state[visibleField];
          if (visible) {
            toEl.classList.remove('hidden');
          } else {
            toEl.classList.add('hidden');
          }
          console.debug(`[LavashOptimistic] onBeforeElUpdated: Applied client state for data-lavash-visible="${visibleField}" (visible=${visible})`);
        }

        const displayField = fromEl.getAttribute('data-lavash-display');
        if (displayField && hook.hasPendingSources(displayField)) {
          toEl.textContent = hook.state[displayField] ?? '';
          console.debug(`[LavashOptimistic] onBeforeElUpdated: Applied client state for data-lavash-display="${displayField}"`);
        }

        const errorsField = fromEl.getAttribute('data-lavash-errors');
        if (errorsField && hook.hasPendingSources(errorsField)) {
          // For errors, preserve the current DOM since it's already rendered by updateDOM
          // (errors have complex innerHTML with show_errors logic)
          toEl.innerHTML = fromEl.innerHTML;
          toEl.className = fromEl.className;
          console.debug(`[LavashOptimistic] onBeforeElUpdated: Preserved DOM for data-lavash-errors="${errorsField}" (stale)`);
        }
      }

      // Check if any registered modal cares about this element
      const registry = window.__lavashModalContentRegistry || {};
      const entry = registry[fromEl.id];

      if (entry) {
        const { hook, field, innerId } = entry;
        const anim = hook.animatedStates?.[field];

        if (anim) {
          const sv = hook.store.get(field);
          const phase = sv.getPhase();
          const shouldPreserve = phase === "visible" || phase === "loading";

          if (shouldPreserve) {
            const fromHasInner = fromEl.querySelector(`#${innerId}`);
            const toHasInner = toEl.querySelector(`#${innerId}`);

            if (fromHasInner && !toHasInner) {
              console.debug(`[LavashOptimistic] onBeforeElUpdated detected content removal for ${field}`);
              if (anim.delegate?.createGhostBeforePatch) {
                anim.delegate.createGhostBeforePatch(fromHasInner);
              }
            }
          }
        }
      }

      // Call original callback
      if (original) {
        original(fromEl, toEl);
      }
    };
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

    // Parse graph — new format has {topo_order, deps, dependents}
    const rawGraph = fnObj.__graph__ || {};
    if (Array.isArray(rawGraph.topo_order)) {
      this.graph = rawGraph;
    } else {
      // Legacy format: flat {name: {deps: [...]}} — convert
      const deps = {};
      for (const [name, meta] of Object.entries(rawGraph)) {
        deps[name] = meta.deps || [];
      }
      this.graph = { topo_order: [], deps, dependents: {} };
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
        if (!this.graph.deps[d]) {
          // Infer dependency from derive name pattern (e.g., "roast_chips" depends on "roast")
          const match = d.match(/^(.+)_chips?$/);
          if (match) {
            const dep = match[1];
            this.graph.deps[d] = [dep];
            // Add to dependents index
            if (!this.graph.dependents[dep]) this.graph.dependents[dep] = [];
            if (!this.graph.dependents[dep].includes(d)) this.graph.dependents[dep].push(d);
            // Leaf derive — safe to append at end of topo_order
            if (!this.graph.topo_order.includes(d)) this.graph.topo_order.push(d);
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

    // Run optimistic action for instant UI update
    this.runOptimisticAction(actionName, value);

    // Push the action event to the server
    // This ensures server-side action handlers run (e.g., for bound field updates)
    const payload = value !== undefined ? { value } : {};
    this.pushEventTo(this.el, actionName, payload, () => {});

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
  },

  handleBlur(e) {
    // Track touched state when user leaves a bound field
    const target = e.target.closest("[data-lavash-bind]");
    if (!target) return;

    // Skip if input is inside a child component (has its own hook)
    if (this.isInsideChildHook(target)) {
      return;
    }

    const fieldPath = target.dataset.lavashBind;
    if (!fieldPath) return;

    if (!this.fieldState[fieldPath]) {
      this.fieldState[fieldPath] = {};
    }

    // For selects, only mark as touched if value was actually modified
    // This prevents Chrome's dropdown interaction from triggering error display
    // (Chrome fires blur events during arrow key navigation in open dropdowns)
    if (target.tagName === "SELECT") {
      const wasModified = this.store.isPending(fieldPath);
      console.debug(`[handleBlur] SELECT ${fieldPath}: wasModified=${wasModified}`);
      if (wasModified) {
        this.fieldState[fieldPath].touched = true;
      }
    } else {
      // For text inputs, mark as touched on any blur (standard UX)
      this.fieldState[fieldPath].touched = true;
    }

    // Get form/field from explicit attributes or derive from path
    const { formName, fieldName } = this.getFormField(target, fieldPath);
    if (!formName || !fieldName) return;

    // Update show_errors state
    this.updateShowErrors(fieldPath, formName, fieldName);

    // Trigger server validation if client validation passes
    this.triggerServerValidation(fieldPath, formName, fieldName, /* immediate */ true, target);

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
    // Get the actual form that was submitted
    const form = e.target.closest("form");
    if (!form) return;

    // Track submitted forms instead of global flag
    // This prevents a child component's form submit from affecting parent forms
    if (!this.submittedForms) this.submittedForms = new Set();

    // Track both the form ID and the form name (derived from first input's params field)
    // This allows isFormSubmitted() to match either the ID or the logical form name
    const formId = form.id || "default";
    this.submittedForms.add(formId);

    // Also try to derive the form name from bound inputs (e.g., "payment" from "payment_params.card_number")
    const firstInput = form.querySelector("[data-lavash-bind]");
    if (firstInput) {
      const fieldPath = firstInput.dataset.lavashBind;
      const { formName } = this.getFormField(firstInput, fieldPath);
      if (formName) {
        this.submittedForms.add(formName);
      }
    }

    // Collect bound inputs only within the submitted form
    const boundInputs = form.querySelectorAll("[data-lavash-bind]");
    const inputElements = [];
    boundInputs.forEach(input => {
      const fieldPath = input.dataset.lavashBind;
      if (fieldPath) {
        if (!this.fieldState[fieldPath]) {
          this.fieldState[fieldPath] = {};
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
    for (const { input, formName, fieldName } of inputElements) {
      if (!formName || !fieldName) continue;

      // Use custom valid field if specified on input, otherwise standard naming
      const customValidField = input.dataset?.lavashValid;
      const validField = customValidField || `${formName}_${fieldName}_valid`;
      const clientValid = this.state[validField] ?? true;
      const errorsField = `${formName}_${fieldName}_errors`;
      const errors = this.state[errorsField] || [];

      // Field is invalid if validation fails or has errors (client + server merged in derive)
      if (!clientValid || errors.length > 0) {
        // Focus this field and prevent form submission
        e.preventDefault();
        input.focus();

        // Scroll invalid field into view (center in viewport for visibility)
        input.scrollIntoView({ behavior: "smooth", block: "center" });

        // Scroll error summary into view if present
        const errorSummary = form.querySelector("[data-lavash-error-summary]");
        if (errorSummary) {
          errorSummary.scrollIntoView({ behavior: "smooth", block: "nearest" });
        }

        return;
      }
    }
  },

  /**
   * Handle lavash-set events from child ClientComponents.
   * This allows nested components to set bound state on parent components.
   * The event bubbles up from a ClientComponent that has a bound field.
   *
   * @param {CustomEvent} e - Event with detail: { field: string, value: any }
   */
  handleLavashSet(e) {
    const { field, value } = e.detail;
    if (!field) return;

    console.debug("[LavashOptimistic] handleLavashSet", field, "=", value);

    // Check if this field has an animated state (modal/flyover)
    if (this.animatedStates?.[field]) {
      e.stopPropagation();
      const animValue = value ? value : null;
      const setterAction = `set_${field}`;
      this.store.get(field).set(animValue, (payload, callback) => {
        this.pushEventTo(this.el, setterAction, { ...payload, value: animValue }, callback);
      });
      return;
    }

    // Check if this field exists in our state (we own it)
    if (field in this.state) {
      // Stop propagation - we own this field
      e.stopPropagation();

      // Regular field - update state and push to server
      this.state[field] = value;

      // Track in SyncedVarStore if available
      if (this.store) {
        const syncedVar = this.store.get(field, value);
        syncedVar.setOptimistic(value);
      }

      // Bump client version
      if (this.clientVersion !== undefined) {
        this.clientVersion++;
      }

      // Recompute derives and update DOM
      this.recomputeDerives([field]);
      this.updateDOM();

      // Push to server
      const setterAction = `set_${field}`;
      this.pushEventTo(this.el, setterAction, { value }, () => {});
      return;
    }

    // We don't own this field - let the event continue propagating
    // (another hook up the tree may own it)
    console.debug("[LavashOptimistic] Field", field, "not owned by this hook, letting event propagate");
  },

  /**
   * Trigger server-side validation for a field.
   * Only sends if client validation passes.
   *
   * @param {string} fieldPath - e.g., "registration_params.name"
   * @param {string} formName - e.g., "registration"
   * @param {string} fieldName - e.g., "name"
   * @param {boolean} immediate - if true, skip debounce (used for blur)
   * @param {HTMLElement} inputEl - optional input element to check for custom valid field
   */
  triggerServerValidation(fieldPath, formName, fieldName, immediate = false, inputEl = null) {
    // Check if client validation passes for this field
    // Use custom valid field if specified on input, otherwise standard naming
    const customValidField = inputEl?.dataset?.lavashValid;
    const validField = customValidField || `${formName}_${fieldName}_valid`;
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
      // Send validation event to server
      // Server stores result in #{form}_server_errors state → re-render → data attr updates
      const params = this.state[`${formName}_params`] || {};
      this.pushEvent(`validate_${formName}`, {
        field: fieldName,
        value: params[fieldName]
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
   * Update *_show_errors state for a field based on touched/submitted status.
   *
   * @param {string} fieldPath - e.g., "registration_params.name"
   * @param {string} formName - e.g., "registration"
   * @param {string} fieldName - e.g., "name"
   */
  updateShowErrors(fieldPath, formName, fieldName) {
    // Compute show_errors: touched || (this form was submitted)
    const touched = this.fieldState[fieldPath]?.touched || false;
    const formSubmitted = this.isFormSubmitted(formName);
    const showErrors = touched || formSubmitted;

    // Update state
    const showErrorsKey = `${formName}_${fieldName}_show_errors`;
    const oldValue = this.state[showErrorsKey];
    this.state[showErrorsKey] = showErrors;

    // Log changes to show_errors state for debugging flickering
    if (oldValue !== showErrors) {
      console.debug(`[LavashOptimistic] ${showErrorsKey} changed: ${oldValue} → ${showErrors} (touched=${touched}, submitted=${formSubmitted})`);
    }
  },

  /**
   * Check if a specific form has been submitted.
   * @param {string} formName - The form name (e.g., "payment", "address_form")
   * @returns {boolean}
   */
  isFormSubmitted(formName) {
    if (!this.submittedForms) return false;
    // Check both the form name and any form IDs that contain the form name
    // This handles both "payment-form" (id) and "payment" (form name)
    for (const id of this.submittedForms) {
      if (id === formName || id.startsWith(formName + "-") || id.includes(formName)) {
        return true;
      }
    }
    return false;
  },

  handleInput(e) {
    const target = e.target.closest("[data-lavash-bind]");
    if (!target) {
      return;
    }

    // Each element type should only process one event type to avoid double handling:
    // - SELECT: process "change" (skip "input") — "change" is reliable cross-browser for selects
    // - INPUT/TEXTAREA: process "input" (skip "change") — "change" fires on blur, redundant with handleBlur
    if (target.tagName === "SELECT" && e.type === "input") return;
    if ((target.tagName === "INPUT" || target.tagName === "TEXTAREA") && e.type === "change") return;

    // Skip if input is inside a child component (has its own hook)
    // Child components handle their own inputs and sync to parent via syncParentUrl()
    const childHook = target.closest("[data-lavash-state]");
    if (childHook && childHook !== this.el) {
      return;
    }

    const fieldPath = target.dataset.lavashBind;
    // For form inputs, keep as string to match Elixir params behavior
    let value = target.value;

    // Apply input formatting if specified
    const format = target.dataset.lavashFormat;
    if (format) {
      const formatted = this.formatInputValue(value, format);
      if (formatted !== null) {
        value = formatted.value;
        // Update the input's displayed value with formatting
        if (formatted.display !== target.value) {
          const cursorPos = target.selectionStart;
          const oldLen = target.value.length;
          target.value = formatted.display;
          // Adjust cursor position based on added/removed characters
          const newLen = formatted.display.length;
          const newPos = Math.min(cursorPos + (newLen - oldLen), newLen);
          target.setSelectionRange(newPos, newPos);
        }
      }
    }

    // Get or create a SyncedVar for this path (for version/pending tracking)
    // Use undefined as initial value - will be set properly on first setOptimistic
    const syncedVar = this.store.get(fieldPath);

    // Mark as optimistically updated (this bumps version for pending tracking)
    syncedVar.setOptimistic(value);

    // Update state - this is the source of truth for derives
    this.setStateAtPath(fieldPath, value);

    // Bump client version for stale patch rejection
    this.clientVersion++;

    // Optimistically clear server errors for this field
    // This prevents stale server errors from displaying while user is editing
    const { formName, fieldName } = this.getFormField(target, fieldPath);
    if (formName && fieldName) {
      // Clear the server error for this field immediately
      const serverErrorsField = `${formName}_server_errors`;
      const currentServerErrors = this.state[serverErrorsField] || {};
      const updatedServerErrors = { ...currentServerErrors, [fieldName]: [] };
      this.state[serverErrorsField] = updatedServerErrors;
    }

    // Determine root field for derive recomputation
    const dotIndex = fieldPath.indexOf(".");
    const rootField = dotIndex > 0 ? fieldPath.substring(0, dotIndex) : fieldPath;

    // Recompute derives affected by the root field
    this.recomputeDerives([rootField]);

    // For selects, defer DOM update to blur - Chrome fires change events during
    // arrow key navigation in open dropdowns, which causes flickering errors.
    // State and derives are updated, but visual error display waits for blur.
    if (target.tagName !== "SELECT") {
      this.updateDOM();
    }

    // Sync URL fields immediately (optimistic URL update)
    this.syncUrl();

    // Schedule debounced server validation (if field is touched or form submitted)
    // formName and fieldName already extracted above
    if (formName && fieldName) {
      // Only trigger server validation if field is already touched or form was submitted
      const touched = this.fieldState[fieldPath]?.touched || false;
      if (touched || this.isFormSubmitted(formName)) {
        this.triggerServerValidation(fieldPath, formName, fieldName, /* immediate */ false, target);
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

      // Propagate bound field changes to parent
      // When client action updates a bound field, parent needs to know immediately
      this.propagateBoundFieldsToParent(changedFields);

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

  /**
   * Notify animated state managers when their fields change.
   */
  /**
   * Notify animated states that async data is ready.
   * Called when a read/async field gets populated.
   */
  notifyAsyncReady(asyncField) {
    if (!this.animatedStates) return;

    for (const [field, anim] of Object.entries(this.animatedStates)) {
      if (anim.config.async === asyncField) {
        this.store.get(field).onAsyncDataReady();
      }
    }
  },

  /**
   * Notify animated state delegates of a LiveView update.
   * Delegates can use this for post-update logic like FLIP animations.
   */
  notifyAnimatedStatesDelegatesUpdated() {
    if (!this.animatedStates) return;

    for (const [field, anim] of Object.entries(this.animatedStates)) {
      if (anim.delegate?.onUpdated) {
        const sv = this.store.get(field);
        anim.delegate.onUpdated(sv, sv.getPhase());
      }
    }
  },

  recomputeDerives(changedFields = null) {
    // Use graph-based recomputation if topo_order is available
    if (this.graph.topo_order.length > 0) {
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

  // Graph-based derive recomputation using pre-computed topo_order + dependents
  recomputeGraph(changedFields = null) {
    let toRecompute;

    if (!changedFields) {
      // No specific fields — recompute everything in pre-sorted order
      toRecompute = this.graph.topo_order;
    } else {
      // Find affected derives via pre-built dependents index, then filter topo_order
      const affected = this.findAffected(changedFields);
      toRecompute = this.graph.topo_order.filter(f => affected.has(f));
    }

    for (const name of toRecompute) {
      const fn = this.fns[name];
      if (fn) {
        try {
          const oldValue = this.state[name];
          const result = fn(this.state);
          this.state[name] = result;

          // Log error field and validity changes for debugging
          if (name.endsWith("_errors") && JSON.stringify(oldValue) !== JSON.stringify(result)) {
            console.debug(`[LavashOptimistic] Derive ${name} changed: ${JSON.stringify(oldValue)} → ${JSON.stringify(result)}`);
          }
          if (name.endsWith("_valid") && oldValue !== result) {
            console.debug(`[LavashOptimistic] Derive ${name} changed: ${oldValue} → ${result}`);
          }
        } catch (err) {
          if (typeof console !== "undefined" && console.debug) {
            console.debug(`[Lavash] Error computing derive ${name}:`, err.message);
          }
        }
      }
    }
  },

  // BFS over pre-built dependents index — mirrors Reactive.Graph.transitive_dependents
  findAffected(changedFields) {
    const affected = new Set();
    const queue = [...changedFields];

    while (queue.length > 0) {
      const field = queue.shift();
      const directDependents = this.graph.dependents[field] || [];
      for (const dep of directDependents) {
        if (!affected.has(dep)) {
          affected.add(dep);
          queue.push(dep);
        }
      }
    }

    return affected;
  },

  // Check if element is inside a nested child hook (e.g., ClientComponent)
  // We should not manipulate elements inside child hooks - they manage their own state
  isInsideChildHook(el) {
    let parent = el.parentElement;
    while (parent && parent !== this.el) {
      if (parent.hasAttribute("phx-hook") && parent !== this.el) {
        return true;
      }
      parent = parent.parentElement;
    }
    return false;
  },

  // Check if element is inside a hidden container (e.g., closed modal content)
  // This prevents reading stale DOM values from hidden form elements
  isInsideHiddenContainer(el) {
    let parent = el.parentElement;
    while (parent && parent !== this.el) {
      // Check for hidden class (used by modal main_content when closed)
      if (parent.classList && parent.classList.contains("hidden")) {
        return true;
      }
      // Also check for display:none or visibility:hidden inline styles
      if (parent.style) {
        if (parent.style.display === "none" || parent.style.visibility === "hidden") {
          return true;
        }
      }
      parent = parent.parentElement;
    }
    return false;
  },

  updateDOM() {
    console.debug(`[LavashOptimistic] updateDOM() called`);

    // Update all elements with data-lavash-display attribute (text content)
    const displayElements = this.el.querySelectorAll("[data-lavash-display]");
    displayElements.forEach(el => {
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

      const fieldName = el.dataset.lavashDisplay;
      const value = this.state[fieldName];
      if (value !== undefined) {
        el.textContent = value;
      }
    });

    // Update all elements with data-lavash-visible attribute (show/hide based on boolean)
    const visibleElements = this.el.querySelectorAll("[data-lavash-visible]");
    visibleElements.forEach(el => {
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

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
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

      const fieldName = el.dataset.lavashEnabled;
      const value = this.state[fieldName];
      const enabled = value === true;
      const wasDisabled = el.disabled;

      // Update disabled attribute
      el.disabled = !enabled;

      // Log state changes for debugging
      if (wasDisabled !== el.disabled) {
        console.debug(`[LavashOptimistic] Button ${fieldName} enabled state changed: disabled=${wasDisabled} → ${el.disabled} (value=${value})`);
      }

      // Update classes for visual feedback
      if (enabled) {
        el.classList.remove('btn-disabled', 'opacity-60', 'cursor-not-allowed');
      } else {
        el.classList.add('opacity-60', 'cursor-not-allowed');
      }
    });

    // Update all elements with data-lavash-toggle attribute
    // Format: "fieldName|trueClasses|falseClasses" (uses | to avoid conflict with Tailwind's :)
    const classToggleElements = this.el.querySelectorAll("[data-lavash-toggle]");
    classToggleElements.forEach(el => {
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

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
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

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
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

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

      // Errors already include both client and server errors (merged in the derive)
      const allErrors = clientErrors;

      // Track previous visibility state
      const wasVisible = !el.classList.contains("hidden");
      const willBeVisible = showErrors && allErrors.length > 0;

      // Clear existing error content
      el.innerHTML = "";

      // Only render errors if showErrors is true and there are errors
      if (willBeVisible) {
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

      // Log visibility changes for debugging flickering
      if (wasVisible !== willBeVisible) {
        console.debug(`[LavashOptimistic] DOM error visibility changed for ${errorsField}: ${wasVisible} → ${willBeVisible} (showErrors=${showErrors}, errors=${JSON.stringify(allErrors)})`);
      }
    });

    // Update error summary element (shows all errors when form is submitted)
    const errorSummaryElements = this.el.querySelectorAll("[data-lavash-error-summary]");
    errorSummaryElements.forEach(el => {
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

      const formName = el.dataset.lavashErrorSummary; // e.g., "registration"

      // Only show if this specific form has been submitted
      if (!this.isFormSubmitted(formName)) {
        el.classList.add("hidden");
        el.innerHTML = "";
        return;
      }

      // Collect all errors for this form
      const allErrors = [];

      // Find all error fields for this form (errors already include server errors from derive)
      for (const key of Object.keys(this.state)) {
        if (key.startsWith(`${formName}_`) && key.endsWith("_errors")) {
          const fieldErrors = this.state[key] || [];
          const fieldName = key.replace(`${formName}_`, "").replace(/_errors$/, "");

          if (fieldErrors.length > 0) {
            allErrors.push({ field: fieldName, errors: fieldErrors });
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

    // Update field status indicators (✗ when invalid, empty otherwise)
    const statusElements = this.el.querySelectorAll("[data-lavash-status]");
    statusElements.forEach(el => {
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(el)) return;

      const validField = el.dataset.lavashStatus; // e.g., "registration_name_valid"

      // Use explicit form/field if provided
      const explicitForm = el.dataset.lavashForm;
      const explicitField = el.dataset.lavashField;

      const showErrorsField = el.dataset.lavashShowErrors ||
        (explicitForm && explicitField ? `${explicitForm}_${explicitField}_show_errors` : validField.replace(/_valid$/, "_show_errors"));

      const isValid = this.state[validField] ?? true;
      const showErrors = this.state[showErrorsField] ?? false;

      // Check for errors (client + server already merged in derive)
      const errorsField = validField.replace(/_valid$/, "_errors");
      const hasErrors = (this.state[errorsField] || []).length > 0;

      // Only show status if field has been touched/submitted and is invalid
      // (no success indicator - green checkmarks are distracting)
      if (!showErrors || (isValid && !hasErrors)) {
        el.textContent = "";
        el.className = el.className.replace(/text-red-\d+/g, "").trim();
      } else {
        el.textContent = "✗";
        el.className = el.className.replace(/text-red-\d+/g, "").trim() + " text-red-500";
      }
    });

    // Update input border colors based on validation state
    // Find all bound inputs and update their border/ring classes
    const boundInputs = this.el.querySelectorAll("[data-lavash-bind]");
    boundInputs.forEach(input => {
      // Skip elements inside nested child hooks - they manage their own state
      if (this.isInsideChildHook(input)) return;

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

      // Check for errors (client + server already merged in derive)
      const errorsField = `${formName}_${fieldName}_errors`;
      const hasErrors = (this.state[errorsField] || []).length > 0;

      // Remove existing validation state classes (DaisyUI semantic + Tailwind fallback)
      const validationClasses = [
        // DaisyUI semantic classes
        "input-error",
        // Tailwind fallback classes
        "border-gray-300", "border-red-300",
        "focus:ring-blue-500", "focus:ring-red-500"
      ];
      validationClasses.forEach(c => input.classList.remove(c));

      // Apply error class only when invalid (no success styling - green is distracting)
      if (showErrors && (!isValid || hasErrors)) {
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

  /**
   * Called by parent hook when parent state changes.
   * Updates local state for bound fields and triggers animations.
   */
  refreshFromParent(parentHook) {
    if (!this.bindings || Object.keys(this.bindings).length === 0) return;

    const changedFields = [];

    // Check each binding for changes
    for (const [localField, parentField] of Object.entries(this.bindings)) {
      const parentValue = parentHook.state[parentField];
      const localValue = this.state[localField];

      if (parentValue !== localValue) {
        this.state[localField] = parentValue;
        changedFields.push(localField);

        // All fields (including animated) live in the store.
        // For animated fields, setOptimistic drives the phase machine automatically.
        // For non-animated fields, it just tracks pending state.
        const syncedVar = this.store.get(localField, parentValue, (newVal) => {
          this.state[localField] = newVal;
        });
        syncedVar.setOptimistic(parentValue);
      }
    }

    if (changedFields.length > 0) {
      this.recomputeDerives(changedFields);
      this.updateDOM();
    }
  },

  /**
   * Propagate bound field changes to parent hook via lavash-set events.
   * When the server updates a bound field (e.g., on_saved sets open: nil),
   * the parent needs to update its corresponding state.
   */
  propagateBoundFieldsToParent(changedFields) {
    if (!this.bindings || Object.keys(this.bindings).length === 0) return;
    if (!changedFields || changedFields.length === 0) return;

    for (const localField of changedFields) {
      const parentField = this.bindings[localField];
      if (parentField) {
        const value = this.state[localField];

        // Dispatch lavash-set event to parent
        // The event bubbles up to the parent hook which handles it via handleLavashSet
        const event = new CustomEvent("lavash-set", {
          bubbles: true,
          detail: { field: parentField, value }
        });
        this.el.dispatchEvent(event);
      }
    }
  },

  // Convert snake_case field name to Title Case
  humanizeFieldName(name) {
    return name
      .split("_")
      .map(word => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" ");
  },

  // Sync URL fields to browser URL without triggering navigation
  syncUrl() {
    syncStateToUrl(this.urlFields, this.state);
  },

  // Check if a field has pending sources (for derives)
  hasPendingSources(field) {
    const deps = this.graph.deps[field];
    if (!deps) return false;

    const pendingPaths = this.store.getPendingPaths();

    // Check if any dependency is pending (either directly or transitively)
    for (const dep of deps) {
      // Check if dep or any nested path under it is pending
      if (pendingPaths.some(p => p === dep || p.startsWith(dep + "."))) return true;
      // Recursively check if dep is a derive with pending sources
      if (this.hasPendingSources(dep)) return true;
    }
    return false;
  },

  /**
   * Before DOM update - capture pre-update state for FLIP animations.
   * Called by Phoenix LiveView before morphdom applies patches.
   */
  beforeUpdate() {
    if (this.animatedStates) {
      for (const [field, anim] of Object.entries(this.animatedStates)) {
        const phase = this.store.get(field).getPhase();
        if (phase === "visible" || phase === "entering" || phase === "loading") {
          anim.delegate?.capturePreUpdateRect?.(phase);
        }
      }
    }
  },

  updated() {
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

    // Detect async fields that became ready (before store.serverUpdate overwrites old values)
    const asyncFieldsReady = this.detectAsyncFieldsReady(serverState);

    // Detect if any animated field is opening (for _params clearing in mergeServerState).
    // Check phase rather than value — by the time updated() runs, refreshFromParent
    // may have already set the value optimistically, so old/new comparison won't work.
    // "entering" phase means the modal just opened this cycle.
    let isModalOpening = false;
    if (this.animatedStates) {
      for (const field of Object.keys(this.animatedStates)) {
        const sv = this.store.get(field);
        const phase = sv.getPhase();
        if (phase === "entering" || phase === "loading") {
          isModalOpening = true;
        }
      }
    }

    // Update all SyncedVars from server state.
    // Animated vars always accept (server-authoritative). Plain vars reject when pending.
    // The animated SyncedVar's onChange callback updates this.state automatically,
    // and its phase machine fires from _handleValueChange.
    this.store.serverUpdate(serverState);

    // Track which _params fields were cleared by server (to skip re-init from DOM)
    this._clearedParamsFields = new Set();

    // Update this.state for non-store fields (nested objects, etc.)
    const pendingPaths = new Set(this.store.getPendingPaths());
    this.mergeServerState(serverState, "", pendingPaths, [], isModalOpening);

    // Update version tracking
    if (newServerVersion >= this.clientVersion) {
      this.serverVersion = newServerVersion;
      this.clientVersion = newServerVersion;
    } else {
      this.serverVersion = newServerVersion;
    }

    // Notify animated states that async data is ready
    for (const asyncField of asyncFieldsReady) {
      this.notifyAsyncReady(asyncField);
    }

    // Let delegates handle post-update logic (e.g., modal FLIP animations)
    this.notifyAnimatedStatesDelegatesUpdated();

    // Initialize form params from any newly-added inputs (e.g., async modal content)
    this.initializeFormParamsFromDOM();

    this.recomputeDerives();
    this.updateDOM();

    // Restore inputs with pending values (server may have overwritten them)
    const boundInputs = this.el.querySelectorAll("[data-lavash-bind]");
    boundInputs.forEach(input => {
      const fieldPath = input.dataset.lavashBind;
      if (fieldPath && this.store.isPending(fieldPath)) {
        const val = this.store.getValue(fieldPath);
        if (val !== undefined && input.value !== val) {
          input.value = val;
        }
      }
    });

    this._clearedParamsFields = null;
  },

  /**
   * Detect which async fields went from null/undefined to having a value.
   * Used to notify animated states that async data is ready.
   */
  detectAsyncFieldsReady(serverState) {
    const ready = [];
    if (this.animatedStates) {
      for (const anim of Object.values(this.animatedStates)) {
        const asyncField = anim.config.async;
        if (asyncField) {
          // Check the form's _action field — it transitions from null/loading to create/update
          // when async data arrives. The form itself isn't in the client state JSON.
          const actionField = `${asyncField}_action`;
          const oldAction = this.state[actionField];
          const newAction = serverState[actionField];
          if ((!oldAction || oldAction === "loading") && newAction && newAction !== "loading") {
            ready.push(asyncField);
          }
        }
      }
    }
    return ready;
  },

  /**
   * Merge server state into this.state, skipping paths that are pending.
   * Returns array of top-level changed field names.
   * @param isModalOpening - true if a modal/overlay is opening in this update
   */
  mergeServerState(obj, prefix, pendingPaths, changedFields = [], isModalOpening = false) {
    // Track changed fields at the top level only

    for (const [key, value] of Object.entries(obj)) {
      const path = prefix ? `${prefix}.${key}` : key;
      const topLevelField = prefix ? prefix.split(".")[0] : key;

      // Check if this exact path or any child path is pending
      let hasPendingChild = [...pendingPaths].some(p => p === path || p.startsWith(path + "."));

      // Special handling for server_errors paths:
      // Skip merging server errors for a field if its corresponding params field is pending
      // Example: skip "address_form_server_errors.city" if "address_form_params.city" is pending
      if (prefix && prefix.endsWith("_server_errors")) {
        const formName = prefix.replace(/_server_errors$/, "");
        const paramPath = `${formName}_params.${key}`;
        if (pendingPaths.has(paramPath)) {
          console.debug(`[LavashOptimistic] Skipping server error update for ${path} - corresponding param ${paramPath} is pending`);
          hasPendingChild = true; // Treat as pending to skip this server error update
        }
      }

      if (value !== null && typeof value === "object" && !Array.isArray(value)) {
        // Empty server object replaces client object (clears stale keys like old server_errors)
        if (Object.keys(value).length === 0) {
          // Special case: For _params fields, server sending {} means "clear the form"
          // Only clear pending paths if a modal is OPENING in this update
          // When modal is already open, preserve pending paths (user's current input)
          if (key.endsWith("_params") && prefix === "") {
            const formName = key.replace(/_params$/, "");

            if (hasPendingChild && isModalOpening) {
              console.debug(`[LavashOptimistic] Modal opening: clearing pending paths for ${key}`);
              for (const pendingPath of [...pendingPaths]) {
                if (pendingPath.startsWith(path + ".")) {
                  this.store.clearPending(pendingPath);
                  pendingPaths.delete(pendingPath);
                }
              }
              hasPendingChild = false;
            }

            // Clear touched/show_errors state only when modal is opening
            if (isModalOpening) {
              for (const fieldPath of Object.keys(this.fieldState)) {
                if (fieldPath.startsWith(path + ".")) {
                  delete this.fieldState[fieldPath];
                  const fieldName = fieldPath.substring(path.length + 1);
                  const showErrorsKey = `${formName}_${fieldName}_show_errors`;
                  this.state[showErrorsKey] = false;
                }
              }
            }

          }

          // Special case: Don't clear {form}_server_errors if ANY params for that form are pending
          let shouldSkipClear = false;
          if (key.endsWith("_server_errors") && prefix === "") {
            const formName = key.replace(/_server_errors$/, "");
            const paramsField = `${formName}_params`;
            // Check if any params for this form are pending
            const hasFormParamsPending = [...pendingPaths].some(p => p.startsWith(paramsField + "."));
            if (hasFormParamsPending) {
              console.debug(`[LavashOptimistic] Skipping clear of ${key} - form has pending params`);
              shouldSkipClear = true;
            }
          }

          if (!shouldSkipClear && !hasPendingChild) {
            const oldValue = this.getStateAtPath(path);
            if (oldValue !== undefined && oldValue !== null && typeof oldValue === "object" && Object.keys(oldValue).length > 0) {
              console.debug(`[LavashOptimistic] Clearing ${path}: empty object from server, no pending paths`);
              this.setStateAtPath(path, {});
              if (changedFields && !changedFields.includes(topLevelField)) {
                changedFields.push(topLevelField);
              }

              // For _params fields that we're actually clearing (not just seeing empty):
              // Track as cleared and clear DOM input values
              if (key.endsWith("_params") && prefix === "") {
                // Track this params field as cleared so initializeFormParamsFromDOM skips it
                if (this._clearedParamsFields) {
                  this._clearedParamsFields.add(key);
                }

                // Clear DOM input values to prevent stale data showing when form is reset
                const inputSelector = `[data-lavash-bind^="${key}."]`;
                const inputs = this.el.querySelectorAll(inputSelector);
                inputs.forEach(input => {
                  if (input.value !== "") {
                    console.debug(`[LavashOptimistic] Clearing DOM input value for ${input.dataset.lavashBind}`);
                    input.value = "";
                  }
                });
              }
            }
          }
        } else {
          // Recurse into nested objects
          this.mergeServerState(value, path, pendingPaths, changedFields, isModalOpening);
        }
      } else if (!hasPendingChild) {
        // Leaf value with no pending - update state
        const oldValue = this.getStateAtPath(path);
        if (oldValue !== value) {
          this.setStateAtPath(path, value);
          // Track the top-level field that changed
          if (changedFields && !changedFields.includes(topLevelField)) {
            changedFields.push(topLevelField);
          }
        }
      }
    }

    return prefix === "" ? changedFields : null;
  },

  /**
   * Format an input value based on the format type.
   * Returns { value: rawValue, display: formattedDisplay } or null if no formatting needed.
   *
   * Supported formats:
   * - "credit-card": Format as XXXX XXXX XXXX XXXX (spaces every 4 digits)
   * - "expiry": Format as MM/YY (slash after 2 digits)
   */
  formatInputValue(rawValue, format) {
    switch (format) {
      case "credit-card": {
        // Strip non-digits
        const digits = rawValue.replace(/\D/g, "");
        // Limit to 16 digits (or 19 for some card types, but 16 is standard)
        const limited = digits.slice(0, 16);
        // Format with spaces every 4 digits
        const display = limited.match(/.{1,4}/g)?.join(" ") || "";
        // Store the formatted value (with spaces) - validation strips non-digits anyway
        return { value: display, display };
      }

      case "expiry": {
        // Strip non-digits
        const digits = rawValue.replace(/\D/g, "");
        // Limit to 4 digits (MMYY)
        const limited = digits.slice(0, 4);
        // Format as MM/YY
        let display;
        if (limited.length <= 2) {
          display = limited;
        } else {
          display = limited.slice(0, 2) + "/" + limited.slice(2);
        }
        // Store the formatted value (with slash)
        return { value: display, display };
      }

      default:
        return null;
    }
  },

  destroyed() {
    // Preserve client-only state for potential remount
    // This allows touched/submitted state to survive hook remounts during LiveView patches
    if (this.el.id) {
      _preservedClientState.set(this.el.id, {
        fieldState: this.fieldState,
        submittedForms: this.submittedForms
      });
      // Clear after a short delay if not reused (prevents memory leaks)
      setTimeout(() => {
        _preservedClientState.delete(this.el.id);
      }, 1000);
    }

    // Remove event listeners (attached for both LiveViews and components)
    this.el.removeEventListener("click", this.handleClick.bind(this), true);
    this.el.removeEventListener("input", this.handleInput.bind(this), true);
    this.el.removeEventListener("change", this.handleInput.bind(this), true);
    this.el.removeEventListener("blur", this.handleBlur.bind(this), true);
    this.el.removeEventListener("submit", this.handleFormSubmit.bind(this), true);

    // Clean up modal event listeners
    if (this._modalEventListeners) {
      for (const { el, open, close } of this._modalEventListeners) {
        el.removeEventListener("open-panel", open);
        el.removeEventListener("close-panel", close);
      }
      this._modalEventListeners = [];
    }

    // Clean up modal content registry entries for this hook
    if (window.__lavashModalContentRegistry) {
      for (const [contentId, entry] of Object.entries(window.__lavashModalContentRegistry)) {
        if (entry.hook === this) {
          delete window.__lavashModalContentRegistry[contentId];
        }
      }
    }

    // Clean up animated SyncedVars
    if (this.animatedStates) {
      for (const field of Object.keys(this.animatedStates)) {
        this.store.get(field).destroy();
      }
      this.animatedStates = {};
    }
  }
};

export { LavashOptimistic };
