// Debug: Animation speed multiplier (1 = normal, 0.1 = 10x slower, 2 = 2x faster)
const ANIMATION_SPEED = 1;

const OVERLAY_OPACITY = "0.5";

/**
 * OverlayAnimator - Phase-derived DOM control for modal and flyover overlays.
 *
 * This class implements the SyncedVar delegate interface. The design rule:
 * every style and class on the live chrome elements (wrapper, overlay,
 * panel, loading, main) is a pure function of the phase machine's state —
 * `(phase, contentReady)` — applied through one idempotent entry point,
 * `applyPhaseStyles`. No path hand-edits individual styles; interrupted
 * animations are handled by re-applying, not by bespoke undo code.
 *
 * The one deliberate exception is ghost elements: on exit, the panel and
 * backdrop are cloned to document.body and animated out there, because the
 * real elements' content is about to be removed by the server patch. Ghosts
 * exist precisely to outlive the declarative DOM.
 *
 * Target inputs:
 *   open         - phase is entering/loading/visible
 *   contentReady - SyncedVar.isAsyncReady (server content present)
 *   hidden       - phase is exiting (ghosts own the visuals)
 *
 * Usage (handled automatically by LavashOptimistic hook):
 *
 *   const animator = new OverlayAnimator(chromeEl, {
 *     type: 'modal' | 'flyover',
 *     slideFrom: 'right',          // flyover only
 *     duration: 200,
 *     openField: 'product_id',
 *   });
 */
export class OverlayAnimator {
  /**
   * @param {HTMLElement} el - The overlay wrapper element
   * @param {Object} config - Configuration options
   * @param {string} config.type - 'modal' or 'flyover'
   * @param {string} config.slideFrom - For flyover: 'left', 'right', 'top', 'bottom'
   * @param {number} config.duration - Animation duration in ms (default: 200)
   * @param {string} config.openField - The open state field name (for logging)
   */
  constructor(el, config = {}) {
    this.el = el;
    this.config = config;
    this.type = config.type || "modal";
    this.slideFrom = config.slideFrom || "right";

    // Apply speed multiplier: lower = slower (0.1 = 10x slower)
    this.duration = (config.duration || 200) / ANIMATION_SPEED;

    this._initAnimationConfig();

    // Cache element references
    const id = el.id;
    this.overlay = el.querySelector(`#${id}-overlay`);
    this.panelContent = el.querySelector(`#${id}-panel_content`);

    // Dynamic getters for elements that may be replaced by LiveView
    this.getMainContentContainer = () => el.querySelector(`#${id}-main_content`);
    this.getMainContentInner = () => el.querySelector(`#${id}-main_content_inner`);
    this.getLoadingContent = () => el.querySelector(`#${id}-loading_content`);

    // Ghost element state (exit animation)
    this.ghostElement = null;
    this._ghostOverlay = null;

    // Declarative state: the target inputs of the last apply.
    this._applied = null;
    // SyncedVar captured from delegate callbacks (source of phase/contentReady)
    this._sv = null;

    // In-flight transition bookkeeping
    this._transitionHandler = null;
    this._completionTimer = null;
    this._sizeLockApplied = false;
  }

  /**
   * Initialize type-specific animation configuration.
   */
  _initAnimationConfig() {
    if (this.type === "modal") {
      this._openTransform = "scale(1)";
      this._closedTransform = "scale(0.95)";
      this._panelFades = true; // Modal panel fades in/out
      this._animatesSize = true; // Modal animates width/height on content swap
    } else {
      // Flyover
      this._openTransform = "translate(0, 0)";
      this._closedTransform = this._getFlyoverClosedTransform();
      this._panelFades = false; // Flyover only slides, no opacity
      this._animatesSize = false; // Flyover has fixed size
    }
  }

  _getFlyoverClosedTransform() {
    switch (this.slideFrom) {
      case "left":
        return "translateX(-100%)";
      case "right":
        return "translateX(100%)";
      case "top":
        return "translateY(-100%)";
      case "bottom":
        return "translateY(100%)";
      default:
        return "translateX(100%)";
    }
  }

  // --- Target computation ---

  /**
   * The complete set of inputs that determine chrome styling.
   * Everything applyPhaseStyles writes derives from these three booleans.
   */
  _targetInputs(phase) {
    const open =
      phase === "entering" || phase === "loading" || phase === "visible";
    return {
      open,
      contentReady: !!this._sv?.isAsyncReady,
      // During exit the ghosts own the visuals; the real elements hide.
      hidden: phase === "exiting",
    };
  }

