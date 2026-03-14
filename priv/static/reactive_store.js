/**
 * ReactiveStore - Unified reactive state with dependency graph and version tracking.
 *
 * Combines:
 * - Plain state object (source of truth for renders)
 * - Dependency graph with topological recomputation (from graph.js)
 * - Per-field version tracking for optimistic/server conflict resolution
 * - SyncedVar composition for animated fields (modals, flyovers)
 *
 * Usage:
 *   const store = new ReactiveStore({
 *     initialState: { count: 0 },
 *     graph: { topo_order: ["doubled"], deps: { doubled: ["count"] }, dependents: { count: ["doubled"] } },
 *     fns: { doubled: (s) => s.count * 2 },
 *     onChange: (changedFields) => updateDOM(),
 *   });
 *
 *   store.set("count", 5);         // optimistic, recomputes doubled, calls onChange
 *   store.applyDelta({ count: 5 }); // batch from action result
 *   store.serverUpdate({ count: 5 }); // accept/reject based on pending state
 */

import { SyncedVar } from "./synced_var.js";
import { recomputeGraph } from "./graph.js";

export class ReactiveStore {
  /**
   * @param {Object} options
   * @param {Object} options.initialState - Initial state values
   * @param {Object} options.graph - { topo_order, deps, dependents }
   * @param {Object} options.fns - { name: (state) => value } compute functions
   * @param {Object} [options.animatedConfigs] - { field: { animated, onPhaseChange } }
   * @param {Function} [options.onChange] - (changedFields: string[]) => void
   */
  constructor({ initialState = {}, graph = {}, fns = {}, animatedConfigs = {}, onChange = null } = {}) {
    this.state = { ...initialState };
    this.graph = graph.topo_order ? graph : { topo_order: [], deps: {}, dependents: {} };
    this.fns = fns;
    this.onChange = onChange;

    // Per-field version tracking (lightweight for plain fields)
    this._versions = {};

    // Animated fields get full SyncedVar instances
    this._animatedVars = {};

    for (const [field, config] of Object.entries(animatedConfigs)) {
      this._animatedVars[field] = new SyncedVar(initialState[field] ?? null, {
        animated: config.animated,
        onChange: (newVal) => { this.state[field] = newVal; },
        onPhaseChange: config.onPhaseChange,
      });
    }
  }

  // --- Mutation API ---

  /**
   * Set a top-level field optimistically (no server push).
   * Recomputes affected derives and notifies onChange.
   */
  set(field, value) {
    this.state[field] = value;
    this._bumpVersion(field);

    if (this._animatedVars[field]) {
      this._animatedVars[field].setOptimistic(value);
    }

    this._recompute([field]);
    this.onChange?.([field]);
  }

  /**
   * Set a value at a dotted path (e.g., "form_params.name").
   * Recomputes derives affected by the root field.
   */
  setAtPath(path, value) {
    this._setNestedValue(path, value);
    this._bumpVersion(path);

    const rootField = path.split(".")[0];
    this._recompute([rootField]);
    this.onChange?.([rootField]);
  }

  /**
   * Optimistic set + push to server.
   * For animated fields, delegates to SyncedVar.set().
   */
  setAndPush(field, value, pushFn, extraParams = {}) {
    if (this._animatedVars[field]) {
      this._animatedVars[field].set(value, pushFn, extraParams);
    } else {
      this.state[field] = value;
      this._bumpVersion(field);
      pushFn?.({ ...extraParams }, () => {
        this._confirmVersion(field);
      });
    }
    this._recompute([field]);
    this.onChange?.([field]);
  }

  /**
   * Batch multiple mutations, recompute once.
   *
   * Usage:
   *   store.transaction(tx => {
   *     tx.set("count", 5);
   *     tx.set("name", "hello");
   *   });
   */
  transaction(fn) {
    const changes = [];
    const tx = {
      set: (field, value) => {
        this.state[field] = value;
        this._bumpVersion(field);
        if (this._animatedVars[field]) {
          this._animatedVars[field].setOptimistic(value);
        }
        changes.push(field);
      },
      setAtPath: (path, value) => {
        this._setNestedValue(path, value);
        this._bumpVersion(path);
        const rootField = path.split(".")[0];
        if (!changes.includes(rootField)) changes.push(rootField);
      },
    };
    fn(tx);
    if (changes.length > 0) {
      this._recompute(changes);
      this.onChange?.(changes);
    }
  }

  /**
   * Apply a delta object from an optimistic action.
   * Returns array of changed field names.
   */
  applyDelta(delta) {
    const changedFields = [];
    for (const [key, val] of Object.entries(delta)) {
      this.state[key] = val;
      this._bumpVersion(key);
      if (this._animatedVars[key]) {
        this._animatedVars[key].setOptimistic(val);
      }
      changedFields.push(key);
    }
    this._recompute(changedFields);
    this.onChange?.(changedFields);
    return changedFields;
  }

