/**
 * PlainCounter — hand-coded hook using Lavash client primitives.
 *
 * Demonstrates the raw API: SyncedVarStore for state sync,
 * syncStateToUrl for URL-backed fields, manual DOM updates.
 *
 * Feature parity with the DSL counter:
 * - count (URL-backed), multiplier (ephemeral)
 * - doubled (sync derive), fact (async on server, instant on client)
 * - Actions: increment, decrement, set_count, set_multiplier, reset
 */
import { SyncedVarStore } from "lavash/synced_var.js";
import { syncStateToUrl } from "lavash/url_sync.js";

// -- Pure functions: actions and derives --

function factorial(n) {
  if (n < 0) return null;
  if (n > 170) return Infinity;
  let result = 1;
  for (let i = 2; i <= n; i++) result *= i;
  return result;
}

const actions = {
  increment(state) {
    return { count: state.count + 1 };
  },
  decrement(state) {
    return { count: state.count - 1 };
  },
  set_count(state, params) {
    return { count: Number(params.value) };
  },
  set_multiplier(state, params) {
    return { multiplier: Number(params.value) };
  },
  reset() {
    return { count: 0, multiplier: 2 };
  },
};

const derives = {
  doubled(state) {
    return state.count * state.multiplier;
  },
  fact(state) {
    return factorial(Math.max(state.count, 0));
  },
};

// -- Hook --

const PlainCounter = {
  mounted() {
    this.store = new SyncedVarStore();
    this.state = JSON.parse(this.el.dataset.state);
    this.urlFields = JSON.parse(this.el.dataset.urlFields || "[]");

    // Initialize SyncedVars for each field
    for (const [key, value] of Object.entries(this.state)) {
      this.store.get(key, value);
    }

    // Wire up data-action clicks (delegated)
    this.el.addEventListener("click", (e) => {
      const actionEl = e.target.closest("[data-action]");
      if (!actionEl) return;

      const name = actionEl.dataset.action;
      const fn = actions[name];
      if (!fn) return;

      // Collect params from data-* attributes (skip data-action itself)
      const params = {};
      for (const [attr, val] of Object.entries(actionEl.dataset)) {
        if (attr !== "action") params[attr] = val;
      }

      // Apply optimistic changes
      const changes = fn(this.state, params);
      this._applyOptimistic(changes);

      // Push to server
      this.pushEvent(name, params);
    });

    // Wire up data-bind inputs (delegated)
    this.el.addEventListener("input", (e) => {
      const bindEl = e.target.closest("[data-bind]");
      if (!bindEl) return;

      const field = bindEl.dataset.bind;
      const value = Number(bindEl.value);
      this._applyOptimistic({ [field]: value });
    });

    this._updateDOM();
  },

  updated() {
    // Server sent a new render — reconcile
    const serverState = JSON.parse(this.el.dataset.state);
    this.store.serverUpdate(serverState);
    this.state = this.store.toState();
    this._recomputeDerives();
    this._updateDOM();
  },

  _applyOptimistic(changes) {
    for (const [key, value] of Object.entries(changes)) {
      this.store.get(key).setOptimistic(value);
      this.state[key] = value;
    }

    this._recomputeDerives();
    syncStateToUrl(this.urlFields, this.state);
    this._updateDOM();
  },

  _recomputeDerives() {
    for (const [name, fn] of Object.entries(derives)) {
      const value = fn(this.state);
      this.state[name] = value;
      // Update the SyncedVar too so server reconciliation works
      const sv = this.store.get(name);
      sv.value = value;
      sv.confirmedValue = value;
    }
  },

  _updateDOM() {
    // Update data-display elements
    for (const el of this.el.querySelectorAll("[data-display]")) {
      const field = el.dataset.display;
      if (!(field in this.state)) continue;

      const value = this.state[field];

      // Special handling: if server is loading, skip client update
      // (let server-rendered loading state show through)
      if (field === "fact" && this.state.fact_loading) continue;

      el.textContent = value ?? "?";
    }

    // Update data-bind inputs (skip focused element)
    for (const el of this.el.querySelectorAll("[data-bind]")) {
      const field = el.dataset.bind;
      if (field in this.state && el !== document.activeElement) {
        el.value = this.state[field];
      }
    }
  },
};

export default PlainCounter;