  // --- Declarative style application ---

  /**
   * Apply the complete chrome style state for a phase. Idempotent: applying
   * the same target inputs twice is a no-op, so callers never need to know
   * what state the DOM was left in by an interrupted animation.
   */
  applyPhaseStyles(phase, { animate = true } = {}) {
    const t = this._targetInputs(phase);
    const prev = this._applied;
    if (
      prev &&
      prev.open === t.open &&
      prev.contentReady === t.contentReady &&
      prev.hidden === t.hidden
    ) {
      return;
    }
    console.debug(
      `[OverlayAnimator:${this.type}] apply: phase=${phase}, open=${t.open}, contentReady=${t.contentReady}, hidden=${t.hidden}, animate=${animate}`
    );
    this._applied = t;

    // Supersede any in-flight transition; the new apply owns the DOM now.
    this._cancelPendingTransition();

    if (animate && t.open) {
      this._applyAnimated(t, prev);
    } else {
      this._applyInstant(t);
    }
  }

  /**
   * Instant apply: jump every element to its target state. Used for idle
   * reset, exit (ghosts animate instead), and normalization before an
   * animated apply.
   */
  _applyInstant(t) {
    const panel = this.panelContent;
    const overlay = this.overlay;
    const loading = this.getLoadingContent();
    const main = this.getMainContentContainer();

    this.el.classList.toggle("invisible", !t.open);
    this.el.classList.toggle("pointer-events-none", !t.open);

    if (panel) {
      panel.style.removeProperty("transition");
      panel.style.visibility = t.hidden ? "hidden" : "";
      panel.style.transform = t.open
        ? this._openTransform
        : this._closedTransform;
      if (this._panelFades) {
        panel.style.opacity = t.open ? "1" : "0";
      }
      panel.style.removeProperty("width");
      panel.style.removeProperty("height");
      panel.style.removeProperty("overflow");
    }

    if (overlay) {
      overlay.style.removeProperty("transition");
      overlay.style.visibility = t.hidden ? "hidden" : "";
      overlay.style.opacity = t.open ? OVERLAY_OPACITY : "0";
    }

    const loadingShown = t.open && !t.contentReady;
    if (loading) {
      loading.style.removeProperty("transition");
      loading.classList.toggle("hidden", !loadingShown);
      if (loadingShown) {
        loading.classList.remove("opacity-0");
        loading.style.opacity = "1";
      } else {
        loading.style.removeProperty("opacity");
      }
    }

    const mainShown = t.open && t.contentReady;
    if (main) {
      main.style.removeProperty("transition");
      main.classList.toggle("hidden", !mainShown);
      if (mainShown) {
        main.style.opacity = "1";
      } else {
        main.style.removeProperty("opacity");
      }
    }

    this._sizeLockApplied = false;
  }

