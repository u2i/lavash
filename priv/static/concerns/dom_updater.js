/**
 * DOM update logic for optimistic state rendering.
 *
 * Reads from the hook's state and updates DOM elements with data-lavash-*
 * attributes: display, visible, enabled, toggle, class, errors, status,
 * input validation styling.
 */
import { isInsideChildHook, humanizeFieldName } from "./utils.js";

/**
 * Select elements matching a selector within rootEl, excluding those
 * inside nested child hooks (which have their own LavashOptimistic instance).
 */
function selectOwn(rootEl, selector) {
  const results = [];
  for (const el of rootEl.querySelectorAll(selector)) {
    if (!isInsideChildHook(el, rootEl)) results.push(el);
  }
  return results;
}

/**
 * Update all data-lavash-* DOM elements from current state.
 *
 * @param {HTMLElement} rootEl - The hook root element
 * @param {Object} state - Current state object
 * @param {Object} opts - { getFormField, isFormSubmitted, isOptimistic }
 */
// Phoenix class-list semantics for a transpiled class value: flatten,
// drop everything that isn't a non-empty string, space-join.
function normalizeClassValue(value) {
  if (Array.isArray(value)) {
    return value
      .flat(Infinity)
      .filter((v) => typeof v === "string" && v !== "")
      .join(" ");
  }
  return value == null ? "" : value;
}

export function updateDOM(rootEl, state, opts) {
  const { getFormField, isFormSubmitted } = opts;

  // data-lavash-display: text content from state
  for (const el of selectOwn(rootEl, "[data-lavash-display]")) {
    const value = state[el.dataset.lavashDisplay];
    if (value !== undefined) el.textContent = value;
  }

  // data-lavash-visible: show/hide based on boolean state
  for (const el of selectOwn(rootEl, "[data-lavash-visible]")) {
    if (state[el.dataset.lavashVisible]) {
      el.classList.remove("hidden");
    } else {
      el.classList.add("hidden");
    }
  }

  // data-lavash-enabled: enable/disable based on boolean state.
  // The disabled PROPERTY only — visual disabled styling belongs to
  // the author's class expression (reactive attribute derives handle
  // it), never to design-system class names hardcoded in core (#126).
  for (const el of selectOwn(rootEl, "[data-lavash-enabled]")) {
    el.disabled = state[el.dataset.lavashEnabled] !== true;
  }

  // data-lavash-toggle: toggle classes based on boolean
  // Format: "fieldName|trueClasses|falseClasses"
  for (const el of selectOwn(rootEl, "[data-lavash-toggle]")) {
    const [fieldName, trueClasses, falseClasses] = el.dataset.lavashToggle.split("|");
    const value = state[fieldName];
    const allClasses = (trueClasses + " " + falseClasses).split(/\s+/).filter(c => c);
    el.classList.remove(...allClasses);
    const classesToAdd = (value ? trueClasses : falseClasses).split(/\s+/).filter(c => c);
    el.classList.add(...classesToAdd);
  }

  // data-lavash-member: toggle classes based on array membership
  // Format: "arrayField|trueClasses|falseClasses"
  // Value to check comes from phx-value-val or data-lavash-member-value
  for (const el of selectOwn(rootEl, "[data-lavash-member]")) {
    const [fieldName, trueClasses, falseClasses] = el.dataset.lavashMember.split("|");
    const arr = state[fieldName] || [];
    const val = el.getAttribute("phx-value-val") || el.dataset.lavashMemberValue;
    const isMember = Array.isArray(arr) && arr.includes(val);
    const allClasses = (trueClasses + " " + falseClasses).split(/\s+/).filter(c => c);
    el.classList.remove(...allClasses);
    const classesToAdd = (isMember ? trueClasses : falseClasses).split(/\s+/).filter(c => c);
    el.classList.add(...classesToAdd);
  }

  // data-lavash-attr-disabled: set disabled from reactive derive
  for (const el of selectOwn(rootEl, "[data-lavash-attr-disabled]")) {
    const value = state[el.dataset.lavashAttrDisabled];
    if (value !== undefined) el.disabled = !!value;
  }

  // data-lavash-attr-class: set full className from reactive derive.
  // List-form class expressions (`class={["static", if(@x, ...)]}`)
  // transpile to JS arrays — normalize with Phoenix's class-list
  // semantics (flatten, drop nil/false, space-join) instead of
  // letting `el.className = array` comma-join and break every class.
  for (const el of selectOwn(rootEl, "[data-lavash-attr-class]")) {
    const value = state[el.dataset.lavashAttrClass];
    if (value !== undefined) el.className = normalizeClassValue(value);
  }

  // data-lavash-attr-hidden: set hidden from reactive derive
  for (const el of selectOwn(rootEl, "[data-lavash-attr-hidden]")) {
    const value = state[el.dataset.lavashAttrHidden];
    if (value !== undefined) el.hidden = !!value;
  }

  // data-lavash-html: render subtree from JS derive (for :if/:for over optimistic state)
  // Only applies during optimistic updates, not server patches.
  if (opts.isOptimistic) {
    for (const el of selectOwn(rootEl, "[data-lavash-html]")) {
      const html = state[el.dataset.lavashHtml];
      if (html !== undefined) {
        if (window.morphdom) {
          const temp = document.createElement(el.tagName);
          temp.innerHTML = html;
          window.morphdom(el, temp, {
            childrenOnly: true,
            onBeforeElUpdated(fromEl, toEl) {
              if (fromEl.hasAttribute('data-lavash-preserve')) return false;
              return true;
            }
          });
        } else {
          el.innerHTML = html;
        }
      }
    }
  }

  // data-lavash-errors: error messages (only shown when touched/submitted)
  for (const el of selectOwn(rootEl, "[data-lavash-errors]")) {
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
  for (const el of selectOwn(rootEl, "[data-lavash-error-summary]")) {
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
  for (const el of selectOwn(rootEl, "[data-lavash-status]")) {
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
      el.textContent = "\u2717";
      el.className = el.className.replace(/text-red-\d+/g, "").trim() + " text-red-500";
    }
  }

  // Input border colors based on validation state
  for (const input of selectOwn(rootEl, "[data-lavash-bind]")) {
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
