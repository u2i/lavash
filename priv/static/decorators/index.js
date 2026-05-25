/**
 * Lavash decorators — composable hook wrappers shipped with the
 * library.
 *
 * ## Default vs opt-in
 *
 * `defaultDecorators` is what you'd normally include in a lavash app.
 * It excludes dev/debug decorators that you wouldn't ship to
 * production but might want during development (e.g. `logLifecycle`).
 *
 *     import { decorate, defaultDecorators } from "lavash/decorators";
 *
 *     const decoratedHooks = decorate(Hooks, [
 *       ...defaultDecorators,
 *       ...myDecorators
 *     ]);
 *
 * Individual decorators are also named exports so you can pick and
 * choose:
 *
 *     import { decorate, logLifecycle } from "lavash/decorators";
 *
 *     const decoratedHooks = decorate(Hooks, [logLifecycle]);
 */

export { compose, decorate } from "./compose.js";
export { logLifecycle } from "./log_lifecycle.js";

import { logLifecycle as _logLifecycle } from "./log_lifecycle.js";

/**
 * Decorators applied by default when you call `defaultDecorators`.
 * As lavash grows, the things that today live as top-level event
 * listeners in `lavash.js` (socket sync, component sync) will be
 * moved into decorators and included here.
 */
export const defaultDecorators = [
  // (Currently empty — populated as we extract top-level listeners
  //  from lavash.js into decorators in subsequent passes.)
];

/**
 * Dev-only decorators. Not in `defaultDecorators` — opt in
 * explicitly during development.
 */
export const devDecorators = [_logLifecycle];
