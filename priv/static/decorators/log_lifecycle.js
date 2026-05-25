/**
 * Dev-only decorator: log every hook's mount/updated/destroyed events
 * with the hook name. Off by default — opt in by including in your
 * decorator list explicitly.
 *
 * Useful as a debugging aid ("is this hook even mounting?") and as
 * the canonical minimal example of decorator shape.
 *
 *     import { logLifecycle } from "lavash/decorators";
 *
 *     const decoratedHooks = decorate(Hooks, [logLifecycle, ...]);
 */

export const logLifecycle = (hook) => ({
  ...hook,
  mounted() {
    const name = this.el.dataset.phxHook || "(unknown)";
    console.debug(`[lavash] mount ${name}`, this.el);
    hook.mounted?.call(this);
  },
  updated() {
    const name = this.el.dataset.phxHook || "(unknown)";
    console.debug(`[lavash] update ${name}`);
    hook.updated?.call(this);
  },
  destroyed() {
    const name = this.el.dataset.phxHook || "(unknown)";
    console.debug(`[lavash] destroy ${name}`);
    hook.destroyed?.call(this);
  }
});
