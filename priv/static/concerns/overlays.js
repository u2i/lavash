/**
 * Overlays concern — orchestration shim around overlay_manager.js
 * primitives for the LavashOptimistic hook.
 *
 * This module owns the lavash-overlay (modal/flyover) lifecycle
 * within the hook: animated-field initialisation at mount, FLIP
 * capture before each update, async-readiness + modal-opening
 * detection used by mergeServerState, post-update delegate
 * notifications, and cleanup at destroy.
 *
 * ## Why building blocks instead of `overlays.updated(hook)`
 *
 * The main hook's `updated()` interleaves overlay work with
 * non-overlay work in a specific order (pending-paths capture,
 * store.serverUpdate, mergeServerState, version tracking,
 * recompute, DOM restoration). The overlay-related pieces sit
 * at known points in that flow:
 *
 *   1. detectAsyncFieldsReady — BEFORE store.serverUpdate (the
 *      store update mutates the values we compare against to
 *      detect "became ready this cycle").
 *   2. detectModalOpening — BEFORE store.serverUpdate (we look
 *      at SyncedVar phase, which serverUpdate may transition).
 *   3. notifyAsyncReadyForFields — AFTER store.serverUpdate +
 *      mergeServerState (the SyncedVars must already hold the
 *      new value when we notify).
 *   4. notifyDelegatesUpdated — AFTER recomputeDerives, so
 *      delegates see the post-recompute DOM.
 *
 * Bundling these into a single `overlays.updated(hook)` would
 * either require returning a "capture context" + a separate
 * "apply" call, or threading non-overlay state through this
 * module. Both leak the orchestration. Easier: the hook keeps
 * orchestration; overlays exports four narrow building blocks.
 */

import {
  initAnimatedFields as _initAnimatedFields,
  captureBeforeUpdate,
  notifyAsyncReady as _notifyAsyncReady,
  notifyDelegatesUpdated as _notifyDelegatesUpdated,
  detectAsyncFieldsReady as _detectAsyncFieldsReady,
  destroyOverlays
} from "./overlay_manager.js";

/**
 * Initialise animated-state managers for any `data-lavash-animated`
 * config on the hook root. Wires SyncedVar delegates, registers the
 * phase-change callback that surfaces `data-modal-phase` /
 * `data-flyover-phase` to DOM, sets up the modal-content registry
 * for FLIP animations.
 *
 * Writes to: `hook.animatedStates`, `hook._modalEventListeners`.
 */
export function mounted(hook) {
  const result = _initAnimatedFields(hook);
  hook.animatedStates = result.animatedStates;
  hook._modalEventListeners = result.modalEventListeners;
}

/**
 * Capture DOM positions for FLIP animation BEFORE LiveView patches
 * the DOM. Called from the hook's `beforeUpdate()` lifecycle.
 *
 * Reads: `hook.animatedStates`, `hook.store`.
 */
export function beforeUpdate(hook) {
  captureBeforeUpdate(hook.animatedStates, hook.store);
}

/**
 * Detect which async fields just transitioned to a ready state in
 * the incoming `serverState`. Must be called BEFORE
 * `hook.store.serverUpdate(serverState)` — the store update will
 * mutate the SyncedVar values that this comparison reads from.
 *
 * Returns an array of field names.
 */
export function detectAsyncFieldsReady(hook, serverState) {
  return _detectAsyncFieldsReady(hook.animatedStates, hook.state, serverState);
}

/**
 * Detect whether any animated field's SyncedVar is in an opening
 * phase (entering or loading). Used by mergeServerState to decide
 * whether to clear pending `_params` on a modal-open cycle.
 *
 * Phase-based detection (not value-based) because by the time
 * `updated()` runs, `refreshFromParent` may have already set the
 * value optimistically — so old/new comparison wouldn't reflect
 * "this cycle opened the modal." The phase machine has the right
 * answer.
 */
export function detectModalOpening(hook) {
  if (!hook.animatedStates) return false;

  for (const field of Object.keys(hook.animatedStates)) {
    const syncedVar = hook.store.get(field);
    const phase = syncedVar.getPhase();
    if (phase === "entering" || phase === "loading") return true;
  }

  return false;
}

/**
 * Notify the animated states that the named fields' async data has
 * become ready. Called AFTER `store.serverUpdate` so the SyncedVars
 * hold the post-update values when their delegates run.
 */
export function notifyAsyncReadyForFields(hook, asyncFieldsReady) {
  for (const asyncField of asyncFieldsReady) {
    _notifyAsyncReady(hook.animatedStates, hook.store, asyncField);
  }
}

/**
 * Let animated-state delegates run post-update logic (FLIP-animation
 * commits, etc.). Called AFTER recomputeDerives so delegates see the
 * post-recompute DOM.
 */
export function notifyDelegatesUpdated(hook) {
  _notifyDelegatesUpdated(hook.animatedStates, hook.store);
}

/**
 * Cleanup at hook destroy: tear down overlay delegates, remove modal
 * event listeners, prune the modal-content registry for this hook.
 *
 * The empty-object assignment to `hook.animatedStates` matches the
 * original main-hook destroyed code — leaves the field truthy-but-
 * empty so `isAnyAnimating()` and similar return safely if called
 * during teardown.
 */
export function destroyed(hook) {
  destroyOverlays(hook.animatedStates, hook._modalEventListeners, hook.store);
  hook._modalEventListeners = [];

  // Clean up modal content registry entries for this hook
  if (window.__lavashModalContentRegistry) {
    for (const [contentId, entry] of Object.entries(window.__lavashModalContentRegistry)) {
      if (entry.hook === hook) {
        delete window.__lavashModalContentRegistry[contentId];
      }
    }
  }

  hook.animatedStates = {};
}
