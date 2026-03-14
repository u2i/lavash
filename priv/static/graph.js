/**
 * Pure graph algorithms for dependency graphs.
 *
 * Mirrors Lavash.Graph on the Elixir side.
 * Used by LavashOptimistic for client-side reactive recomputation.
 */

/**
 * BFS to find all fields transitively affected by `changedFields`.
 *
 * @param {Object} dependents - reverse index: {field: [dependents]}
 * @param {string[]} changedFields - fields that changed
 * @returns {Set<string>} all transitively affected derived fields
 */
export function findAffected(dependents, changedFields) {
  const affected = new Set();
  const queue = [...changedFields];

  while (queue.length > 0) {
    const field = queue.shift();
    const direct = dependents[field] || [];
    for (const dep of direct) {
      if (!affected.has(dep)) {
        affected.add(dep);
        queue.push(dep);
      }
    }
  }

  return affected;
}

/**
 * Recompute derived fields in topological order.
 *
 * When changedFields is provided, only transitively affected fields are
 * recomputed. Otherwise all derives are recomputed.
 *
 * @param {Object} graph - {topo_order: string[], deps: Object, dependents: Object}
 * @param {Object} fns - {name: (state) => value} compute functions
 * @param {Object} state - mutable state object (updated in place)
 * @param {string[]|null} changedFields - fields that changed, or null for all
 */
/**
 * Parse raw graph metadata from generated JS modules.
 *
 * @param {Object} rawGraph - raw graph from __graph__ property
 * @returns {{topo_order: string[], deps: Object, dependents: Object}}
 */
export function parseGraph(rawGraph) {
  if (!rawGraph || typeof rawGraph !== "object" || !Array.isArray(rawGraph.topo_order)) {
    return { topo_order: [], deps: {}, dependents: {} };
  }
  return rawGraph;
}

/**
 * Add a leaf derive to the graph (no other derives depend on it).
 *
 * Mutates the graph in place — adds to deps, dependents, and topo_order.
 *
 * @param {Object} graph - {topo_order, deps, dependents}
 * @param {string} name - derive field name
 * @param {string[]} fieldDeps - fields this derive depends on
 */
export function addLeafDerive(graph, name, fieldDeps) {
  if (graph.deps[name]) return; // already present

  graph.deps[name] = fieldDeps;
  for (const dep of fieldDeps) {
    if (!graph.dependents[dep]) graph.dependents[dep] = [];
    if (!graph.dependents[dep].includes(name)) graph.dependents[dep].push(name);
  }
  if (!graph.topo_order.includes(name)) graph.topo_order.push(name);
}

/**
 * Recompute derived fields in topological order.
 *
 * When changedFields is provided, only transitively affected fields are
 * recomputed. Otherwise all derives are recomputed.
 *
 * @param {Object} graph - {topo_order: string[], deps: Object, dependents: Object}
 * @param {Object} fns - {name: (state) => value} compute functions
 * @param {Object} state - mutable state object (updated in place)
 * @param {string[]|null} changedFields - fields that changed, or null for all
 */
export function recomputeGraph(graph, fns, state, changedFields = null) {
  let toRecompute;

  if (!changedFields) {
    toRecompute = graph.topo_order;
  } else {
    const affected = findAffected(graph.dependents, changedFields);
    toRecompute = graph.topo_order.filter(f => affected.has(f));
  }

  for (const name of toRecompute) {
    const fn = fns[name];
    if (fn) {
      try {
        state[name] = fn(state);
      } catch (err) {
        if (typeof console !== "undefined" && console.debug) {
          console.debug(`[Lavash] Error computing derive ${name}:`, err.message);
        }
      }
    }
  }
}
