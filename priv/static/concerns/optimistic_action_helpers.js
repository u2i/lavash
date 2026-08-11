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

  // Extract phx-value-* attributes. One attribute → scalar `value`
  // (the historical contract single-param action fns compile
  // against); several → an object keyed by snake_cased param names
  // (what multi-param action fns compile against).
  const entries = [];
  for (const attr of target.attributes) {
    if (attr.name.startsWith("phx-value-")) {
      entries.push([attr.name.slice("phx-value-".length).replace(/-/g, "_"), attr.value]);
    }
  }

  const value =
    entries.length === 0 ? undefined :
    entries.length === 1 ? entries[0][1] :
    Object.fromEntries(entries);

  // Defer the prediction one macrotask: applying it synchronously
  // re-renders any data-lavash-html subtree the clicked element sits
  // in, detaching it from the document BEFORE Phoenix's bubble-phase
  // click delegate runs — which silently kills the server push. One
  // tick later the event has fully propagated (the push is out) and
  // the prediction still lands orders of magnitude before the reply.
  setTimeout(() => {
    runOptimisticAction(actionName, value, hook);

    // Clear LiveView's element lock so rapid clicks on the same element work.
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

  // Actions with appends are provisional: the predicted row carries a
  // temp key, so the next server push (the same event's re-read, with
  // the real record) must replace it rather than be rejected as a
  // mismatched prediction. seed() applies the value without marking
  // the var pending.
  const provisional =
    hook.moduleName &&
    (window.Lavash.optimistic[hook.moduleName]?.__provisional__ || []).includes(actionName);

  hook.clientVersion++;

  try {
    const delta = fn(hook.state, value);

    const changedFields = [];
    for (const [key, val] of Object.entries(delta)) {
      hook.state[key] = val;
      const syncedVar = hook.store.get(key, null, (newVal) => {
        hook.state[key] = newVal;
      });
      if (provisional) {
        syncedVar.seed(val);
      } else {
        syncedVar.setOptimistic(val);
      }
      changedFields.push(key);
    }

    hook.propagateBoundFieldsToParent(changedFields, { serverHandled: true });
    hook.recomputeDerives(changedFields);
    hook.updateDOM(true);
    hook.syncUrl();
  } catch (err) {
    // Silently ignore client-side errors — server is source of truth
  }
}
