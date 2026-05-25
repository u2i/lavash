/**
 * Forms concern — owns the forms-related lifecycle within the
 * LavashOptimistic hook: touched-field tracking, per-form submitted
 * state, input/change/blur/submit event listeners, server-side form
 * validation debouncing, and the touched/show_errors clearing that
 * happens when a modal opens.
 *
 * ## What lives on the hook
 *
 *   - `hook.fieldState`      — per-field `{ touched: bool }` map
 *   - `hook.submittedForms`  — Set of form ids that have been submitted
 *   - `hook.validationTimers` — per-field-path debounce timers
 *   - `hook._formListeners`  — bound handler refs stashed for cleanup
 *
 * These are kept on the hook (not on the module) because today's main
 * hook reads them directly from other concerns (e.g. updateDOM's
 * isFormSubmitted check). When the refactor reaches a true decorator
 * boundary, namespace these under `hook._lavash_forms_*`.
 *
 * ## Remount preservation
 *
 * Client-only state (fieldState, submittedForms) survives a brief
 * window across hook remounts via the module-local
 * `_preservedClientState` Map. LiveView patches can rip a hook
 * element out and re-create it; without this stash, the user would
 * see "touched"/"submitted" UI reset to clean on every patch.
 *
 * The stash is keyed by `hook.el.id` and self-evicts after 1s so a
 * truly destroyed hook doesn't leak.
 */

import {
  getFormField as _getFormField,
  isFormSubmitted as _isFormSubmitted,
  handleBlur as _handleBlur,
  handleFormSubmit as _handleFormSubmit,
  handleInput as _handleInput,
  initializeFormParamsFromDOM as _initializeFormParamsFromDOM
} from "./form_handler.js";

// Keyed by element id. Values: { fieldState, submittedForms }.
const _preservedClientState = new Map();

/**
 * Init forms state at mount: rehydrate from preserved-client-state if
 * this is a remount, install the 4 input-related listeners, then
 * walk the DOM to seed form params from default input values.
 *
 * Stashes bound handler references on `hook._formListeners` so
 * destroyed() can remove the SAME refs (the old code bound fresh
 * functions in destroyed, which silently never matched).
 */
export function mounted(hook) {
  const preserved = _preservedClientState.get(hook.el.id);

  if (preserved) {
    hook.fieldState = preserved.fieldState || {};
    hook.submittedForms = preserved.submittedForms || new Set();
    _preservedClientState.delete(hook.el.id);
  } else {
    hook.fieldState = {};
    hook.submittedForms = new Set();
  }

  hook.validationTimers = {};

  // Bind listener handlers once and stash refs so removeEventListener
  // in destroyed() actually matches.
  hook._formListeners = {
    input: (e) => _handleInput(e, hook),
    blur: (e) => _handleBlur(e, hook),
    submit: (e) => _handleFormSubmit(e, hook)
  };

  // input fires on text keystroke; change fires on select/checkbox.
  // We need both to cover all bound inputs.
  hook.el.addEventListener("input", hook._formListeners.input, true);
  hook.el.addEventListener("change", hook._formListeners.input, true);
  hook.el.addEventListener("blur", hook._formListeners.blur, true);
  hook.el.addEventListener("submit", hook._formListeners.submit, true);

  _initializeFormParamsFromDOM(hook);
}

/**
 * Post-update step: re-seed form params from any newly-added inputs
 * (e.g. inputs inside async modal content that only just rendered).
 */
export function updated(hook) {
  _initializeFormParamsFromDOM(hook);
}

/**
 * Cleanup at destroy: stash client-only state for potential remount,
 * remove the listeners we installed in mounted(). Same-reference
 * removal because we kept the bound refs on `hook._formListeners`.
 */
export function destroyed(hook) {
  if (hook.el.id) {
    _preservedClientState.set(hook.el.id, {
      fieldState: hook.fieldState,
      submittedForms: hook.submittedForms
    });

    // Self-evict if not reused — prevents leaks across full navigations.
    setTimeout(() => _preservedClientState.delete(hook.el.id), 1000);
  }

  if (hook._formListeners) {
    hook.el.removeEventListener("input", hook._formListeners.input, true);
    hook.el.removeEventListener("change", hook._formListeners.input, true);
    hook.el.removeEventListener("blur", hook._formListeners.blur, true);
    hook.el.removeEventListener("submit", hook._formListeners.submit, true);
    hook._formListeners = null;
  }
}

/**
 * Clear `fieldState` entries under a given path prefix AND reset the
 * corresponding `_show_errors` state fields. Called from
 * mergeServerState when a modal opens with `{form}_params: {}` — the
 * server says "this form is fresh", so the touched-state and the
 * per-field error visibility should be wiped.
 *
 * Pure side-effect on hook.fieldState and hook.state.
 */
export function clearFieldStateForPathPrefix(hook, pathPrefix, formName) {
  for (const fieldPath of Object.keys(hook.fieldState)) {
    if (fieldPath.startsWith(pathPrefix + ".")) {
      delete hook.fieldState[fieldPath];

      const fieldName = fieldPath.substring(pathPrefix.length + 1);
      const showErrorsKey = `${formName}_${fieldName}_show_errors`;
      hook.state[showErrorsKey] = false;
    }
  }
}

/**
 * Re-exports so the main hook's updateDOM callback can pass these
 * to the DOM updater without holding hook-method shims.
 */
export const getFormField = _getFormField;

export function isFormSubmittedFor(hook, formName) {
  return _isFormSubmitted(hook.submittedForms, formName);
}
