/**
 * Lavash - Optimistic UI primitives for Phoenix LiveView
 *
 * Public exports:
 *
 *   - `lavash(opts)`        — decorator factory (returns a hook decorator)
 *   - `defaultConcerns`     — the standard concern bundle
 *   - `getState`, `getHooks` — wiring helpers for LiveSocket
 *   - Individual concerns:  `optimisticActions`, `bindings`, `forms`, `overlays`
 *   - Primitives:           `SyncedVar`, `OverlayAnimator`
 *
 * Usage in your app.js:
 *
 *     import { lavash, defaultConcerns, getHooks, getState } from "lavash";
 *
 *     const decorator = lavash({ concerns: defaultConcerns });
 *
 *     const liveSocket = new LiveSocket("/live", Socket, {
 *       hooks: getHooks(decorator, MyAppHooks),
 *       params: () => ({ _csrf_token: csrfToken, _lavash_state: getState() })
 *     });
 */

export {
  lavash,
  defaultConcerns,
  optimisticActions,
  bindings,
  forms,
  overlays,
  getState,
  getHooks,
  SyncedVar,
  OverlayAnimator
} from "./lavash.js";

export { SyncedVar as SyncedVarClass, SyncedVarStore } from "./synced_var.js";
export { ReactiveStore } from "./reactive_store.js";

// Backward-compat aliases
export { OverlayAnimator as ModalAnimator } from "./overlay_animator.js";
export { OverlayAnimator as FlyoverAnimator } from "./overlay_animator.js";
