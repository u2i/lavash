/**
 * SyncedVar - Client-server state synchronization primitive with optional animation support.
 *
 * Models an eventually consistent variable with optimistic updates.
 * Tracks version numbers to detect and reject stale server patches.
 *
 * Basic Usage:
 *   const counter = new SyncedVar(0, { onChange: (newVal, oldVal, source) => { ... } });
 *   counter.setOptimistic(5);
 *   counter.set(5, pushFn);
 *
 * With Animation (for modals, panels, etc.):
 *   const modalState = new SyncedVar(null, {
 *     animated: {
 *       field: "product_id",
 *       phaseField: "product_id_phase",
 *       async: "edit_form",    // optional: wait for async data
 *       preserveDom: true,     // optional: ghost element during exit
 *       duration: 200          // animation duration in ms
 *     },
 *     onChange: (newVal, oldVal, source) => { ... }
 *   });
 *   modalState.setDelegate(modalAnimator); // receives onEntering, onVisible, etc.
 *
 * Animation Phases:
 * - "idle" - closed/hidden state
 * - "entering" - enter animation in progress
 * - "loading" - waiting for async data (when async option set)
 * - "visible" - fully open/visible
 * - "exiting" - exit animation in progress
 *
 * Delegate callbacks:
 * - onEntering(syncedVar) - start enter animation
 * - onLoading(syncedVar) - entered loading state
 * - onVisible(syncedVar) - fully visible
 * - onExiting(syncedVar) - start exit animation
 * - onIdle(syncedVar) - back to closed
 * - onAsyncReady(syncedVar) - async data arrived (in loading or visible phase)
 * - onContentReadyDuringEnter(syncedVar) - content arrived while enter animation running
 * - onTransitionEnd(syncedVar) - enter animation completed
 */

// --- Phase State Classes ---

class Phase {
  constructor(syncedVar) {
    this.syncedVar = syncedVar;
  }

  get name() {
    return this.constructor.name.replace(/Phase$/, "").toLowerCase();
  }

  onOpen() {}
  onClose() {}
  onAsyncReady() {}
  onTransitionEnd() {}
  onEnter() {}
  onExit() {}
}

class IdlePhase extends Phase {
  onEnter() {
    this.syncedVar._setPhase("idle");
    this.syncedVar._notifyDelegate("onIdle");
  }

  onOpen() {
    this.syncedVar._transitionTo(this.syncedVar._phases.entering);
  }
}

class EnteringPhase extends Phase {
  onEnter() {
    this.syncedVar._setPhase("entering");
    this.syncedVar._notifyDelegate("onEntering");

    // Set up fallback timeout in case delegate doesn't call transitionEnd
    this._timeout = setTimeout(() => {
      this.onTransitionEnd();
    }, this.syncedVar.animated.duration + 50);
  }

  onExit() {
    if (this._timeout) {
      clearTimeout(this._timeout);
    }
  }

  onTransitionEnd() {
    if (this._timeout) {
      clearTimeout(this._timeout);
      this._timeout = null;
    }

    // If we have async configured and data isn't ready, go to loading
    if (this.syncedVar.animated.async && !this.syncedVar.isAsyncReady) {
      this.syncedVar._transitionTo(this.syncedVar._phases.loading);
    } else {
      this.syncedVar._transitionTo(this.syncedVar._phases.visible);
    }
  }

  onClose() {
    this.syncedVar._transitionTo(this.syncedVar._phases.exiting);
  }

  onAsyncReady() {
    // Data arrived during enter animation - notify delegate to capture loading rect
    this.syncedVar.isAsyncReady = true;
    this.syncedVar._notifyDelegate("onContentReadyDuringEnter");
  }
}

class LoadingPhase extends Phase {
  onEnter() {
    this.syncedVar._setPhase("loading");
    this.syncedVar._notifyDelegate("onLoading");
  }

