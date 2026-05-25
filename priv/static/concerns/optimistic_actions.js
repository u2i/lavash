/**
 * Optimistic actions concern — owns click interception for
 * `phx-click` actions that have a client-side optimistic
 * implementation.
 *
 * On a matching click, this module's handleClick runs the
 * client-side action function BEFORE the LiveView event delegate
 * fires, so the DOM updates immediately. The LV round-trip then
 * runs server-side and the result reconciles in the hook's
 * `updated()`.
 *
 * Lower-level click classification + state-delta application
 * lives in optimistic_action_helpers.js. This module is the
 * lifecycle orchestrator: capture-phase listener install at
 * mount, listener removal at destroy.
 */

import {
  handleClick as _handleClick,
  runOptimisticAction as _runOptimisticAction
} from "./optimistic_action_helpers.js";

/**
 * Install the capture-phase click listener.
 *
 * Capture phase (third arg `true`) so this runs BEFORE Phoenix's
 * own click delegate — the optimistic patch lands first, the
 * server-side push goes out, and the reconciliation happens later
 * in updated().
 *
 * Stashes the bound listener ref on `hook._clickListener` so
 * destroyed() can remove the same reference.
 */
export function mounted(hook) {
  hook._clickListener = (e) => _handleClick(e, hook);
  hook.el.addEventListener("click", hook._clickListener, true);
}

/**
 * Remove the click listener using the stashed bound ref.
 */
export function destroyed(hook) {
  if (hook._clickListener) {
    hook.el.removeEventListener("click", hook._clickListener, true);
    hook._clickListener = null;
  }
}

/**
 * Re-exported so the hook's `runOptimisticAction(actionName, value)`
 * delegator can call the helper. Inline component scripts call
 * `hook.runOptimisticAction(...)` so the hook must keep that
 * method.
 */
export const runOptimisticAction = _runOptimisticAction;
