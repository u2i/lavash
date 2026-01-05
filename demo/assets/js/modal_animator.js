/**
 * ModalAnimator - Modal-specific DOM manipulation as an AnimatedState delegate.
 *
 * This class implements the AnimatedState delegate interface for modal-specific
 * behavior including:
 * - Panel open/close animations
 * - Overlay fade in/out
 * - Ghost element creation for close animation
 * - FLIP animation for loading→content transition
 * - onBeforeElUpdated hook for content removal detection
 *
 * Usage (handled automatically by LavashModal hook):
 *
 *   const animator = new ModalAnimator(modalElement, {
 *     duration: 200,
 *     openField: 'product_id'
 *   });
 *
 *   // Set as delegate for AnimatedState
 *   animatedState.setDelegate(animator);
 */

export class ModalAnimator {
  /**
   * Create a ModalAnimator.
   *
   * @param {HTMLElement} el - The modal wrapper element
   * @param {Object} config - Configuration options
   * @param {number} config.duration - Animation duration in ms (default: 200)
   * @param {string} config.openField - The open state field name (for logging)
   */
  constructor(el, config = {}) {
    this.el = el;
    this.config = config;
    this.duration = config.duration || 200;
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
    this._flipPreRect = null;
    this._ghostInsertedInBeforeUpdate = false;
    this._preUpdateContentClone = null;

    // IDs for onBeforeElUpdated detection
    this._mainContentId = `${id}-main_content`;
    this._mainContentInnerId = `${id}-main_content_inner`;

    // Transition handler reference
    this._transitionHandler = null;

    // Callback for notifying AnimatedState of transition end
    this.onTransitionEnd = null;
  }

  // --- AnimatedState Delegate Callbacks ---

