/**
 * Shared utility functions used across multiple concerns.
 * Pure functions with no shared state dependencies.
 */

/**
 * Set a value in a state object at a dotted path.
 * Creates intermediate objects as needed.
 */
export function setStateAtPath(state, path, value) {
  const parts = path.split(".");
  if (parts.length === 1) {
    state[path] = value;
    return;
  }
  let current = state;
  for (let i = 0; i < parts.length - 1; i++) {
    const part = parts[i];
    if (!(part in current) || typeof current[part] !== "object") {
      current[part] = {};
    }
    current = current[part];
  }
  current[parts[parts.length - 1]] = value;
}

/**
 * Get a value from a state object at a dotted path.
 */
export function getStateAtPath(state, path) {
  const parts = path.split(".");
  let current = state;
  for (const part of parts) {
    if (current == null || typeof current !== "object") return undefined;
    current = current[part];
  }
  return current;
}

/**
 * Check if an element is inside a nested child hook (e.g., a child lavash component).
 * We should not manipulate elements inside child hooks — they manage their own state.
 */
export function isInsideChildHook(el, rootEl) {
  let parent = el.parentElement;
  while (parent && parent !== rootEl) {
    if (parent.hasAttribute("phx-hook") && parent !== rootEl) {
      return true;
    }
    parent = parent.parentElement;
  }
  return false;
}

/**
 * Check if an element is inside a hidden container (e.g., closed modal content).
 * Prevents reading stale DOM values from hidden form elements.
 */
export function isInsideHiddenContainer(el, rootEl) {
  let parent = el.parentElement;
  while (parent && parent !== rootEl) {
    if (parent.classList && parent.classList.contains("hidden")) {
      return true;
    }
    if (parent.style) {
      if (parent.style.display === "none" || parent.style.visibility === "hidden") {
        return true;
      }
    }
    parent = parent.parentElement;
  }
  return false;
}

/**
 * Convert snake_case field name to Title Case.
 */
export function humanizeFieldName(name) {
  return name
    .split("_")
    .map(word => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

/**
 * Format an input value based on the format type.
 * Returns { value, display } or null if no formatting needed.
 */
export function formatInputValue(rawValue, format) {
  switch (format) {
    case "credit-card": {
      const digits = rawValue.replace(/\D/g, "");
      const limited = digits.slice(0, 16);
      const display = limited.match(/.{1,4}/g)?.join(" ") || "";
      return { value: display, display };
    }
    case "expiry": {
      const digits = rawValue.replace(/\D/g, "");
      const limited = digits.slice(0, 4);
      let display;
      if (limited.length <= 2) {
        display = limited;
      } else {
        display = limited.slice(0, 2) + "/" + limited.slice(2);
      }
      return { value: display, display };
    }
    default:
      return null;
  }
}
