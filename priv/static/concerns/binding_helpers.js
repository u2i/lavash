/**
 * Parent-child binding logic.
 *
 * Handles bidirectional state sync between parent and child hooks
 * via the bindings map (local field -> parent field).
 */
import { deepEqual } from "../synced_var.js";

/**
 * Refresh local state from a parent hook's state via bindings.
 * Called by parent's notifyChildren when parent state changes.
 *
 * @param {Object} bindings - Map of localField -> parentField
 * @param {Object} state - This hook's state object (mutated in place)
 * @param {Object} store - SyncedVarStore instance
 * @param {Object} parentHook - Parent hook instance
 * @returns {string[]} Array of changed local field names
 */
export function refreshFromParent(bindings, state, store, parentHook) {
  if (!bindings || Object.keys(bindings).length === 0) return [];

  const changedFields = [];

  for (const [localField, parentField] of Object.entries(bindings)) {
    const parentValue = parentHook.state[parentField];
    // Skip if parent doesn't have this field — avoid clobbering local state
    if (parentValue === undefined) continue;
    const localValue = state[localField];

    // deepEqual, not !== : array/object values from the parent are fresh
    // references every render — identity comparison would re-mark them
    // changed on every parent updateDOM cycle.
    if (!deepEqual(parentValue, localValue)) {
      state[localField] = parentValue;
      changedFields.push(localField);

      const syncedVar = store.get(localField, null, (newVal) => {
        state[localField] = newVal;
      });
      if (syncedVar.animated) {
        // Animated vars must go through the phase machine (seed would
        // snap an overlay open with no enter animation). Their pending
        // state resolves normally: an open/close change always re-renders
        // the child, and that patch's serverSet confirms the match.
        syncedVar.setOptimistic(parentValue);
      } else {
        // seed, not setOptimistic: this mirrors the OWNER's value into
        // the bound child — it is not a client prediction, no confirming
        // push will ever come, so marking it pending would leave the var
        // (and the data-lavash-syncing indicator, issue #72) unresolved
        // forever.
        syncedVar.seed(parentValue);
      }
    }
  }

  return changedFields;
}

/**
 * Propagate bound field changes to the parent hook via lavash-set events.
 *
 * @param {Object} bindings - Map of localField -> parentField
 * @param {Object} state - This hook's state object
 * @param {HTMLElement} el - This hook's root element (event dispatch target)
 * @param {string[]} changedFields - Fields that changed
 */
export function propagateBoundFieldsToParent(bindings, state, el, changedFields, opts = {}) {
  if (!bindings || Object.keys(bindings).length === 0) return;
  if (!changedFields || changedFields.length === 0) return;

  for (const localField of changedFields) {
    const parentField = bindings[localField];
    if (parentField) {
      const value = state[localField];
      const event = new CustomEvent("lavash-set", {
        bubbles: true,
        detail: {
          field: parentField,
          value,
          // When true, the server already has an event for this change
          // (from the component's own action), so the parent should only
          // update client-side state — not push a set_ event to the server.
          serverHandled: opts.serverHandled || false
        }
      });
      el.dispatchEvent(event);
    }
  }
}
