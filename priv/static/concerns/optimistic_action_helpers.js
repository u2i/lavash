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
 * Handle Enter on an action-committing input (`data-lavash-action`).
 *
 * The "text input commits to an action" primitive (tag editors, todo
 * add-forms): Enter runs the named action with the input's trimmed
 * value — optimistic half via runOptimisticAction (when the action
 * transpiled), server half via pushEventTo — then clears the input
 * and restores focus for rapid entry (the prediction may have
 * re-rendered the subtree containing the input, replacing the node).
 *
 * @param {Event} e - keydown event
 * @param {Object} hook - The hook instance
 */
export function handleActionInputKeydown(e, hook) {
  if (e.key !== "Enter") return;

  const input = e.target;
  if (!input?.dataset?.lavashAction) return;
  if (!hook.el.contains(input)) return;

  // Inputs owned by a nested child hook are that hook's business.
  const owner = input.closest("[data-lavash-state]");
  if (owner && owner !== hook.el) return;

  const actionName = input.dataset.lavashAction;
  const value = (input.value || "").trim();
  if (value === "") return;

  // Enter in a lone input would submit an enclosing form.
  e.preventDefault();

  // Same client-generated append-id contract as handleClick: mint and
  // stash per-append UUIDs so the Enter-triggered prediction and the
  // server-created record share identity. Without this a streamed
  // append's confirming stream_insert would target a different dom id
  // than the predicted row.
  const payload = { value };
  const appendKeys =
    (window.Lavash?.optimistic?.[hook.moduleName]?.__append_ids__ || {})[actionName] || [];

  if (appendKeys.length > 0 && window.crypto?.randomUUID) {
    const ids = {};
    for (const key of appendKeys) {
      ids[key] = crypto.randomUUID();
      window.Lavash.stashAppendId(key, ids[key]);
    }
    payload._lavash_ids = JSON.stringify(ids);
  }

  // Push first (nothing here depends on the DOM afterwards), then
  // predict — the prediction's re-render may replace the input node.
  hook.pushEventTo(hook.el, actionName, payload);
  input.value = "";
  runOptimisticAction(actionName, value, hook);

  const fresh = hook.el.querySelector(`[data-lavash-action="${actionName}"]`);
  if (fresh) fresh.focus();
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
// Row ids a provisional prediction added or mutated: ids present in
// the new array but absent from the old (appends, client-minted id),
// plus ids whose row object changed (upsert on_conflict merge). Non-
// array values contribute no row ids — the field-level annotation
// still covers them.
function diffChangedRowIds(oldVal, newVal) {
  if (!Array.isArray(newVal)) return [];
  const oldRows = new Map(
    (Array.isArray(oldVal) ? oldVal : [])
      .filter(r => r && r.id != null)
      .map(r => [String(r.id), r])
  );
  const ids = [];
  for (const row of newVal) {
    if (!row || row.id == null) continue;
    const id = String(row.id);
    const prev = oldRows.get(id);
    if (!prev || !shallowRowEqual(prev, row)) ids.push(id);
  }
  return ids;
}

function shallowRowEqual(a, b) {
  const keysA = Object.keys(a);
  const keysB = Object.keys(b);
  if (keysA.length !== keysB.length) return false;
  return keysA.every(k => a[k] === b[k]);
}

// Predicted row ops for stream-backed projections (issue #71).
// Inserted/replaced rows go into the phx-update="stream" container —
// which never reconciles children on patch, so the predicted node
// survives until the server's confirming stream op (same client-minted
// dom id) morphs it in place. That morph strips
// data-lavash-provisional (the server HTML doesn't carry it), which is
// the confirmation signal refreshSyncAnnotations watches for.
// Predicted deletes remove the node immediately; the confirming
// stream_delete is a no-op on the already-gone node, so they resolve
// when the next server patch (version bump) arrives.
function applyStreamOps(hook, ops) {
  hook.streamRows = hook.streamRows || new Map();

  for (const op of ops) {
    if (op.op === "delete") {
      document.getElementById(op.domId)?.remove();
      hook.streamRows.set(op.domId, { kind: "delete", version: hook.serverVersion });
      continue;
    }

    if (op.op === "replace") {
      const el = document.getElementById(op.domId);
      if (!el) continue;
      el.outerHTML = op.html;
    } else {
      if (document.getElementById(op.domId)) continue;
      const container = document.getElementById(op.container);
      if (!container) continue;
      container.insertAdjacentHTML(op.at === 0 ? "afterbegin" : "beforeend", op.html);
    }

    const el = document.getElementById(op.domId);
    if (el) {
      el.setAttribute("data-lavash-provisional", "");
      hook.streamRows.set(op.domId, { kind: op.op });
    }
  }
}

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
    // Snapshot BEFORE running the prediction: projection ops assign
    // into state inside the generated fn (replacing array references),
    // so hook.state already holds the predicted arrays by the time the
    // delta comes back. The shallow copy keeps the pre-prediction
    // references as the diff base for provisional row ids (issue #72).
    const stateBefore = provisional ? { ...hook.state } : null;
    const delta = fn(hook.state, value);

    // Stream-backed projections (issue #71): the prediction is a DOM
    // row op, not a state delta — apply and drop before the state loop.
    if (delta.__stream_ops__) {
      applyStreamOps(hook, delta.__stream_ops__);
      delete delta.__stream_ops__;
    }

    const changedFields = [];
    for (const [key, val] of Object.entries(delta)) {
      // Which projected rows did this prediction add or mutate? Their
      // ids drive row-level provisional annotations — client-minted
      // append ids make the identity stable across predict and confirm.
      const changedIds = provisional ? diffChangedRowIds(stateBefore[key], val) : [];
      hook.state[key] = val;
      const syncedVar = hook.store.get(key, null, (newVal) => {
        hook.state[key] = newVal;
      });
      if (provisional) {
        syncedVar.seed(val, { provisional: true, changedIds });
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
