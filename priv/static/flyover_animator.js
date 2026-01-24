// Debug: Animation speed multiplier (1 = normal, 0.1 = 10x slower, 2 = 2x faster)
const ANIMATION_SPEED = 1;

/**
 * FlyoverAnimator - Flyover-specific DOM manipulation as a SyncedVar delegate.
 *
 * This class implements the SyncedVar delegate interface for flyover-specific
 * behavior including:
 * - Panel slide open/close animations (from any edge)
 * - Overlay fade in/out
 * - Ghost element creation for close animation
 * - Unified transition from loading→content (interrupts enter animation if needed)
 * - onBeforeElUpdated hook for content removal detection
 *
 * Usage (handled automatically by LavashOptimistic hook):
 *
 *   const animator = new FlyoverAnimator(flyoverElement, {
 *     duration: 200,
 *     slideFrom: 'right',  // 'left', 'right', 'top', 'bottom'
 *     openField: 'open',
 *     js: this.js()  // LiveView JS commands interface
 *   });
 *
 *   // Set as delegate for SyncedVar (with animated config)
 *   syncedVar.setDelegate(animator);
 */

export class FlyoverAnimator {
  /**
   * Create a FlyoverAnimator.
   *
   * @param {HTMLElement} el - The flyover wrapper element
   * @param {Object} config - Configuration options
   * @param {number} config.duration - Animation duration in ms (default: 200)
   * @param {string} config.slideFrom - Slide direction: 'left', 'right', 'top', 'bottom'
   * @param {string} config.openField - The open state field name (for logging)
   * @param {Object} config.js - LiveView JS commands interface (this.js() from hook)
   */
  constructor(el, config = {}) {
    this.el = el;
    this.config = config;
    // Apply speed multiplier: lower = slower (0.1 = 10x slower)
    this.duration = (config.duration || 200) / ANIMATION_SPEED;
    this.slideFrom = config.slideFrom || "right";
    this.panelIdForLog = `#${el.id}`;
    this.js = config.js;

    // Cache element references
    const id = el.id;
    this.overlay = el.querySelector(`#${id}-overlay`);
    this.panelContent = el.querySelector(`#${id}-panel_content`);

    // Dynamic getters for elements that may be replaced by LiveView
    this.getMainContentContainer = () => el.querySelector(`#${id}-main_content`);
    this.getMainContentInner = () => el.querySelector(`#${id}-main_content_inner`);
    this.getLoadingContent = () => el.querySelector(`#${id}-loading_content`);

    // Ghost element state
    this.ghostElement = null;
    this._ghostOverlay = null;
    this._ghostInsertedInBeforeUpdate = false;
    this._preUpdateContentClone = null;

    // Animation state
    this._transitionHandler = null;
    this._loadingFadedOut = false;

    // Get transform values
    this._openTransform = this._getOpenTransform();
    this._closedTransform = this._getClosedTransform();
  }

  _getOpenTransform() {
    return "translate(0, 0)";
  }

