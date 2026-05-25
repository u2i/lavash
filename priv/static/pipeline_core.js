/**
 * Pipeline core — internal stages of the lavash update cycle.
 *
 * The pipeline runner in `pipeline.js` wraps lifecycle methods on user
 * hooks. The HEAVY lifting — core init at mount, the per-cycle ctx
 * construction, the merge walker, version reconciliation — lives here.
 *
 * Concerns plug in via named stages (see PIPELINE.md). Core stages run
 * around concern stages in a fixed order:
 *
 *     mounted:    coreInit → concerns.mounted
 *     beforeUpd:  coreCaptureBeforeUpdate → concerns.beforeUpdate
 *     updated:    coreUpdated drives the full cycle, invoking concerns
 *                  at observeBeforeMerge / notifyAfterMerge /
 *                  afterRecompute / afterRender
 *     destroyed:  concerns.destroyed (reverse order) → core has nothing
 */

import { SyncedVarStore } from "./synced_var.js";
import { syncStateToUrl } from "./url_sync.js";
import { recomputeGraph } from "./graph.js";
import {
  setStateAtPath,
  getStateAtPath
} from "./concerns/utils.js";
import { installGlobalDomCallback } from "./concerns/global_dom_callback.js";
import { updateDOM, notifyChildren } from "./concerns/dom_updater.js";
import { loadGeneratedFunctions } from "./concerns/function_loader.js";
import { captureBeforeUpdate } from "./concerns/overlay_manager.js";
import { runStage } from "./pipeline.js";
import { runMergeWalker } from "./merge_walker.js";

/**
 * Core init at mount: parse dataset, create SyncedVarStore, version
 * tracking, load generated fns, attach hook-level methods.
 *
 * Runs BEFORE any concern's `mounted` so concerns can rely on the
 * substrate being ready.
 */
export function coreInit(hook) {
  // ----- State -----
  hook.state = JSON.parse(hook.el.dataset.lavashState || "{}");

  // SyncedVarStore for path-keyed pending/confirmed tracking.
  hook.store = new SyncedVarStore();

  // Version tracking for stale-patch rejection.
  hook.serverVersion = parseInt(hook.el.dataset.lavashVersion || "0", 10);
  hook.clientVersion = hook.serverVersion;

  // Module identity + URL fields config.
  hook.moduleName = hook.el.dataset.lavashModule || null;
  hook.urlFields = JSON.parse(hook.el.dataset.lavashUrlFields || "[]");

  // ----- Generated functions -----
  // Load the per-module optimistic functions (delta computers + the
  // dependency graph) from the inline JSON script tag.
  loadGeneratedFns(hook);

  // ----- Hook-level utility methods that concerns + external code use -----
  attachHookMethods(hook);

  // Expose for `onBeforeElUpdated` DOM preservation callback.
  hook.el.__lavash_hook__ = hook;

  // Is this a component-shaped hook (vs a top-level LV)?
  hook.isComponent = hook.el.hasAttribute("data-lavash-component");

  // Install the (global, once-per-page) onBeforeElUpdated callback.
  installGlobalDomCallback(hook.liveSocket);
}

function loadGeneratedFns(hook) {
  const result = loadGeneratedFunctions(hook.moduleName, hook.el);
  hook.fns = result.fns;
  hook.deriveNames = result.deriveNames;
  hook.graph = result.graph;

  // Merge custom-registered functions (overrides from window.Lavash.optimistic).
  const customFns = hook.moduleName
    ? (window.Lavash?.optimistic?.[hook.moduleName] || {})
    : {};
  hook.fns = { ...hook.fns, ...customFns };

  // Fallback derive-name inference if none declared.
  if (!hook.deriveNames || hook.deriveNames.length === 0) {
    hook.deriveNames = Object.keys(hook.fns).filter(k =>
      k.endsWith("_chips") || k.endsWith("_chip") || k === "doubled" || k === "fact"
    );
  }
}

function attachHookMethods(hook) {
  // These are called from concerns AND from external code (other
  // hooks reaching into this one, inline component scripts). They
  // need to live on the hook object as methods.

  hook.recomputeDerives = function(changedFields = null) {
    recomputeGraph(this.graph, this.fns, this.state, changedFields);
  };

  hook.setStateAtPath = function(path, value) {
    setStateAtPath(this.state, path, value);
  };

  hook.getStateAtPath = function(path) {
    return getStateAtPath(this.state, path);
  };

  hook.syncUrl = function() {
    syncStateToUrl(this.urlFields, this.state);
  };

  hook.getPendingCount = function() {
    return this.store ? this.store.getPendingPaths().length : 0;
  };

  hook.notifyChildren = function() {
    notifyChildren(this.el, this);
  };

  hook.hasPendingSources = function(field) {
    const deps = this.graph.deps[field];
    if (!deps) return false;
    const pendingPaths = this.store.getPendingPaths();
    for (const dep of deps) {
      if (pendingPaths.some(p => p === dep || p.startsWith(dep + "."))) return true;
      if (this.hasPendingSources(dep)) return true;
    }
    return false;
  };

  // updateDOM needs the forms helpers — concerns expose them by
  // attaching to the hook in their `mounted`. If forms isn't loaded,
  // we fall back to passing-through callbacks that do nothing form-y.
  hook.updateDOM = function(isOptimistic = false) {
    updateDOM(this.el, this.state, {
      getFormField: this._lavashFormsGetField || (() => undefined),
      isFormSubmitted: this._lavashFormsIsSubmitted || (() => false),
      isOptimistic
    });
    this.notifyChildren();
  };
}

