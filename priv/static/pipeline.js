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
 *     import { lavash, defaultConcerns, getHooks } from "lavash";
 *
 *     const lavashDecorator = lavash({ concerns: defaultConcerns });
 *
 *     const liveSocket = new LiveSocket("/live", Socket, {
 *       hooks: getHooks(lavashDecorator, MyAppHooks)
 *     });
 *
 * ## Auto-activation
 *
 * The decorator can be applied to ANY user hook. At mount time it
 * checks whether the hook's element has `data-lavash-state`:
 *
 *   - **Present** (the lavash server runtime emits this on every
 *     lavash-managed element): the decorator runs the full pipeline
 *     — core init, concerns mount, registers for update/destroy.
 *
 *   - **Absent** (a user hook on a non-lavash element): the decorator
 *     no-ops. The user's hook runs normally; lavash adds zero cost.
 *
 * This means `getHooks(decorator, MyAppHooks)` is safe to use even
 * when most of your hooks have nothing to do with lavash.
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
 * pipeline at each phase (when active). Wrapping (not replacing)
 * means the user's hook keeps doing whatever it does, AND can read
 * lavash state (`this.state`, `this.store`, etc.) if it wants.
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
      // Activation gate: only run lavash if the element is
      // lavash-managed. `data-lavash-state` is emitted by the server
      // runtime on every lavash element (LiveView root, modal wrapper,
      // flyover wrapper). On user-hook elements without it, lavash
      // sits out completely — zero overhead.
      this._lavashEnabled = this.el.hasAttribute("data-lavash-state");

      if (this._lavashEnabled) {
        // Core init first (state, store, version, fns) — sets up the
        // substrate everything else reads from.
        coreInit(this);

        // Each concern's mount-time setup runs in array order.
        for (const concern of concerns) {
          if (concern.mounted) concern.mounted(this, null);
        }

        // Stash the concerns list on the hook so update/destroyed can
        // access it without closing over the original array.
        this._lavashConcerns = concerns;
      }

      // Always call the wrapped hook's own mounted if any. User hook
      // runs whether or not lavash activated — if lavash activated,
      // the user hook can read this.state / this.store.
      hook.mounted?.call(this);
    },

    beforeUpdate() {
      if (this._lavashEnabled) {
        coreCaptureBeforeUpdate(this);

        for (const concern of this._lavashConcerns || []) {
          if (concern.beforeUpdate) concern.beforeUpdate(this, null);
        }
      }

      hook.beforeUpdate?.call(this);
    },

    updated() {
      if (this._lavashEnabled) {
        // The core update cycle handles all internal stages and walks
        // the registered concerns at the appropriate stage points.
        coreUpdated(this, this._lavashConcerns || []);
      }

      hook.updated?.call(this);
    },

    destroyed() {
      if (this._lavashEnabled) {
        // Concerns tear down in REVERSE order — mirror of mounted.
        // If concern A was mounted "on top of" concern B, A tears
        // down first so B's invariants still hold while A cleans up.
        const concerns = this._lavashConcerns || [];
        for (let i = concerns.length - 1; i >= 0; i--) {
          const concern = concerns[i];
          if (concern.destroyed) concern.destroyed(this, null);
        }

        this._lavashConcerns = null;

        if (this.lavashHookId && window.Lavash?.hooks?.[this.lavashHookId] === this) {
          delete window.Lavash.hooks[this.lavashHookId];
        }
      }

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