  /**
   * Animated apply: freeze each element at its current visual value, then
   * transition to the target. Because starting values come from computed
   * style, interrupted animations (reopen mid-exit, content mid-enter)
   * continue smoothly from wherever they are.
   */
  _applyAnimated(t, prev) {
    const panel = this.panelContent;
    const overlay = this.overlay;
    const loading = this.getLoadingContent();
    const main = this.getMainContentContainer();
    const dur = this.duration;

    // Structural state (instant): wrapper visible + interactive, no
    // exit-time visibility:hidden.
    this.el.classList.remove("invisible", "pointer-events-none");
    if (panel) panel.style.visibility = "";
    if (overlay) overlay.style.visibility = "";

    const loadingWasShown = loading && !loading.classList.contains("hidden");
    const mainWasShown = main && !main.classList.contains("hidden");
    const loadingShown = t.open && !t.contentReady;
    const mainShown = t.open && t.contentReady;

    // Freeze continuous values at their current computed state.
    if (panel) {
      this._freeze(panel, this._panelFades ? ["transform", "opacity"] : ["transform"]);
    }
    if (overlay) this._freeze(overlay, ["opacity"]);
    if (loading && loadingWasShown) this._freeze(loading, ["opacity"]);
    if (main && mainWasShown) this._freeze(main, ["opacity"]);

    // Elements becoming shown start transparent.
    if (loading && loadingShown && !loadingWasShown) {
      loading.classList.remove("hidden", "opacity-0");
      loading.style.transition = "none";
      loading.style.opacity = "0";
    }
    if (main && mainShown && !mainWasShown) {
      main.classList.remove("hidden");
      main.style.transition = "none";
      main.style.opacity = "0";
    }

    // Size FLIP (modal only): when a loading/main swap changes the panel's
    // natural size while it's already open, animate width/height across it.
    let sizeFlip = null;
    if (
      this._animatesSize &&
      panel &&
      prev?.open &&
      (loadingShown !== loadingWasShown || mainShown !== mainWasShown)
    ) {
      sizeFlip = this._prepareSizeFlip(panel, loading, main, {
        loadingShown,
        mainShown,
      });
    }
    // Any pre-patch size lock is now owned (and cleaned up) by this apply.
    this._sizeLockApplied = false;

    // Reflow so frozen/starting values are committed before transitions.
    if (panel) panel.offsetHeight;

    // Set up transitions.
    const panelTransitions = [`transform ${dur}ms ease-out`];
    if (this._panelFades) panelTransitions.push(`opacity ${dur}ms ease-out`);
    if (sizeFlip) {
      panelTransitions.push(`width ${dur}ms ease-out`);
      panelTransitions.push(`height ${dur}ms ease-out`);
    }
    if (panel) panel.style.transition = panelTransitions.join(", ");
    if (overlay) overlay.style.transition = `opacity ${dur}ms ease-out`;
    if (loading) loading.style.transition = `opacity ${dur}ms ease-out`;
    if (main) main.style.transition = `opacity ${dur}ms ease-out`;

    if (panel) panel.offsetHeight;

    // Write targets.
    if (panel) {
      panel.style.transform = this._openTransform;
      if (this._panelFades) panel.style.opacity = "1";
      if (sizeFlip) {
        panel.style.width = `${sizeFlip.width}px`;
        panel.style.height = `${sizeFlip.height}px`;
      }
    }
    if (overlay) overlay.style.opacity = OVERLAY_OPACITY;
    if (loading) loading.style.opacity = loadingShown ? "1" : "0";
    if (main) main.style.opacity = mainShown ? "1" : "0";

    // Completion: timer-backed so cleanup runs even when no panel property
    // actually transitioned (e.g. content swap while the panel is already
    // at its open transform and unchanged size).
    this._scheduleCompletion(() => {
      for (const elm of [panel, overlay, loading, main]) {
        if (elm) elm.style.removeProperty("transition");
      }
      if (panel) {
        panel.style.removeProperty("width");
        panel.style.removeProperty("height");
        panel.style.removeProperty("overflow");
      }
      if (loading && !loadingShown) loading.classList.add("hidden");
      if (main && !mainShown) main.classList.add("hidden");
      if (this._sv?.getPhase() === "entering") {
        this._sv.notifyTransitionEnd();
      }
    });
  }

  /**
   * Freeze an element's continuous properties at their current computed
   * values so a new transition starts from the visual present.
   */
  _freeze(elm, props) {
    const cs = getComputedStyle(elm);
    elm.style.transition = "none";
    for (const p of props) {
      elm.style[p] = cs[p];
    }
  }

  /**
   * Measure the panel's natural size in the target display state, then
   * re-lock it at its current size so width/height can transition.
   */
  _prepareSizeFlip(panel, loading, main, target) {
    const cs = getComputedStyle(panel);
    const startWidth = parseFloat(cs.width);
    const startHeight = parseFloat(cs.height);

    // Apply end-state display, unlock, measure — invisibly.
    const prevVisibility = panel.style.visibility;
    panel.style.visibility = "hidden";
    const loadingWasHidden = loading && loading.classList.contains("hidden");
    const mainWasHidden = main && main.classList.contains("hidden");
    if (loading) loading.classList.toggle("hidden", !target.loadingShown);
    if (main) main.classList.toggle("hidden", !target.mainShown);
    panel.style.width = "";
    panel.style.height = "";
    panel.offsetHeight;
    const endStyle = getComputedStyle(panel);
    const width = parseFloat(endStyle.width);
    const height = parseFloat(endStyle.height);

    // Restore crossfade display state (both layers visible during fade)
    // and re-lock at the starting size.
    if (loading) loading.classList.toggle("hidden", loadingWasHidden);
    if (main) main.classList.toggle("hidden", mainWasHidden);
    panel.style.width = `${startWidth}px`;
    panel.style.height = `${startHeight}px`;
    panel.style.overflow = "hidden";
    panel.style.visibility = prevVisibility;
    panel.offsetHeight;

    return { width, height };
  }