  /**
   * Recompute all or specific derives.
   * Exposed for cases where external code modifies state directly.
   */
  recompute(changedFields = null) {
    this._recompute(changedFields);
  }

  // --- Server Reconciliation ---

  /**
   * Update state from server.
   * Animated vars always accept. Plain vars reject when pending
   * (unless server confirms the optimistic value).
   */
  serverUpdate(serverState) {
    const flat = this._flattenState(serverState);

    for (const [path, value] of Object.entries(flat)) {
      if (this._animatedVars[path]) {
        this._animatedVars[path].serverSet(value);
      } else if (this.isPending(path)) {
        if (this._deepEqual(value, this._getNestedValue(path))) {
          this._confirmVersion(path);
        }
        // else: reject — client has uncommitted work
      } else {
        this._setNestedValue(path, value);
      }
    }
  }

  // --- Query API ---

  /**
   * Check if a specific path has pending (unconfirmed) changes.
   */
  isPending(path) {
    const v = this._versions[path];
    if (!v) return false;
    return v.version !== v.confirmedVersion;
  }

  /**
   * Get all paths with pending changes.
   */
  getPendingPaths() {
    return Object.entries(this._versions)
      .filter(([_, v]) => v.version !== v.confirmedVersion)
      .map(([p]) => p);
  }

  /**
   * Check if a derive field has upstream sources with pending changes.
   */
  hasPendingSources(field) {
    const deps = this.graph.deps[field];
    if (!deps) return false;
    const pendingPaths = this.getPendingPaths();
    for (const dep of deps) {
      if (pendingPaths.some(p => p === dep || p.startsWith(dep + "."))) return true;
      if (this.hasPendingSources(dep)) return true;
    }
    return false;
  }

  /**
   * Get the animated SyncedVar for a field (or undefined).
   */
  getAnimatedVar(field) {
    return this._animatedVars[field];
  }

  /**
   * Check if any animated field is currently in an enter/exit transition.
   */
  isAnyAnimating() {
    return Object.values(this._animatedVars).some(sv => sv.isAnimating());
  }

  /**
   * Get a value from state at a dotted path.
   */
  getValue(path) {
    return this._getNestedValue(path);
  }

  // --- Lifecycle ---

  /**
   * Clean up animated SyncedVars.
   */
  destroy() {
    for (const sv of Object.values(this._animatedVars)) {
      sv.destroy();
    }
    this._animatedVars = {};
  }

  // --- Internal ---

  _bumpVersion(path) {
    if (!this._versions[path]) {
      this._versions[path] = { version: 0, confirmedVersion: 0 };
    }
    this._versions[path].version++;
  }

  _confirmVersion(path) {
    const v = this._versions[path];
    if (v) v.confirmedVersion = v.version;
  }

  clearPending(path) {
    this._confirmVersion(path);
  }

  _recompute(changedFields) {
    recomputeGraph(this.graph, this.fns, this.state, changedFields);
  }

  _setNestedValue(path, value) {
    const parts = path.split(".");
    if (parts.length === 1) {
      this.state[path] = value;
      return;
    }
    let cur = this.state;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!(p in cur) || typeof cur[p] !== "object" || cur[p] === null) cur[p] = {};
      cur = cur[p];
    }
    cur[parts[parts.length - 1]] = value;
  }

  _getNestedValue(path) {
    const parts = path.split(".");
    let cur = this.state;
    for (const p of parts) {
      if (cur == null || typeof cur !== "object") return undefined;
      cur = cur[p];
    }
    return cur;
  }

  _flattenState(obj, prefix = "") {
    const result = {};
    for (const [key, value] of Object.entries(obj)) {
      const path = prefix ? `${prefix}.${key}` : key;
      if (value !== null && typeof value === "object" && !Array.isArray(value)) {
        Object.assign(result, this._flattenState(value, path));
      } else {
        result[path] = value;
      }
    }
    return result;
  }

  _deepEqual(a, b) {
    if (a === b) return true;
    if (a == null || b == null) return a == b;
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false;
      for (let i = 0; i < a.length; i++) {
        if (!this._deepEqual(a[i], b[i])) return false;
      }
      return true;
    }
    if (typeof a === "object" && typeof b === "object") {
      const keysA = Object.keys(a);
      const keysB = Object.keys(b);
      if (keysA.length !== keysB.length) return false;
      for (const key of keysA) {
        if (!this._deepEqual(a[key], b[key])) return false;
      }
      return true;
    }
    return false;
  }
}

// --- Expose globally ---

window.Lavash = window.Lavash || {};
window.Lavash.ReactiveStore = ReactiveStore;

export default ReactiveStore;
