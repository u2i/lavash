/**
 * Overlay animation management.
 *
 * Handles animated state fields (modals/flyovers): initialization,
 * OverlayAnimator delegates, open/close event listeners, phase field
 * management, async data detection, and FLIP animation capture.
 */

import {
  overlayOpened,
  overlayVisible,
  overlayClosed,
  overlayDestroyed
} from "./overlay_a11y.js";

/**
 * Initialize animated fields from metadata.
 * Sets up SyncedVars, OverlayAnimator delegates, and event listeners.
 *
 * @param {Object} hook - The LavashOptimistic hook instance
 * @returns {{ animatedStates: Object, modalEventListeners: Array }}
 */
export function initAnimatedFields(hook) {
  const animatedStates = {};
  const modalEventListeners = [];

  let animatedConfigs = hook.fns.__animated__ || [];
  if (animatedConfigs.length === 0 && hook.el.dataset.lavashAnimated) {
    try {
      animatedConfigs = JSON.parse(hook.el.dataset.lavashAnimated);
    } catch (e) {
      console.warn("[LavashOptimistic] Failed to parse data-lavash-animated:", e);
    }
  }

  for (const config of animatedConfigs) {
    const field = config.field;

    // Filled in below once the chrome element is located; the phase
    // callback closes over it for a11y stack/focus management.
    const a11y = { chromeEl: null, panelEl: null };

    // Register animated config on store
    hook.store.registerAnimated(field, {
      animated: { duration: config.duration || 200, async: config.async || null },
      onPhaseChange: (phase) => {
        if (hook.state) {
          hook.state[config.phaseField] = phase;
          hook.recomputeDerives?.([config.phaseField]);
          hook.updateDOM?.();
        }
        // Surface the current phase on the hook root so tests (and CSS
        // selectors) can observe transitions directly. `data-modal-phase`
        // matches the server-rendered attribute name (see
        // Lavash.Overlay.Modal.RenderGenerator), so it transitions
        // server→client→client as the phase machine drives it.
        if (config.type === "modal" || config.type === "flyover") {
          hook.el.setAttribute(`data-${config.type}-phase`, phase);

          // A11y stack: push + focus on leaving idle, re-anchor focus
          // once visible (async content may have replaced the loading
          // nodes), pop + restore on return to idle.
          if (a11y.chromeEl && a11y.panelEl) {
            if (phase === "entering" || phase === "loading") {
              overlayOpened(a11y.chromeEl, a11y.panelEl);
            } else if (phase === "visible") {
              overlayVisible(a11y.chromeEl, a11y.panelEl);
            } else if (phase === "idle") {
              overlayClosed(a11y.chromeEl);
            }
          }
        }
      },
    });

    // Create delegate based on overlay type
    let delegate = null;
    let chromeEl = null;

    if (config.type === "modal" || config.type === "flyover") {
      const OverlayAnimator = window.Lavash?.OverlayAnimator;
      if (OverlayAnimator) {
        const wrapperId = hook.el.id;
        const componentId = wrapperId.replace(/^lavash-/, "");
        const chromeId = `${componentId}-${config.type}`;
        chromeEl = document.getElementById(chromeId);

        if (chromeEl) {
          a11y.chromeEl = chromeEl;
          a11y.panelEl = document.getElementById(`${chromeId}-panel_content`);

          const overlayOpts = {
            type: config.type,
            duration: config.duration || 200,
            openField: config.field,
            js: hook.js()
          };
          if (config.type === "flyover") {
            overlayOpts.slideFrom = chromeEl.dataset.slideFrom || 'right';
          }
          delegate = new OverlayAnimator(chromeEl, overlayOpts);

          const mainContentId = `${chromeId}-main_content`;
          const mainContentInnerId = `${chromeId}-main_content_inner`;
          registerModalContentIds(mainContentId, mainContentInnerId, field, hook);
        }
      }
    }

    animatedStates[field] = { config, delegate };

    // Eagerly create the SyncedVar so the delegate gets attached
    const currentValue = hook.state[field] ?? null;
    const syncedVar = hook.store.get(field, null, {
      onChange: (newVal) => { hook.state[field] = newVal; },
    });
    if (delegate) syncedVar.setDelegate(delegate);
    if (currentValue != null) {
      // A non-null value at mount is server-rendered truth: seed it as
      // confirmed (no pending window) and skip the enter animation
      // (issue #30). If the overlay's async data is already loaded,
      // seed lands in visible rather than loading.
      if (config.async) {
        const asyncAction = hook.state[`${config.async}_action`];
        if (asyncAction && asyncAction !== "loading") syncedVar.isAsyncReady = true;
      }
      syncedVar.seed(currentValue);
    }

    // Set up open/close event listeners on chrome element
    if (chromeEl) {
      const setterAction = `set_${field}`;

      const openHandler = (e) => {
        const openValue = e.detail?.[field] ?? e.detail?.open ?? e.detail?.value ?? true;
        const sv = hook.store.get(field);
        sv.set(openValue, (p, cb) => {
          hook.pushEventTo(chromeEl, setterAction, { ...p, value: openValue }, cb);
        });
      };

      // Canonical close path (issue #26): every close affordance dispatches
      // close-panel, and this handler pushes the :close *action* — versioned
      // through SyncedVar — rather than the raw setter, so user sets merged
      // into :close run on backdrop/Escape/close-button closes too.
      const closeHandler = () => {
        const sv = hook.store.get(field);
        sv.set(null, (p, cb) => {
          hook.pushEventTo(chromeEl, "close", { ...p }, cb);
        });
        hook.propagateBoundFieldsToParent([field]);
      };

      chromeEl.addEventListener("open-panel", openHandler);
      chromeEl.addEventListener("close-panel", closeHandler);
      modalEventListeners.push({ el: chromeEl, open: openHandler, close: closeHandler });
    }
  }

  return { animatedStates, modalEventListeners };
}

