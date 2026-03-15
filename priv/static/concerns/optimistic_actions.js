/**
 * Optimistic action execution.
 *
 * Intercepts phx-click events, runs client-side action functions for
 * instant UI updates, and clears LiveView's element lock for rapid clicks.
 */

/**
 * Handle a click event on a phx-click element.
 * Runs the optimistic action if the action name matches a known function.
 *
 * @param {Event} e - Click event
 * @param {Object} hook - The hook instance
 */
export function handleClick(e, hook) {
  const target = e.target.closest("[phx-click]");
  if (!target || !hook.el.contains(target)) return;

  const actionName = target.getAttribute("phx-click");

  // Only intercept if this is a known optimistic action
  if (!hook.fns[actionName]) return;

  // Extract value from first phx-value-* attribute
  let value;
  for (const attr of target.attributes) {
    if (attr.name.startsWith("phx-value-")) {
      value = attr.value;
      break;
    }
  }

  runOptimisticAction(actionName, value, hook);

  // Clear LiveView's element lock so rapid clicks on the same element work.
  target.removeAttribute("data-phx-ref-src");
  target.removeAttribute("data-phx-ref-lock");
  setTimeout(() => {
    target.removeAttribute("data-phx-ref-src");
    target.removeAttribute("data-phx-ref-lock");
  }, 0);
}

/**
 * Run an optimistic action by name.
 * Looks up the function, applies the state delta, and triggers
 * derive recomputation, DOM update, and URL sync.
 *
 * @param {string} actionName
 * @param {any} value - The phx-value-* parameter
 * @param {Object} hook - The hook instance
 */
export function runOptimisticAction(actionName, value, hook) {
  let fn = hook.fns[actionName];

  // Check module registry for dynamically added component functions
  if (!fn && hook.moduleName) {
    const moduleFns = window.Lavash.optimistic[hook.moduleName];
    if (moduleFns && moduleFns[actionName]) {
      fn = moduleFns[actionName];
      hook.fns[actionName] = fn;
      if (moduleFns.__derives__) {
        for (const d of moduleFns.__derives__) {
          if (!hook.deriveNames.includes(d)) {
            hook.deriveNames.push(d);
          }
          if (moduleFns[d] && !hook.fns[d]) {
            hook.fns[d] = moduleFns[d];
          }
        }
      }
    }
  }

  if (!fn) return;

  hook.clientVersion++;

  try {
    const delta = fn(hook.state, value);

    const changedFields = [];
    for (const [key, val] of Object.entries(delta)) {
      hook.state[key] = val;
      const syncedVar = hook.store.get(key, null, (newVal) => {
        hook.state[key] = newVal;
      });
      syncedVar.setOptimistic(val);
      changedFields.push(key);
    }

    hook.propagateBoundFieldsToParent(changedFields);
    hook.recomputeDerives(changedFields);
    hook.updateDOM();
    hook.syncUrl();
  } catch (err) {
    // Silently ignore client-side errors — server is source of truth
  }
}