  onAsyncReady() {
    this.syncedVar.isAsyncReady = true;
    this.syncedVar._notifyDelegate("onAsyncReady");
    this.syncedVar._transitionTo(this.syncedVar._phases.visible);
  }

  onClose() {
    this.syncedVar._transitionTo(this.syncedVar._phases.exiting);
  }
}

class VisiblePhase extends Phase {
  onEnter() {
    this.syncedVar._setPhase("visible");
    this.syncedVar._notifyDelegate("onVisible");
  }

  onClose() {
    this.syncedVar._transitionTo(this.syncedVar._phases.exiting);
  }

  onAsyncReady() {
    // Data refresh while visible
    this.syncedVar._notifyDelegate("onAsyncReady");
  }
}

class ExitingPhase extends Phase {
  onEnter() {
    this.syncedVar._setPhase("exiting");
    this.syncedVar._notifyDelegate("onExiting");

    // Transition to idle after animation duration
    this._timeout = setTimeout(() => {
      this.syncedVar._transitionTo(this.syncedVar._phases.idle);
    }, this.syncedVar.animated.duration + 50);
  }

  onExit() {
    if (this._timeout) {
      clearTimeout(this._timeout);
    }
  }

  onOpen() {
    // Interrupted close - start opening again
    this.syncedVar._transitionTo(this.syncedVar._phases.entering);
  }
}

// --- SyncedVar Class ---

export class SyncedVar {
  /**
   * Create a SyncedVar.
   * @param {any} initialValue - Initial value
   * @param {Object|Function} options - Options object or onChange callback (for backwards compat)
   * @param {Function} options.onChange - Callback: (newValue, oldValue, source) => void
   * @param {Object} options.animated - Animation config (field, phaseField, async, preserveDom, duration)
   */
  constructor(initialValue, options = {}) {
    // Support legacy (value, callback) signature
    if (typeof options === "function") {
      options = { onChange: options };
    }

    this.value = initialValue;
    this.confirmedValue = initialValue;
    this.version = 0;
    this.confirmedVersion = 0;
    this.onChange = options.onChange || null;

    // FLIP animation support - captured rect travels with the state transition
    this.flipPreRect = null;

    // Animation support
    this.animated = options.animated || null;
    if (this.animated) {
      this._delegate = null;
      this.isAsyncReady = false;
      this.phase = "idle";

      // Initialize phase state machine
      this._phases = {
        idle: new IdlePhase(this),
        entering: new EnteringPhase(this),
        loading: new LoadingPhase(this),
        visible: new VisiblePhase(this),
        exiting: new ExitingPhase(this),
      };
      this._currentPhase = null;
      this._transitionTo(this._phases.idle);
    }
  }

  // --- Basic SyncedVar Methods ---

  /**
   * Optimistically set value without pushing to server.
   * Use this when the push happens externally (e.g., via phx-click).
   */
  setOptimistic(newValue) {
    const oldValue = this.value;
    if (newValue === oldValue) return false;

    this.version++;
    this.value = newValue;
    this._handleValueChange(newValue, oldValue, "optimistic");
    return true;
  }

  /**
   * Optimistically set value and push to server.
   * @param newValue - The new value to set
   * @param pushFn - Function to push to server: (params, replyCallback) => void
   * @param extraParams - Additional params to include in the push
   */
  set(newValue, pushFn, extraParams = {}) {
    const oldValue = this.value;
    if (newValue === oldValue) return;

    this.version++;
    const v = this.version;
    this.value = newValue;

    // Handle value change (triggers animation if configured)
    this._handleValueChange(newValue, oldValue, "optimistic");

    // Push to server with version tracking
    pushFn?.({ ...extraParams, _version: v }, (reply) => {
      if (v !== this.version) {
        // Stale response - a newer operation has started
        return;
      }
      this.confirmedVersion = v;
      this.confirmedValue = newValue;
      this.onChange?.(newValue, oldValue, "confirmed");
    });
  }