/**
 * Register overlay content element IDs for ghost detection in onBeforeElUpdated.
 */
function registerModalContentIds(contentId, innerId, field, hook) {
  window.__lavashModalContentRegistry = window.__lavashModalContentRegistry || {};
  window.__lavashModalContentRegistry[contentId] = {
    hook: hook,
    field: field,
    innerId: innerId
  };
}

/**
 * Capture pre-update state for FLIP animations.
 */
export function captureBeforeUpdate(animatedStates, store) {
  if (!animatedStates) return;
  for (const [field, anim] of Object.entries(animatedStates)) {
    const phase = store.get(field).getPhase();
    if (phase === "visible" || phase === "entering" || phase === "loading") {
      anim.delegate?.capturePreUpdateRect?.(phase);
    }
  }
}

/**
 * Notify animated states that async data is ready.
 */
export function notifyAsyncReady(animatedStates, store, asyncField) {
  if (!animatedStates) return;
  for (const [field, anim] of Object.entries(animatedStates)) {
    if (anim.config.async === asyncField) {
      store.get(field).onAsyncDataReady();
    }
  }
}

/**
 * Notify animated state delegates of a LiveView update (post-update FLIP).
 */
export function notifyDelegatesUpdated(animatedStates, store) {
  if (!animatedStates) return;
  for (const [field, anim] of Object.entries(animatedStates)) {
    if (anim.delegate?.onUpdated) {
      const sv = store.get(field);
      anim.delegate.onUpdated(sv, sv.getPhase());
    }
  }
}

/**
 * Detect which async fields went from null/loading to having data.
 */
export function detectAsyncFieldsReady(animatedStates, state, serverState) {
  const ready = [];
  if (!animatedStates) return ready;

  for (const anim of Object.values(animatedStates)) {
    const asyncField = anim.config.async;
    if (asyncField) {
      const actionField = `${asyncField}_action`;
      const oldAction = state[actionField];
      const newAction = serverState[actionField];
      if ((!oldAction || oldAction === "loading") && newAction && newAction !== "loading") {
        ready.push(asyncField);
      }
    }
  }
  return ready;
}

/**
 * Clean up overlay resources on destroy.
 */
export function destroyOverlays(animatedStates, modalEventListeners, store) {
  if (modalEventListeners) {
    for (const { el, open, close } of modalEventListeners) {
      el.removeEventListener("open-panel", open);
      el.removeEventListener("close-panel", close);
      overlayDestroyed(el);
    }
  }

  if (window.__lavashModalContentRegistry) {
    // Can't easily filter by hook here — caller should handle
  }

  if (animatedStates) {
    for (const field of Object.keys(animatedStates)) {
      store.get(field).destroy();
    }
  }
}
