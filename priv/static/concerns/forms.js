/**
 * Forms concern — owns the forms-related lifecycle within a lavash-
 * decorated hook: touched-field tracking, per-form submitted state,
 * input/change/blur/submit listeners, server-side form validation
 * debouncing, and touched/show_errors clearing on modal open.
 *
 * Conforms to the lavash concern interface (see PIPELINE.md):
 *   - mounted: install listeners + rehydrate preserved state
 *   - destroyed: stash + remove listeners
 *   - afterRecompute: re-seed form params from DOM
 *   - mergeVisitors.emptyParams: clear fieldState when modal opens
 *
 * The clear-on-modal-open visitor reads `ctx.isModalOpening`, which
 * is written by the overlays concern during observeBeforeMerge.
 *
 * ## Remount preservation
 *
 * Client-only state (fieldState, submittedForms) survives a brief
 * window across hook remounts via the module-local
 * `_preservedClientState` Map. LiveView patches can rip a hook
 * element out and re-create it; without this stash, the user would
 * see "touched"/"submitted" UI reset to clean on every patch.
 * Stash self-evicts after 1s.
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

export const forms = {
  name: "forms",

  mounted(hook) {
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

    hook._forms = {
      listeners: {
        input: (e) => _handleInput(e, hook),
        blur: (e) => _handleBlur(e, hook),
        submit: (e) => _handleFormSubmit(e, hook)
      }
    };

    // input fires on text keystroke; change fires on select/checkbox.
    hook.el.addEventListener("input", hook._forms.listeners.input, true);
    hook.el.addEventListener("change", hook._forms.listeners.input, true);
    hook.el.addEventListener("blur", hook._forms.listeners.blur, true);
    hook.el.addEventListener("submit", hook._forms.listeners.submit, true);

    // Expose form helpers to updateDOM via hooks the pipeline core
    // reads (see attachHookMethods in pipeline_core.js — falls back to
    // no-ops if forms isn't loaded).
    hook._lavashFormsGetField = _getFormField;
    hook._lavashFormsIsSubmitted = (formName) =>
      _isFormSubmitted(hook.submittedForms, formName);

    _initializeFormParamsFromDOM(hook);
  },

  destroyed(hook) {
    if (hook.el.id) {
      _preservedClientState.set(hook.el.id, {
        fieldState: hook.fieldState,
        submittedForms: hook.submittedForms
      });
      setTimeout(() => _preservedClientState.delete(hook.el.id), 1000);
    }

    if (hook._forms?.listeners) {
      hook.el.removeEventListener("input", hook._forms.listeners.input, true);
      hook.el.removeEventListener("change", hook._forms.listeners.input, true);
      hook.el.removeEventListener("blur", hook._forms.listeners.blur, true);
      hook.el.removeEventListener("submit", hook._forms.listeners.submit, true);
    }
    hook._forms = null;
    hook._lavashFormsGetField = null;
    hook._lavashFormsIsSubmitted = null;
  },

  /**
   * After hook.recomputeDerives() runs in the update cycle: re-seed
   * form params from any newly-rendered inputs (e.g. inputs inside
   * async modal content that just became visible).
   */
  afterRecompute(hook, _ctx) {
    _initializeFormParamsFromDOM(hook);
  },

  /**
   * After updateDOM(): if the server's echo overwrote a typed value
   * for a `data-lavash-bind` input whose SyncedVar still holds the
   * pending value, push the SyncedVar value back into the DOM input.
   *
   * Without this, the input would briefly show the stale server echo
   * before the next user keystroke. The SyncedVar still has the right
   * value; we just need to reflect it to the DOM.
   *
   * Lives in forms because `data-lavash-bind` is forms' domain — same
   * inputs that handleInput / handleBlur / handleFormSubmit listen on.
   */
  afterRender(hook, _ctx) {
    const boundInputs = hook.el.querySelectorAll("[data-lavash-bind]");
    boundInputs.forEach(input => {
      const fieldPath = input.dataset.lavashBind;
      if (fieldPath && hook.store.isPending(fieldPath)) {
        const val = hook.store.getValue(fieldPath);
        if (val !== undefined && input.value !== val) {
          input.value = val;
        }
      }
    });
  },

  mergeVisitors: {
    /**
     * When the merge walker hits `{form}_params: {}` at the top level
     * AND a modal is opening this cycle, clear pending paths from the
     * store and wipe the per-form fieldState + _show_errors fields.
     */
    emptyParams(hook, ctx, { path, formName, hasPendingChild }) {
      if (!ctx.isModalOpening) return;

      // Clear store pending paths under this prefix
      if (hasPendingChild) {
        for (const pendingPath of [...ctx.pendingPaths]) {
          if (pendingPath.startsWith(path + ".")) {
            hook.store.clearPending(pendingPath);
            ctx.pendingPaths.delete(pendingPath);
          }
        }
      }

      // Wipe fieldState entries + reset _show_errors flags
      for (const fieldPath of Object.keys(hook.fieldState)) {
        if (fieldPath.startsWith(path + ".")) {
          delete hook.fieldState[fieldPath];

          const fieldName = fieldPath.substring(path.length + 1);
          const showErrorsKey = `${formName}_${fieldName}_show_errors`;
          hook.state[showErrorsKey] = false;
        }
      }
    },

    /**
     * Don't clear `{form}_server_errors: {}` if the form has pending
     * params — those errors might still be relevant once the params
     * settle.
     */
    skipServerErrorClear(hook, ctx, { formName }) {
      const paramsField = `${formName}_params`;
      for (const p of ctx.pendingPaths) {
        if (p.startsWith(paramsField + ".")) return true;
      }
      return false;
    },

    /**
     * When a `_params` field is actually being cleared (server sent
     * `{}` and the client had a non-empty value), wipe matching DOM
     * inputs so stale values don't flash before the next render.
     */
    paramsCleared(hook, _ctx, { key }) {
      const inputSelector = `[data-lavash-bind^="${key}."]`;
      const inputs = hook.el.querySelectorAll(inputSelector);
      inputs.forEach(input => {
        if (input.value !== "") input.value = "";
      });
    }
  }
};
