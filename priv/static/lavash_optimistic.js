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
import { AnimatedState } from "./animated_state.js";

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

    // Bindings map: local field -> parent field (for parent-to-child propagation)
    // When parent state changes, we update our local state and animate
    this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");

    // Form field state tracking (client-side only)
    // Maps field path -> { touched: boolean, serverErrors: [], validationRequestId: number }
    this.fieldState = {};

    // Per-form submitted state: Set of form IDs that have been submitted
    // This prevents a child component's form submit from affecting parent forms
    this.submittedForms = new Set();

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

    // Check if this is a component
    this.isComponent = this.el.hasAttribute("data-lavash-component");

    // Intercept clicks on elements with data-lavash-action
    this.el.addEventListener("click", this.handleClick.bind(this), true);

    // Intercept input/change on elements with data-lavash-bind
    this.el.addEventListener("input", this.handleInput.bind(this), true);

    // Track blur events for touched state
    this.el.addEventListener("blur", this.handleBlur.bind(this), true);

    // Track form submit for formSubmitted state
    this.el.addEventListener("submit", this.handleFormSubmit.bind(this), true);

    // Handle lavash-set events from child ClientComponents
    // This allows nested components to set bound state on parent components
    // Use bubbling mode (not capture) so the closest ancestor hook handles it first
    this.el.addEventListener("lavash-set", this.handleLavashSet.bind(this), false);

    if (!this.isComponent) {

      // Listen for server validation responses
      this.handleEvent("validation_result", (payload) => this.handleValidationResult(payload));
    }

    // Install global DOM callback for input preservation (only once globally)
    this._installGlobalDomCallback();

    // Initialize animated state managers
    this.initAnimatedFields();
  },

  /**
   * Initialize AnimatedState managers for fields with animated: true.
   * Reads configuration from __animated__ metadata in the generated optimistic module.
   * For type: "modal" or "flyover" fields, creates an OverlayAnimator as the delegate.
   */
  initAnimatedFields() {
    this.animatedStates = {};

    // First try __animated__ from generated functions (LiveViews)
    let animatedConfigs = this.fns.__animated__ || [];

    // For components, also check data-lavash-animated attribute
    if (animatedConfigs.length === 0 && this.el.dataset.lavashAnimated) {
      try {
        animatedConfigs = JSON.parse(this.el.dataset.lavashAnimated);
        console.log(`[LavashOptimistic] Parsed animated configs from data attr:`, animatedConfigs);
      } catch (e) {
        console.warn("[LavashOptimistic] Failed to parse data-lavash-animated:", e);
      }
    }

    console.log(`[LavashOptimistic] initAnimatedFields: ${animatedConfigs.length} configs`, animatedConfigs);

    for (const config of animatedConfigs) {
      // Create delegate based on type
      let delegate = null;

      if (config.type === "modal") {
        // For modal type, create OverlayAnimator targeting the modal chrome element
        const OverlayAnimator = window.Lavash?.OverlayAnimator;
        if (OverlayAnimator) {
          // Modal chrome ID is "{component_id}-modal" where component_id is extracted from wrapper ID
          // Wrapper ID is "lavash-{component_id}", so modal ID is "{component_id}-modal"
          const wrapperId = this.el.id; // e.g., "lavash-product-edit-modal"
          const componentId = wrapperId.replace(/^lavash-/, ""); // e.g., "product-edit-modal"
          const modalChromeId = `${componentId}-modal`; // e.g., "product-edit-modal-modal"
          const modalChrome = document.getElementById(modalChromeId);

          if (modalChrome) {
            delegate = new OverlayAnimator(modalChrome, {
              type: 'modal',
              duration: config.duration || 200,
              openField: config.field,
              js: this.js()
            });
            console.debug(`[LavashOptimistic] Created OverlayAnimator (modal) for ${config.field} on #${modalChromeId}`);

            // Register content element IDs for ghost detection in onBeforeElUpdated
            const mainContentId = `${modalChromeId}-main_content`;
            const mainContentInnerId = `${modalChromeId}-main_content_inner`;
            this._registerModalContentIds(mainContentId, mainContentInnerId, config.field);

            // Set up event listeners on modal chrome for open/close events
            // We store references for cleanup in destroyed()
            this._modalEventListeners = this._modalEventListeners || [];
            const setterAction = `set_${config.field}`;

            const openHandler = (e) => {
              const openValue = e.detail?.[config.field] ?? e.detail?.value ?? true;
              console.log(`[LavashOptimistic] open-panel event for ${config.field}:`, openValue);
              console.log(`[LavashOptimistic] animatedStates:`, Object.keys(this.animatedStates || {}));
              // AnimatedState is created after this block, access via closure
              const animState = this.animatedStates[config.field];
              if (animState) {
                console.log(`[LavashOptimistic] Found animState, calling set()`);
                animState.syncedVar.set(openValue, (p, cb) => {
                  console.log(`[LavashOptimistic] pushEventTo ${setterAction}`, p);
                  this.pushEventTo(modalChrome, setterAction, { ...p, value: openValue }, cb);
                });
              } else {
                console.warn(`[LavashOptimistic] No animState found for ${config.field}`);
              }
            };

            const closeHandler = () => {
              console.debug(`[LavashOptimistic] close-panel event for ${config.field}`);
              const animState = this.animatedStates[config.field];
              if (animState) {
                animState.syncedVar.set(null, (p, cb) => {
                  this.pushEventTo(modalChrome, setterAction, { ...p, value: null }, cb);
                });
              }
            };

            modalChrome.addEventListener("open-panel", openHandler);
            modalChrome.addEventListener("close-panel", closeHandler);
            this._modalEventListeners.push({ el: modalChrome, open: openHandler, close: closeHandler });
          } else {
            console.warn(`[LavashOptimistic] Modal chrome element #${modalChromeId} not found for animated field ${config.field}`);
          }
        } else {
          console.warn("[LavashOptimistic] OverlayAnimator not found in window.Lavash for type:modal field");
        }
      } else if (config.type === "flyover") {
        // For flyover type, create OverlayAnimator targeting the flyover chrome element
        const OverlayAnimator = window.Lavash?.OverlayAnimator;
        if (OverlayAnimator) {
          // Flyover chrome ID is "{component_id}-flyover" where component_id is extracted from wrapper ID
          // Wrapper ID is "lavash-{component_id}", so flyover ID is "{component_id}-flyover"
          const wrapperId = this.el.id; // e.g., "lavash-nav-flyover"
          const componentId = wrapperId.replace(/^lavash-/, ""); // e.g., "nav-flyover"
          const flyoverChromeId = `${componentId}-flyover`; // e.g., "nav-flyover-flyover"
          const flyoverChrome = document.getElementById(flyoverChromeId);

          if (flyoverChrome) {
            delegate = new OverlayAnimator(flyoverChrome, {
              type: 'flyover',
              duration: config.duration || 200,
              slideFrom: flyoverChrome.dataset.slideFrom || 'right',
              openField: config.field,
              js: this.js()
            });
            console.debug(`[LavashOptimistic] Created OverlayAnimator (flyover) for ${config.field} on #${flyoverChromeId}`);

            // Register content element IDs for ghost detection in onBeforeElUpdated
            const mainContentId = `${flyoverChromeId}-main_content`;
            const mainContentInnerId = `${flyoverChromeId}-main_content_inner`;
            this._registerModalContentIds(mainContentId, mainContentInnerId, config.field);

            // Set up event listeners on flyover chrome for open/close events
            this._modalEventListeners = this._modalEventListeners || [];
            const setterAction = `set_${config.field}`;

            const openHandler = (e) => {
              const openValue = e.detail?.[config.field] ?? e.detail?.open ?? e.detail?.value ?? true;
              console.log(`[LavashOptimistic] open-panel event for flyover ${config.field}:`, openValue);
              const animState = this.animatedStates[config.field];
              if (animState) {
                animState.syncedVar.set(openValue, (p, cb) => {
                  console.log(`[LavashOptimistic] pushEventTo ${setterAction}`, p);
                  this.pushEventTo(flyoverChrome, setterAction, { ...p, value: openValue }, cb);
                });
              } else {
                console.warn(`[LavashOptimistic] No animState found for ${config.field}`);
              }
            };

            const closeHandler = () => {
              console.debug(`[LavashOptimistic] close-panel event for flyover ${config.field}`);
              const animState = this.animatedStates[config.field];
              if (animState) {
                animState.syncedVar.set(null, (p, cb) => {
                  this.pushEventTo(flyoverChrome, setterAction, { ...p, value: null }, cb);
                });
              }
            };

            flyoverChrome.addEventListener("open-panel", openHandler);
            flyoverChrome.addEventListener("close-panel", closeHandler);
            this._modalEventListeners.push({ el: flyoverChrome, open: openHandler, close: closeHandler });
          } else {
            console.warn(`[LavashOptimistic] Flyover chrome element #${flyoverChromeId} not found for animated field ${config.field}`);
          }
        } else {
          console.warn("[LavashOptimistic] OverlayAnimator not found in window.Lavash for type:flyover field");
        }
      }

      const animated = new AnimatedState(config, this, delegate);

      // Initialize from current state value
      const currentValue = this.state[config.field];
      if (currentValue != null) {
        // Already open - transition to appropriate phase
        animated.syncedVar.setOptimistic(currentValue);
      }

      this.animatedStates[config.field] = animated;

      console.debug(`[LavashOptimistic] Initialized animated field: ${config.field}${delegate ? " with delegate" : ""}`);
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
    return Object.values(this.animatedStates).some(
      a => a.getPhase() === "entering" || a.getPhase() === "exiting"
    );
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
      // Preserve input values for form fields with data-lavash-bind
      // This runs before morphdom patches the DOM, so we can prevent value overwrites
      if (fromEl.hasAttribute && fromEl.hasAttribute("data-lavash-bind")) {
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
      }

      // Check if any registered modal cares about this element
      const registry = window.__lavashModalContentRegistry || {};
      const entry = registry[fromEl.id];

      if (entry) {
        const { hook, field, innerId } = entry;
        const animated = hook.animatedStates?.[field];

        if (animated) {
          // Check if modal is in a state where we should preserve content
          const phase = animated.getPhase();
          const shouldPreserve = phase === "visible" || phase === "loading";

          if (shouldPreserve) {
            const fromHasInner = fromEl.querySelector(`#${innerId}`);
            const toHasInner = toEl.querySelector(`#${innerId}`);

            if (fromHasInner && !toHasInner) {
              // Content is being removed! Create ghost NOW before morphdom patches
              console.debug(`[LavashOptimistic] onBeforeElUpdated detected content removal for ${field}`);
              if (animated.delegate?.createGhostBeforePatch) {
                animated.delegate.createGhostBeforePatch(fromHasInner);
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

      // Use custom valid field if specified on input, otherwise standard naming
      const customValidField = input.dataset?.lavashValid;
      const validField = customValidField || `${formName}_${fieldName}_valid`;
      const clientValid = this.state[validField] ?? true;
      const serverErrors = this.fieldState[fieldPath]?.serverErrors || [];

      // Field is invalid if client validation fails or has server errors
      if (!clientValid || serverErrors.length > 0) {
        // Focus this field and prevent form submission
        e.preventDefault();
        input.focus();

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

    console.log("[LavashOptimistic] handleLavashSet", field, "=", value);

    // Check if this field has an animated state (modal/flyover)
    const animatedState = this.animatedStates?.[field];
    if (animatedState) {
      // Stop propagation - we own this field
      e.stopPropagation();

      // For animated states (modal/flyover), falsy values mean "close" which is represented as null
      // The animation system uses null to detect close transitions
      const animValue = value ? value : null;

      // Use the animated state's syncedVar to set the value
      // This triggers proper animations and server sync
      const setterAction = `set_${field}`;
      animatedState.syncedVar.set(animValue, (payload, callback) => {
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
    console.log("[LavashOptimistic] Field", field, "not owned by this hook, letting event propagate");
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
    // Compute show_errors: touched || (this form was submitted)
    const touched = this.fieldState[fieldPath]?.touched || false;
    const formSubmitted = this.isFormSubmitted(formName);
    const showErrors = touched || formSubmitted;

    // Update state
    const showErrorsKey = `${formName}_${fieldName}_show_errors`;
    this.state[showErrorsKey] = showErrors;
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

      // Notify animated states of value changes
      this.notifyAnimatedStates(changedFields);

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
  notifyAnimatedStates(changedFields) {
    if (!this.animatedStates || !changedFields) return;

    for (const field of changedFields) {
      const animated = this.animatedStates[field];
      if (animated) {
        const oldValue = animated.syncedVar.getValue();
        const newValue = this.state[field];
        animated.syncedVar.setOptimistic(newValue);
        animated.onValueChange(newValue, oldValue, 'optimistic');
      }
    }
  },

  /**
   * Notify animated states that async data is ready.
   * Called when a read/async field gets populated.
   */
  notifyAsyncReady(asyncField) {
    if (!this.animatedStates) return;

    for (const animated of Object.values(this.animatedStates)) {
      if (animated.config.async === asyncField) {
        animated.onAsyncDataReady();
      }
    }
  },

  /**
   * Notify animated state delegates of a LiveView update.
   * Delegates can use this for post-update logic like FLIP animations.
   */
  notifyAnimatedStatesDelegatesUpdated() {
    if (!this.animatedStates) return;

    for (const animated of Object.values(this.animatedStates)) {
      if (animated.delegate?.onUpdated) {
        const phase = animated.getPhase();
        animated.delegate.onUpdated(animated, phase);
      }
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
          // Log error in development for debugging
          if (typeof console !== "undefined" && console.debug) {
            console.debug(`[Lavash] Error computing derive ${name}:`, err.message);
          }
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

  updateDOM() {
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
      el.disabled = !value;
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

      // Only show status if field has been touched/submitted and is invalid
      // (no success indicator - green checkmarks are distracting)
      if (!showErrors || (isValid && !hasServerErrors)) {
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

      // Check for server errors
      const hasServerErrors = (this.fieldState[fieldPath]?.serverErrors || []).length > 0;

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
      if (showErrors && !(isValid && !hasServerErrors)) {
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
        console.log(`[LavashOptimistic] refreshFromParent: ${localField} = ${JSON.stringify(parentValue)} (was ${JSON.stringify(localValue)})`);
        this.state[localField] = parentValue;
        changedFields.push(localField);

        // Update SyncedVar if exists
        const syncedVar = this.store.get(localField, parentValue, (newVal) => {
          this.state[localField] = newVal;
        });
        syncedVar.setOptimistic(parentValue);
      }
    }

    if (changedFields.length > 0) {
      // Notify animated states (this triggers modal animations!)
      this.notifyAnimatedStates(changedFields);

      // Recompute derives affected by changed fields
      this.recomputeDerives(changedFields);

      // Update DOM
      this.updateDOM();
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

  /**
   * Before DOM update - capture pre-update state for FLIP animations.
   * Called by Phoenix LiveView before morphdom applies patches.
   */
  beforeUpdate() {
    // Capture pre-update rects for animated states with delegates
    if (this.animatedStates) {
      for (const animated of Object.values(this.animatedStates)) {
        const phase = animated.getPhase();
        // Only capture if currently visible/entering/loading (something to animate from)
        if (phase === "visible" || phase === "entering" || phase === "loading") {
          if (animated.delegate?.capturePreUpdateRect) {
            animated.delegate.capturePreUpdateRect(phase);
          }
        }
      }
    }
  },

  updated() {
    // Server patch arrived - check version to decide whether to accept
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");

    console.log(`[LavashOptimistic] updated() - serverState keys:`, Object.keys(serverState));

    // Track which async fields got populated (for animated state coordination)
    const asyncFieldsReady = this.detectAsyncFieldsReady(serverState);
    console.log(`[LavashOptimistic] updated() - asyncFieldsReady:`, asyncFieldsReady);

    // Update SyncedVars from server state (flattened paths)
    // serverUpdate only updates vars that are not pending
    this.store.serverUpdate(serverState);

    // Also update our state object for fields without pending changes
    const pendingPaths = new Set(this.store.getPendingPaths());
    const changedFields = this.mergeServerState(serverState, "", pendingPaths);

    // Update version tracking
    if (newServerVersion >= this.clientVersion) {
      this.serverVersion = newServerVersion;
      this.clientVersion = newServerVersion;
    } else {
      this.serverVersion = newServerVersion;
    }

    // Notify animated states of server-side value changes
    if (changedFields && changedFields.length > 0) {
      this.notifyAnimatedStatesServerUpdate(changedFields);
    }

    // Notify animated states that async data is ready
    for (const asyncField of asyncFieldsReady) {
      this.notifyAsyncReady(asyncField);
    }

    // Let animated state delegates handle post-update logic (e.g., modal FLIP animations)
    this.notifyAnimatedStatesDelegatesUpdated();

    // Recompute derives based on current state
    this.recomputeDerives();

    // Update DOM after server patch
    this.updateDOM();

    // Restore all inputs with pending values (server may have overwritten them)
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
  },

  /**
   * Detect which async fields went from null/undefined to having a value.
   * Used to notify animated states that async data is ready.
   */
  detectAsyncFieldsReady(serverState) {
    const ready = [];

    // Check each animated field's async config
    if (this.animatedStates) {
      for (const animated of Object.values(this.animatedStates)) {
        const asyncField = animated.config.async;
        if (asyncField) {
          const oldValue = this.state[asyncField];
          const newValue = serverState[asyncField];

          // If was null/undefined and now has value, async is ready
          if ((oldValue == null) && (newValue != null)) {
            ready.push(asyncField);
          }
        }
      }
    }

    return ready;
  },

  /**
   * Notify animated states of value changes from server updates.
   */
  notifyAnimatedStatesServerUpdate(changedFields) {
    if (!this.animatedStates || !changedFields) return;

    console.log(`[LavashOptimistic] notifyAnimatedStatesServerUpdate - changedFields:`, changedFields);

    for (const field of changedFields) {
      const animated = this.animatedStates[field];
      if (animated) {
        const oldValue = animated.syncedVar.getValue();
        const newValue = this.state[field];

        console.log(`[LavashOptimistic] animated field ${field}: oldValue=${oldValue}, newValue=${newValue}`);

        // Only notify if value actually changed
        if (oldValue !== newValue) {
          console.log(`[LavashOptimistic] Notifying animated state for ${field}: ${oldValue} -> ${newValue}`);
          try {
            // Directly update the SyncedVar's value and confirmed state
            // We bypass serverSet() because it rejects when isPending, but version
            // tracking happens at the hook level, not the AnimatedState level
            animated.syncedVar.value = newValue;
            animated.syncedVar.confirmedValue = newValue;
            animated.syncedVar.confirmedVersion = animated.syncedVar.version;
            // AnimatedState.onValueChange handles the phase state machine
            animated.onValueChange(newValue, oldValue, 'server');
          } catch (e) {
            console.error(`[LavashOptimistic] Error notifying animated state for ${field}:`, e);
          }
        }
      }
    }
  },

  /**
   * Merge server state into this.state, skipping paths that are pending.
   * Returns array of top-level changed field names.
   */
  mergeServerState(obj, prefix, pendingPaths, changedFields = null) {
    // Track changed fields at the top level only
    const isTopLevel = prefix === "";
    if (isTopLevel && changedFields === null) {
      changedFields = [];
    }

    for (const [key, value] of Object.entries(obj)) {
      const path = prefix ? `${prefix}.${key}` : key;
      const topLevelField = prefix ? prefix.split(".")[0] : key;

      // Check if this exact path or any child path is pending
      const hasPendingChild = [...pendingPaths].some(p => p === path || p.startsWith(path + "."));

      if (value !== null && typeof value === "object" && !Array.isArray(value)) {
        // Recurse into nested objects
        this.mergeServerState(value, path, pendingPaths, changedFields);
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

    return isTopLevel ? changedFields : null;
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
    // Remove event listeners (attached for both LiveViews and components)
    this.el.removeEventListener("click", this.handleClick.bind(this), true);
    this.el.removeEventListener("input", this.handleInput.bind(this), true);
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

    // Clean up animated state managers
    if (this.animatedStates) {
      for (const animated of Object.values(this.animatedStates)) {
        animated.destroy();
      }
      this.animatedStates = {};
    }
  }
};

export { LavashOptimistic };
