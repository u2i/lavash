/**
 * Decorator composition for Phoenix LiveView hooks.
 *
 * A decorator is a function `(hook) => hook` that wraps a hook's
 * lifecycle callbacks with additional behaviour. Decorators compose
 * right-to-left (last argument is innermost), matching standard
 * function-composition convention:
 *
 *     compose(outer, middle, inner)(hook)
 *     // ≡ outer(middle(inner(hook)))
 *
 * At runtime, a decorated hook's `this` is the LiveView hook instance.
 * Decorators that need to read which hook they're attached to should
 * look at `this.el.dataset.phxHook` — names are runtime, not
 * compose-time.
 *
 * ## Decorator contract
 *
 * A decorator returns an object with the same shape as a hook:
 * `{ mounted, updated, destroyed, beforeUpdate, ... }`. When wrapping,
 * decorators should:
 *
 *   1. Call the wrapped callback (`hook.mounted?.call(this)`) so the
 *      chain isn't broken.
 *   2. Namespace any per-instance state under `this._lavash_<name>`
 *      (e.g. `this._lavash_socket_sync_listener`). Two decorators on
 *      the same hook share `this` — namespace to avoid collisions.
 *   3. Clean up in `destroyed`. Forgotten event listeners and timers
 *      leak across LiveView navigations.
 *
 * ## Example
 *
 *     const withLogging = (hook) => ({
 *       ...hook,
 *       mounted() {
 *         const name = this.el.dataset.phxHook;
 *         console.debug(`[mount] ${name}`);
 *         hook.mounted?.call(this);
 *       }
 *     });
 *
 *     const decorated = compose(withLogging)(MyHook);
 */

/**
 * Compose a list of decorators into a single decorator.
 *
 * Right-to-left composition: `compose(a, b, c)(hook)` is
 * `a(b(c(hook)))`. The rightmost decorator is innermost — it sees the
 * raw hook; the leftmost is outermost — it sees everything below
 * already wrapped.
 *
 * @param {...Function} decorators
 * @returns {(hook: object) => object}
 */
export function compose(...decorators) {
  return (hook) => decorators.reduceRight((acc, decorator) => decorator(acc), hook);
}

/**
 * Apply a decorator pipeline to every hook in a hooks object.
 *
 * @param {Object<string, object>} hooks - Hooks dict (name → hook spec)
 * @param {Function[]} decorators - Decorators to compose, right-to-left
 * @returns {Object<string, object>} Hooks dict with each hook decorated
 */
export function decorate(hooks, decorators) {
  const pipeline = compose(...decorators);
  return Object.fromEntries(
    Object.entries(hooks).map(([name, hook]) => [name, pipeline(hook)])
  );
}
