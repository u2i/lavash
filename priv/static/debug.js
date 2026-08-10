/**
 * Debug gate for the optimistic layer's diagnostic logging.
 *
 * Off by default. Enable from the browser console:
 *
 *     window.Lavash.debug = true
 *
 * Call sites guard with `if (debugEnabled())` so message construction
 * (JSON.stringify of state values, stack capture) is only paid when
 * the flag is on — `setOptimistic` runs on every optimistic state
 * change, and building its log line eagerly was measurable on the hot
 * path (issue #32).
 *
 * Genuine error/warning logs (delegate failures, script errors,
 * malformed metadata) stay unconditional — they indicate bugs, not
 * diagnostics.
 */
export function debugEnabled() {
  return typeof window !== "undefined" && !!(window.Lavash && window.Lavash.debug);
}
