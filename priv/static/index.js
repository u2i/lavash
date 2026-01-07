/**
 * Lavash - Optimistic UI primitives for Phoenix LiveView
 *
 * This module exports the core JavaScript classes needed for Lavash:
 *
 * - SyncedVar: Optimistic state synchronization with version tracking and animation support
 * - SyncedVarStore: Collection of SyncedVars with dependency tracking
 * - ModalAnimator: Modal-specific animation delegate (includes FLIP animation)
 * - LavashOptimistic: Main Phoenix LiveView hook
 *
 * Usage in your app.js:
 *
 *   import { LavashOptimistic, SyncedVar, ModalAnimator } from "lavash";
 *
 *   // Register on window for colocated hooks
 *   window.Lavash = window.Lavash || {};
 *   window.Lavash.SyncedVar = SyncedVar;
 *   window.Lavash.ModalAnimator = ModalAnimator;
 *
 *   // Add to LiveSocket hooks
 *   const liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { LavashOptimistic, ...otherHooks }
 *   });
 */

export { SyncedVar, SyncedVarStore } from "./synced_var.js";
export { ModalAnimator } from "./modal_animator.js";
export { LavashOptimistic } from "./lavash_optimistic.js";
