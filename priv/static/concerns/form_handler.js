/**
 * Form handling concern.
 *
 * Manages form input binding, blur/touched tracking, form submission,
 * server validation, show_errors state, and input formatting.
 */
import {
  isInsideChildHook,
  isInsideHiddenContainer,
  formatInputValue,
} from "./utils.js";

/**
 * Get form name and field name from explicit attributes or derive from field path.
 *
 * @param {HTMLElement} el
 * @param {string} fieldPath - e.g., "registration_params.name"
 * @returns {{ formName: string|null, fieldName: string|null }}
 */
export function getFormField(el, fieldPath) {
  const explicitForm = el.dataset.lavashForm;
  const explicitField = el.dataset.lavashField;

  if (explicitForm && explicitField) {
    return { formName: explicitForm, fieldName: explicitField };
  }

  const parts = fieldPath.split(".");
  if (parts.length >= 2) {
    const paramsField = parts[0];
    const fieldName = explicitField || parts.slice(1).join("_");
    const formName = explicitForm || paramsField.replace(/_params$/, "");
    return { formName, fieldName };
  }

  return { formName: null, fieldName: null };
}

/**
 * Check if a specific form has been submitted.
 */
export function isFormSubmitted(submittedForms, formName) {
  if (!submittedForms) return false;
  for (const id of submittedForms) {
    if (id === formName || id.startsWith(formName + "-") || id.includes(formName)) {
      return true;
    }
  }
  return false;
}

/**
 * Update show_errors state for a field based on touched/submitted status.
 */
export function updateShowErrors(hook, fieldPath, formName, fieldName) {
  const touched = hook.fieldState[fieldPath]?.touched || false;
  const formSubmitted = isFormSubmitted(hook.submittedForms, formName);
  const showErrors = touched || formSubmitted;
  const showErrorsKey = `${formName}_${fieldName}_show_errors`;
  hook.state[showErrorsKey] = showErrors;
}

/**
 * Trigger server-side validation for a field (debounced).
 */
export function triggerServerValidation(hook, fieldPath, formName, fieldName, immediate = false, inputEl = null) {
  const customValidField = inputEl?.dataset?.lavashValid;
  const validField = customValidField || `${formName}_${fieldName}_valid`;
  const clientValid = hook.state[validField] ?? true;

  if (!clientValid) {
    if (hook.validationTimers[fieldPath]) {
      clearTimeout(hook.validationTimers[fieldPath]);
      delete hook.validationTimers[fieldPath];
    }
    return;
  }

  if (hook.validationTimers[fieldPath]) {
    clearTimeout(hook.validationTimers[fieldPath]);
  }

  const sendValidation = () => {
    const params = hook.state[`${formName}_params`] || {};
    hook.pushEvent(`validate_${formName}`, {
      field: fieldName,
      value: params[fieldName]
    });
  };

  if (immediate) {
    sendValidation();
  } else {
    hook.validationTimers[fieldPath] = setTimeout(sendValidation, 500);
  }
}

/**
 * Handle blur event on a bound input — marks field as touched.
 */
export function handleBlur(e, hook) {
  const target = e.target.closest("[data-lavash-bind]");
  if (!target) return;
  if (isInsideChildHook(target, hook.el)) return;

  const fieldPath = target.dataset.lavashBind;
  if (!fieldPath) return;

  if (!hook.fieldState[fieldPath]) {
    hook.fieldState[fieldPath] = {};
  }
  hook.fieldState[fieldPath].touched = true;

  const { formName, fieldName } = getFormField(target, fieldPath);
  if (!formName || !fieldName) return;

  updateShowErrors(hook, fieldPath, formName, fieldName);
  triggerServerValidation(hook, fieldPath, formName, fieldName, true, target);
  hook.updateDOM();
}

/**
 * Handle form submit — marks all fields as touched, validates, prevents if invalid.
 */
export function handleFormSubmit(e, hook) {
  const form = e.target.closest("form");
  if (!form) return;

  if (!hook.submittedForms) hook.submittedForms = new Set();

  const formId = form.id || "default";
  hook.submittedForms.add(formId);

  const firstInput = form.querySelector("[data-lavash-bind]");
  if (firstInput) {
    const fieldPath = firstInput.dataset.lavashBind;
    const { formName } = getFormField(firstInput, fieldPath);
    if (formName) {
      hook.submittedForms.add(formName);
    }
  }

  const boundInputs = form.querySelectorAll("[data-lavash-bind]");
  const inputElements = [];
  boundInputs.forEach(input => {
    const fieldPath = input.dataset.lavashBind;
    if (fieldPath) {
      if (!hook.fieldState[fieldPath]) {
        hook.fieldState[fieldPath] = {};
      }
      hook.fieldState[fieldPath].touched = true;

      const { formName, fieldName } = getFormField(input, fieldPath);
      if (formName && fieldName) {
        updateShowErrors(hook, fieldPath, formName, fieldName);
      }
      inputElements.push({ input, fieldPath, formName, fieldName });
    }
  });

  hook.updateDOM();

  // Prevent submission if any field is invalid
  for (const { input, formName, fieldName } of inputElements) {
    if (!formName || !fieldName) continue;

    const customValidField = input.dataset?.lavashValid;
    const validField = customValidField || `${formName}_${fieldName}_valid`;
    const clientValid = hook.state[validField] ?? true;
    const errorsField = `${formName}_${fieldName}_errors`;
    const errors = hook.state[errorsField] || [];

    if (!clientValid || errors.length > 0) {
      e.preventDefault();
      input.focus();
      input.scrollIntoView({ behavior: "smooth", block: "center" });

      const errorSummary = form.querySelector("[data-lavash-error-summary]");
      if (errorSummary) {
        errorSummary.scrollIntoView({ behavior: "smooth", block: "nearest" });
      }
      return;
    }
  }
}