  /**
   * Run `finalize` when the current transition completes — via panel
   * transitionend when one fires, or the duration-based fallback timer
   * when none does. Exactly once.
   */
  _scheduleCompletion(finalize) {
    const panel = this.panelContent;
    let done = false;
    const complete = () => {
      if (done) return;
      done = true;
      if (panel && this._transitionHandler) {
        panel.removeEventListener("transitionend", this._transitionHandler);
      }
      this._transitionHandler = null;
      if (this._completionTimer) clearTimeout(this._completionTimer);
      this._completionTimer = null;
      finalize();
    };

    if (panel) {
      this._transitionHandler = (e) => {
        if (e.target !== panel) return;
        complete();
      };
      panel.addEventListener("transitionend", this._transitionHandler);
    }
    this._completionTimer = setTimeout(complete, this.duration + 60);
  }

  _cancelPendingTransition() {
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener(
        "transitionend",
        this._transitionHandler
      );
    }
    this._transitionHandler = null;
    if (this._completionTimer) clearTimeout(this._completionTimer);
    this._completionTimer = null;
  }

  // --- SyncedVar Delegate Callbacks ---

  /**
   * Called when entering the "entering" phase. Normalizing to idle first
   * makes reopen-mid-exit identical to a fresh open: any exit residue
   * (ghosts, hidden panels, locked sizes) is wiped by the idempotent
   * instant apply, then the enter animation plays.
   */
  onEntering(syncedVar) {
    this._sv = syncedVar;
    this._cleanupGhosts();
    this.applyPhaseStyles("idle", { animate: false });
    this.applyPhaseStyles("entering");
  }

  /**
   * Called when entering the "loading" phase. Targets are identical to
   * entering-without-content, so the apply is a no-op by idempotency.
   */
  onLoading(syncedVar) {
    this._sv = syncedVar;
    this.applyPhaseStyles("loading");
  }

  /**
   * Called when entering the "visible" phase.
   */
  onVisible(syncedVar) {
    this._sv = syncedVar;
    this.applyPhaseStyles("visible");
  }

  /**
   * Called when entering the "exiting" phase. Ghosts are cloned from the
   * current visual state before the real elements are hidden.
   */
  onExiting(syncedVar) {
    this._sv = syncedVar;
    this._createGhosts();
    this.applyPhaseStyles("exiting", { animate: false });
  }

  /**
   * Called when entering the "idle" phase.
   */
  onIdle(syncedVar) {
    this._sv = syncedVar;
    this.applyPhaseStyles("idle", { animate: false });
  }

  /**
   * Called when async data arrives in loading or visible phase.
   * isAsyncReady has flipped, so the apply crossfades loading -> content.
   */
  onAsyncReady(syncedVar) {
    this._sv = syncedVar;
    this.applyPhaseStyles(syncedVar.getPhase());
  }

  /**
   * Called when content arrives while the enter animation is still running.
   * The crossfade composes with the in-flight enter transition because the
   * animated apply freezes at current computed values first.
   */
  onContentReadyDuringEnter(syncedVar) {
    this._sv = syncedVar;
    this.applyPhaseStyles("entering");
  }

  /**
   * Called by LavashOptimistic after a LiveView update. Pure detection:
   * notice server content arriving and inform the phase machine; the
   * delegate callbacks it triggers do the styling.
   */
  onUpdated(animated, _phase) {
    this._sv = animated;
    const mainInner = this.getMainContentInner();
    const contentLoaded = mainInner && mainInner.children.length > 0;
    const phase = animated.getPhase();

    console.debug(
      `[OverlayAnimator:${this.type}] onUpdated: phase=${phase}, contentLoaded=${!!contentLoaded}, asyncReady=${animated.isAsyncReady}`
    );

    if (contentLoaded && !animated.isAsyncReady) {
      animated.onAsyncDataReady();
    } else if (
      contentLoaded &&
      (phase === "entering" || phase === "loading" || phase === "visible")
    ) {
      // Content present but the swap not yet applied (no-op when it was).
      this.applyPhaseStyles(phase);
    }

    this.releaseSizeLockIfNeeded();
  }

  // --- Size Lock (pre-patch FLIP capture, modal only) ---

  capturePreUpdateRect(phase) {
    if (!this._animatesSize || !this.panelContent || phase === "idle") return;
    const style = getComputedStyle(this.panelContent);
    this._sizeLockApplied = true;
    this.panelContent.style.width = style.width;
    this.panelContent.style.height = style.height;
  }

  releaseSizeLockIfNeeded() {
    if (this._sizeLockApplied && this.panelContent) {
      this._sizeLockApplied = false;
      this.panelContent.style.removeProperty("width");
      this.panelContent.style.removeProperty("height");
    }
  }

  // --- Ghost Element Animation ---

  /**
   * Clone the panel and backdrop to document.body and animate the clones
   * out. The clones start from the panel's current computed state, so a
   * close mid-enter animates out from wherever the panel visually is.
   */
  _createGhosts() {
    const panel = this.panelContent;
    if (!panel) return;

    const rect = panel.getBoundingClientRect();
    // Skip if panel has zero dimensions (hidden or not laid out)
    if (rect.width === 0 || rect.height === 0) {
      console.debug(
        `[OverlayAnimator:${this.type}] _createGhosts: skipping - panel has zero dimensions`
      );
      return;
    }

    const cs = getComputedStyle(panel);

    const ghost = panel.cloneNode(true);
    ghost.removeAttribute("id");
    ghost.removeAttribute("phx-click");
    ghost.removeAttribute("phx-target");
    ghost.removeAttribute("phx-window-keydown");
    ghost.removeAttribute("phx-key");
    // Strip IDs from all descendants to prevent duplicate IDs in the DOM
    ghost.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"));

    Object.assign(ghost.style, {
      position: "fixed",
      top: `${rect.top}px`,
      left: `${rect.left}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      margin: "0",
      pointerEvents: "none",
      zIndex: "9999",
      backgroundColor: cs.backgroundColor,
      borderRadius: cs.borderRadius,
      transition: "none",
      transform: "none",
      opacity: this._panelFades ? cs.opacity : "1",
    });
    document.body.appendChild(ghost);
    this.ghostElement = ghost;

    if (this.overlay) {
      const overlayOpacity = getComputedStyle(this.overlay).opacity;
      this._ghostOverlay = document.createElement("div");
      Object.assign(this._ghostOverlay.style, {
        position: "fixed",
        inset: "0",
        backgroundColor: "black",
        opacity: overlayOpacity,
        pointerEvents: "none",
        zIndex: "9998",
        transition: "none",
      });
      document.body.appendChild(this._ghostOverlay);
    }

    // Animate ghosts to the closed target state.
    ghost.offsetHeight;
    const ghostTransitions = [`transform ${this.duration}ms ease-out`];
    if (this._panelFades) {
      ghostTransitions.push(`opacity ${this.duration}ms ease-out`);
    }
    ghost.style.transition = ghostTransitions.join(", ");
    if (this._ghostOverlay) {
      this._ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
    }
    ghost.offsetHeight;

    ghost.style.transform = this._closedTransform;
    if (this._panelFades) ghost.style.opacity = "0";
    if (this._ghostOverlay) this._ghostOverlay.style.opacity = "0";

    // Remove after the animation completes.
    setTimeout(() => {
      if (this.ghostElement?.parentNode) {
        this.ghostElement.remove();
        this.ghostElement = null;
      }
      if (this._ghostOverlay?.parentNode) {
        this._ghostOverlay.remove();
        this._ghostOverlay = null;
      }
    }, this.duration + 60);
  }

  _cleanupGhosts() {
    if (this.ghostElement?.parentNode) this.ghostElement.remove();
    this.ghostElement = null;
    if (this._ghostOverlay?.parentNode) this._ghostOverlay.remove();
    this._ghostOverlay = null;
  }

  // --- Cleanup ---

  destroy() {
    this._cancelPendingTransition();
    this._cleanupGhosts();
  }
}

// Expose globally
window.Lavash = window.Lavash || {};
window.Lavash.OverlayAnimator = OverlayAnimator;

// Keep backwards compatibility aliases
window.Lavash.ModalAnimator = OverlayAnimator;
window.Lavash.FlyoverAnimator = OverlayAnimator;
