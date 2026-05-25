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
 * 2. Add phx-click="actionName" to buttons/elements (optimistic actions are auto-detected)
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
 * - phx-click: Triggers optimistic action on click (if action name matches a known optimistic function)
 * - phx-value-*: Value to pass to action (first phx-value-* attribute is used)
 * - data-lavash-display: Display state value as text content
 * - data-lavash-visible: Show/hide element based on boolean state (toggles "hidden" class)
 * - data-lavash-enabled: Enable/disable element based on boolean state
 * - data-lavash-toggle: Toggle classes based on boolean (format: "field|trueClasses|falseClasses")
 * - data-lavash-errors: Container for field error messages
 * - data-lavash-error-summary: Container for form error summary
 * - data-lavash-status: Field status indicator (✗ when invalid)
 * - data-lavash-show-errors: Override which show_errors field to check for visibility
 * - data-lavash-preserve: Prevent morphdom from updating this element
 */

import { SyncedVarStore } from "./synced_var.js";
import { syncStateToUrl } from "./url_sync.js";
import { recomputeGraph as _recomputeGraph } from "./graph.js";
import {
  setStateAtPath as _setStateAtPath,
  getStateAtPath as _getStateAtPath,
} from "./concerns/utils.js";
import { installGlobalDomCallback } from "./concerns/global_dom_callback.js";
import { updateDOM as _updateDOM, notifyChildren as _notifyChildren } from "./concerns/dom_updater.js";
import * as bindings from "./concerns/bindings.js";
import * as optimisticActions from "./concerns/optimistic_actions.js";
import { loadGeneratedFunctions as _loadGeneratedFunctions } from "./concerns/function_loader.js";
import * as forms from "./concerns/forms.js";
import * as overlays from "./concerns/overlays.js";

