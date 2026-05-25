/**
 * Merge walker — visitor-based replacement for the inline
 * `mergeServerState` method on the old LavashOptimistic hook.
 *
 * Recursively walks an incoming server payload and merges values into
 * `hook.state`, skipping paths the client has pending and consulting
 * concern-registered visitors at decision points.
 *
 * ## Visitor protocol
 *
 * Concerns can register `mergeVisitors` keyed by pattern name:
 *
 *   - `animatedPhaseField(hook, ctx, { key }) → bool`
 *       Called at every top-level key. Return true to skip the key
 *       entirely (e.g. animated `_phase` fields managed by the
 *       client-side phase machine).
 *
 *   - `serverErrors(hook, ctx, { key, path, formName, hasPendingChild }) → bool`
 *       Called when prefix ends with `_server_errors`. Return true to
 *       FORCE-SKIP the merge for this specific child (used when the
 *       corresponding `_params` field is pending).
 *
 *   - `emptyParams(hook, ctx, { key, path, formName, hasPendingChild })`
 *       Called when we hit `{form}_params: {}` at the top level. Free
 *       to mutate ctx, mutate the store, mutate hook.fieldState. The
 *       walker itself doesn't decide what cleanup to do — it just
 *       fires this event.
 *
 *   - `skipServerErrorClear(hook, ctx, { key, formName }) → bool`
 *       Called when we hit `{form}_server_errors: {}` at the top
 *       level. Return true to skip the clear (e.g. because the form
 *       has pending params).
 *
 *   - `paramsCleared(hook, ctx, { key, path })`
 *       Called when an empty `_params` object actually replaces a
 *       non-empty client object (i.e. the form is being reset).
 *       Forms uses this to clear DOM input values.
 *
 * Walker behaviour is otherwise straightforward: copy server values
 * to hook.state at any path not covered by a pending entry or visitor.
 */

/**
 * Top-level entry point. Walks the server payload and mutates
 * `hook.state` + `ctx.changedFields` as side effects.
 */
export function runMergeWalker(hook, ctx) {
  // Build the animated-phase-field skip set ONCE per cycle by polling
  // visitors. Concerns return the keys they own.
  ctx.animatedPhaseFields = ctx.animatedPhaseFields || new Set();

  walkLevel(hook, ctx, ctx.serverState, "");
}

function walkLevel(hook, ctx, obj, prefix) {
  for (const [key, value] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${key}` : key;
    const topLevelField = prefix ? prefix.split(".")[0] : key;

    // Animated-phase-field skip (overlays visitor).
    if (!prefix && visitorReturnsTrue(ctx, "animatedPhaseField", hook, { key })) {
      continue;
    }

    // Check if this path or any descendant is pending in the store.
    let hasPendingChild = pathOrChildPending(ctx.pendingPaths, path);

    // Server-errors-while-params-pending skip (forms visitor).
    if (prefix && prefix.endsWith("_server_errors")) {
      const formName = prefix.replace(/_server_errors$/, "");
      if (visitorReturnsTrue(ctx, "serverErrors", hook, { key, path, formName, hasPendingChild })) {
        hasPendingChild = true;
      }
    }

    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      if (Object.keys(value).length === 0) {
        handleEmptyObject(hook, ctx, { key, path, topLevelField, hasPendingChild, prefix });
      } else {
        walkLevel(hook, ctx, value, path);
      }
    } else if (!hasPendingChild) {
      // Leaf — overwrite local if changed.
      const oldValue = hook.getStateAtPath(path);
      if (oldValue !== value) {
        hook.setStateAtPath(path, value);
        if (!ctx.changedFields.includes(topLevelField)) {
          ctx.changedFields.push(topLevelField);
        }
      }
    }
  }
}

function handleEmptyObject(hook, ctx, { key, path, topLevelField, hasPendingChild, prefix }) {
  // ----- Special case: top-level {form}_params: {} -----
  if (key.endsWith("_params") && prefix === "") {
    const formName = key.replace(/_params$/, "");

    // Fire emptyParams visitor. The visitor may clear pending paths
    // and ctx-tracked fieldState; it mutates hook + ctx + pendingPaths.
    // After it runs we re-derive hasPendingChild — visitor may have
    // cleared it.
    runVisitors(ctx, "emptyParams", hook, {
      key, path, formName, hasPendingChild
    });

    // Visitor may have cleared pending paths. Re-check.
    hasPendingChild = pathOrChildPending(ctx.pendingPaths, path);
  }

  // ----- Special case: top-level {form}_server_errors: {} -----
  let shouldSkipClear = false;
  if (key.endsWith("_server_errors") && prefix === "") {
    const formName = key.replace(/_server_errors$/, "");
    if (visitorReturnsTrue(ctx, "skipServerErrorClear", hook, { key, formName })) {
      shouldSkipClear = true;
    }
  }

  // ----- General empty-object handling -----
  if (!shouldSkipClear && !hasPendingChild) {
    const oldValue = hook.getStateAtPath(path);
    const isNonEmptyObject =
      oldValue !== undefined && oldValue !== null &&
      typeof oldValue === "object" && Object.keys(oldValue).length > 0;

    if (isNonEmptyObject) {
      hook.setStateAtPath(path, {});
      if (!ctx.changedFields.includes(topLevelField)) {
        ctx.changedFields.push(topLevelField);
      }

      // Fire paramsCleared visitor IF this was a _params field actually
      // being reset (not just observed empty).
      if (key.endsWith("_params") && prefix === "") {
        ctx.clearedParamsFields.add(key);
        runVisitors(ctx, "paramsCleared", hook, { key, path });
      }
    }
  }
}

// ----- Helpers -----

function pathOrChildPending(pendingPaths, path) {
  for (const p of pendingPaths) {
    if (p === path || p.startsWith(path + ".")) return true;
  }
  return false;
}

function runVisitors(ctx, visitorName, hook, args) {
  for (const concern of ctx.concerns) {
    const visitor = concern.mergeVisitors?.[visitorName];
    if (visitor) visitor(hook, ctx, args);
  }
}

function visitorReturnsTrue(ctx, visitorName, hook, args) {
  for (const concern of ctx.concerns) {
    const visitor = concern.mergeVisitors?.[visitorName];
    if (visitor && visitor(hook, ctx, args)) return true;
  }
  return false;
}