  _getClosedTransform() {
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

  // --- SyncedVar Delegate Callbacks ---

  /**
   * Called when entering the "entering" phase.
   * Shows loading content and animates panel in.
   */
  onEntering(syncedVar) {
    // Check if this is a reopen (interrupting close animation)
    const isReopen = !!this._ghostOverlay || !this.el.classList.contains("invisible");
    console.log(`[FlyoverAnimator] onEntering: isReopen=${isReopen}, hasGhostOverlay=${!!this._ghostOverlay}, wrapperVisible=${!this.el.classList.contains("invisible")}`);

    // If reopening, don't make wrapper invisible - just clean up and continue
    if (isReopen) {
      // Clean up any ghost elements with fade
      this._cleanupCloseAnimation(false);
      // Reset internal state but don't touch wrapper visibility
      this._loadingFadedOut = false;
      this._ghostInsertedInBeforeUpdate = false;
      this._preUpdateContentClone = null;
      // Clean up transition handler
      if (this.panelContent && this._transitionHandler) {
        this.panelContent.removeEventListener("transitionend", this._transitionHandler);
        this._transitionHandler = null;
      }
    } else {
      // First open - reset DOM completely
      this._resetDOM();
    }

    // Make wrapper visible and interactive
    this.js.removeClass(this.el, "invisible pointer-events-none");
    this.el.classList.remove("invisible", "pointer-events-none");

    // Show loading content if present
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      // Remove hidden but keep opacity-0 for transition setup
      this.js.removeClass(loadingContent, "hidden");
      loadingContent.classList.remove("hidden");
      // Use inline styles for animation (starting at opacity 0)
      loadingContent.style.opacity = "0";
      loadingContent.style.transition = "none";
      loadingContent.offsetHeight; // Force reflow to commit opacity:0
      // Now set transition and fade in
      loadingContent.style.transition = `opacity ${this.duration}ms ease-out`;
      loadingContent.offsetHeight; // Force reflow to commit transition
      loadingContent.style.opacity = "1";
      // Remove the opacity-0 class since we're controlling via inline style now
      this.js.removeClass(loadingContent, "opacity-0");
    }

    // Animate panel in using inline styles
    if (this.panelContent) {
      // Set initial state (closed position)
      this.panelContent.style.transition = "none";
      this.panelContent.style.transform = this._closedTransform;
      this.panelContent.offsetHeight; // Force reflow

      // Set transition and animate to open state
      this.panelContent.style.transition = `transform ${this.duration}ms ease-out`;
      this.panelContent.offsetHeight; // Force reflow
      this.panelContent.style.transform = this._openTransform;

      // Set up transition end handler
      this._transitionHandler = (e) => {
        console.log(`[FlyoverAnimator] transitionend fired, property=${e.propertyName}, target=${e.target === this.panelContent ? "panelContent" : "other"}`);
        if (e.target !== this.panelContent) return;
        if (e.propertyName !== "transform") return;
        this.panelContent.removeEventListener("transitionend", this._transitionHandler);
        this._transitionHandler = null;
        // Notify SyncedVar that transition completed
        syncedVar.notifyTransitionEnd();
      };
      this.panelContent.addEventListener("transitionend", this._transitionHandler);
    }

    // Animate overlay in using inline styles
    if (this.overlay) {
      this.overlay.style.transition = "none";
      this.overlay.style.opacity = "0";
      this.overlay.offsetHeight; // Force reflow
      this.overlay.style.transition = `opacity ${this.duration}ms ease-out`;
      this.overlay.offsetHeight; // Force reflow
      this.overlay.style.opacity = "0.5";
    }
  }

  /**
   * Called when entering the "loading" phase.
   * Panel is open but waiting for async data.
   */
  onLoading(_syncedVar) {
    console.log(`[FlyoverAnimator] onLoading - waiting for async data`);
    // Panel is already open, just waiting for content
  }

  /**
   * Called when entering the "visible" phase.
   * Flyover is fully open and visible.
   */
  onVisible(_syncedVar) {
    console.log(`[FlyoverAnimator] onVisible called`);
    // Panel is now fully visible (ensure structural class removed via js)
    this.js.removeClass(this.el, "invisible");
    // Content transition is handled by _transitionToContent when content arrives
  }

  /**
   * Called when entering the "exiting" phase.
   * Sets up ghost element and animates close.
   */
  onExiting(_syncedVar) {
    console.log(`[FlyoverAnimator] onExiting`);

    // Disable pointer events immediately
    this.js.addClass(this.el, "pointer-events-none");
    this.el.classList.add("pointer-events-none");

    // Remove any pending transition handlers
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener("transitionend", this._transitionHandler);
      this._transitionHandler = null;
    }