  /**
   * Called when entering the "entering" phase.
   * Shows loading content and animates panel open.
   */
  onEntering(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onEntering`);

    // Reset DOM state before opening
    this._resetDOM();

    // Make wrapper visible
    this.el.classList.remove("invisible", "pointer-events-none");

    // Show loading content
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      loadingContent.classList.remove("hidden", "opacity-0");
      loadingContent.classList.add("opacity-100");
    }

    // Animate panel open
    if (this.panelContent) {
      this.panelContent.classList.add("transition-all", "duration-200", "ease-out");
      // Force reflow
      this.panelContent.offsetHeight;
      // Animate to visible state
      this.panelContent.classList.remove("opacity-0", "scale-95");
      this.panelContent.classList.add("opacity-100", "scale-100");

      // Set up transition end handler
      this._transitionHandler = (e) => {
        if (e.target !== this.panelContent) return;
        console.log(`ModalAnimator ${this.panelIdForLog}: transitionend fired`);
        this.panelContent.removeEventListener("transitionend", this._transitionHandler);
        this._transitionHandler = null;
        // Notify AnimatedState that transition completed
        animatedState.notifyTransitionEnd();
      };
      this.panelContent.addEventListener("transitionend", this._transitionHandler);
    }

    // Animate overlay open
    if (this.overlay) {
      this.overlay.classList.add("transition-opacity", "duration-200", "ease-out");
      this.overlay.offsetHeight;
      this.overlay.classList.remove("opacity-0");
      this.overlay.classList.add("opacity-50");
    }
  }

  /**
   * Called when entering the "loading" phase.
   * Panel is open but waiting for async data.
   */
  onLoading(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onLoading - waiting for async data`);
    // Panel is already open, just waiting for content
  }

  /**
   * Called when entering the "visible" phase.
   * Modal is fully open and visible.
   */
  onVisible(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onVisible`);
    // Panel is now fully visible
    this.el.classList.remove("invisible");
  }

  /**
   * Called when entering the "exiting" phase.
   * Sets up ghost element and animates close.
   */
  onExiting(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onExiting`);

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
  onIdle(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onIdle`);
    this._resetDOM();
    this._cleanupCloseAnimation();
  }

  /**
   * Called when async data arrives.
   * Runs FLIP animation from loading to content.
   */
  onAsyncReady(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onAsyncReady - running FLIP animation`);
    this._runFlipAnimation();
  }

  /**
   * Called when enter transition completes (forwarded from onEntering handler).
   * This is for internal tracking, AnimatedState handles the phase transition.
   */
  onTransitionEnd(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onTransitionEnd`);
    // AnimatedState handles the phase transition
  }

  // --- FLIP Animation Support ---

  /**
   * Capture panel rect before update for FLIP animation.
   * Call this in beforeUpdate() of the hook.
   */
  capturePreUpdateRect() {
    if (this.panelContent && this.getLoadingContent()) {
      this._flipPreRect = this.panelContent.getBoundingClientRect();
      this._sizeLockApplied = true;

      // CRITICAL: Lock the panel to its current size to prevent flash during DOM patch
      // This ensures the panel doesn't visually resize until we explicitly animate it
      this.panelContent.style.width = `${this._flipPreRect.width}px`;
      this.panelContent.style.height = `${this._flipPreRect.height}px`;

      // Disable all transitions during the update to prevent any flash
      this.panelContent.style.transition = "none";
      if (this.overlay) {
        this.overlay.style.transition = "none";
      }
    }
  }

  /**
   * Release size lock if it wasn't released by FLIP animation.
   * Call this at the end of updated() if FLIP didn't run.
   */
  releaseSizeLockIfNeeded() {
    if (this._sizeLockApplied) {
      this._sizeLockApplied = false;
      if (this.panelContent) {
        this.panelContent.style.removeProperty("width");
        this.panelContent.style.removeProperty("height");
        this.panelContent.style.removeProperty("transition");
      }
      if (this.overlay) {
        this.overlay.style.removeProperty("transition");
      }
    }
  }

  /**
   * Run FLIP animation if panel size changed.
   * Call this after content arrives (in onAsyncReady or onUpdate).
   */
  _runFlipAnimation() {
    const loadEl = this.getLoadingContent();
    const mainInnerEl = this.getMainContentInner();
    const mainContent = this.getMainContentContainer();

    console.log(`ModalAnimator _runFlipAnimation: mainInnerEl=${!!mainInnerEl}, loadEl=${!!loadEl}, _flipPreRect=${!!this._flipPreRect}`);

    // Helper to release size lock and restore transitions
    const releaseSizeLock = () => {
      this._sizeLockApplied = false;
      if (this.panelContent) {
        this.panelContent.style.removeProperty("width");
        this.panelContent.style.removeProperty("height");
        this.panelContent.style.removeProperty("transition");
      }
      if (this.overlay) {
        this.overlay.style.removeProperty("transition");
      }
    };

    // If no FLIP rect captured or no panel, just do content swap
    if (!this._flipPreRect || !this.panelContent || !loadEl) {
      this._flipPreRect = null;
      releaseSizeLock();

      // Still need to swap content visibility
      if (loadEl && !loadEl.classList.contains("hidden")) {
        loadEl.classList.add("hidden", "opacity-0");
        loadEl.classList.remove("opacity-100");
      }
      if (mainContent) {
        mainContent.classList.remove("opacity-0");
        mainContent.classList.add("opacity-100");
      }
      return;
    }

    const firstRect = this._flipPreRect;
    this._flipPreRect = null;

    // Measure the new content size while panel is still locked at old size
    // We measure the main content inner element to get the natural size
    let targetWidth = firstRect.width;
    let targetHeight = firstRect.height;

    if (mainInnerEl) {
      // Get the scroll dimensions of the content
      targetWidth = mainInnerEl.scrollWidth;
      targetHeight = mainInnerEl.scrollHeight;

      // Account for panel padding by measuring the difference
      const panelStyle = getComputedStyle(this.panelContent);
      const paddingX = parseFloat(panelStyle.paddingLeft) + parseFloat(panelStyle.paddingRight);
      const paddingY = parseFloat(panelStyle.paddingTop) + parseFloat(panelStyle.paddingBottom);

      // The target size is the content plus padding (panel's natural size with new content)
      targetWidth = targetWidth + paddingX;
      targetHeight = targetHeight + paddingY;
    }

    // Skip if size didn't change significantly
    if (
      Math.abs(firstRect.width - targetWidth) < 1 &&
      Math.abs(firstRect.height - targetHeight) < 1
    ) {
      releaseSizeLock();
      // Still swap content visibility
      if (loadEl && !loadEl.classList.contains("hidden")) {
        loadEl.classList.add("hidden", "opacity-0");
        loadEl.classList.remove("opacity-100");
      }
      if (mainContent) {
        mainContent.classList.remove("opacity-0");
        mainContent.classList.add("opacity-100");
      }
      return;
    }

    // Panel is still locked at old size, swap content visibility ATOMICALLY
    // Show main content BEFORE hiding loading to prevent any gap
    if (mainContent) {
      mainContent.classList.remove("opacity-0");
      mainContent.classList.add("opacity-100");
    }
    // Now hide loading (main is already visible underneath in grid)
    if (loadEl && !loadEl.classList.contains("hidden")) {
      loadEl.classList.add("hidden", "opacity-0");
      loadEl.classList.remove("opacity-100");
    }

    // Mark size lock as released since we're starting animation
    this._sizeLockApplied = false;

    // Animate to new size
    requestAnimationFrame(() => {
      // Re-enable transitions for the animation
      this.panelContent.style.transition = "";
      if (this.overlay) {
        this.overlay.style.transition = "";
      }

      this.panelContent.classList.add("transition-all", "ease-in-out");
      this.panelContent.style.transitionDuration = `${this.duration}ms`;
      this.panelContent.style.width = `${targetWidth}px`;
      this.panelContent.style.height = `${targetHeight}px`;

      this.panelContent.addEventListener(
        "transitionend",
        (e) => {
          if (e.target !== this.panelContent) return;
          this.panelContent.classList.remove("transition-all", "ease-in-out");
          this.panelContent.style.removeProperty("transition-duration");
          this.panelContent.style.removeProperty("width");
          this.panelContent.style.removeProperty("height");
        },
        { once: true }
      );
    });
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

    // Get position for fixed positioning on body
    const rect = originalElement.getBoundingClientRect();

    // Get panel background for ghost
    const panelBg = this.panelContent
      ? getComputedStyle(this.panelContent).backgroundColor
      : "white";

    Object.assign(this._preUpdateContentClone.style, {
      position: "fixed",
      top: `${rect.top}px`,
      left: `${rect.left}px`,
      width: `${rect.width}px`,
      margin: "0",
      pointerEvents: "none",
      zIndex: "9999",
      backgroundColor: panelBg,
      borderRadius: this.panelContent
        ? getComputedStyle(this.panelContent).borderRadius
        : "0.5rem",
    });

    // Insert ghost on document.body (outside morphdom)
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

    // Hide original to prevent flash when morphdom removes it
    originalElement.style.visibility = "hidden";
    if (this.overlay) {
      this.overlay.style.visibility = "hidden";
    }

    this._ghostInsertedInBeforeUpdate = true;
    console.log(`ModalAnimator ${this.panelIdForLog}: Ghost inserted via onBeforeElUpdated`);
  }

  /**
   * Set up ghost element animation for close.
   */
  _setupGhostElementAnimation() {
    // Check if ghost was already inserted via onBeforeElUpdated
    if (this._ghostInsertedInBeforeUpdate && this._preUpdateContentClone) {
      console.log(`ModalAnimator ${this.panelIdForLog}: Using ghost from onBeforeElUpdated`);
      this.ghostElement = this._preUpdateContentClone;
      this._preUpdateContentClone = null;
      this._ghostInsertedInBeforeUpdate = false;

      // Animate ghost overlay out
      if (this._ghostOverlay) {
        this._ghostOverlay.classList.add("transition-opacity", "duration-200", "ease-out");
        this._ghostOverlay.offsetHeight;
        this._ghostOverlay.style.opacity = "0";
      }

      // Animate ghost panel out
      requestAnimationFrame(() => {
        this.ghostElement.classList.add("transition-all", "duration-200", "ease-out", "origin-center");
        this.ghostElement.offsetHeight;
        requestAnimationFrame(() => {
          this.ghostElement.style.opacity = "0";
          this.ghostElement.style.transform = "scale(0.95)";
        });
      });

      // Also animate the real panel out (it's hidden but we need it reset for next open)
      if (this.panelContent) {
        this.panelContent.classList.add("transition-all", "duration-200", "ease-out");
        this.panelContent.offsetHeight;
        this.panelContent.classList.remove("opacity-100", "scale-100");
        this.panelContent.classList.add("opacity-0", "scale-95");
      }
      return;
    }

    // Fallback: create ghost from current content (user-initiated close)
    const originalMainContentInner = this.getMainContentInner();

    if (!originalMainContentInner && !this._preUpdateContentClone) {
      return;
    }

    if (originalMainContentInner) {
      this.ghostElement = originalMainContentInner.cloneNode(true);
      originalMainContentInner.remove();
    } else {
      this.ghostElement = this._preUpdateContentClone;
      this._preUpdateContentClone = null;
    }

    this.ghostElement.removeAttribute("phx-remove");
    Object.assign(this.ghostElement.style, {
      pointerEvents: "none",
      zIndex: "61",
    });

    // Insert ghost into panel
    const mainContentContainer = this.getMainContentContainer();
    if (mainContentContainer) {
      mainContentContainer.appendChild(this.ghostElement);
    } else if (this.panelContent) {
      this.panelContent.appendChild(this.ghostElement);
    } else {
      this.ghostElement = null;
      return;
    }

    // Animate ghost out
    requestAnimationFrame(() => {
      this.ghostElement.classList.add("transition-all", "duration-200", "ease-out", "origin-center");
      this.ghostElement.offsetHeight;
      this.ghostElement.style.opacity = "0";
      this.ghostElement.style.transform = "scale(0.95)";
    });

    // Animate panel out
    if (this.panelContent) {
      this.panelContent.classList.add("transition-all", "duration-200", "ease-out");
      this.panelContent.offsetHeight;
      this.panelContent.classList.remove("opacity-100", "scale-100");
      this.panelContent.classList.add("opacity-0", "scale-95");
    }

    // Animate overlay out
    if (this.overlay) {
      this.overlay.classList.add("transition-opacity", "duration-200", "ease-out");
      this.overlay.offsetHeight;
      this.overlay.classList.remove("opacity-50");
      this.overlay.classList.add("opacity-0");
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
  }

  // --- DOM Reset ---

  /**
   * Reset all DOM state to closed/invisible.
   */
  _resetDOM() {
    console.log(`ModalAnimator ${this.panelIdForLog}: _resetDOM`);

    // Clean up animations
    this._cleanupCloseAnimation();
    this._flipPreRect = null;
    this._ghostInsertedInBeforeUpdate = false;
    this._preUpdateContentClone = null;

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
        "opacity-100", "scale-100",
        "transition-all", "transition-opacity", "transition-none",
        "ease-out", "ease-in-out", "origin-center"
      );
      // Remove duration-* classes
      [...this.panelContent.classList]
        .filter(c => c.startsWith("duration-"))
        .forEach(c => this.panelContent.classList.remove(c));

      this.panelContent.classList.add("opacity-0", "scale-95");
      this.panelContent.style.removeProperty("transform");
      this.panelContent.style.removeProperty("transition");
      this.panelContent.style.removeProperty("transition-duration");
      this.panelContent.style.removeProperty("width");
      this.panelContent.style.removeProperty("height");
      this.panelContent.style.removeProperty("--flip-translate-x");
      this.panelContent.style.removeProperty("--flip-translate-y");
      this.panelContent.style.removeProperty("--flip-scale-x");
      this.panelContent.style.removeProperty("--flip-scale-y");
      this.panelContent.style.removeProperty("--flip-duration");
    }

    // Overlay - reset
    if (this.overlay) {
      this.overlay.style.visibility = "";
      this.overlay.classList.remove("opacity-50", "transition-opacity", "ease-out");
      [...this.overlay.classList]
        .filter(c => c.startsWith("duration-"))
        .forEach(c => this.overlay.classList.remove(c));
      this.overlay.classList.add("opacity-0");
    }

    // Loading - reset
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      loadingContent.classList.add("hidden", "opacity-0");
      loadingContent.classList.remove("opacity-100", "transition-opacity", "ease-out");
      [...loadingContent.classList]
        .filter(c => c.startsWith("duration-"))
        .forEach(c => loadingContent.classList.remove(c));
      loadingContent.style.removeProperty("transform");
      loadingContent.style.removeProperty("transition");
      loadingContent.style.removeProperty("transform-origin");
    }
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