// Registry for optimistic function modules (for custom overrides)
window.Lavash = window.Lavash || {};
window.Lavash.optimistic = window.Lavash.optimistic || {};

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

    // Install global DOM callback for input preservation (only once globally)
    this._installGlobalDomCallback();

    // Optimistic actions: capture-phase click listener that runs the
    // client-side optimistic patch before Phoenix's event delegate fires.
    optimisticActions.mounted(this);

    // Bindings init: parse data-lavash-bindings map, install
    // lavash-set listener for parent↔child state propagation.
    bindings.mounted(this);

    // Forms init: per-field touched state, submitted-form tracking,
    // input/change/blur/submit listeners, validation-timer scratchpad.
    forms.mounted(this);

    // Initialize animated state managers (modals, flyovers, etc.)
    overlays.mounted(this);
  },

  getAnimatedState(field) {
    return this.animatedStates?.[field];
  },

  isAnyAnimating() {
    if (!this.animatedStates) return false;
    return Object.keys(this.animatedStates).some(
      field => this.store.get(field).isAnimating()
    );
  },

  _installGlobalDomCallback() {
    installGlobalDomCallback(this.liveSocket);
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
    const result = _loadGeneratedFunctions(this.moduleName, this.el);
    this.fns = result.fns;
    this.deriveNames = result.deriveNames;
    this.graph = result.graph;
  },

  setStateAtPath(path, value) {
    _setStateAtPath(this.state, path, value);
  },

  getStateAtPath(path) {
    return _getStateAtPath(this.state, path);
  },

  // Inline component scripts (loaded from generated <script> tags
  // by loadGeneratedFunctions) call hook.runOptimisticAction(...) to
  // dispatch by name. Keep the method as a thin delegator.
  runOptimisticAction(actionName, value) {
    optimisticActions.runOptimisticAction(actionName, value, this);
  },

  recomputeDerives(changedFields = null) {
    _recomputeGraph(this.graph, this.fns, this.state, changedFields);
  },


  updateDOM(isOptimistic = false) {
    _updateDOM(this.el, this.state, {
      getFormField: forms.getFormField,
      isFormSubmitted: (formName) => forms.isFormSubmittedFor(this, formName),
      isOptimistic,
    });
    this.notifyChildren();
  },

  notifyChildren() {
    _notifyChildren(this.el, this);
  },

  // Bindings methods kept on the hook because external callers
  // (parent hooks calling into this child, dom_updater calling out
  // to the parent) reach for `hook.refreshFromParent(...)` /
  // `hook.propagateBoundFieldsToParent(...)`. Delegate to the
  // bindings module for the actual work.
  refreshFromParent(parentHook) {
    bindings.refreshFromParent(this, parentHook);
  },

  propagateBoundFieldsToParent(changedFields, opts) {
    bindings.propagateBoundFieldsToParent(this, changedFields, opts);
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

  beforeUpdate() {
    overlays.beforeUpdate(this);
  },

  updated() {
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");
    const module = this.el.dataset.lavashModule || "?";

    // Log animated field states from server
    if (this.animatedStates) {
      for (const field of Object.keys(this.animatedStates)) {
        const sv = this.store.get(field);
        console.warn(`[LO:${module}] updated() entry: field=${field}, serverVal=${JSON.stringify(serverState[field])}, clientVal=${JSON.stringify(sv.value)}, v=${sv.version}, cv=${sv.confirmedVersion}, phase=${sv.getPhase()}, closeProt=${!!sv._closeProtection}`);
      }
    }

    // Detect async fields that became ready (before store.serverUpdate
    // overwrites old values). Detect whether any animated field is
    // entering/loading (for _params clearing in mergeServerState). Both
    // detections read SyncedVar state BEFORE store.serverUpdate runs.
    const asyncFieldsReady = overlays.detectAsyncFieldsReady(this, serverState);
    const isModalOpening = overlays.detectModalOpening(this);

    // Capture pending paths BEFORE serverUpdate — serverUpdate may increment
    // confirmedVersion (clearing pending state) while still rejecting the server
    // value. Without this, mergeServerState would see "not pending" and overwrite
    // this.state with the stale server value that the SyncedVar correctly rejected.
    const pendingPaths = new Set(this.store.getPendingPaths());
    if (pendingPaths.size > 0) {
      console.warn(`[LO:${module}] updated() pendingPaths before serverUpdate:`, [...pendingPaths]);
    }

    // Update all SyncedVars from server state.
    console.warn(`[LO:${module}] updated() calling store.serverUpdate`);
    this.store.serverUpdate(serverState);

    // Track which _params fields were cleared by server (to skip re-init from DOM)
    this._clearedParamsFields = new Set();

    // Update this.state for non-store fields (nested objects, etc.)
    this.mergeServerState(serverState, "", pendingPaths, [], isModalOpening);

    // Ensure this.state matches SyncedVar values for all store-managed fields.
    // SyncedVars are the source of truth — they may have rejected the server
    // value (keeping the optimistic value) while mergeServerState accepted it.
    for (const [path, sv] of Object.entries(this.store.vars)) {
      const cur = this.getStateAtPath(path);
      if (cur !== undefined && cur !== sv.value) {
        console.warn(`[LO:${module}] SV override: ${path} state=${JSON.stringify(cur)} → sv=${JSON.stringify(sv.value)}`);
        this.setStateAtPath(path, sv.value);
      }
    }

    // Update version tracking
    if (newServerVersion >= this.clientVersion) {
      this.serverVersion = newServerVersion;
      this.clientVersion = newServerVersion;
    } else {
      this.serverVersion = newServerVersion;
    }

    // Notify animated states that async data is ready, then let
    // delegates handle post-update logic (e.g., modal FLIP animations).
    overlays.notifyAsyncReadyForFields(this, asyncFieldsReady);
    overlays.notifyDelegatesUpdated(this);

    // Forms post-update: re-seed form params from any newly-added
    // inputs (e.g., async modal content that just rendered).
    forms.updated(this);

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
   * Merge server state into this.state, skipping paths that are pending.
   * Returns array of top-level changed field names.
   * @param isModalOpening - true if a modal/overlay is opening in this update
   */
  mergeServerState(obj, prefix, pendingPaths, changedFields = [], isModalOpening = false) {
    // Build set of animated phase fields to skip (managed client-side, server always sends stale "idle")
    if (!prefix && !this._animatedPhaseFields) {
      this._animatedPhaseFields = new Set();
      if (this.animatedStates) {
        for (const anim of Object.values(this.animatedStates)) {
          if (anim.config?.phaseField) {
            this._animatedPhaseFields.add(anim.config.phaseField);
          }
        }
      }
    }

    for (const [key, value] of Object.entries(obj)) {
      const path = prefix ? `${prefix}.${key}` : key;
      const topLevelField = prefix ? prefix.split(".")[0] : key;

      // Skip animated phase fields — they're managed by the SyncedVar phase machine,
      // not by server state. The server always sends "idle" which would overwrite
      // the client's actual phase (e.g., "visible", "entering").
      if (!prefix && this._animatedPhaseFields?.has(key)) continue;

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
              forms.clearFieldStateForPathPrefix(this, path, formName);
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


  destroyed() {
    // Forms cleanup: stash fieldState/submittedForms for potential
    // remount, remove input/change/blur/submit listeners.
    forms.destroyed(this);

    // Bindings cleanup: remove the lavash-set listener.
    bindings.destroyed(this);

    // Optimistic actions cleanup: remove the capture-phase click listener.
    optimisticActions.destroyed(this);

    // Overlay cleanup: tear down animation delegates, remove modal
    // event listeners, prune the modal-content registry for this hook.
    overlays.destroyed(this);
  }
};

export { LavashOptimistic };
