/**
 * Function loading for optimistic actions and derives.
 *
 * Loads auto-generated functions from the window registry (populated by
 * colocated JS imports), executes inline component scripts, and merges
 * dynamically registered functions.
 */
import { parseGraph, addLeafDerive } from "../graph.js";

/**
 * Load generated functions for a module from the global registry.
 *
 * @param {string|null} moduleName - The module name for lookup
 * @param {HTMLElement} el - The hook root element (for component scripts)
 * @returns {{ fns: Object, deriveNames: string[], graph: Object }}
 */
export function loadGeneratedFunctions(moduleName, el) {
  const fnObj = moduleName ? (window.Lavash.optimistic[moduleName] || {}) : {};

  let fns = fnObj;
  let deriveNames = fnObj.__derives__ || [];
  let graph = parseGraph(fnObj.__graph__);

  // Execute component-generated optimistic scripts
  const scripts = el.querySelectorAll('script[id$="-optimistic"]');
  scripts.forEach(script => {
    if (script.id === "lavash-optimistic-fns") return;
    try {
      new Function(script.textContent)();
    } catch (e) {
      console.error(`[LavashOptimistic] Error executing component script ${script.id}:`, e);
    }
  });

  // Merge any dynamically registered functions
  if (moduleName) {
    const moduleFns = window.Lavash.optimistic[moduleName];
    if (moduleFns) {
      for (const [name, fn] of Object.entries(moduleFns)) {
        if (typeof fn === 'function' && !fns[name]) {
          fns[name] = fn;
        }
      }
      if (moduleFns.__derives__) {
        for (const d of moduleFns.__derives__) {
          if (!deriveNames.includes(d)) {
            deriveNames.push(d);
          }
          if (!graph.deps[d]) {
            const match = d.match(/^(.+)_chips?$/);
            if (match) {
              addLeafDerive(graph, d, [match[1]]);
            }
          }
        }
      }
    }
  }

  // Merge custom registered functions (overrides)
  const customFns = moduleName ? (window.Lavash.optimistic[moduleName] || {}) : {};
  fns = { ...fns, ...customFns };

  if (!deriveNames || deriveNames.length === 0) {
    deriveNames = Object.keys(fns).filter(k =>
      k.endsWith("_chips") || k.endsWith("_chip") || k === "doubled" || k === "fact"
    );
  }

  return { fns, deriveNames, graph };
}
