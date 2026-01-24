/**
 * Lavash - Optimistic UI primitives for Phoenix LiveView
 *
 * This module exports the core JavaScript classes needed for Lavash:
 *
 * - SyncedVar: Optimistic state synchronization with version tracking and animation support
 * - SyncedVarStore: Collection of SyncedVars with dependency tracking
 * - OverlayAnimator: Unified animation delegate for modals and flyovers
 * - LavashOptimistic: Main Phoenix LiveView hook
 *
 * Usage in your app.js:
 *
 *   import { LavashOptimistic, SyncedVar, OverlayAnimator } from "lavash";
 *
 *   // Register on window for colocated hooks
 *   window.Lavash = window.Lavash || {};
 *   window.Lavash.SyncedVar = SyncedVar;
 *   window.Lavash.OverlayAnimator = OverlayAnimator;
 *
 *   // Add to LiveSocket hooks
 *   const liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { LavashOptimistic, ...otherHooks }
 *   });
 */

export { SyncedVar, SyncedVarStore } from "./synced_var.js";
export { OverlayAnimator } from "./overlay_animator.js";
export { LavashOptimistic } from "./lavash_optimistic.js";

// Backward compatibility aliases
export { OverlayAnimator as ModalAnimator } from "./overlay_animator.js";
export { OverlayAnimator as FlyoverAnimator } from "./overlay_animator.js";
