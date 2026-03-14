/**
 * ClientComponent hook factory.
 *
 * Extracts the shared lifecycle, event handling, and DOM update logic
 * so that generated hooks only provide the component-specific parts:
 * fns, graph, render, validateAction, applyOptimisticAction.
 */

import { ReactiveStore } from "./reactive_store.js";

function humanize(value) {
  return String(value).replace(/_/g, ' ').replace(/^\w/, c => c.toUpperCase());
}

/**
 * Create a Phoenix LiveView hook for a ClientComponent.
 *
 * @param {Object} opts
 * @param {Object} opts.fns - { name: (state) => value } compute functions
 * @param {Object} opts.graph - { topo_order, deps, dependents }
 * @param {Function} opts.render - (state) => HTML string
 * @param {Function} opts.validateAction - (action, field, value, arg, state) => boolean
 * @param {Function} opts.applyOptimisticAction - (action, field, value, arg, state) => void
 */
export function createClientComponentHook({ fns = {}, graph = {}, render, validateAction, applyOptimisticAction }) {
  return {
    mounted() {
      const initialState = JSON.parse(this.el.dataset.lavashState || "{}");
      this.bindings = JSON.parse(this.el.dataset.lavashBindings || "{}");

      this.rstore = new ReactiveStore({
        initialState, graph, fns,
        onChange: () => this._updateDOM()
      });
      this.state = this.rstore.state;
      this._render = render;
      this._validateAction = validateAction;
      this._applyOptimisticAction = applyOptimisticAction;

      this._clickHandler = this._handleClick.bind(this);
      this._keydownHandler = this._handleKeydown.bind(this);
      this._inputHandler = this._handleInput.bind(this);
      this.el.addEventListener("click", this._clickHandler, true);
      this.el.addEventListener("keydown", this._keydownHandler, true);
      this.el.addEventListener("input", this._inputHandler, true);
      this.el.__lavash_hook__ = this;

      this.rstore.recompute();
      this._updateDOM();
    },

    updated() {
      if (this.rstore.getPendingPaths().length === 0) {
        const serverState = JSON.parse(this.el.dataset.lavashState || "{}");
        this.rstore.serverUpdate(serverState);
        this.rstore.recompute();
      }
    },

    _updateDOM() {
      const newHtml = this._render(this.state);
      const temp = document.createElement('div');
      temp.innerHTML = newHtml;
      if (temp.firstElementChild && window.morphdom) {
        const currentChild = this.el.firstElementChild;
        const newChild = temp.firstElementChild;
        if (currentChild && newChild) {
          window.morphdom(currentChild, newChild, {
            onBeforeElUpdated(fromEl, toEl) {
              if (fromEl.hasAttribute('data-lavash-preserve')) {
                return false;
              }
              return true;
            }
          });
        } else {
          this.el.innerHTML = newHtml;
        }
      } else {
        this.el.innerHTML = newHtml;
      }
    },

    _handleInput(e) {
      const target = e.target.closest("[data-lavash-state-field]");
      if (target) {
        e.stopPropagation();
      }
    },

    _handleKeydown(e) {
      if (e.key !== "Enter") return;
      const input = e.target;
      const action = input.dataset.lavashAction;
      const field = input.dataset.lavashStateField;
      if (action !== "add" || !field) return;

      e.preventDefault();
      e.stopPropagation();
      const value = input.value.trim();
      if (!value) return;

      if (!this._validateAction(action, field, value, undefined, this.state)) return;

      this._applyOptimisticAction(action, field, value, undefined, this.state);
      this.rstore.recompute([field]);
      this._updateDOM();
      this._syncParentUrl();

      const newInput = this.el.querySelector(`[data-lavash-action="add"][data-lavash-state-field="${field}"]`);
      if (newInput) newInput.value = "";

      const phxEvent = `${action}_${field.replace(/s$/, '')}`;
      this.pushEventTo(this.el, phxEvent, { val: value }, () => {
        this.rstore.clearPending(field);
      });
    },

    _handleClick(e) {
      const target = e.target.closest("[data-lavash-action]");
      if (!target) return;

      const action = target.dataset.lavashAction;
      const field = target.dataset.lavashStateField;
      const value = target.dataset.lavashValue;

      if (action === "add" && !value) return;

      e.stopPropagation();

      if (!this._validateAction(action, field, value, undefined, this.state)) return;

      this._applyOptimisticAction(action, field, value, undefined, this.state);
      this.rstore._bumpVersion(field);
      this.rstore.recompute([field]);
      this._updateDOM();

      // Check if this field is bound to a parent
      const parentField = this.bindings[field];
      if (parentField) {
        const newValue = this.state[field];
        this.el.dispatchEvent(new CustomEvent('lavash-set', {
          bubbles: true,
          detail: { field: parentField, value: newValue }
        }));
        this.rstore.clearPending(field);
        return;
      }

      // Not bound - sync to LiveView root and push event
      this._syncParentUrl();

      const phxEvent = target.dataset.phxClick || `${action}_${field.replace(/s$/, '')}`;
      this.pushEventTo(this.el, phxEvent, { val: value }, () => {
        this.rstore.clearPending(field);
      });
    },

    _syncParentUrl() {
      if (Object.keys(this.bindings).length === 0) return;
      const parentRoot = document.getElementById("lavash-optimistic-root");
      if (!parentRoot || !parentRoot.__lavash_hook__) return;
      const parentHook = parentRoot.__lavash_hook__;
      const changedFields = [];
      for (const [localField, parentField] of Object.entries(this.bindings)) {
        const value = this.state[localField];
        if (value !== undefined) {
          parentHook.state[parentField] = value;
          if (parentHook.store) {
            const syncedVar = parentHook.store.get(parentField, value);
            syncedVar.setOptimistic(value);
          }
          changedFields.push(parentField);
        }
      }
      if (changedFields.length > 0 && parentHook.clientVersion !== undefined) {
        parentHook.clientVersion++;
      }
      if (changedFields.length > 0 && typeof parentHook.recomputeDerives === 'function') {
        parentHook.recomputeDerives(changedFields);
      }
      if (typeof parentHook.updateDOM === 'function') {
        parentHook.updateDOM();
      }
      if (typeof parentHook.syncUrl === 'function') {
        parentHook.syncUrl();
      }
    },

    refreshFromParent(parentHook) {
      const changedFields = [];
      for (const [localField, parentField] of Object.entries(this.bindings)) {
        const parentValue = parentHook.state[parentField];
        if (parentValue !== undefined && parentValue !== this.state[localField]) {
          this.state[localField] = parentValue;
          changedFields.push(localField);
        }
      }
      if (changedFields.length > 0) {
        this.rstore.recompute(changedFields);
        this._updateDOM();
      }
    },

    destroyed() {
      if (this.rstore) this.rstore.destroy();
      if (this._clickHandler) {
        this.el.removeEventListener("click", this._clickHandler, true);
      }
      if (this._keydownHandler) {
        this.el.removeEventListener("keydown", this._keydownHandler, true);
      }
      if (this._inputHandler) {
        this.el.removeEventListener("input", this._inputHandler, true);
      }
    }
  };
}

// Expose humanize for generated render functions
export { humanize };

window.Lavash = window.Lavash || {};
window.Lavash.createClientComponentHook = createClientComponentHook;
