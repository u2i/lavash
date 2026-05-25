/**
 * Lavash pipeline runner.
 *
 * The `lavash()` factory returns a decorator that wraps any user hook
 * with the lavash optimistic-state machinery. The decorator runs a
 * pipeline of named stages against a list of registered concerns.
 *
 * See PIPELINE.md for the full architecture: stages, ctx schema,
 * concern interface, merge visitor protocol.
 *
 * ## Usage
 *
 *     import { lavash } from "lavash/pipeline";
 *     import { decorate } from "lavash/decorators";
 *     import { forms, overlays, bindings, optimisticActions }
 *       from "lavash/concerns";
 *
 *     const lavashDecorator = lavash({
 *       concerns: [optimisticActions, bindings, forms, overlays]
 *     });
 *
 *     const decoratedHooks = decorate(myHooks, [lavashDecorator]);
 *
 * ## Order
 *
 *   - `mounted` stage: concerns run in array order
 *   - `destroyed` stage: concerns run in reverse array order
 *   - `updated` cycle stages: concerns run in array order at each stage
 *   - `beforeUpdate`: concerns run in array order
 *
 * ## How user hook integrates
 *
 * The decorator wraps the user's lifecycle methods. The user's
 * `mounted`/`updated`/`destroyed`/`beforeUpdate` run AFTER lavash's
 * pipeline at each phase. Wrapping (not replacing) means the user's
 * hook keeps doing whatever it does.
 */

import { coreInit, coreCaptureBeforeUpdate, coreUpdated } from "./pipeline_core.js";

/**
 * Build a lavash decorator from a list of concerns.
 *
 * @param {object} opts
 * @param {object[]} opts.concerns - List of concern objects (see PIPELINE.md)
 * @returns {(hook: object) => object} Decorator function
 */
export function lavash({ concerns = [] } = {}) {
  return (hook) => ({
    ...hook,

    mounted() {
      // Core init first (state, store, version, fns) — sets up the
      // substrate everything else reads from.
      coreInit(this);

      // Each concern's mount-time setup runs in array order.
      for (const concern of concerns) {
        if (concern.mounted) concern.mounted(this, null);
      }

      // Stash the concerns list on the hook so update/destroyed can
      // access it without closing over the original array (avoids
      // surprises if app.js shares concern arrays across decorators).
      this._lavashConcerns = concerns;

      // Finally call the wrapped hook's own mounted if any.
      hook.mounted?.call(this);
    },

    beforeUpdate() {
      coreCaptureBeforeUpdate(this);

      for (const concern of this._lavashConcerns || []) {
        if (concern.beforeUpdate) concern.beforeUpdate(this, null);
      }

      hook.beforeUpdate?.call(this);
    },

    updated() {
      // The core update cycle handles all internal stages and walks
      // the registered concerns at the appropriate stage points.
      coreUpdated(this, this._lavashConcerns || []);

      hook.updated?.call(this);
    },

    destroyed() {
      // Concerns tear down in REVERSE order — mirror of mounted.
      // This way, if concern A was mounted "on top of" concern B,
      // A tears down first and B's invariants still hold while A
      // is cleaning up.
      const concerns = this._lavashConcerns || [];
      for (let i = concerns.length - 1; i >= 0; i--) {
        const concern = concerns[i];
        if (concern.destroyed) concern.destroyed(this, null);
      }

      this._lavashConcerns = null;

      hook.destroyed?.call(this);
    }
  });
}

/**
 * Run a named stage against a list of concerns. Each concern that has
 * a handler for `stageName` is invoked with `(hook, ctx)`.
 *
 * Exposed for `pipeline_core.js` to drive the update-cycle stages.
 */
export function runStage(stageName, concerns, hook, ctx) {
  for (const concern of concerns) {
    const handler = concern[stageName];
    if (handler) handler(hook, ctx);
  }
}