/**
 * Read the value of a bound input element in a type-appropriate way.
 *
 * `target.value` works for text/textarea/select-single, but is wrong
 * for:
 *
 *   - **checkbox** — `target.value` is the static `value=""` attr
 *     (typically "true" or "on"), regardless of whether the box is
 *     checked. We need `target.checked` (boolean) so the bind writes
 *     a real boolean and downstream `data-lavash-enabled` /
 *     reactive-graph comparisons against the literal `true` work.
 *
 *   - **radio** — same shape as checkbox: `target.value` is the
 *     radio's static group-value. The right reading is "the value
 *     of the currently-checked radio in this group" but we handle
 *     that at the callsite (skip when !target.checked; the
 *     newly-checked radio fires its own event and writes its
 *     `target.value`). So here we just return target.value, which
 *     is correct when target.checked is true.
 *
 *   - **select[multiple]** — `target.value` is just the FIRST
 *     selected option's value, dropping the rest. The correct
 *     reading is an array of all selected option values.
 */
function readBoundInputValue(target) {
  if (target.tagName === "INPUT" && target.type === "checkbox") {
    return target.checked;
  }
  if (target.tagName === "SELECT" && target.multiple) {
    return Array.from(target.selectedOptions, opt => opt.value);
  }
  return target.value;
}

/**
 * Handle input/change event on a bound input.
 */
export function handleInput(e, hook) {
  const target = e.target.closest("[data-lavash-bind]");
  if (!target) return;

  // Avoid double handling per element type
  if (target.tagName === "SELECT" && e.type === "input") return;
  if ((target.tagName === "INPUT" || target.tagName === "TEXTAREA") && e.type === "change") return;

  // Skip inputs inside child components
  const childHook = target.closest("[data-lavash-state]");
  if (childHook && childHook !== hook.el) return;

  const fieldPath = target.dataset.lavashBind;
  let value = readBoundInputValue(target);

  // For radio: an unchecked radio firing means the user clicked
  // another radio in the group. The just-selected one will fire
  // its own event; let that one update state. Skip the unchecked
  // event so we don't write `null` over a valid selection.
  if (target.type === "radio" && !target.checked) return;

  // Apply input formatting (string inputs only — checkbox/multi-select
  // already produce booleans/arrays which formatting can't process).
  const format = target.dataset.lavashFormat;
  if (format && typeof value === "string") {
    const formatted = formatInputValue(value, format);
    if (formatted !== null) {
      value = formatted.value;
      if (formatted.display !== target.value) {
        const cursorPos = target.selectionStart;
        const oldLen = target.value.length;
        target.value = formatted.display;
        const newLen = formatted.display.length;
        const newPos = Math.min(cursorPos + (newLen - oldLen), newLen);
        target.setSelectionRange(newPos, newPos);
      }
    }
  }

  const syncedVar = hook.store.get(fieldPath);
  syncedVar.setOptimistic(value);
  hook.setStateAtPath(fieldPath, value);
  hook.clientVersion++;

  // Optimistically clear server errors for this field
  const { formName, fieldName } = getFormField(target, fieldPath);
  if (formName && fieldName) {
    const serverErrorsField = `${formName}_server_errors`;
    const currentServerErrors = hook.state[serverErrorsField] || {};
    hook.state[serverErrorsField] = { ...currentServerErrors, [fieldName]: [] };
  }

  const dotIndex = fieldPath.indexOf(".");
  const rootField = dotIndex > 0 ? fieldPath.substring(0, dotIndex) : fieldPath;
  hook.recomputeDerives([rootField]);
  hook.updateDOM();
  hook.syncUrl();

  // Debounced server validation
  if (formName && fieldName) {
    const touched = hook.fieldState[fieldPath]?.touched || false;
    if (touched || isFormSubmitted(hook.submittedForms, formName)) {
      triggerServerValidation(hook, fieldPath, formName, fieldName, false, target);
    }
  }
}

/**
 * Initialize form params from DOM values for prepopulated/default fields.
 */
export function initializeFormParamsFromDOM(hook) {
  const boundInputs = hook.el.querySelectorAll("[data-lavash-bind]");
  let initialized = false;

  boundInputs.forEach(input => {
    const fieldPath = input.dataset.lavashBind;
    if (isInsideChildHook(input, hook.el)) return;
    if (isInsideHiddenContainer(input, hook.el)) return;
    if (!fieldPath || !fieldPath.includes("_params.")) return;

    const dotIndex = fieldPath.indexOf(".");
    if (dotIndex === -1) return;

    const paramsField = fieldPath.substring(0, dotIndex);
    const field = fieldPath.substring(dotIndex + 1);

    if (hook._clearedParamsFields && hook._clearedParamsFields.has(paramsField)) return;

    const currentValue = input.value;
    if (currentValue != null && currentValue !== "") {
      hook.state[paramsField] = hook.state[paramsField] || {};
      if (hook.state[paramsField][field] === undefined) {
        hook.state[paramsField][field] = currentValue;
        initialized = true;
      }
    }
  });

  if (initialized) {
    hook.recomputeDerives();
  }
}
