/**
 * SyncedVar2 - Client-server state synchronization with optional animation.
 *
 * Models an eventually consistent variable with optimistic updates and
 * version tracking. Optionally drives a phase state machine for animated
 * open/close transitions (modals, flyovers, etc.).
 *
 * Basic usage:
 *   const counter = new SyncedVar2(0, { onChange: (val, old, src) => {} });
 *   counter.setOptimistic(5);
 *   counter.set(5, pushFn);
 *
 * Animated usage:
 *   const modal = new SyncedVar2(null, {
 *     animated: { duration: 200, async: "edit_form" },
 *     onChange: (val, old, src) => { hook.state.open = val; },
 *     onPhaseChange: (phase) => { hook.state.open_phase = phase; },
 *   });
 *   modal.setDelegate(overlayAnimator);
 *
 * Animation phases: idle -> entering -> [loading] -> visible -> exiting -> idle
 *
 * Delegate callbacks:
 *   onEntering(syncedVar)  - start enter animation
 *   onLoading(syncedVar)   - entered loading phase
 *   onVisible(syncedVar)   - fully visible
 *   onExiting(syncedVar)   - start exit animation
 *   onIdle(syncedVar)      - back to closed
 *   onAsyncReady(syncedVar) - async data arrived (loading or visible)
 *   onContentReadyDuringEnter(syncedVar) - async arrived during enter
 *   onUpdated(syncedVar, phase) - LiveView patch applied
 */

// --- Phase classes ---

class Phase {
  constructor(sv) { this.sv = sv; }
  get name() { return this._name; }
  onOpen() {}
  onClose() {}
  onAsyncReady() {}
  onTransitionEnd() {}
  onEnter() {}
  onExit() {}
}

class IdlePhase extends Phase {
  _name = "idle";
  onEnter() {
    this.sv._setPhase("idle");
    this.sv._notifyDelegate("onIdle");
  }
  onOpen() {
    this.sv._transitionTo(this.sv._phases.entering);
  }
}

class EnteringPhase extends Phase {
  _name = "entering";
  onEnter() {
    this.sv._setPhase("entering");
    this.sv._notifyDelegate("onEntering");
    this._timeout = setTimeout(() => this.onTransitionEnd(), this.sv._animDuration + 50);
  }
  onExit() {
    if (this._timeout) clearTimeout(this._timeout);
  }
  onTransitionEnd() {
    if (this._timeout) { clearTimeout(this._timeout); this._timeout = null; }
    if (this.sv._animAsync && !this.sv.isAsyncReady) {
      this.sv._transitionTo(this.sv._phases.loading);
    } else {
      this.sv._transitionTo(this.sv._phases.visible);
    }
  }
  onClose() {
    this.sv._transitionTo(this.sv._phases.exiting);
  }
  onAsyncReady() {
    this.sv.isAsyncReady = true;
    this.sv._notifyDelegate("onContentReadyDuringEnter");
  }
}

class LoadingPhase extends Phase {
  _name = "loading";
  onEnter() {
    this.sv._setPhase("loading");
    this.sv._notifyDelegate("onLoading");
  }
  onAsyncReady() {
    this.sv.isAsyncReady = true;
    this.sv._notifyDelegate("onAsyncReady");
    this.sv._transitionTo(this.sv._phases.visible);
  }
  onClose() {
    this.sv._transitionTo(this.sv._phases.exiting);
  }
}

class VisiblePhase extends Phase {
  _name = "visible";
  onEnter() {
    this.sv._setPhase("visible");
    this.sv._notifyDelegate("onVisible");
  }
  onClose() {
    this.sv._transitionTo(this.sv._phases.exiting);
  }
  onAsyncReady() {
    this.sv._notifyDelegate("onAsyncReady");
  }
}

class ExitingPhase extends Phase {
  _name = "exiting";
  onEnter() {
    this.sv._setPhase("exiting");
    this.sv._notifyDelegate("onExiting");
    this._timeout = setTimeout(() => {
      this.sv._transitionTo(this.sv._phases.idle);
    }, this.sv._animDuration + 50);
  }
  onExit() {
    if (this._timeout) clearTimeout(this._timeout);
  }
  onOpen() {
    this.sv._transitionTo(this.sv._phases.entering);
  }
}

// --- SyncedVar2 ---

