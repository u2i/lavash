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
}

// Expose globally for other hooks
window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;

export default SyncedVar;
