/**
 * AnimatedState - Client-side state machine for animated state transitions.
 *
 * This class manages the phase state machine for fields with `animated: true`:
 *
 * Phases:
 * - "idle" - closed/hidden state
 * - "entering" - enter animation in progress
 * - "loading" - waiting for async data (when async option set)
 * - "visible" - fully open/visible
 * - "exiting" - exit animation in progress
 *
 * Usage (handled automatically by LavashOptimistic hook):
 *
 *   const animated = new AnimatedState({
 *     field: 'product_id',
 *     phaseField: 'product_id_phase',
 *     async: 'product',  // optional: wait for async data
 *     preserveDom: true, // optional: ghost element during exit
 *     duration: 200      // animation duration in ms
 *   }, hook, delegate);
 *
 * The delegate (optional) implements lifecycle callbacks:
 * - onEntering(animatedState) - start enter animation
 * - onLoading(animatedState) - entered loading state
 * - onVisible(animatedState) - fully visible
 * - onExiting(animatedState) - start exit animation
 * - onIdle(animatedState) - back to closed
 * - onAsyncReady(animatedState) - async data arrived (in loading or visible phase)
 * - onContentReadyDuringEnter(animatedState) - content arrived while enter animation running
 * - onTransitionEnd(animatedState) - enter animation completed
 */

import { SyncedVar } from "./synced_var.js";

// --- Base State Class ---
class AnimatedStatePhase {
  constructor(manager) {
    this.manager = manager;
  }

  get name() {
    return this.constructor.name
      .replace(/Phase$/, "")
      .toLowerCase();
  }

  onOpen() {}
  onClose() {}
  onAsyncReady() {}
  onTransitionEnd() {}
  onEnter() {}
  onExit() {}
}

// --- Concrete Phase Implementations ---

class IdlePhase extends AnimatedStatePhase {
  onEnter() {
    this.manager._setPhase("idle");
    this.manager._notifyDelegate("onIdle");
  }

  onOpen() {
    this.manager.transitionTo(this.manager.phases.entering);
  }
}

class EnteringPhase extends AnimatedStatePhase {
  onEnter() {
    this.manager._setPhase("entering");
    this.manager._notifyDelegate("onEntering");

    // Set up fallback timeout in case delegate doesn't call transitionEnd
    this._timeout = setTimeout(() => {
      this.onTransitionEnd();
    }, this.manager.config.duration + 50);
  }

  onExit() {
    if (this._timeout) {
      clearTimeout(this._timeout);
    }
  }

  onTransitionEnd() {
    if (this._timeout) {
      clearTimeout(this._timeout);
      this._timeout = null;
    }

    // If we have async configured and data isn't ready, go to loading
    if (this.manager.config.async && !this.manager.isAsyncReady) {
      this.manager.transitionTo(this.manager.phases.loading);
    } else {
      this.manager.transitionTo(this.manager.phases.visible);
    }
  }

  onClose() {
    this.manager.transitionTo(this.manager.phases.exiting);
  }

  onAsyncReady() {
    // Data arrived during enter animation - notify delegate to capture loading rect
    // before it gets overwritten by subsequent DOM updates
    this.manager.isAsyncReady = true;
    this.manager._notifyDelegate("onContentReadyDuringEnter");
  }
}

class LoadingPhase extends AnimatedStatePhase {
  onEnter() {
    this.manager._setPhase("loading");
    this.manager._notifyDelegate("onLoading");
  }

  onAsyncReady() {
    this.manager.isAsyncReady = true;
    this.manager._notifyDelegate("onAsyncReady");
    this.manager.transitionTo(this.manager.phases.visible);
  }

  onClose() {
    this.manager.transitionTo(this.manager.phases.exiting);
  }
}

class VisiblePhase extends AnimatedStatePhase {
  onEnter() {
    this.manager._setPhase("visible");
    this.manager._notifyDelegate("onVisible");
  }

  onClose() {
    this.manager.transitionTo(this.manager.phases.exiting);
  }

  onAsyncReady() {
    // Data refresh while visible
    this.manager._notifyDelegate("onAsyncReady");
  }
}

class ExitingPhase extends AnimatedStatePhase {
  onEnter() {
    this.manager._setPhase("exiting");
    this.manager._notifyDelegate("onExiting");

    // Transition to idle after animation duration
    this._timeout = setTimeout(() => {
      this.manager.transitionTo(this.manager.phases.idle);
    }, this.manager.config.duration + 50);
  }

