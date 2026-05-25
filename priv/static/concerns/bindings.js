/**
 * Bindings concern — owns parent↔child component state propagation
 * within the LavashOptimistic hook.
 *
 * A child component declares a binding from one of its local fields
 * to a parent field via `data-lavash-bindings`. The hook then:
 *
 *   - hydrates `hook.bindings` from the dataset at mount
 *   - installs a `lavash-set` listener that catches state-change
 *     events bubbling up from descendant ClientComponents
 *   - exposes `refreshFromParent` (called from parent → this child
 *     when the parent's bound field changes) and
 *     `propagateBoundFieldsToParent` (called from this hook → its
 *     parent when a locally-owned bound field changes)
 *
 * The lower-level binding-resolution helpers live in
 * binding_helpers.js. This module is the lifecycle orchestrator
 * around them.
 */

import {
  refreshFromParent as _refreshFromParent,
  propagateBoundFieldsToParent as _propagateBoundFieldsToParent
} from "./binding_helpers.js";

/**
 * Init bindings state at mount: parse the `data-lavash-bindings`
 * JSON map (`{ local: "parent.field" }`) and install the
 * `lavash-set` listener.
 *
 * Uses bubble mode (not capture) so the closest ancestor hook handles
 * a given lavash-set event first — the field-ownership check inside
 * `onLavashSet` then decides whether to consume it or re-bubble.
 *
 * Stashes the bound listener ref on `hook._bindingsListener` for
 * cleanup in destroyed().
 */
export function mounted(hook) {
  hook.bindings = JSON.parse(hook.el.dataset.lavashBindings || "{}");

  hook._bindingsListener = (e) => onLavashSet(e, hook);
  hook.el.addEventListener("lavash-set", hook._bindingsListener, false);
}

/**
 * Cleanup at destroy: remove the lavash-set listener using the same
 * bound ref we stashed at mount.
 */
export function destroyed(hook) {
  if (hook._bindingsListener) {
    hook.el.removeEventListener("lavash-set", hook._bindingsListener, false);
    hook._bindingsListener = null;
  }
}

/**
 * Refresh this hook from a parent's bound fields. Called by the
 * parent hook when its state changes, walks `hook.bindings` and
 * pulls the new values from `parentHook` into this hook's state.
 *
 * If any fields changed, runs recompute + DOM update.
 */
export function refreshFromParent(hook, parentHook) {
  const changedFields = _refreshFromParent(
    hook.bindings,
    hook.state,
    hook.store,
    parentHook
  );

  if (changedFields.length > 0) {
    hook.recomputeDerives(changedFields);
    hook.updateDOM();
  }
}

/**
 * Propagate bound fields from this hook UP to the parent: dispatches
 * `lavash-set` events for each bound field that just changed.
 */
export function propagateBoundFieldsToParent(hook, changedFields, opts) {
  _propagateBoundFieldsToParent(
    hook.bindings,
    hook.state,
    hook.el,
    changedFields,
    opts
  );
}

/**
 * Handler for `lavash-set` events. Three cases:
 *
 *   1. Field has animated state (modal/flyover open_field) — route
 *      through the SyncedVar so the phase machine engages.
 *      Stops propagation; this hook owns the field.
 *
 *   2. Field exists on `hook.state` — this hook owns it. Update
 *      state directly, mark version dirty, recompute + push to
 *      server (unless serverHandled, meaning the originating
 *      component already pushed its own action).
 *      Stops propagation.
 *
 *   3. Neither — this hook doesn't own the field. Let the event
 *      keep bubbling so an ancestor hook can claim it.
 *
 * Internal — not exported. Wired in mounted().
 */
function onLavashSet(e, hook) {
  const { field, value, serverHandled } = e.detail;
  if (!field) return;

  console.warn(
    `[LO] handleLavashSet: field=${field}, value=${JSON.stringify(value)}, serverHandled=${serverHandled}`
  );

  // Case 1: animated state — route through SyncedVar.
  if (hook.animatedStates?.[field]) {
    e.stopPropagation();
    const animValue = value ? value : null;

    if (!serverHandled) {
      const setterAction = `set_${field}`;
      hook.store.get(field).set(animValue, (payload, callback) => {
        hook.pushEventTo(hook.el, setterAction, { ...payload, value: animValue }, callback);
      });
    } else {
      hook.store.get(field).setOptimistic(animValue);
    }

    return;
  }

  // Case 2: plain owned field.
  if (field in hook.state) {
    e.stopPropagation();

    hook.state[field] = value;

    if (hook.store) {
      const syncedVar = hook.store.get(field, null);
      syncedVar.setOptimistic(value);
    }

    if (hook.clientVersion !== undefined) {
      hook.clientVersion++;
    }

    hook.recomputeDerives([field]);
    hook.updateDOM();

    if (!serverHandled) {
      const setterAction = `set_${field}`;
      hook.pushEventTo(hook.el, setterAction, { value }, () => {});
    }

    return;
  }

  // Case 3: not our field, keep bubbling.
  console.debug("[LavashOptimistic] Field", field, "not owned by this hook, letting event propagate");
}