    // Set up ghost element animation
    this._setupGhostElementAnimation();
  }

  /**
   * Called when entering the "idle" phase.
   * Resets DOM to closed state. Ghost cleanup is handled by scheduled timeout in _setupGhostElementAnimation.
   */
  onIdle(_syncedVar) {
    this._resetDOM();
    // Note: Ghost cleanup is NOT done here - the scheduled cleanup in _setupGhostElementAnimation handles it
    // This allows the close animation to complete smoothly even after server confirms close
  }

  /**
   * Called when async data arrives (in loading or visible phase).
   * Note: Transition is triggered from the hook's updated() method.
   */
  onAsyncReady(_syncedVar) {
    console.log(`[FlyoverAnimator] onAsyncReady`);
  }

  /**
   * Called by LavashOptimistic after a LiveView update.
   */
  onUpdated(animated, _phase) {
    const mainInner = this.getMainContentInner();
    const mainContentLoaded = mainInner && mainInner.children.length > 0;

    const currentPhase = animated.getPhase();
    const loadingContent = this.getLoadingContent();
    const loadingVisible = loadingContent && !loadingContent.classList.contains("hidden");

    console.log(`[FlyoverAnimator] onUpdated: phase=${currentPhase}, mainContentLoaded=${mainContentLoaded}, loadingVisible=${loadingVisible}, isAsyncReady=${animated.isAsyncReady}`);

    // Handle content arrival - use unified transition approach
    // This works for entering, loading, and visible phases
    if (mainContentLoaded && !animated.isAsyncReady) {
      console.log(`[FlyoverAnimator] onUpdated: content ready during ${currentPhase} phase, calling onAsyncDataReady`);
      animated.onAsyncDataReady();
      console.log(`[FlyoverAnimator] onUpdated: after onAsyncDataReady, phase=${animated.getPhase()}, isAsyncReady=${animated.isAsyncReady}`);
      // onContentReadyDuringEnter handles the transition for entering phase
      // For loading or visible phase with loading showing, trigger transition here
      if ((currentPhase === "loading" || currentPhase === "visible") && loadingVisible) {
        this._transitionToContent(animated);
      }
      return;
    }

    // For visible phase with loading still showing (edge case after isAsyncReady), run transition
    if (mainContentLoaded && currentPhase === "visible" && loadingVisible) {
      this._transitionToContent(animated);
    }
  }

  /**
   * Called when content arrives while enter animation is still running.
   * Interrupts the enter animation and transitions directly to final content state.
   */
  onContentReadyDuringEnter(syncedVar) {
    console.log(`[FlyoverAnimator] onContentReadyDuringEnter called`);
    this._transitionToContent(syncedVar);
  }

  /**
   * Unified transition to content state.
   * Captures current visual state, stops transitions, and animates to final state.
   * Works whether called during entering or loading phase.
   */
  _transitionToContent(syncedVar) {
    const mainContent = this.getMainContentContainer();
    const mainInnerEl = this.getMainContentInner();
    const loadingContent = this.getLoadingContent();

    if (!this.panelContent || !mainInnerEl) {
      console.log(`[FlyoverAnimator] _transitionToContent: missing elements, skipping`);
      return;
    }

    // 1. Capture AND FREEZE both panel and loading state IMMEDIATELY
    // Must capture and freeze in the same breath before any other work

    // Capture loading first and freeze it immediately
    let loadingCurrentOpacity = "0";
    if (loadingContent) {
      loadingCurrentOpacity = getComputedStyle(loadingContent).opacity;
      loadingContent.style.transition = "none";
      loadingContent.offsetHeight; // Force reflow to stop the fade-in transition NOW
      loadingContent.style.opacity = loadingCurrentOpacity;
    }

    // Now capture panel transform state
    const computedStyle = getComputedStyle(this.panelContent);
    const currentTransform = computedStyle.transform;

    console.log(`[FlyoverAnimator] _transitionToContent: current state - transform=${currentTransform}`);
    console.log(`[FlyoverAnimator] _transitionToContent: loading opacity when content arrives: ${loadingCurrentOpacity}`);

    // 2. Freeze panel to current state
    this.panelContent.style.transition = "none";
    this.panelContent.style.transform = currentTransform;

    // Remove enter transition handler since we're taking over
    if (this._transitionHandler) {
      this.panelContent.removeEventListener("transitionend", this._transitionHandler);
      this._transitionHandler = null;
    }

    // 3. Show main content at opacity 0, ready for fade-in
    if (mainContent) {
      this.js.removeClass(mainContent, "hidden");
      mainContent.classList.remove("hidden");
      mainContent.style.transition = "none";
      mainContent.style.opacity = "0";
      mainContent.offsetHeight; // Force reflow to apply opacity:0 before transition
    }

    // 4. Start ALL animations together in the same frame
    // Panel: transform to open position
    // Content: fade in
    // Loading: counter-fade out
    this.panelContent.style.transition = `transform ${this.duration}ms ease-out`;

    if (mainContent) {
      mainContent.style.transition = `opacity ${this.duration}ms ease-out`;
    }

    // Counter-fade loading to negate the panel's visibility effect
    //
    // Problem: Loading is INSIDE the panel, so apparent_loading depends on when
    // the panel became visible and how far through its animation we are.
    //
    // For flyovers (unlike modals), the panel doesn't fade - it slides.
    // But the loading still fades in, so we use the same counter-fade technique:
    // - Set loading to its current opacity
    // - Fade it out faster so it disappears before content fully appears
    //
    // For zero-latency: loading is hidden immediately, content just fades in
    // For high-latency: loading crossfades naturally with content
    const loadingOpacityNum = parseFloat(loadingCurrentOpacity);
    const shouldFadeLoading = loadingContent && loadingOpacityNum >= 0.1;

    if (loadingContent) {
      // Set loading's opacity to its current value
      loadingContent.style.opacity = loadingCurrentOpacity;
      if (shouldFadeLoading) {
        // Fade loading out faster, proportional to how visible it currently is
        const loadingFadeDuration = this.duration * loadingOpacityNum;
        loadingContent.style.transition = `opacity ${loadingFadeDuration}ms ease-out`;
      } else {
        loadingContent.style.transition = "none";
      }
    }

    // Force reflow to apply transitions before changing values
    // CRITICAL: Each element needs its own reflow to commit its transition
    this.panelContent.offsetHeight;
    if (mainContent) {
      mainContent.offsetHeight;
    }
    if (loadingContent) {
      loadingContent.offsetHeight;
    }

    // Now trigger all animations simultaneously
    this.panelContent.style.transform = this._openTransform;
    if (mainContent) {
      mainContent.style.opacity = "1";
    }
    if (loadingContent) {
      loadingContent.style.opacity = "0";
      if (shouldFadeLoading) {
        const loadingFadeDuration = this.duration * loadingOpacityNum;
        // Hide after fade completes
        setTimeout(() => {
          this.js.addClass(loadingContent, "hidden");
          loadingContent.style.removeProperty("transition");
        }, loadingFadeDuration);
      } else {
        // Hide immediately since loading is barely visible
        this.js.addClass(loadingContent, "hidden");
        loadingContent.style.removeProperty("transition");
      }
    }

    // Clean up after animation
    const cleanup = (e) => {
      if (e.target !== this.panelContent) return;
      if (e.propertyName !== "transform") return;
      this.panelContent.removeEventListener("transitionend", cleanup);
      this.panelContent.style.removeProperty("transition");
      console.log(`[FlyoverAnimator] _transitionToContent: animation complete`);
      // Notify state machine if still in entering phase
      if (syncedVar && syncedVar.getPhase() === "entering") {
        syncedVar.notifyTransitionEnd();
      }
    };
    this.panelContent.addEventListener("transitionend", cleanup);

    // Mark that we've handled the content transition
    this._loadingFadedOut = true;
  }

  // --- Ghost Element Animation ---

  /**
   * Create ghost element before morphdom patches (for server-initiated close).
   * Call this from onBeforeElUpdated when content removal is detected.
   */
  createGhostBeforePatch(originalElement) {
    // Clone the content that's about to be removed
    this._preUpdateContentClone = originalElement.cloneNode(true);
    this._preUpdateContentClone.id = `${originalElement.id}_ghost`;

    // Get position for fixed positioning
    const rect = originalElement.getBoundingClientRect();

    const panelBg = this.panelContent
      ? getComputedStyle(this.panelContent).backgroundColor
      : "white";

    Object.assign(this._preUpdateContentClone.style, {
      position: "fixed",
      top: `${rect.top}px`,
      left: `${rect.left}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      margin: "0",
      pointerEvents: "none",
      zIndex: "9999",
      backgroundColor: panelBg,
      transform: this._openTransform,
    });

    document.body.appendChild(this._preUpdateContentClone);

    // Create ghost overlay
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
      });
      document.body.appendChild(this._ghostOverlay);
    }

    // Hide original
    originalElement.style.visibility = "hidden";
    if (this.overlay) {
      this.overlay.style.visibility = "hidden";
    }

    this._ghostInsertedInBeforeUpdate = true;
    console.log(`[FlyoverAnimator] Ghost inserted via onBeforeElUpdated`);
  }

  /**
   * Set up ghost element animation for close.
   */
  _setupGhostElementAnimation() {
    // If ghost was created from onBeforeElUpdated, use it
    if (this._ghostInsertedInBeforeUpdate && this._preUpdateContentClone) {
      console.log(`[FlyoverAnimator] _setupGhostElementAnimation: using ghost from onBeforeElUpdated`);

      // Animate ghost overlay out
      if (this._ghostOverlay) {
        this._ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
        this._ghostOverlay.offsetHeight;
        this._ghostOverlay.style.opacity = "0";
      }

      // Animate ghost panel out
      const ghost = this._preUpdateContentClone;
      ghost.style.transition = `transform ${this.duration}ms ease-out`;
      ghost.offsetHeight;
      ghost.style.transform = this._closedTransform;

      // Also animate the real panel out (it's hidden but we need it reset for next open)
      if (this.panelContent) {
        this.panelContent.style.transition = `transform ${this.duration}ms ease-out`;
        this.panelContent.offsetHeight;
        this.panelContent.style.transform = this._closedTransform;
      }

      // Schedule ghost cleanup after animation completes
      setTimeout(() => {
        if (this._preUpdateContentClone?.parentNode) {
          this._preUpdateContentClone.remove();
          this._preUpdateContentClone = null;
        }
        if (this._ghostOverlay?.parentNode) {
          this._ghostOverlay.remove();
          this._ghostOverlay = null;
        }
      }, this.duration + 50);
      return;
    }

    // Fallback: animate real panel out (user-initiated close)
    console.log(`[FlyoverAnimator] _setupGhostElementAnimation: animating real panel out`);

    // Animate overlay out
    if (this.overlay) {
      this.overlay.style.transition = `opacity ${this.duration}ms ease-out`;
      this.overlay.offsetHeight;
      this.overlay.style.opacity = "0";
    }

    // Animate panel out
    if (this.panelContent) {
      this.panelContent.style.transition = `transform ${this.duration}ms ease-out`;
      this.panelContent.offsetHeight;
      this.panelContent.style.transform = this._closedTransform;
    }

    // Schedule cleanup after animation
    setTimeout(() => {
      // Nothing to clean up for real panel animation
    }, this.duration + 50);
  }

  /**
   * Clean up ghost elements after close animation.
   * @param {boolean} instant - If true, remove instantly. If false, fade out first.
   */
  _cleanupCloseAnimation(instant = true) {
    if (this._preUpdateContentClone?.parentNode) {
      if (instant) {
        this._preUpdateContentClone.remove();
      } else {
        // Fade out ghost panel
        this._preUpdateContentClone.style.transition = `opacity ${this.duration / 2}ms ease-out`;
        this._preUpdateContentClone.style.opacity = "0";
        setTimeout(() => {
          if (this._preUpdateContentClone?.parentNode) {
            this._preUpdateContentClone.remove();
          }
          this._preUpdateContentClone = null;
        }, this.duration / 2);
      }
    } else {
      this._preUpdateContentClone = null;
    }

    if (this._ghostOverlay?.parentNode) {
      if (instant) {
        this._ghostOverlay.remove();
        this._ghostOverlay = null;
      } else {
        // Fade out ghost overlay
        this._ghostOverlay.style.transition = `opacity ${this.duration / 2}ms ease-out`;
        this._ghostOverlay.style.opacity = "0";
        setTimeout(() => {
          if (this._ghostOverlay?.parentNode) {
            this._ghostOverlay.remove();
          }
          this._ghostOverlay = null;
        }, this.duration / 2);
      }
    } else {
      this._ghostOverlay = null;
    }

    if (this.ghostElement?.parentNode) {
      this.ghostElement.remove();
    }
    this.ghostElement = null;

    this._ghostInsertedInBeforeUpdate = false;
  }

  // --- DOM Reset ---

  /**
   * Reset all DOM state to closed/invisible.
   */
  _resetDOM() {
    console.log(`[FlyoverAnimator] _resetDOM`);

    // Reset internal state
    this._loadingFadedOut = false;
    this._ghostInsertedInBeforeUpdate = false;
    this._preUpdateContentClone = null;

    // Clean up transition handler
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener("transitionend", this._transitionHandler);
      this._transitionHandler = null;
    }

    // Wrapper - invisible (structural classes via js for patch safety)
    this.js.addClass(this.el, "invisible pointer-events-none");

    // Panel - reset to closed state (set starting animation state via inline styles)
    if (this.panelContent) {
      this.panelContent.style.visibility = "";
      this.panelContent.style.transform = this._closedTransform;
      this.panelContent.style.removeProperty("transition");
    }

    // Overlay - reset (clear inline styles, set starting opacity)
    if (this.overlay) {
      this.overlay.style.visibility = "";
      this.overlay.style.opacity = "0";
      this.overlay.style.removeProperty("transition");
    }

    // Loading - reset to hidden (will be shown in onEntering)
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      this.js.addClass(loadingContent, "hidden opacity-0");
      loadingContent.style.removeProperty("opacity");
      loadingContent.style.removeProperty("transition");
    }

    // Main content - hide so panel shows loading skeleton on next open
    const mainContent = this.getMainContentContainer();
    if (mainContent) {
      this.js.addClass(mainContent, "hidden");
    }
  }

  // --- Capture Pre-Update Rect (no-op for flyover, no FLIP needed) ---
  capturePreUpdateRect(_phase) {
    // Flyovers don't need FLIP animation
  }

  releaseSizeLockIfNeeded() {
    // Flyovers don't need size locking
  }

  // --- Cleanup ---

  /**
   * Clean up when destroyed.
   */
  destroy() {
    this._cleanupCloseAnimation();
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener("transitionend", this._transitionHandler);
    }
  }
}

// Expose globally for flyover hooks
window.Lavash = window.Lavash || {};
window.Lavash.FlyoverAnimator = FlyoverAnimator;