  onExit() {
    if (this._timeout) {
      clearTimeout(this._timeout);
    }
  }

  onOpen() {
    // Interrupted close - start opening again
    this.manager.transitionTo(this.manager.phases.entering);
  }
}

// --- Main AnimatedState Manager ---

export class AnimatedState {
  /**
   * Create an AnimatedState manager.
   *
   * @param {Object} config - Configuration from __animated__ metadata
   * @param {string} config.field - The state field name (e.g., "product_id")
   * @param {string} config.phaseField - The phase state field (e.g., "product_id_phase")
   * @param {string|null} config.async - Async field to coordinate with (e.g., "product")
   * @param {boolean} config.preserveDom - Keep DOM alive during exit animation
   * @param {number} config.duration - Animation duration in ms
   * @param {Object} hook - The LavashOptimistic hook instance (for state updates)
   * @param {Object} delegate - Optional object implementing lifecycle callbacks
   */
  constructor(config, hook, delegate = null) {
    this.config = config;
    this.hook = hook;
    this.delegate = delegate;

    // SyncedVar for the main field value
    this.syncedVar = new SyncedVar(null, (newValue, oldValue, source) => {
      this.onValueChange(newValue, oldValue, source);
    });

    // Track async data readiness
    this.isAsyncReady = false;

    // Phase state machine
    this.phases = {
      idle: new IdlePhase(this),
      entering: new EnteringPhase(this),
      loading: new LoadingPhase(this),
      visible: new VisiblePhase(this),
      exiting: new ExitingPhase(this)
    };

    this.currentPhase = null;
    this.transitionTo(this.phases.idle);
  }

  /**
   * Set or update the delegate for lifecycle callbacks.
   * @param {Object} delegate - Object implementing onEntering, onVisible, etc.
   */
  setDelegate(delegate) {
    this.delegate = delegate;
  }

  /**
   * Handle value changes from the hook.
   */
  onValueChange(newValue, oldValue, source) {
    const wasOpen = oldValue != null;
    const isOpen = newValue != null;

    if (isOpen && !wasOpen) {
      // Opening
      this.isAsyncReady = false; // Reset async state for new open
      this.currentPhase.onOpen();
    } else if (!isOpen && wasOpen) {
      // Closing
      this.currentPhase.onClose();
    }
  }

  /**
   * Notify that async data has arrived.
   */
  onAsyncDataReady() {
    this.isAsyncReady = true;
    this.currentPhase.onAsyncReady();
  }

  /**
   * Notify that enter transition has completed.
   * Call this from delegate's onEntering when animation finishes.
   */
  notifyTransitionEnd() {
    if (this.currentPhase.onTransitionEnd) {
      this.currentPhase.onTransitionEnd();
    }
  }

  /**
   * Transition to a new phase.
   */
  transitionTo(newPhase) {
    const oldPhaseName = this.currentPhase ? this.currentPhase.name : "initial";
    console.debug(`[AnimatedState ${this.config.field}] ${oldPhaseName} -> ${newPhase.name}`);

    if (this.currentPhase) {
      this.currentPhase.onExit();
    }
    this.currentPhase = newPhase;
    this.currentPhase.onEnter();
  }

  /**
   * Get current phase name.
   */
  getPhase() {
    return this.currentPhase ? this.currentPhase.name : "idle";
  }

  /**
   * Check if currently in a transitioning phase.
   */
  isAnimating() {
    const phase = this.getPhase();
    return phase === "entering" || phase === "exiting";
  }

  // --- Internal Methods ---

  /**
   * Update the phase state in the hook's state and recompute derives.
   */
  _setPhase(phaseName) {
    if (this.hook?.state) {
      this.hook.state[this.config.phaseField] = phaseName;
      // Recompute derives that depend on the phase
      this.hook.recomputeDerives?.([this.config.phaseField]);
      this.hook.updateDOM?.();
    }
  }

  /**
   * Notify delegate of lifecycle event.
   */
  _notifyDelegate(methodName) {
    try {
      this.delegate?.[methodName]?.(this);
    } catch (e) {
      console.error(`[AnimatedState ${this.config.field}] Delegate ${methodName} error:`, e);
    }
  }

  /**
   * Clean up when destroyed.
   */
  destroy() {
    if (this.currentPhase) {
      this.currentPhase.onExit();
    }
    this.delegate = null;
    this.hook = null;
  }
}

// Expose globally for modal hooks
window.Lavash = window.Lavash || {};
window.Lavash.AnimatedState = AnimatedState;