  /**
   * Server-initiated change (e.g., from patch in updated()).
   * Only accepts if client has no pending operations.
   * @returns true if accepted, false if rejected due to pending ops
   */
  serverSet(newValue) {
    if (this.isPending) {
      // Client has pending operations - ignore server change
      return false;
    }
    const oldValue = this.value;
    if (newValue === oldValue) return false;

    this.value = newValue;
    this.confirmedValue = newValue;
    this._handleValueChange(newValue, oldValue, "server");
    return true;
  }

  /**
   * Confirm that server has caught up to our version.
   * Call this when server version >= our version.
   */
  confirm(serverValue) {
    this.confirmedVersion = this.version;
    this.confirmedValue = serverValue;
    this.value = serverValue;
    this.onChange?.(serverValue, this.value, "confirmed");
  }

  /**
   * Whether there are pending operations not yet confirmed by server.
   */
  get isPending() {
    return this.version !== this.confirmedVersion;
  }

  /**
   * Get the current value.
   */
  getValue() {
    return this.value;
  }

  // --- Animation Methods (only available when animated config is set) ---

  /**
   * Set or update the delegate for lifecycle callbacks.
   * @param {Object} delegate - Object implementing onEntering, onVisible, etc.
   */
  setDelegate(delegate) {
    if (this.animated) {
      this._delegate = delegate;
    }
  }

  /**
   * Get current animation phase name.
   */
  getPhase() {
    if (!this.animated) return null;
    return this._currentPhase ? this._currentPhase.name : "idle";
  }

  /**
   * Check if currently in a transitioning phase.
   */
  isAnimating() {
    if (!this.animated) return false;
    const phase = this.getPhase();
    return phase === "entering" || phase === "exiting";
  }

  /**
   * Notify that async data has arrived.
   */
  onAsyncDataReady() {
    if (!this.animated) return;
    this.isAsyncReady = true;
    this._currentPhase?.onAsyncReady();
  }

  /**
   * Notify that enter transition has completed.
   * Call this from delegate's onEntering when animation finishes.
   */
  notifyTransitionEnd() {
    if (!this.animated) return;
    this._currentPhase?.onTransitionEnd?.();
  }

  /**
   * Clean up when destroyed.
   */
  destroy() {
    if (this.animated && this._currentPhase) {
      this._currentPhase.onExit();
    }
    this._delegate = null;
  }

  // --- Internal Methods ---

  /**
   * Handle value changes - calls onChange and triggers animation if configured.
   */
  _handleValueChange(newValue, oldValue, source) {
    // Always call onChange
    this.onChange?.(newValue, oldValue, source);

    // Handle animation phase transitions
    if (this.animated) {
      const wasOpen = oldValue != null;
      const isOpen = newValue != null;

      if (isOpen && !wasOpen) {
        // Opening
        this.isAsyncReady = false;
        this._currentPhase?.onOpen();
      } else if (!isOpen && wasOpen) {
        // Closing
        this._currentPhase?.onClose();
      }
    }
  }

  /**
   * Transition to a new phase.
   */
  _transitionTo(newPhase) {
    if (!this.animated) return;

    const oldPhaseName = this._currentPhase ? this._currentPhase.name : "initial";
    console.debug(
      `[SyncedVar ${this.animated.field}] ${oldPhaseName} -> ${newPhase.name}`
    );

    if (this._currentPhase) {
      this._currentPhase.onExit();
    }
    this._currentPhase = newPhase;
    this._currentPhase.onEnter();
  }

  /**
   * Update the phase (for external tracking/derives).
   */
  _setPhase(phaseName) {
    if (!this.animated) return;
    this.phase = phaseName;
    // Note: Hook integration for derives would go here if needed
  }

  /**
   * Notify delegate of lifecycle event.
   */
  _notifyDelegate(methodName) {
    if (!this.animated) return;
    try {
      this._delegate?.[methodName]?.(this);
    } catch (e) {
      console.error(
        `[SyncedVar ${this.animated.field}] Delegate ${methodName} error:`,
        e
      );
    }
  }
}

