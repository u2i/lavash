/**
 * Lavash - Declarative state management for Phoenix LiveView
 *
 * This module provides a unified entry point for initializing Lavash in your Phoenix app.
 *
 * Usage:
 *
 *     import Lavash from "lavash"
 *
 *     const liveSocket = new LiveSocket("/live", Socket, {
 *       hooks: Lavash.hooks,
 *       params: () => ({ _csrf_token: csrfToken, _lavash_state: Lavash.state })
 *     })
 *
 * This handles all the boilerplate for:
 * - Registering the LavashOptimistic hook
 * - Merging colocated hooks from your app and Lavash library
 * - Setting up the Lavash global namespace
 * - Managing Lavash state for reconnection
 */

import { SyncedVar } from "./synced_var.js";
import { LavashOptimistic } from "./lavash_optimistic.js";
import { OverlayAnimator } from "./overlay_animator.js";

// Lavash state - survives reconnects, lost on page refresh
const lavashState = {
  // Page-level state (LiveView)
  // Component state is stored under _components keyed by component ID
  _components: {}
};

// Listen for LiveView state sync events
window.addEventListener("phx:_lavash_sync", (e) => {
  Object.assign(lavashState, e.detail);
  console.debug("[Lavash] LiveView state synced:", lavashState);
});

// Listen for component state sync events
window.addEventListener("phx:_lavash_component_sync", (e) => {
  const { id, state } = e.detail;
  lavashState._components[id] = { ...lavashState._components[id], ...state };
  console.debug(`[Lavash] Component ${id} state synced:`, lavashState._components[id]);
});

// Register Lavash on window for colocated hooks and generated optimistic functions
window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.OverlayAnimator = OverlayAnimator;
window.Lavash.optimistic = window.Lavash.optimistic || {};

/**
 * Get merged hooks for LiveSocket.
 *
 * Merges Lavash core hooks with app-specific colocated hooks.
 *
 * @param {Object} appHooks - Your app's colocated hooks (optional)
 * @param {Object} lavashLibraryHooks - Lavash library colocated hooks (optional)
 * @returns {Object} Merged hooks object
 */
function getHooks(appHooks = {}, lavashLibraryHooks = {}) {
  return {
    ...lavashLibraryHooks,
    ...appHooks,
    LavashOptimistic
  };
}

/**
 * Get Lavash state for LiveSocket params.
 *
 * Returns the current Lavash state object that will be sent to the server
 * on mount and reconnect.
 *
 * @returns {Object} Current Lavash state
 */
function getState() {
  return lavashState;
}

/**
 * Register optimistic functions from your app.
 *
 * Call this after importing your app's generated optimistic functions.
 *
 * @param {Object} optimisticFns - Generated optimistic functions
 */
function registerOptimistic(optimisticFns) {
  Object.assign(window.Lavash.optimistic, optimisticFns);
}

// Default export for convenient importing
export default {
  hooks: getHooks(),
  state: lavashState,
  getHooks,
  getState,
  registerOptimistic,
  SyncedVar,
  OverlayAnimator
};

// Named exports for flexibility
export {
  LavashOptimistic,
  SyncedVar,
  OverlayAnimator,
  getHooks,
  getState,
  registerOptimistic,
  lavashState
};
