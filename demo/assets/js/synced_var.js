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
 * Path-based access (for nested maps):
 *   const params = new SyncedVar({}, onChange);
 *   params.setAtPath("name", "Alice");           // Sets params.name = "Alice"
 *   params.getAtPath("name");                    // Returns "Alice"
 *   params.setAtPath("address.city", "Boston");  // Sets params.address.city = "Boston"
 */
export class SyncedVar {
  constructor(initialValue, onChange) {
    this.value = initialValue;           // optimistic client value
    this.confirmedValue = initialValue;  // last server-confirmed value
    this.version = 0;
    this.confirmedVersion = 0;
    this.onChange = onChange;            // callback: (newValue, oldValue, source) => void
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

  /**
   * Get a value at a dotted path within the value (for nested maps).
   * @param path - Dotted path like "name" or "address.city"
   * @returns The value at the path, or undefined if not found
   */
  getAtPath(path) {
    if (!path) return this.value;
    const parts = path.split(".");
    let current = this.value;
    for (const part of parts) {
      if (current == null || typeof current !== "object") return undefined;
      current = current[part];
    }
    return current;
  }

  /**
   * Optimistically set a value at a dotted path within the value (for nested maps).
   * Creates intermediate objects as needed.
   * @param path - Dotted path like "name" or "address.city"
   * @param newValue - The value to set at the path
   * @returns true if the value changed, false otherwise
   */
  setAtPath(path, newValue) {
    if (!path) {
      return this.setOptimistic(newValue);
    }

    const oldRootValue = this.value;
    const parts = path.split(".");

    // Deep clone the current value to avoid mutation
    const newRootValue = typeof oldRootValue === "object" && oldRootValue !== null
      ? { ...oldRootValue }
      : {};

    // Navigate to parent, creating intermediate objects as needed
    let current = newRootValue;
    for (let i = 0; i < parts.length - 1; i++) {
      const part = parts[i];
      if (current[part] == null || typeof current[part] !== "object") {
        current[part] = {};
      } else {
        // Clone to avoid mutating the original
        current[part] = { ...current[part] };
      }
      current = current[part];
    }

    // Set the final value
    const lastPart = parts[parts.length - 1];
    const oldValue = current[lastPart];
    if (newValue === oldValue) return false;

    current[lastPart] = newValue;

    // Update version and value
    this.version++;
    this.value = newRootValue;
    this.onChange?.(newRootValue, oldRootValue, "optimistic");
    return true;
  }

  /**
   * Check if a specific path has a pending value different from confirmed.
   * Useful for deciding whether to accept server updates for nested fields.
   * @param path - Dotted path to check
   * @returns true if the path has pending changes
   */
  isPathPending(path) {
    if (!this.isPending) return false;
    const currentVal = this.getAtPath(path);
    const confirmedVal = this.getConfirmedAtPath(path);
    return currentVal !== confirmedVal;
  }

  /**
   * Get the confirmed (server-acknowledged) value at a dotted path.
   * @param path - Dotted path
   * @returns The confirmed value at the path
   */
  getConfirmedAtPath(path) {
    if (!path) return this.confirmedValue;
    const parts = path.split(".");
    let current = this.confirmedValue;
    for (const part of parts) {
      if (current == null || typeof current !== "object") return undefined;
      current = current[part];
    }
    return current;
  }
}

// Expose globally for other hooks
window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;

export default SyncedVar;
