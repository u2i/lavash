/**
 * SyncedVar - Client-server state synchronization primitive
 *
 * Models an eventually consistent variable with optimistic updates.
 * Tracks version numbers to detect and reject stale server patches.
 *
 * Usage:
 *   const counter = new SyncedVar(0, (newVal, oldVal, source) => {
 *     console.log(`Changed from ${oldVal} to ${newVal} via ${source}`);
 *   });
 *
 *   // Optimistic update (client-side only, bumps version)
 *   counter.setOptimistic(5);
 *
 *   // With server push
 *   counter.set(5, (params, callback) => {
 *     this.pushEvent("increment", params, callback);
 *   });
 *
 *   // Server-initiated update (only accepts if not pending)
 *   counter.serverSet(5);
 *
 * For nested paths, use flattened keys in a SyncedVarStore:
 *   store.get("params.name").setOptimistic("Alice");
 */
export class SyncedVar {
  constructor(initialValue, onChange) {
    this.value = initialValue;           // optimistic client value
    this.confirmedValue = initialValue;  // last server-confirmed value
    this.version = 0;
    this.confirmedVersion = 0;
    this.onChange = onChange;            // callback: (newValue, oldValue, source) => void

    // FLIP animation support - captured rect travels with the state transition
    this.flipPreRect = null;
  }

  /**
   * Optimistically set value without pushing to server.
   * Use this when the push happens externally (e.g., via phx-click).
   */
  setOptimistic(newValue) {
    const oldValue = this.value;
    if (newValue === oldValue) return false;

    this.version++;
    this.value = newValue;
    this.onChange?.(newValue, oldValue, 'optimistic');
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

    // Notify of optimistic change
    this.onChange?.(newValue, oldValue, 'optimistic');

    // Push to server with version tracking
    pushFn?.({ ...extraParams, _version: v }, (reply) => {
      if (v !== this.version) {
        // Stale response - a newer operation has started
        return;
      }
      this.confirmedVersion = v;
      this.confirmedValue = newValue;
      this.onChange?.(newValue, oldValue, 'confirmed');
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
    this.onChange?.(newValue, oldValue, 'server');
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
    this.onChange?.(serverValue, this.value, 'confirmed');
  }

  /**
   * Whether there are pending operations not yet confirmed by server.
   */
  get isPending() {
    return this.version !== this.confirmedVersion;
  }
}

/**
 * SyncedVarStore - Manages a collection of SyncedVars with flattened keys.
 *
 * Supports dotted path keys (e.g., "params.name") that map to nested state.
 * Each leaf path gets its own SyncedVar for independent pending tracking.
 */
export class SyncedVarStore {
  constructor() {
    this.vars = {};  // path -> SyncedVar
  }

  /**
   * Get or create a SyncedVar for a path.
   * @param path - Dotted path like "count" or "params.name"
   * @param initialValue - Initial value if creating new
   * @param onChange - Change callback if creating new
   */
  get(path, initialValue = undefined, onChange = null) {
    if (!this.vars[path]) {
      this.vars[path] = new SyncedVar(initialValue, onChange);
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
    return Object.values(this.vars).some(v => v.isPending);
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
   * e.g., {"params.name": "Alice", "params.age": "25"} -> {params: {name: "Alice", age: "25"}}
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
   * @param serverState - Nested state object from server
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
   * Get value at a path (from SyncedVar if exists, otherwise undefined).
   */
  getValue(path) {
    return this.vars[path]?.value;
  }
}

/**
 * Set a value in a nested object using a dotted path.
 * Creates intermediate objects as needed.
 */
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

/**
 * Flatten a nested state object to dotted path keys.
 * e.g., {params: {name: "Alice"}} -> {"params.name": "Alice"}
 */
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

// Expose globally for other hooks
window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.SyncedVarStore = SyncedVarStore;

export default SyncedVar;