export class SyncedVar2 {
  /**
   * @param {any} initialValue
   * @param {Object} options
   * @param {Function} options.onChange - (newValue, oldValue, source) => void
   * @param {Object}  options.animated - { duration, async } or null
   * @param {Function} options.onPhaseChange - (phaseName) => void (for hook state/derives)
   */
  constructor(initialValue, options = {}) {
    this.value = initialValue;
    this.confirmedValue = initialValue;
    this.version = 0;
    this.confirmedVersion = 0;
    this.onChange = options.onChange || null;

    // FLIP support
    this.flipPreRect = null;

    // Animation
    this.animated = !!options.animated;
    if (this.animated) {
      this._animDuration = options.animated.duration || 200;
      this._animAsync = options.animated.async || null;
      this._onPhaseChange = options.onPhaseChange || null;
      this._delegate = null;
      this.isAsyncReady = false;
      this.phase = "idle";
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

  // --- Value methods ---

  /**
   * Optimistic set without server push.
   * Returns true if value changed.
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
   * Optimistic set + push to server.
   */
  set(newValue, pushFn, extraParams = {}) {
    const oldValue = this.value;
    if (newValue === oldValue) return;
    this.version++;
    const v = this.version;
    this.value = newValue;
    this._handleValueChange(newValue, oldValue, "optimistic");

    pushFn?.({ ...extraParams, _version: v }, (reply) => {
      if (v !== this.version) return; // stale
      this.confirmedVersion = v;
      this.confirmedValue = newValue;
      this.onChange?.(newValue, oldValue, "confirmed");
    });
  }

  /**
   * Server-initiated change.
   *
   * For animated vars: always accepts (server is authoritative for open/close).
   * For plain vars: rejects when client has pending ops, unless server
   * confirms the same value we optimistically set.
   *
   * Returns true if value changed.
   */
  serverSet(newValue) {
    if (this.animated) {
      return this._serverSetAnimated(newValue);
    }
    return this._serverSetPlain(newValue);
  }

  _serverSetPlain(newValue) {
    if (this.isPending) {
      if (newValue === this.value) {
        // Server confirmed our optimistic value
        this.confirmedVersion = this.version;
        this.confirmedValue = newValue;
        return false;
      }
      return false; // reject — client has uncommitted work
    }
    const oldValue = this.value;
    if (newValue === oldValue) return false;
    this.value = newValue;
    this.confirmedValue = newValue;
    this._handleValueChange(newValue, oldValue, "server");
    return true;
  }

  _serverSetAnimated(newValue) {
    const oldValue = this.value;
    // Clear pending regardless — server is authoritative
    this.confirmedVersion = this.version;
    this.confirmedValue = newValue;
    if (newValue === oldValue) return false;
    this.value = newValue;
    this._handleValueChange(newValue, oldValue, "server");
    return true;
  }

  get isPending() {
    return this.version !== this.confirmedVersion;
  }

  getValue() {
    return this.value;
  }

  // --- Animation methods (no-op when not animated) ---

  setDelegate(delegate) {
    if (this.animated) this._delegate = delegate;
  }

  getPhase() {
    if (!this.animated) return null;
    return this._currentPhase ? this._currentPhase.name : "idle";
  }

  isAnimating() {
    if (!this.animated) return false;
    const p = this.getPhase();
    return p === "entering" || p === "exiting";
  }

  onAsyncDataReady() {
    if (!this.animated) return;
    this.isAsyncReady = true;
    this._currentPhase?.onAsyncReady();
  }

  notifyTransitionEnd() {
    if (!this.animated) return;
    this._currentPhase?.onTransitionEnd?.();
  }

  destroy() {
    if (this.animated && this._currentPhase) {
      this._currentPhase.onExit();
    }
    this._delegate = null;
  }

  // --- Internal ---

  _handleValueChange(newValue, oldValue, source) {
    this.onChange?.(newValue, oldValue, source);

    if (this.animated && source !== "confirmed") {
      const wasOpen = oldValue != null;
      const isOpen = newValue != null;
      if (isOpen && !wasOpen) {
        this.isAsyncReady = false;
        this._currentPhase?.onOpen();
      } else if (!isOpen && wasOpen) {
        this._currentPhase?.onClose();
      }
    }
  }

  _transitionTo(newPhase) {
    if (!this.animated) return;
    const old = this._currentPhase ? this._currentPhase.name : "init";
    console.debug(`[SyncedVar2] ${old} -> ${newPhase.name}`);
    if (this._currentPhase) this._currentPhase.onExit();
    this._currentPhase = newPhase;
    this._currentPhase.onEnter();
  }

  _setPhase(name) {
    if (!this.animated) return;
    this.phase = name;
    this._onPhaseChange?.(name);
  }

  _notifyDelegate(method) {
    if (!this.animated) return;
    try {
      this._delegate?.[method]?.(this);
    } catch (e) {
      console.error(`[SyncedVar2] delegate ${method} error:`, e);
    }
  }
}

// --- SyncedVarStore2 ---

export class SyncedVarStore2 {
  constructor() {
    this.vars = {};
  }

  /**
   * Get or create a SyncedVar2 for a path.
   * @param {string} path
   * @param {any} initialValue
   * @param {Object} options - { onChange, animated, onPhaseChange }
   */
  get(path, initialValue = undefined, options = null) {
    if (!this.vars[path]) {
      const opts = typeof options === "function"
        ? { onChange: options }
        : (options || {});
      this.vars[path] = new SyncedVar2(initialValue, opts);
    }
    return this.vars[path];
  }

  has(path) {
    return path in this.vars;
  }

  get hasPending() {
    return Object.values(this.vars).some(v => v.isPending);
  }

  getPendingPaths() {
    return Object.entries(this.vars)
      .filter(([_, v]) => v.isPending)
      .map(([p]) => p);
  }

  isPending(path) {
    return this.vars[path]?.isPending ?? false;
  }

  clearPending(path) {
    const v = this.vars[path];
    if (v) v.confirmedVersion = v.version;
  }

  toState() {
    const state = {};
    for (const [path, sv] of Object.entries(this.vars)) {
      setNestedValue(state, path, sv.value);
    }
    return state;
  }

  /**
   * Update vars from server state.
   * Each var's serverSet handles accept/reject based on its own policy.
   */
  serverUpdate(serverState) {
    const flat = flattenState(serverState);
    for (const [path, value] of Object.entries(flat)) {
      if (this.vars[path]) {
        this.vars[path].serverSet(value);
      }
    }
  }

  getValue(path) {
    return this.vars[path]?.value;
  }
}

// --- Helpers ---

function setNestedValue(obj, path, value) {
  const parts = path.split(".");
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const p = parts[i];
    if (!(p in cur) || typeof cur[p] !== "object") cur[p] = {};
    cur = cur[p];
  }
  cur[parts[parts.length - 1]] = value;
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

// --- Expose globally ---

window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar2 = SyncedVar2;
window.Lavash.SyncedVarStore2 = SyncedVarStore2;
