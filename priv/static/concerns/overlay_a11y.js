/**
 * Overlay accessibility: focus management and stacking-aware Escape.
 *
 * A single module-level stack tracks every open overlay (modal or
 * flyover) across all hooks, in open order. While the stack is
 * non-empty, one capture-phase keydown listener and one focusin
 * listener are installed on the document:
 *
 *   - Escape closes ONLY the topmost overlay (and only if its chrome
 *     opts in via data-close-on-escape) by dispatching the canonical
 *     `close-panel` event. No listener exists while everything is
 *     closed.
 *   - Tab is trapped inside the topmost panel: focus cycles through
 *     its focusable elements instead of escaping to the page.
 *   - focusin pulls focus back if it lands outside the topmost panel
 *     (mouse clicks on background, programmatic focus).
 *
 * Opening saves `document.activeElement` (the trigger); closing
 * restores it — or, for nested overlays, focus falls back into the
 * overlay below via the trap.
 */

const stack = [];
let keydownListener = null;
let focusinListener = null;

const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(", ");

function focusables(panelEl) {
  return Array.from(panelEl.querySelectorAll(FOCUSABLE_SELECTOR)).filter(
    (el) => el.offsetParent !== null || el === document.activeElement
  );
}

function top() {
  return stack[stack.length - 1] || null;
}

function focusInto(panelEl) {
  // The panel may still be animating in — focus() inside a
  // visibility:hidden ancestor silently no-ops — so retry each frame
  // (rechecking for focusables as async content lands) until focus
  // sticks or the panel's overlay left the stack. Capped at ~1s.
  let attempts = 60;

  const attempt = () => {
    if (!stack.some((e) => e.panelEl === panelEl)) return;
    const target = focusables(panelEl)[0] || panelEl;
    target.focus({ preventScroll: true });

    if (document.activeElement !== target && attempts-- > 0) {
      requestAnimationFrame(attempt);
    }
  };

  requestAnimationFrame(attempt);
}

/**
 * Called when an overlay leaves idle (entering/loading). Pushes it on
 * the stack, saves the trigger's focus, and moves focus into the panel.
 */
export function overlayOpened(chromeEl, panelEl) {
  if (stack.some((e) => e.chromeEl === chromeEl)) return;

  stack.push({ chromeEl, panelEl, previousFocus: document.activeElement });
  installListeners();
  setTriggerExpanded(chromeEl, true);
  focusInto(panelEl);
}

// Keep the declared trigger's aria-expanded current through optimistic
// open/close — the server-rendered value lags the round trip.
function setTriggerExpanded(chromeEl, expanded) {
  const trigger = document.querySelector(
    `[data-lavash-overlay-trigger="${chromeEl.id}"]`
  );
  if (trigger) trigger.setAttribute("aria-expanded", String(expanded));
}

/**
 * Called at the visible phase: async overlays swap loading content for
 * real content, so ensure focus is inside the panel (it may have been
 * on a since-removed loading node).
 */
export function overlayVisible(chromeEl, panelEl) {
  const entry = top();
  if (!entry || entry.chromeEl !== chromeEl) return;
  if (!panelEl.contains(document.activeElement)) focusInto(panelEl);
}

/**
 * Called when an overlay returns to idle. Pops it (wherever it sits in
 * the stack) and restores focus to the saved trigger if it still exists.
 */
export function overlayClosed(chromeEl) {
  const idx = stack.findIndex((e) => e.chromeEl === chromeEl);
  if (idx === -1) return;

  const [entry] = stack.splice(idx, 1);
  if (stack.length === 0) removeListeners();
  setTriggerExpanded(chromeEl, false);

  const prev = entry.previousFocus;
  if (prev && document.contains(prev) && typeof prev.focus === "function") {
    prev.focus({ preventScroll: true });
  }
}

function installListeners() {
  if (keydownListener) return;

  keydownListener = (e) => {
    const entry = top();
    if (!entry) return;

    if (e.key === "Escape") {
      if (entry.chromeEl.dataset.closeOnEscape !== "false") {
        e.stopPropagation();
        e.preventDefault();
        entry.chromeEl.dispatchEvent(new CustomEvent("close-panel"));
      }
      return;
    }

    if (e.key === "Tab") {
      const items = focusables(entry.panelEl);
      if (items.length === 0) {
        // Nothing focusable: keep focus pinned on the panel itself.
        e.preventDefault();
        entry.panelEl.focus({ preventScroll: true });
        return;
      }

      const first = items[0];
      const last = items[items.length - 1];
      const current = document.activeElement;

      if (e.shiftKey && (current === first || !entry.panelEl.contains(current))) {
        e.preventDefault();
        last.focus({ preventScroll: true });
      } else if (!e.shiftKey && (current === last || !entry.panelEl.contains(current))) {
        e.preventDefault();
        first.focus({ preventScroll: true });
      }
    }
  };

  focusinListener = (e) => {
    const entry = top();
    if (!entry) return;
    if (entry.panelEl.contains(e.target)) return;
    // Ignore focus moving to another overlay's panel below the top —
    // that only happens transiently during close/restore.
    focusInto(entry.panelEl);
  };

  document.addEventListener("keydown", keydownListener, true);
  document.addEventListener("focusin", focusinListener);
}

function removeListeners() {
  if (!keydownListener) return;
  document.removeEventListener("keydown", keydownListener, true);
  document.removeEventListener("focusin", focusinListener);
  keydownListener = null;
  focusinListener = null;
}

/**
 * Drop any stack entries belonging to a destroyed hook's chrome
 * elements (LiveView navigation while an overlay is open).
 */
export function overlayDestroyed(chromeEl) {
  overlayClosed(chromeEl);
}
