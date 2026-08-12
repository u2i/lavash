/**
 * Sync-state DOM annotations (issue #72).
 *
 * Optimistic UI never waits — so nothing distinguishes *applied* from
 * *confirmed* on screen. This pass derives that distinction from
 * SyncedVar state on every render and writes it into the DOM as
 * attributes for CSS to style. Nothing is toggled imperatively from
 * event handlers: annotations are recomputed from the store each
 * `hook.updateDOM()`, so a subtree re-render can never resurrect a
 * stale one.
 *
 * Three levels:
 *
 * - Hook root: `data-lavash-syncing` + `aria-busy="true"` while ANY of
 *   the hook's own vars is unresolved (pending optimistic set OR
 *   provisional append/upsert seed). Bindings propagate across hooks,
 *   so each hook reflects only its own vars; a page-level indicator
 *   can watch the whole tree with CSS `:has([data-lavash-syncing])`.
 *
 * - Field level: `data-lavash-pending` on elements bound to an
 *   unresolved field — directly, or through the derive graph (a cart
 *   total derived from a provisional projection is itself unresolved).
 *   Applies to data-lavash-display / -toggle / -member / -visible /
 *   -html elements.
 *
 * - Row level: inside a `data-lavash-html` subtree whose source field
 *   is provisional, elements carrying `data-lavash-id` matching a
 *   predicted row id get `data-lavash-provisional`. Convention: render
 *   `data-lavash-id={row.id}` on your row template to opt in — client-
 *   generated append ids make the identity stable across predict and
 *   confirm.
 *
 * Styling is the app's job. The recommended recipe delays the visible
 * affordance so fast round-trips never flash it:
 *
 *     [data-lavash-provisional] { opacity: 0.5; transition: opacity 0.15s; transition-delay: 0.2s; }
 *     .sync-dot { opacity: 0; }
 *     body:has([data-lavash-syncing]) .sync-dot { opacity: 1; transition-delay: 0.2s; }
 */
import { isInsideChildHook } from "./utils.js";

/**
 * Is `field` unresolved — itself, or through any of its derive
 * sources? (Parallel to hook.hasPendingSources, but counting
 * provisional seeds too.)
 */
export function fieldUnresolved(hook, field, seen = new Set()) {
  if (seen.has(field)) return false;
  seen.add(field);

  const unresolvedPaths = hook.store.getUnresolvedPaths();
  if (unresolvedPaths.some(p => p === field || p.startsWith(field + "."))) return true;

  const deps = hook.graph?.deps?.[field];
  if (!deps) return false;
  return deps.some(dep => fieldUnresolved(hook, dep, seen));
}

// The projection var whose provisional ids drive a subtree's row
// annotations: the subtree's own field is a derive (html string) — walk
// its sources for the var that actually holds provisional ids.
function provisionalIdsForField(hook, field, seen = new Set()) {
  if (seen.has(field)) return null;
  seen.add(field);

  const direct = hook.store.provisionalIds(field);
  if (direct && direct.size > 0) return direct;

  const deps = hook.graph?.deps?.[field];
  if (!deps) return null;
  for (const dep of deps) {
    const ids = provisionalIdsForField(hook, dep, seen);
    if (ids) return ids;
  }
  return null;
}

function selectOwn(rootEl, selector) {
  const results = [];
  for (const el of rootEl.querySelectorAll(selector)) {
    if (!isInsideChildHook(el, rootEl)) results.push(el);
  }
  return results;
}

const FIELD_ATTRS = [
  ["data-lavash-display", "lavashDisplay"],
  ["data-lavash-visible", "lavashVisible"],
  ["data-lavash-html", "lavashHtml"],
];

// data-lavash-toggle / -member pack "field|classes|classes".
const PACKED_ATTRS = [
  ["data-lavash-toggle", "lavashToggle"],
  ["data-lavash-member", "lavashMember"],
];

export function refreshSyncAnnotations(hook) {
  if (!hook.store) return;

  // ----- Stream rows (issue #71) -----
  // A predicted row resolves when the server's confirming stream op
  // morphs it (stripping data-lavash-provisional) or removes it.
  if (hook.streamRows && hook.streamRows.size > 0) {
    for (const domId of [...hook.streamRows.keys()]) {
      const el = document.getElementById(domId);
      if (!el || !el.hasAttribute("data-lavash-provisional")) {
        hook.streamRows.delete(domId);
      }
    }
  }

  // ----- Hook level -----
  if (hook.store.hasUnresolved || hook.streamRows?.size > 0) {
    hook.el.setAttribute("data-lavash-syncing", "");
    hook.el.setAttribute("aria-busy", "true");
  } else {
    hook.el.removeAttribute("data-lavash-syncing");
    hook.el.removeAttribute("aria-busy");
  }

  // ----- Field level -----
  const mark = (el, field) => {
    if (fieldUnresolved(hook, field)) {
      el.setAttribute("data-lavash-pending", "");
    } else {
      el.removeAttribute("data-lavash-pending");
    }
  };

  for (const [attr, dataKey] of FIELD_ATTRS) {
    for (const el of selectOwn(hook.el, `[${attr}]`)) {
      mark(el, el.dataset[dataKey]);
    }
  }

  for (const [attr, dataKey] of PACKED_ATTRS) {
    for (const el of selectOwn(hook.el, `[${attr}]`)) {
      mark(el, el.dataset[dataKey].split("|")[0]);
    }
  }

  // ----- Row level (provisional rows in projected subtrees) -----
  for (const container of selectOwn(hook.el, "[data-lavash-html]")) {
    const ids = provisionalIdsForField(hook, container.dataset.lavashHtml);
    for (const row of container.querySelectorAll("[data-lavash-id]")) {
      if (ids && ids.has(row.dataset.lavashId)) {
        row.setAttribute("data-lavash-provisional", "");
      } else {
        row.removeAttribute("data-lavash-provisional");
      }
    }
  }
}
