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
   * Note: FLIP animation is now triggered from the hook's updated() method
   * using the rect stored on the SyncedVar, not from here.
   */
  onAsyncReady(animatedState) {
    console.log(`ModalAnimator ${this.panelIdForLog}: onAsyncReady`);
    // FLIP animation is handled by the hook's updated() method
    // which has access to the pre-captured rect on the SyncedVar
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
   * Run FLIP animation with a pre-captured rect.
   * This is the public API called from the hook's updated() method.
   * The rect should be captured in beforeUpdate() and stored on the SyncedVar.
   *
   * @param {DOMRect} preRect - The panel's bounding rect captured before the DOM update
   */
  runFlipAnimation(preRect) {
    if (!preRect) {
      console.log(`ModalAnimator runFlipAnimation: no preRect provided, skipping`);
      return;
    }
    this._runFlipAnimationWithPreRect(preRect);
  }

  /**
   * Internal FLIP animation implementation with pre-captured rect.
   * Uses CSS transforms like the baseline for GPU-accelerated animation.
   *
   * @param {DOMRect} firstRect - The panel's bounding rect from before the update
   */
  _runFlipAnimationWithPreRect(firstRect) {
    // Guard against running twice (can happen with multiple rapid updates)
    if (this._flipAnimationRunning) {
      console.log(`ModalAnimator _runFlipAnimationWithPreRect: already running, skipping`);
      return;
    }
    this._flipAnimationRunning = true;

    const loadEl = this.getLoadingContent();
    const mainInnerEl = this.getMainContentInner();
    const mainContent = this.getMainContentContainer();

    console.log(`ModalAnimator _runFlipAnimationWithPreRect: mainInnerEl=${!!mainInnerEl}, loadEl=${!!loadEl}, firstRect=${firstRect.width}x${firstRect.height}`);

    // Always hide loading if loadEl exists, even without flip animation
    if (loadEl && !loadEl.classList.contains("hidden")) {
      console.log(`ModalAnimator _runFlipAnimation: hiding loading, current classes:`, loadEl.className);
      // Hide loading with transition (classList with Tailwind classes)
      loadEl.classList.add("transition-opacity", "duration-200");
      loadEl.offsetHeight;
      loadEl.classList.remove("opacity-100");
      loadEl.classList.add("opacity-0");
      console.log(`ModalAnimator _runFlipAnimation: after class changes:`, loadEl.className);
      // Add hidden class after transition
      setTimeout(() => {
        loadEl.classList.add("hidden");
        loadEl.classList.remove("transition-opacity", "duration-200");
        this._flipAnimationRunning = false;
      }, 200);
      // Also show main content
      if (mainContent) {
        mainContent.classList.add("transition-opacity", "duration-200");
        mainContent.offsetHeight;
        mainContent.classList.remove("opacity-0");
        mainContent.classList.add("opacity-100");
      }
    }

    // Bail if no FLIP needed (firstRect is guaranteed to exist since we check in runFlipAnimation)
    if (!this.panelContent || !loadEl) {
      // Reset flag if we're not running full FLIP (fade already started above if loadEl existed)
      if (!loadEl) this._flipAnimationRunning = false;
      return;
    }

    // To measure the panel's FINAL size, we need to temporarily remove loading from layout
    // Otherwise the grid cell won't expand to fit the taller main content
    const savedDisplay = loadEl.style.display;

    // Debug: measure main content inner directly
    const mainInnerRect = mainInnerEl ? mainInnerEl.getBoundingClientRect() : null;
    console.log(`ModalAnimator FLIP debug: mainInnerEl rect=${mainInnerRect ? `${mainInnerRect.width}x${mainInnerRect.height}` : 'null'}`);

    loadEl.style.display = 'none';
    this.panelContent.offsetHeight; // Force reflow
    const lastRect = this.panelContent.getBoundingClientRect();
    loadEl.style.display = savedDisplay; // Restore for fade animation

    console.log(`ModalAnimator FLIP: firstRect=${firstRect.width}x${firstRect.height}, lastRect=${lastRect.width}x${lastRect.height}`);
    if (
      Math.abs(firstRect.width - lastRect.width) < 1 &&
      Math.abs(firstRect.height - lastRect.height) < 1
    ) {
      console.log(`ModalAnimator _runFlipAnimation: size didn't change, skipping FLIP transform`);
      return;
    }

    console.log(`ModalAnimator _runFlipAnimation: running FLIP transform`);
    // Calculate FLIP transform values
    const sX = lastRect.width === 0 ? 1 : firstRect.width / lastRect.width;
    const sY = lastRect.height === 0 ? 1 : firstRect.height / lastRect.height;
    const dX = firstRect.left - lastRect.left + (firstRect.width - lastRect.width) / 2;
    const dY = firstRect.top - lastRect.top + (firstRect.height - lastRect.height) / 2;

    // Set up loading element inverse transform
    // NOTE: Don't set loadEl.style.transition = "none" here - it would kill the opacity fade
    // The transform is instant (no transition needed) while opacity fades via CSS class
    loadEl.style.transform = `scale(${1 / sX},${1 / sY})`;
    loadEl.style.transformOrigin = "top left";

    // Set CSS custom properties for the animation
    this.panelContent.style.setProperty("--flip-translate-x", `${dX}px`);
    this.panelContent.style.setProperty("--flip-translate-y", `${dY}px`);
    this.panelContent.style.setProperty("--flip-scale-x", sX);
    this.panelContent.style.setProperty("--flip-scale-y", sY);
    this.panelContent.style.setProperty("--flip-duration", `${this.duration}ms`);

    // Apply initial transform (Invert step)
    this.panelContent.classList.add("transition-none", "origin-center");
    this.panelContent.style.transform = `translate(var(--flip-translate-x), var(--flip-translate-y)) scale(var(--flip-scale-x), var(--flip-scale-y))`;

    // Force reflow then animate (Play step)
    this.panelContent.offsetHeight;
    requestAnimationFrame(() => {
      this.panelContent.classList.remove("transition-none");
      this.panelContent.classList.add("transition-all", "ease-in-out");
      this.panelContent.style.transitionDuration = "var(--flip-duration)";
      this.panelContent.style.transform = "";

      this.panelContent.addEventListener(
        "transitionend",
        () => {
          this.panelContent.classList.remove("transition-all", "ease-in-out", "origin-center");
          this.panelContent.style.removeProperty("transition-duration");
          this.panelContent.style.removeProperty("--flip-translate-x");
          this.panelContent.style.removeProperty("--flip-translate-y");
          this.panelContent.style.removeProperty("--flip-scale-x");
          this.panelContent.style.removeProperty("--flip-scale-y");
          this.panelContent.style.removeProperty("--flip-duration");
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

// Expose globally for modal hooks
window.Lavash = window.Lavash || {};
window.Lavash.ModalAnimator = ModalAnimator;
