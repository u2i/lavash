/**
 * Global onBeforeElUpdated callback for morphdom interception.
 *
 * Installs once globally on the LiveSocket. Cross-cuts multiple concerns:
 * - Input preservation (form): preserve pending input values during patches
 * - Display preservation (DOM): keep client-computed display/visible/enabled during stale patches
 * - Overlay preservation (overlay): prevent stale server closes from removing modal content
 *
 * Each concern is accessed via the hook instance found on the closest hook root element.
 */

import { debugEnabled } from "../debug.js";

let installed = false;

/**
 * Install the global DOM callback on the given liveSocket.
 * Idempotent — only installs once across all hook instances.
 */
export function installGlobalDomCallback(liveSocket) {
  if (installed) return;
  installed = true;

  const original = liveSocket.domCallbacks.onBeforeElUpdated;
  liveSocket.domCallbacks.onBeforeElUpdated = (fromEl, toEl) => {
    // --- Form input preservation ---
    // Preserve input values for form fields with data-lavash-bind
    if (fromEl.hasAttribute && fromEl.hasAttribute("data-lavash-bind")) {
      // Skip updating a focused select/input — user is actively interacting
      if (fromEl === document.activeElement) {
        return false;
      }

      const fieldPath = fromEl.getAttribute("data-lavash-bind");
      const hookEl = fromEl.closest("[phx-hook='LavashOptimistic']");
      const hook = hookEl?.__lavash_hook__;

      if (hook && hook.store && hook.store.isPending(fieldPath)) {
        const pendingValue = hook.store.getValue(fieldPath);
        if (pendingValue !== undefined) {
          toEl.value = pendingValue;
        }
      }

      // For inputs inside child LiveComponents, preserve DOM value over server value
      if (fromEl.value !== toEl.value) {
        const isInsideChildComponent = fromEl.closest("[data-phx-component]") !== null;
        if (isInsideChildComponent) {
          toEl.value = fromEl.value;
        }
      }
    }

    // --- Display preservation during stale patches ---
    // Apply client state to elements when server data is stale
    const hookEl = fromEl.closest("[phx-hook='LavashOptimistic']");
    const hook = hookEl?.__lavash_hook__;

    if (hook && hook.hasPendingSources && hook.state) {
      const fieldName = fromEl.getAttribute('data-lavash-enabled');
      if (fieldName && hook.fns[fieldName]) {
        const enabled = hook.state[fieldName] === true;
        toEl.disabled = !enabled;
        if (enabled) {
          toEl.classList.remove('btn-disabled', 'opacity-60', 'cursor-not-allowed');
        } else {
          toEl.classList.add('opacity-60', 'cursor-not-allowed');
        }
        if (debugEnabled()) console.debug(`[LavashOptimistic] onBeforeElUpdated: Applied client state for data-lavash-enabled="${fieldName}" (enabled=${enabled})`);
      }

      const visibleField = fromEl.getAttribute('data-lavash-visible');
      if (visibleField && hook.hasPendingSources(visibleField)) {
        const visible = hook.state[visibleField];
        if (visible) {
          toEl.classList.remove('hidden');
        } else {
          toEl.classList.add('hidden');
        }
        if (debugEnabled()) console.debug(`[LavashOptimistic] onBeforeElUpdated: Applied client state for data-lavash-visible="${visibleField}" (visible=${visible})`);
      }

      const displayField = fromEl.getAttribute('data-lavash-display');
      if (displayField && hook.hasPendingSources(displayField)) {
        toEl.textContent = hook.state[displayField] ?? '';
        if (debugEnabled()) console.debug(`[LavashOptimistic] onBeforeElUpdated: Applied client state for data-lavash-display="${displayField}"`);
      }

      const memberSpec = fromEl.getAttribute('data-lavash-member');
      if (memberSpec) {
        const [fieldName, trueClasses, falseClasses] = memberSpec.split("|");
        // Check if the array field itself has a pending optimistic value
        if (hook.store && hook.store.isPending(fieldName)) {
          const arr = hook.state[fieldName] || [];
          const val = fromEl.getAttribute("phx-value-val") || fromEl.dataset.lavashMemberValue;
          const isMember = Array.isArray(arr) && arr.includes(val);
          const allClasses = (trueClasses + " " + falseClasses).split(/\s+/).filter(c => c);
          allClasses.forEach(c => toEl.classList.remove(c));
          const classesToAdd = (isMember ? trueClasses : falseClasses).split(/\s+/).filter(c => c);
          classesToAdd.forEach(c => toEl.classList.add(c));
        }
      }

      const errorsField = fromEl.getAttribute('data-lavash-errors');
      if (errorsField && hook.hasPendingSources(errorsField)) {
        toEl.innerHTML = fromEl.innerHTML;
        toEl.className = fromEl.className;
        if (debugEnabled()) console.debug(`[LavashOptimistic] onBeforeElUpdated: Preserved DOM for data-lavash-errors="${errorsField}" (stale)`);
      }
    }

    // --- Overlay content preservation ---
    // Check if any registered overlay cares about this element
    const registry = window.__lavashModalContentRegistry || {};
    const entry = registry[fromEl.id];

    if (entry) {
      const { hook: overlayHook, field, innerId } = entry;
      const anim = overlayHook.animatedStates?.[field];

      if (anim) {
        const sv = overlayHook.store.get(field);
        const phase = sv.getPhase();
        const shouldPreserve = phase === "entering" || phase === "loading" || phase === "visible";

        if (shouldPreserve) {
          const fromHasInner = fromEl.querySelector(`#${innerId}`);
          const toHasInner = toEl.querySelector(`#${innerId}`);

          if (fromHasInner && !toHasInner) {
            if (debugEnabled()) console.debug(`[lavash:dom] preserving content for ${field} (phase=${phase}, stale server close)`);
            return false;
          }

          if (debugEnabled()) console.debug(`[lavash:dom] overlay ${field} (phase=${phase}): fromHasInner=${!!fromHasInner}, toHasInner=${!!toHasInner} → allowing update`);
        }
      }
    }

    // Call original callback
    if (original) {
      return original(fromEl, toEl);
    }
  };
}
