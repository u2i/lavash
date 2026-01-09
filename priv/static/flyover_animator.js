/**
 * FlyoverAnimator - Flyover-specific DOM manipulation as a SyncedVar delegate.
 *
 * This class implements the SyncedVar delegate interface for flyover-specific
 * behavior including:
 * - Panel slide open/close animations (from any edge)
 * - Overlay fade in/out
 * - Ghost element creation for close animation
 *
 * Usage (handled automatically by LavashOptimistic hook):
 *
 *   const animator = new FlyoverAnimator(flyoverElement, {
 *     duration: 200,
 *     slideFrom: 'right',  // 'left', 'right', 'top', 'bottom'
 *     openField: 'open'
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
   */
  constructor(el, config = {}) {
    this.el = el;
    this.config = config;
    this.duration = config.duration || 200;
    this.slideFrom = config.slideFrom || 'right';
    this.panelIdForLog = `#${el.id}`;

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

    // Transition handler reference
    this._transitionHandler = null;

    // Get transform classes from data attributes
    this._openTransform = el.dataset.openTransform || 'translate-x-0';
    this._closedTransform = el.dataset.closedTransform || this._getDefaultClosedTransform();
  }

  _getDefaultClosedTransform() {
    switch (this.slideFrom) {
      case 'left': return '-translate-x-full';
      case 'right': return 'translate-x-full';
      case 'top': return '-translate-y-full';
      case 'bottom': return 'translate-y-full';
      default: return 'translate-x-full';
    }
  }

  // --- SyncedVar Delegate Callbacks ---

  /**
   * Called when entering the "entering" phase.
   * Shows loading content and animates panel in.
   */
  onEntering(syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onEntering`);

    // Reset DOM state before opening
    this._resetDOM();

    // Make wrapper visible and interactive
    this.el.classList.remove("invisible", "pointer-events-none");

    // Show loading content if present
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      loadingContent.classList.remove("hidden");
      loadingContent.classList.add("opacity-100");
    }

    // Animate panel in
    if (this.panelContent) {
      this.panelContent.classList.add("transition-transform", "ease-out");
      this.panelContent.style.transitionDuration = `${this.duration}ms`;
      // Force reflow
      this.panelContent.offsetHeight;
      // Remove closed transform and add open transform
      this.panelContent.classList.remove(this._closedTransform);
      this.panelContent.classList.add(this._openTransform);

      // Set up transition end handler
      this._transitionHandler = (e) => {
        if (e.target !== this.panelContent) return;
        if (e.propertyName !== 'transform') return;
        console.log(`FlyoverAnimator ${this.panelIdForLog}: transitionend fired`);
        this.panelContent.removeEventListener("transitionend", this._transitionHandler);
        this._transitionHandler = null;
        // Notify SyncedVar that transition completed
        syncedVar.notifyTransitionEnd();
      };
      this.panelContent.addEventListener("transitionend", this._transitionHandler);
    }

    // Animate overlay in
    if (this.overlay) {
      this.overlay.classList.add("transition-opacity", "ease-out");
      this.overlay.style.transitionDuration = `${this.duration}ms`;
      this.overlay.offsetHeight;
      this.overlay.classList.remove("opacity-0");
      this.overlay.classList.add("opacity-50");
    }
  }

  /**
   * Called when entering the "loading" phase.
   * Panel is open but waiting for async data.
   */
  onLoading(_syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onLoading - waiting for async data`);
    // Panel is already open, just waiting for content
  }

  /**
   * Called when entering the "visible" phase.
   * Flyover is fully open and visible.
   */
  onVisible(_syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onVisible`);
    // Panel is now fully visible
    this.el.classList.remove("invisible");
  }

  /**
   * Called when entering the "exiting" phase.
   * Sets up ghost element and animates close.
   */
  onExiting(_syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onExiting`);

    // Disable pointer events immediately
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
   * Resets DOM to closed state and cleans up ghost.
   */
  onIdle(_syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onIdle`);
    this._resetDOM();
    this._cleanupCloseAnimation();
  }

  /**
   * Called when async data arrives.
   */
  onAsyncReady(_syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onAsyncReady`);
    // Swap loading for main content
    const loadEl = this.getLoadingContent();
    const mainContent = this.getMainContentContainer();

    if (loadEl) {
      loadEl.classList.add("hidden", "opacity-0");
      loadEl.classList.remove("opacity-100");
    }
    if (mainContent) {
      mainContent.classList.remove("opacity-0");
      mainContent.classList.add("opacity-100");
    }
  }

  /**
   * Called by LavashOptimistic after a LiveView update.
   */
  onUpdated(animated, _phase) {
    const mainInner = this.getMainContentInner();
    const mainContentLoaded = mainInner && mainInner.offsetHeight > 10;

    const currentPhase = animated.getPhase();
    const loadingContent = this.getLoadingContent();
    const loadingVisible = loadingContent && !loadingContent.classList.contains("hidden");

    console.log(`FlyoverAnimator ${this.panelIdForLog}: onUpdated - phase=${currentPhase}, mainContentLoaded=${mainContentLoaded}, loadingVisible=${loadingVisible}`);

    // If main content is loaded and we're in a loading state, swap content
    if (mainContentLoaded && (currentPhase === "entering" || currentPhase === "loading" || currentPhase === "visible")) {
      if (loadingVisible) {
        console.log(`FlyoverAnimator ${this.panelIdForLog}: swapping loading for content`);
        loadingContent.classList.add("hidden", "opacity-0");
        loadingContent.classList.remove("opacity-100");
      }
      const mainContent = this.getMainContentContainer();
      if (mainContent) {
        mainContent.classList.remove("opacity-0");
        mainContent.classList.add("opacity-100");
      }

      // Notify async ready if needed
      if (!animated.isAsyncReady && currentPhase === "entering") {
        animated.onAsyncDataReady();
      }
    }
  }

  /**
   * Called when content arrives while enter animation is still running.
   */
  onContentReadyDuringEnter(_syncedVar) {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: onContentReadyDuringEnter`);
    // For flyovers, we just swap content without FLIP animation
    const loadEl = this.getLoadingContent();
    if (loadEl && !loadEl.classList.contains("hidden")) {
      loadEl.classList.add("hidden", "opacity-0");
      loadEl.classList.remove("opacity-100");
    }
    const mainContent = this.getMainContentContainer();
    if (mainContent) {
      mainContent.classList.remove("opacity-0");
      mainContent.classList.add("opacity-100");
    }
  }

  // --- Ghost Element Animation ---

  /**
   * Create ghost element before morphdom patches (for server-initiated close).
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
    console.log(`FlyoverAnimator ${this.panelIdForLog}: Ghost inserted via onBeforeElUpdated`);
  }

  /**
   * Set up ghost element animation for close.
   */
  _setupGhostElementAnimation() {
    // Animate overlay out
    if (this.overlay) {
      this.overlay.classList.add("transition-opacity", "ease-out");
      this.overlay.style.transitionDuration = `${this.duration}ms`;
      this.overlay.offsetHeight;
      this.overlay.classList.remove("opacity-50");
      this.overlay.classList.add("opacity-0");
    }

    // Animate panel out
    if (this.panelContent) {
      this.panelContent.classList.add("transition-transform", "ease-out");
      this.panelContent.style.transitionDuration = `${this.duration}ms`;
      this.panelContent.offsetHeight;
      this.panelContent.classList.remove(this._openTransform);
      this.panelContent.classList.add(this._closedTransform);
    }

    // Handle ghost overlay if it was created
    if (this._ghostOverlay) {
      this._ghostOverlay.classList.add("transition-opacity");
      this._ghostOverlay.style.transitionDuration = `${this.duration}ms`;
      this._ghostOverlay.offsetHeight;
      this._ghostOverlay.style.opacity = "0";
    }

    // Handle ghost panel if it was created
    if (this._preUpdateContentClone) {
      const ghost = this._preUpdateContentClone;
      ghost.classList.add("transition-transform");
      ghost.style.transitionDuration = `${this.duration}ms`;
      ghost.offsetHeight;
      // Slide ghost out in the same direction as the panel
      ghost.style.transform = this._getTransformValue(this._closedTransform);
    }
  }

  _getTransformValue(className) {
    switch (className) {
      case '-translate-x-full': return 'translateX(-100%)';
      case 'translate-x-full': return 'translateX(100%)';
      case '-translate-y-full': return 'translateY(-100%)';
      case 'translate-y-full': return 'translateY(100%)';
      case 'translate-x-0':
      case 'translate-y-0':
        return 'translate(0, 0)';
      default: return 'none';
    }
  }

  /**
   * Clean up ghost elements after close animation.
   */
  _cleanupCloseAnimation() {
    if (this.ghostElement?.parentNode) {
      this.ghostElement.remove();
    }
    this.ghostElement = null;

    if (this._ghostOverlay?.parentNode) {
      this._ghostOverlay.remove();
    }
    this._ghostOverlay = null;

    if (this._preUpdateContentClone?.parentNode) {
      this._preUpdateContentClone.remove();
    }
    this._preUpdateContentClone = null;

    this._ghostInsertedInBeforeUpdate = false;
  }

  // --- DOM Reset ---

  /**
   * Reset all DOM state to closed/invisible.
   */
  _resetDOM() {
    console.log(`FlyoverAnimator ${this.panelIdForLog}: _resetDOM`);

    // Clean up animations
    this._cleanupCloseAnimation();

    // Clean up transition handler
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener("transitionend", this._transitionHandler);
      this._transitionHandler = null;
    }

    // Wrapper - invisible
    this.el.classList.add("invisible", "pointer-events-none");

    // Panel - reset to closed state
    if (this.panelContent) {
      this.panelContent.classList.remove(
        "transition-transform", "ease-out", "ease-in-out",
        this._openTransform
      );
      this.panelContent.classList.add(this._closedTransform);
      this.panelContent.style.removeProperty("transform");
      this.panelContent.style.removeProperty("transition");
      this.panelContent.style.removeProperty("transition-duration");
    }

    // Overlay - reset
    if (this.overlay) {
      this.overlay.style.visibility = "";
      this.overlay.classList.remove("opacity-50", "transition-opacity", "ease-out");
      this.overlay.classList.add("opacity-0");
      this.overlay.style.removeProperty("transition-duration");
    }

    // Loading - reset
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      loadingContent.classList.add("hidden", "opacity-0");
      loadingContent.classList.remove("opacity-100");
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