// --- Global Registry ---

/**
 * Get or create a SyncedVar from the global registry.
 * Creates animated SyncedVars from __animated__ metadata in optimistic modules.
 *
 * @param {string} moduleName - The module name (e.g., "DemoWeb.ProductEditModal")
 * @param {string} field - The field name (e.g., "product_id")
 * @returns {SyncedVar|null} The SyncedVar or null if no config found
 */
export function getSyncedVar(moduleName, field) {
  const registry = (window.Lavash._syncedVars =
    window.Lavash._syncedVars || {});
  const key = `${moduleName}:${field}`;

  if (!registry[key]) {
    const moduleFns = window.Lavash.optimistic?.[moduleName];
    const config = moduleFns?.__animated__?.find((c) => c.field === field);

    if (config) {
      registry[key] = new SyncedVar(null, {
        animated: {
          field: config.field,
          phaseField: config.phaseField,
          async: config.async,
          preserveDom: config.preserveDom,
          duration: config.duration,
        },
      });
      console.debug(
        `[Lavash] Created SyncedVar for ${moduleName}:${field}`,
        config
      );
    }
  }
  return registry[key] || null;
}

// --- SyncedVarStore (unchanged) ---

/**
 * SyncedVarStore - Manages a collection of SyncedVars with flattened keys.
 *
 * Supports dotted path keys (e.g., "params.name") that map to nested state.
 * Each leaf path gets its own SyncedVar for independent pending tracking.
 */
export class SyncedVarStore {
  constructor() {
    this.vars = {}; // path -> SyncedVar
  }

  /**
   * Get or create a SyncedVar for a path.
   * @param path - Dotted path like "count" or "params.name"
   * @param initialValue - Initial value if creating new
   * @param onChange - Change callback if creating new
   */
  get(path, initialValue = undefined, onChange = null) {
    if (!this.vars[path]) {
      this.vars[path] = new SyncedVar(initialValue, { onChange });
    }
    return this.vars[path];
  }

  /**
   * Check if a path exists in the store.
   */
  has(path) {
    return path in this.vars;
  }

  /**
   * Check if any SyncedVar in the store has pending changes.
   */
  get hasPending() {
    return Object.values(this.vars).some((v) => v.isPending);
  }

  /**
   * Get all pending paths.
   */
  getPendingPaths() {
    return Object.entries(this.vars)
      .filter(([_, v]) => v.isPending)
      .map(([path, _]) => path);
  }

  /**
   * Check if a specific path has pending changes.
   */
  isPending(path) {
    return this.vars[path]?.isPending ?? false;
  }

  /**
   * Build a nested state object from all SyncedVar values.
   */
  toState() {
    const state = {};
    for (const [path, syncedVar] of Object.entries(this.vars)) {
      setNestedValue(state, path, syncedVar.value);
    }
    return state;
  }

  /**
   * Update SyncedVars from a nested server state object.
   * Only updates vars that are not pending.
   */
  serverUpdate(serverState) {
    const flatState = flattenState(serverState);
    for (const [path, value] of Object.entries(flatState)) {
      if (this.vars[path]) {
        this.vars[path].serverSet(value);
      }
    }
  }

  /**
   * Get value at a path.
   */
  getValue(path) {
    return this.vars[path]?.value;
  }
}

// --- Helper Functions ---

function setNestedValue(obj, path, value) {
  const parts = path.split(".");
  let current = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const part = parts[i];
    if (!(part in current) || typeof current[part] !== "object") {
      current[part] = {};
    }
    current = current[part];
  }
  current[parts[parts.length - 1]] = value;
}

function flattenState(obj, prefix = "") {
  const result = {};
  for (const [key, value] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      Object.assign(result, flattenState(value, path));
    } else {
      result[path] = value;
    }
  }
  return result;
}

// --- Expose Globally ---

window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.SyncedVarStore = SyncedVarStore;
window.Lavash.getSyncedVar = getSyncedVar;

export default SyncedVar;
