/**
 * Overlays concern — owns the modal/flyover phase machine lifecycle.
 *
 * Conforms to the lavash concern interface (see PIPELINE.md):
 *
 *   - mounted: init animated state managers
 *   - destroyed: tear down delegates + modal-content registry
 *   - observeBeforeMerge: write ctx.asyncFieldsReady, ctx.isModalOpening,
 *     ctx.animatedPhaseFields BEFORE the store update mutates SyncedVars
 *   - notifyAfterMerge: notify async-ready + delegates-updated
 *   - mergeVisitors.animatedPhaseField: skip top-level phase fields
 *     (managed client-side by the SyncedVar phase machine, server always
 *     sends stale "idle")
 *
 * Lower-level helpers live in overlay_manager.js. The merge walker's
 * captureBeforeUpdate primitive is called by the pipeline's core
 * coreCaptureBeforeUpdate — it lives in core (not as an overlays
 * beforeUpdate stage) so the FLIP capture happens uniformly even when
 * overlays isn't registered (it just no-ops on null animatedStates).
 */

import {
  initAnimatedFields as _initAnimatedFields,
  notifyAsyncReady as _notifyAsyncReady,
  notifyDelegatesUpdated as _notifyDelegatesUpdated,
  detectAsyncFieldsReady as _detectAsyncFieldsReady,
  destroyOverlays
} from "./overlay_manager.js";

export const overlays = {
  name: "overlays",

  mounted(hook) {
    const result = _initAnimatedFields(hook);
    hook.animatedStates = result.animatedStates;
    hook._modalEventListeners = result.modalEventListeners;
  },

  destroyed(hook) {
    destroyOverlays(hook.animatedStates, hook._modalEventListeners, hook.store);
    hook._modalEventListeners = [];

    if (window.__lavashModalContentRegistry) {
      for (const [contentId, entry] of Object.entries(window.__lavashModalContentRegistry)) {
        if (entry.hook === hook) {
          delete window.__lavashModalContentRegistry[contentId];
        }
      }
    }

    hook.animatedStates = {};
  },

  /**
   * Pre-merge observations (writes to ctx). Runs BEFORE
   * store.serverUpdate so it can read SyncedVar values before they're
   * mutated.
   *
   *   - ctx.asyncFieldsReady: fields that just transitioned to ok
   *   - ctx.isModalOpening: any animated field in entering/loading
   *   - ctx.animatedPhaseFields: phase fields to skip in merge
   */
  observeBeforeMerge(hook, ctx) {
    if (!hook.animatedStates) return;

    ctx.asyncFieldsReady = _detectAsyncFieldsReady(
      hook.animatedStates, hook.state, ctx.serverState
    );

    for (const field of Object.keys(hook.animatedStates)) {
      const syncedVar = hook.store.get(field);
      const phase = syncedVar.getPhase();
      if (phase === "entering" || phase === "loading") {
        ctx.isModalOpening = true;
        break;
      }
    }

    for (const anim of Object.values(hook.animatedStates)) {
      if (anim.config?.phaseField) {
        ctx.animatedPhaseFields.add(anim.config.phaseField);
      }
    }
  },

  /**
   * Post-merge notifications. SyncedVars now hold the new values; let
   * delegates know which became ready (FLIP transitions, etc.).
   */
  notifyAfterMerge(hook, ctx) {
    if (!hook.animatedStates) return;

    for (const field of ctx.asyncFieldsReady) {
      _notifyAsyncReady(hook.animatedStates, hook.store, field);
    }
    _notifyDelegatesUpdated(hook, hook.animatedStates, hook.store);
  },

  mergeVisitors: {
    /**
     * Skip top-level phase fields (e.g. `:open_phase`). The server
     * always sends stale "idle" — overwriting our client phase would
     * undo the phase machine's transitions.
     */
    animatedPhaseField(hook, ctx, { key }) {
      return ctx.animatedPhaseFields.has(key);
    }
  }
};
