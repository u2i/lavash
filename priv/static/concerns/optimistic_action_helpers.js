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

  // Client-generated append ids: for every append op this action will
  // perform (directly or via invoke — compile-time metadata), mint a
  // UUID NOW, before Phoenix's delegate reads the element's attributes,
  // and inject it into the payload as phx-value-_lavash_ids. The
  // deferred prediction consumes the same ids via the stash, so the
  // provisional row and the server-created record share their identity.
  const appendKeys =
    (window.Lavash?.optimistic?.[hook.moduleName]?.__append_ids__ || {})[actionName] || [];

  if (appendKeys.length > 0 && window.crypto?.randomUUID) {
    const ids = {};
    for (const key of appendKeys) {
      ids[key] = crypto.randomUUID();
      window.Lavash.stashAppendId(key, ids[key]);
    }
    target.setAttribute("phx-value-_lavash_ids", JSON.stringify(ids));
  }

  // Extract phx-value-* attributes. One attribute → scalar `value`
  // (the historical contract single-param action fns compile
  // against); several → an object keyed by snake_cased param names
  // (what multi-param action fns compile against). The out-of-band
  // _lavash_ids channel is excluded from the value shape.
  const entries = [];
  for (const attr of target.attributes) {
    if (attr.name.startsWith("phx-value-") && attr.name !== "phx-value-_lavash_ids") {
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
    // The per-click append ids were consumed by the push above; drop
    // the attribute so a future click mints fresh ones.
    target.removeAttribute("phx-value-_lavash_ids");
  }, 0);
}

/**
 * Handle an input/change event on a form carrying phx-change.
 * Mirrors handleClick for the input path: if the phx-change action has
 * a client-side optimistic implementation, run it with the input's
 * value so the prediction (state delta, derives, URL sync) lands
 * immediately — Phoenix's own delegate still pushes the server event,
 * with phx-debounce applying only to that push, not to the prediction.
 *
 * Only fires for the setter convention (a single input named "value",
 * the shape auto-generated set_* actions consume). Inputs owned by the
 * bound-field machinery (data-lavash-bind) are left to it.
 *
 * @param {Event} e - input or change event
 * @param {Object} hook - The hook instance
 */
export function handleChange(e, hook) {
  const input = e.target;
  if (!input || input.name !== "value" || input.dataset?.lavashBind) return;

  const form = input.closest("[phx-change]");
  if (!form || !hook.el.contains(form)) return;

  // Skip inputs belonging to a nested child hook — its own listener runs.
  const owner = input.closest("[data-lavash-state]");
  if (owner && owner !== hook.el) return;

  const actionName = form.getAttribute("phx-change");
  if (!hook.fns[actionName]) return;

  const value = input.type === "checkbox" ? input.checked : input.value;

  // Deferred one macrotask for the same reason as handleClick: the
  // prediction may re-render a subtree containing this input, and
  // detaching it before Phoenix's bubble-phase delegate runs would
  // kill the server push.
  setTimeout(() => runOptimisticAction(actionName, value, hook), 0);
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
