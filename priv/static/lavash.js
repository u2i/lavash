/**
 * Lavash JS entry point.
 *
 * Provides the `lavash()` decorator factory and the concern objects.
 * Also handles the global side-effects (window.Lavash namespace,
 * lavashState for reconnect-survival via _lavash_state connect param,
 * phx:_lavash_sync event listener).
 *
 * ## Usage in your app.js
 *
 *     import { lavash, concerns, getState, getHooks } from "lavash";
 *
 *     const lavashDecorator = lavash({
 *       concerns: [
 *         concerns.optimisticActions,
 *         concerns.bindings,
 *         concerns.forms,
 *         concerns.overlays
 *       ]
 *     });
 *
 *     // Lavash emits <div phx-hook="LavashOptimistic" ...> server-side.
 *     // Register a hook by that name, decorated with the lavash pipeline.
 *     const liveSocket = new LiveSocket("/live", Socket, {
 *       hooks: { LavashOptimistic: lavashDecorator({}) },
 *       params: () => ({ _csrf_token: csrf, _lavash_state: getState() })
 *     });
 */

import { SyncedVar } from "./synced_var.js";
import { OverlayAnimator } from "./overlay_animator.js";

// ----- Global state: survives reconnects, lost on page refresh -----

const lavashState = {
  _components: {}
};

// LiveView state sync events (page-level + component-level).
window.addEventListener("phx:_lavash_sync", (e) => {
  Object.assign(lavashState, e.detail);
});

window.addEventListener("phx:_lavash_component_sync", (e) => {
  const { id, state } = e.detail;
  lavashState._components[id] = { ...lavashState._components[id], ...state };
});

// ----- Global namespace: colocated hooks + generated optimistic fns -----

window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.OverlayAnimator = OverlayAnimator;
window.Lavash.optimistic = window.Lavash.optimistic || {};

window.Lavash.registerOptimistic = function(moduleName, fns) {
  window.Lavash.optimistic[moduleName] = fns;
};

// ----- Public API -----

export { lavash } from "./pipeline.js";

export { optimisticActions } from "./concerns/optimistic_actions.js";
export { bindings } from "./concerns/bindings.js";
export { forms } from "./concerns/forms.js";
export { overlays } from "./concerns/overlays.js";

import { optimisticActions } from "./concerns/optimistic_actions.js";
import { bindings } from "./concerns/bindings.js";
import { forms } from "./concerns/forms.js";
import { overlays } from "./concerns/overlays.js";

/**
 * Bundle of all standard lavash concerns. Use as the default for
 * `lavash({ concerns: defaultConcerns })`.
 */
export const defaultConcerns = [optimisticActions, bindings, forms, overlays];

/**
 * Returns lavashState for the LiveSocket params callback.
 *
 *     new LiveSocket(..., {
 *       params: () => ({ _csrf_token: csrf, _lavash_state: getState() })
 *     });
 */
export function getState() {
  return lavashState;
}

/**
 * Decorate every hook in the dict with the lavash pipeline.
 *
 * Lavash auto-activates only on elements with `data-lavash-state`
 * (which the server runtime emits on lavash-managed elements). Hooks
 * on non-lavash elements pass through with zero overhead — the
 * decorator no-ops, the user's hook runs normally.
 *
 *     const decorator = lavash({ concerns: defaultConcerns });
 *     const liveSocket = new LiveSocket(..., {
 *       hooks: getHooks(decorator, { MyHook, OtherHook })
 *     });
 *
 * The `LavashOptimistic` name (which the server runtime emits in
 * markup) is registered automatically — that's lavash wrapping the
 * empty hook `{}`. User hooks get the same wrapping; if their
 * element is lavash-managed, they get the full machinery + their own
 * hook runs after. If not, they're untouched.
 */
export function getHooks(decorator, userHooks = {}) {
  const decorated = { LavashOptimistic: decorator({}) };
  for (const [name, hook] of Object.entries(userHooks)) {
    decorated[name] = decorator(hook);
  }
  return decorated;
}

export { SyncedVar, OverlayAnimator };
