/**
 * Bindings concern — owns parent↔child component state propagation.
 *
 * Conforms to the lavash concern interface (see PIPELINE.md). The
 * `lavash-set` event handler is purely listener-driven (no update-cycle
 * stages); but mounted attaches two hook methods (`refreshFromParent`
 * and `propagateBoundFieldsToParent`) because OTHER hooks reach for
 * them on this one as an external API.
 *
 * Lower-level binding-resolution helpers live in binding_helpers.js.
 */

import {
  refreshFromParent as _refreshFromParent,
  propagateBoundFieldsToParent as _propagateBoundFieldsToParent
} from "./binding_helpers.js";

export const bindings = {
  name: "bindings",

  mounted(hook) {
    hook.bindings = JSON.parse(hook.el.dataset.lavashBindings || "{}");

    hook._bindings = {
      listener: (e) => onLavashSet(e, hook)
    };
    hook.el.addEventListener("lavash-set", hook._bindings.listener, false);

    // External API — parent hooks call these on their children, and
    // optimistic_actions calls propagateBoundFieldsToParent after
    // applying a state delta.
    hook.refreshFromParent = function(parentHook) {
      const changedFields = _refreshFromParent(
        this.bindings, this.state, this.store, parentHook
      );
      if (changedFields.length > 0) {
        this.recomputeDerives(changedFields);
        this.updateDOM();
      }
    };

    hook.propagateBoundFieldsToParent = function(changedFields, opts) {
      _propagateBoundFieldsToParent(
        this.bindings, this.state, this.el, changedFields, opts
      );
    };
  },

  destroyed(hook) {
    if (hook._bindings?.listener) {
      hook.el.removeEventListener("lavash-set", hook._bindings.listener, false);
    }
    hook._bindings = null;
    hook.refreshFromParent = null;
    hook.propagateBoundFieldsToParent = null;
  }
};

/**
 * Handler for `lavash-set` events. Three cases:
 *
 *   1. Field has animated state — route through SyncedVar (phase
 *      machine engages). Stops propagation.
 *   2. Field is on hook.state — owned. Update + push. Stops propagation.
 *   3. Not owned — keep bubbling so an ancestor hook can claim it.
 */
function onLavashSet(e, hook) {
  const { field, value, serverHandled } = e.detail;
  if (!field) return;

  console.debug(
    `[lavash:bindings] handleLavashSet: field=${field}, value=${JSON.stringify(value)}, serverHandled=${serverHandled}`
  );

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

  if (field in hook.state) {
    e.stopPropagation();
    hook.state[field] = value;

    if (hook.store) {
      const syncedVar = hook.store.get(field, null);
      syncedVar.setOptimistic(value);
    }

    if (hook.clientVersion !== undefined) hook.clientVersion++;

    hook.recomputeDerives([field]);
    hook.updateDOM();

    if (!serverHandled) {
      const setterAction = `set_${field}`;
      hook.pushEventTo(hook.el, setterAction, { value }, () => {});
    }
    return;
  }

  console.debug("[LavashOptimistic] Field", field, "not owned by this hook, letting event propagate");
}
