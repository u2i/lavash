/**
 * Optimistic actions concern — owns click interception for
 * `phx-click` actions that have a client-side optimistic
 * implementation.
 *
 * Conforms to the lavash concern interface (see PIPELINE.md):
 * exports a single object with `name`, `mounted`, `destroyed`. No
 * update-cycle stage handlers — click handling happens off
 * lifecycle, in the listener installed at mount.
 *
 * Lower-level click classification + state-delta application lives
 * in optimistic_action_helpers.js. This module is the lifecycle
 * orchestrator.
 */

import {
  handleClick as _handleClick,
  handleChange as _handleChange,
  handleActionInputKeydown as _handleActionInputKeydown,
  runOptimisticAction as _runOptimisticAction
} from "./optimistic_action_helpers.js";

export const optimisticActions = {
  name: "optimistic_actions",

  /**
   * Install the capture-phase click listener. Capture phase (third
   * arg `true`) so we run BEFORE Phoenix's own click delegate: the
   * optimistic patch lands first, then the server-side push goes
   * out, then reconciliation in updated().
   *
   * Also attach `runOptimisticAction` as a method on the hook —
   * inline component scripts call `hook.runOptimisticAction(...)`
   * by name, so the hook must expose it.
   *
   * Stashes the bound listener ref on `hook._optimisticActions` so
   * destroyed() can remove the same reference.
   */
  mounted(hook) {
    hook._optimisticActions = {
      clickListener: (e) => _handleClick(e, hook),
      changeListener: (e) => _handleChange(e, hook),
      keydownListener: (e) => _handleActionInputKeydown(e, hook)
    };
    hook.el.addEventListener("click", hook._optimisticActions.clickListener, true);
    // input fires per keystroke on text inputs; change on selects and
    // checkboxes. Both route to the same phx-change interception.
    hook.el.addEventListener("input", hook._optimisticActions.changeListener, true);
    hook.el.addEventListener("change", hook._optimisticActions.changeListener, true);
    // Enter on [data-lavash-action] inputs commits the value to the
    // named action (the tag-editor / todo-add primitive).
    hook.el.addEventListener("keydown", hook._optimisticActions.keydownListener, true);

    // External API: inline component scripts dispatch through this.
    hook.runOptimisticAction = function(actionName, value) {
      _runOptimisticAction(actionName, value, this);
    };
  },

  /**
   * Remove the click listener using the stashed bound ref.
   */
  destroyed(hook) {
    if (hook._optimisticActions?.clickListener) {
      hook.el.removeEventListener("click", hook._optimisticActions.clickListener, true);
    }
    if (hook._optimisticActions?.changeListener) {
      hook.el.removeEventListener("input", hook._optimisticActions.changeListener, true);
      hook.el.removeEventListener("change", hook._optimisticActions.changeListener, true);
    }
    if (hook._optimisticActions?.keydownListener) {
      hook.el.removeEventListener("keydown", hook._optimisticActions.keydownListener, true);
    }
    hook._optimisticActions = null;
    hook.runOptimisticAction = null;
  }
};
