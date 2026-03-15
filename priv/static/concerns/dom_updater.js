/**
 * DOM update logic for optimistic state rendering.
 *
 * Reads from the hook's state and updates DOM elements with data-lavash-*
 * attributes: display, visible, enabled, toggle, class, errors, status,
 * input validation styling.
 */
import { isInsideChildHook, humanizeFieldName } from "./utils.js";

/**
 * Update all data-lavash-* DOM elements from current state.
 *
 * @param {HTMLElement} rootEl - The hook root element
 * @param {Object} state - Current state object
 * @param {Object} opts - { getFormField, isFormSubmitted }
 */
export function updateDOM(rootEl, state, opts) {
  const { getFormField, isFormSubmitted } = opts;

  // data-lavash-display: text content from state
  for (const el of rootEl.querySelectorAll("[data-lavash-display]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const fieldName = el.dataset.lavashDisplay;
    const value = state[fieldName];
    if (value !== undefined) {
      el.textContent = value;
    }
  }

  // data-lavash-visible: show/hide based on boolean state
  for (const el of rootEl.querySelectorAll("[data-lavash-visible]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const fieldName = el.dataset.lavashVisible;
    const value = state[fieldName];
    if (value) {
      el.classList.remove("hidden");
    } else {
      el.classList.add("hidden");
    }
  }

  // data-lavash-enabled: enable/disable based on boolean state
  for (const el of rootEl.querySelectorAll("[data-lavash-enabled]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const fieldName = el.dataset.lavashEnabled;
    const value = state[fieldName];
    const enabled = value === true;
    el.disabled = !enabled;
    if (enabled) {
      el.classList.remove('btn-disabled', 'opacity-60', 'cursor-not-allowed');
    } else {
      el.classList.add('opacity-60', 'cursor-not-allowed');
    }
  }

  // data-lavash-toggle: toggle classes based on boolean
  // Format: "fieldName|trueClasses|falseClasses"
  for (const el of rootEl.querySelectorAll("[data-lavash-toggle]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const spec = el.dataset.lavashToggle;
    const [fieldName, trueClasses, falseClasses] = spec.split("|");
    const value = state[fieldName];
    const allClasses = (trueClasses + " " + falseClasses).split(/\s+/).filter(c => c);
    el.classList.remove(...allClasses);
    const classesToAdd = (value ? trueClasses : falseClasses).split(/\s+/).filter(c => c);
    el.classList.add(...classesToAdd);
  }

  // data-lavash-class: apply class from state map
  // Format: "roast_chips.light" means state.roast_chips["light"]
  for (const el of rootEl.querySelectorAll("[data-lavash-class]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const path = el.dataset.lavashClass;
    const [field, key] = path.split(".");
    const classMap = state[field];
    if (classMap && key && classMap[key]) {
      el.className = classMap[key];
    } else if (classMap && !key) {
      el.className = classMap;
    }
  }

  // data-lavash-errors: error messages (only shown when touched/submitted)
  for (const el of rootEl.querySelectorAll("[data-lavash-errors]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const errorsField = el.dataset.lavashErrors;
    const allErrors = state[errorsField] || [];

    const explicitForm = el.dataset.lavashForm;
    const explicitField = el.dataset.lavashField;

    let formName, fieldName;
    if (explicitForm && explicitField) {
      formName = explicitForm;
      fieldName = explicitField;
    } else {
      const match = errorsField.match(/^(.+)_(.+)_errors$/);
      if (match) {
        [, formName, fieldName] = match;
      }
    }

    const showErrorsField = el.dataset.lavashShowErrors || `${formName}_${fieldName}_show_errors`;
    const showErrors = state[showErrorsField] ?? false;
    const willBeVisible = showErrors && allErrors.length > 0;

    el.innerHTML = "";
    if (willBeVisible) {
      allErrors.forEach(error => {
        const p = document.createElement("p");
        p.className = "text-error text-sm";
        p.textContent = error;
        el.appendChild(p);
      });
      el.classList.remove("hidden");
    } else {
      el.classList.add("hidden");
    }
  }

  // data-lavash-error-summary: form-level error summary
  for (const el of rootEl.querySelectorAll("[data-lavash-error-summary]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const formName = el.dataset.lavashErrorSummary;

    if (!isFormSubmitted(formName)) {
      el.classList.add("hidden");
      el.innerHTML = "";
      continue;
    }

    const allErrors = [];
    for (const key of Object.keys(state)) {
      if (key.startsWith(`${formName}_`) && key.endsWith("_errors")) {
        const fieldErrors = state[key] || [];
        const fName = key.replace(`${formName}_`, "").replace(/_errors$/, "");
        if (fieldErrors.length > 0) {
          allErrors.push({ field: fName, errors: fieldErrors });
        }
      }
    }

    el.innerHTML = "";
    if (allErrors.length > 0) {
      const title = document.createElement("p");
      title.className = "font-semibold text-red-700 mb-2";
      title.textContent = "Please fix the following errors:";
      el.appendChild(title);

      const ul = document.createElement("ul");
      ul.className = "list-disc list-inside space-y-1";
      for (const { field, errors } of allErrors) {
        for (const error of errors) {
          const li = document.createElement("li");
          li.textContent = `${humanizeFieldName(field)}: ${error}`;
          ul.appendChild(li);
        }
      }
      el.appendChild(ul);
      el.classList.remove("hidden");
    } else {
      el.classList.add("hidden");
    }
  }

  // data-lavash-status: field status indicator
  for (const el of rootEl.querySelectorAll("[data-lavash-status]")) {
    if (isInsideChildHook(el, rootEl)) continue;
    const validField = el.dataset.lavashStatus;
    const explicitForm = el.dataset.lavashForm;
    const explicitField = el.dataset.lavashField;

    const showErrorsField = el.dataset.lavashShowErrors ||
      (explicitForm && explicitField ? `${explicitForm}_${explicitField}_show_errors` : validField.replace(/_valid$/, "_show_errors"));

    const isValid = state[validField] ?? true;
    const showErrors = state[showErrorsField] ?? false;
    const errorsField = validField.replace(/_valid$/, "_errors");
    const hasErrors = (state[errorsField] || []).length > 0;

    if (!showErrors || (isValid && !hasErrors)) {
      el.textContent = "";
      el.className = el.className.replace(/text-red-\d+/g, "").trim();
    } else {
      el.textContent = "✗";
      el.className = el.className.replace(/text-red-\d+/g, "").trim() + " text-red-500";
    }
  }

  // Input border colors based on validation state
  for (const input of rootEl.querySelectorAll("[data-lavash-bind]")) {
    if (isInsideChildHook(input, rootEl)) continue;
    const fieldPath = input.dataset.lavashBind;
    const { formName, fieldName } = getFormField(input, fieldPath);
    if (!formName || !fieldName) continue;

    const showErrorsField = `${formName}_${fieldName}_show_errors`;
    const showErrors = state[showErrorsField] ?? false;
    const customValidField = input.dataset.lavashValid;
    const validField = customValidField || `${formName}_${fieldName}_valid`;
    const isValid = state[validField] ?? true;
    const errorsField = `${formName}_${fieldName}_errors`;
    const hasErrors = (state[errorsField] || []).length > 0;

    const errorClass = input.tagName === "SELECT" ? "select-error" : "input-error";
    const validationClasses = [
      "input-error", "select-error",
      "border-gray-300", "border-red-300",
      "focus:ring-blue-500", "focus:ring-red-500"
    ];
    validationClasses.forEach(c => input.classList.remove(c));

    if (showErrors && (!isValid || hasErrors)) {
      input.classList.add(errorClass);
    }
  }
}

/**
 * Notify child hooks to refresh from parent state.
 */
export function notifyChildren(rootEl, parentHook) {
  const children = rootEl.querySelectorAll("[phx-hook]");
  children.forEach(el => {
    const hook = el.__lavash_hook__;
    if (hook?.refreshFromParent) {
      hook.refreshFromParent(parentHook);
    }
  });
}