/**
 * beforeUpdate core: capture FLIP positions for animated overlays.
 *
 * Lives in core (not in overlays) because the overlay_manager helper
 * is parameterised by `animatedStates` which is OWNED by overlays but
 * stored on the hook. Calling it here keeps the lifecycle wrapping
 * uniform; if overlays isn't loaded, `hook.animatedStates` is
 * undefined and `captureBeforeUpdate` is a no-op.
 */
export function coreCaptureBeforeUpdate(hook) {
  if (hook.animatedStates) {
    captureBeforeUpdate(hook.animatedStates, hook.store);
  }
}

/**
 * Run the full update cycle.
 *
 * Stages (see PIPELINE.md):
 *   1. observeBeforeMerge  — concerns
 *   2. capturePendingPaths — core
 *   3. applyStoreUpdate    — core
 *   4. mergePayload        — core (visitor-based walker)
 *   5. reconcileSyncedVars — core
 *   6. versionBookkeeping  — core
 *   7. notifyAfterMerge    — concerns
 *   8. afterRecompute      — concerns (after hook.recomputeDerives)
 *   9. afterRender         — concerns (after hook.updateDOM)
 */
export function coreUpdated(hook, concerns) {
  // ----- Build per-cycle ctx -----
  const ctx = {
    serverState: JSON.parse(hook.el.dataset.lavashState || "{}"),
    newServerVersion: parseInt(hook.el.dataset.lavashVersion || "0", 10),
    module: hook.el.dataset.lavashModule || "?",
    concerns,
    // Populated by stages below:
    asyncFieldsReady: [],
    isModalOpening: false,
    animatedPhaseFields: new Set(),
    pendingPaths: new Set(),
    changedFields: [],
    clearedParamsFields: new Set()
  };

  // ----- 1. observeBeforeMerge (concerns) -----
  runStage("observeBeforeMerge", concerns, hook, ctx);

  // ----- 2. capturePendingPaths (core) -----
  ctx.pendingPaths = new Set(hook.store.getPendingPaths());

  // ----- 3. applyStoreUpdate (core) -----
  hook.store.serverUpdate(ctx.serverState);

  // ----- 4. mergePayload (core walker w/ concern visitors) -----
  // The walker mutates ctx.changedFields and ctx.clearedParamsFields,
  // and consults visitors registered by concerns (via concern.mergeVisitors).
  // It also mutates hook.state (via setStateAtPath) and hook.fieldState
  // (via the forms visitor, indirectly).
  hook._clearedParamsFields = ctx.clearedParamsFields;
  runMergeWalker(hook, ctx);
  hook._clearedParamsFields = null;

  // ----- 5. reconcileSyncedVars (core) -----
  // SyncedVars may have rejected the server value (keeping the
  // optimistic). mergeServerState would have accepted it. The store
  // is the source of truth; force state to match.
  for (const [path, sv] of Object.entries(hook.store.vars)) {
    const cur = hook.getStateAtPath(path);
    if (cur !== undefined && cur !== sv.value) {
      hook.setStateAtPath(path, sv.value);
    }
  }

  // ----- 6. versionBookkeeping (core) -----
  if (ctx.newServerVersion >= hook.clientVersion) {
    hook.serverVersion = ctx.newServerVersion;
    hook.clientVersion = ctx.newServerVersion;
  } else {
    hook.serverVersion = ctx.newServerVersion;
  }

  // ----- 7. notifyAfterMerge (concerns) -----
  runStage("notifyAfterMerge", concerns, hook, ctx);

  // ----- 8. afterRecompute (concerns) — after the recompute -----
  hook.recomputeDerives();
  runStage("afterRecompute", concerns, hook, ctx);

  // ----- 9. afterRender (concerns) — after updateDOM -----
  // Forms uses this to restore pending input values that updateDOM may
  // have overwritten (the SyncedVar still holds the user's typed value).
  hook.updateDOM();
  runStage("afterRender", concerns, hook, ctx);
}
