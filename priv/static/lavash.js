/**
 * Layer-4 (optimism) entry point.
 *
 * Provides the `lavash()` decorator factory + the standard concern
 * bundle + the `window.Lavash` global namespace that colocated hooks
 * and the generated optimistic fns plug into.
 *
 * Imports `./state_sync.js` purely for its side effects (the
 * `phx:_lavash_sync` / `phx:_lavash_component_sync` listeners) so any
 * consumer that imports this entry also gets the layer-2 reconnect
 * cache wired up. A layer-2-only consumer can import state_sync
 * directly and skip the optimistic machinery entirely.
 *
 * ## Usage in your app.js
 *
 *     import { lavash, defaultConcerns, getState, getHooks } from "lavash";
 *
 *     const decorator = lavash({ concerns: defaultConcerns });
 *
 *     const liveSocket = new LiveSocket("/live", Socket, {
 *       hooks: getHooks(decorator, MyAppHooks),
 *       params: () => ({ _csrf_token: csrf, _lavash_state: getState() })
 *     });
 */

import { SyncedVar } from "./synced_var.js";
import { OverlayAnimator } from "./overlay_animator.js";

// Side-effect import: installs the layer-2 sync listeners and makes
// `getState` available. Re-exported below for convenience.
import { getState } from "./state_sync.js";

// ----- Global namespace: colocated hooks + generated optimistic fns -----

window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.OverlayAnimator = OverlayAnimator;
// Generated colocated modules self-register here at import time; a bare
// side-effect import of the manifest (`import "phoenix-colocated/my_app"`)
// is all an app needs.
window.Lavash.optimistic = window.Lavash.optimistic || {};

// Diagnostic logging is off by default; flip on from the console with
// `window.Lavash.debug = true` (see debug.js).

// The client half of the `invoke` op: run a named optimistic action on
// another component's hook (looked up by component id in the registry
// pipeline_core maintains). Generated action JS calls this so a page
// action's prediction can include a child component's prediction —
// e.g. add-to-cart bumping the cart flyover's projected badge — in
// the same tick. The server half routes via send_update as before.
window.Lavash.invokeOptimistic = function (targetId, actionName, params) {
  const hook = window.Lavash.hooks && window.Lavash.hooks[targetId];
  hook?.runOptimisticAction?.(actionName, params);
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

export { SyncedVar, OverlayAnimator, getState };
