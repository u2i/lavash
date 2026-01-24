// Debug: Animation speed multiplier (1 = normal, 0.1 = 10x slower, 2 = 2x faster)
const ANIMATION_SPEED = 1;

/**
 * OverlayAnimator - Unified DOM manipulation for modal and flyover overlays.
 *
 * This class implements the SyncedVar delegate interface for overlay-specific
 * behavior including:
 * - Panel open/close animations (opacity, transform, optionally size)
 * - Overlay fade in/out
 * - Ghost element creation for close animation
 * - Unified transition from loading→content (interrupts enter animation if needed)
 * - onBeforeElUpdated hook for content removal detection
 *
 * Usage (handled automatically by LavashOptimistic hook):
 *
 *   // Modal
 *   const animator = new OverlayAnimator(modalElement, {
 *     type: 'modal',
 *     duration: 200,
 *     openField: 'product_id',
 *     js: this.js()
 *   });
 *
 *   // Flyover
 *   const animator = new OverlayAnimator(flyoverElement, {
 *     type: 'flyover',
 *     slideFrom: 'right',
 *     duration: 200,
 *     openField: 'open',
 *     js: this.js()
 *   });
 */
export class OverlayAnimator {
  /**
   * Create an OverlayAnimator.
   *
   * @param {HTMLElement} el - The overlay wrapper element
   * @param {Object} config - Configuration options
   * @param {string} config.type - 'modal' or 'flyover'
   * @param {string} config.slideFrom - For flyover: 'left', 'right', 'top', 'bottom'
   * @param {number} config.duration - Animation duration in ms (default: 200)
   * @param {string} config.openField - The open state field name (for logging)
   * @param {Object} config.js - LiveView JS commands interface (this.js() from hook)
   */
  constructor(el, config = {}) {
    this.el = el;
    this.config = config;
    this.type = config.type || "modal";
    this.slideFrom = config.slideFrom || "right";

    // Apply speed multiplier: lower = slower (0.1 = 10x slower)
    this.duration = (config.duration || 200) / ANIMATION_SPEED;
    this.panelIdForLog = `#${el.id}`;
    this.js = config.js;

    // Type-specific animation config
    this._initAnimationConfig();

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
    this._sizeLockApplied = false;
    this._transitionHandler = null;
    this._loadingFadedOut = false;
  }

  /**
   * Initialize type-specific animation configuration.
   */
  _initAnimationConfig() {
    if (this.type === "modal") {
      this._openTransform = "scale(1)";
      this._closedTransform = "scale(0.95)";
      this._panelFades = true; // Modal panel fades in/out
      this._animatesSize = true; // Modal animates width/height
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

  // --- SyncedVar Delegate Callbacks ---

  /**
   * Called when entering the "entering" phase.
   * Shows loading content and animates panel open.
   */
  onEntering(syncedVar) {
    // Check if this is a reopen (interrupting close animation)
    const isReopen =
      !!this._ghostOverlay || !this.el.classList.contains("invisible");
    console.log(
      `[OverlayAnimator:${this.type}] onEntering: isReopen=${isReopen}`
    );

    if (isReopen) {
      // Clean up any ghost elements INSTANTLY (no fade) to avoid duplicates
      this._cleanupCloseAnimation(true);
      // Reset internal state but don't touch wrapper visibility
      this._sizeLockApplied = false;
      this._loadingFadedOut = false;
      this._ghostInsertedInBeforeUpdate = false;
      this._preUpdateContentClone = null;
      // Clean up transition handler
      if (this.panelContent && this._transitionHandler) {
        this.panelContent.removeEventListener(
          "transitionend",
          this._transitionHandler
        );
        this._transitionHandler = null;
      }
      // Clear visibility:hidden that onExiting sets during ghost animation
      if (this.panelContent) this.panelContent.style.visibility = "";
      if (this.overlay) this.overlay.style.visibility = "";
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
      this.js.removeClass(loadingContent, "hidden");
      loadingContent.classList.remove("hidden");
      // Use inline styles for animation (starting at opacity 0)
      loadingContent.style.opacity = "0";
      loadingContent.style.transition = "none";
      loadingContent.offsetHeight; // Force reflow
      loadingContent.style.transition = `opacity ${this.duration}ms ease-out`;
      loadingContent.offsetHeight; // Force reflow
      loadingContent.style.opacity = "1";
      this.js.removeClass(loadingContent, "opacity-0");
    }

    // Animate panel in
    if (this.panelContent) {
      // Check current state before animating (for reopen handling)
      const currentOpacity = this._panelFades
        ? parseFloat(getComputedStyle(this.panelContent).opacity)
        : 1;
      const alreadyVisible = currentOpacity > 0.5;
      console.log(
        `[OverlayAnimator:${this.type}] onEntering: alreadyVisible=${alreadyVisible}, opacity=${currentOpacity}`
      );
      console.log(
        `[OverlayAnimator:${this.type}] onEntering: wrapper.class="${this.el.className}"`
      );

      if (alreadyVisible) {
        // Panel is already visible (reopen case) - don't animate, just ensure it's at open state
        this.panelContent.style.transform = this._openTransform;
        if (this._panelFades) {
          this.panelContent.style.opacity = "1";
        }
        this.panelContent.style.transition = "none";
        // Still need to notify transition end since we're skipping the animation
        setTimeout(() => syncedVar.notifyTransitionEnd(), 0);
      } else {
        // Set initial state (closed position)
        this.panelContent.style.transform = this._closedTransform;
        if (this._panelFades) {
          this.panelContent.style.opacity = "0";
        }
        this.panelContent.offsetHeight; // Force reflow

        // Build transition string
        let transitionProps = [`transform ${this.duration}ms ease-out`];
        if (this._panelFades) {
          transitionProps.push(`opacity ${this.duration}ms ease-out`);
        }
        this.panelContent.style.transition = transitionProps.join(", ");
        this.panelContent.offsetHeight; // Force reflow

        // Animate to open state
        this.panelContent.style.transform = this._openTransform;
        if (this._panelFades) {
          this.panelContent.style.opacity = "1";
        }

        // Set up transition end handler
        this._transitionHandler = (e) => {
          if (e.target !== this.panelContent) return;
          if (e.propertyName !== "transform") return;
          this.panelContent.removeEventListener(
            "transitionend",
            this._transitionHandler
          );
          this._transitionHandler = null;
          syncedVar.notifyTransitionEnd();
        };
        this.panelContent.addEventListener(
          "transitionend",
          this._transitionHandler
        );
      }
    }

    // Animate overlay in
    if (this.overlay) {
      this.overlay.style.transition = `opacity ${this.duration}ms ease-out`;
      this.overlay.offsetHeight;
      this.overlay.style.opacity = "0.5";
    }
  }

  /**
   * Called when entering the "loading" phase.
   */
  onLoading(_syncedVar) {
    console.log(`[OverlayAnimator:${this.type}] onLoading`);
  }

  /**
   * Called when entering the "visible" phase.
   */
  onVisible(_syncedVar) {
    console.log(`[OverlayAnimator:${this.type}] onVisible`);
    this.js.removeClass(this.el, "invisible");
  }

  /**
   * Called when entering the "exiting" phase.
   */
  onExiting(_syncedVar) {
    console.log(`[OverlayAnimator:${this.type}] onExiting`);

    // Disable pointer events immediately
    this.js.addClass(this.el, "pointer-events-none");
    this.el.classList.add("pointer-events-none");

    // Remove pending transition handlers
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener(
        "transitionend",
        this._transitionHandler
      );
      this._transitionHandler = null;
    }

    // Set up ghost element animation
    this._setupGhostElementAnimation();
  }

  /**
   * Called when entering the "idle" phase.
   */
  onIdle(_syncedVar) {
    this._resetDOM();
  }

  /**
   * Called when async data arrives.
   */
  onAsyncReady(_syncedVar) {
    console.log(`[OverlayAnimator:${this.type}] onAsyncReady`);
  }

  /**
   * Called by LavashOptimistic after a LiveView update.
   */
  onUpdated(animated, _phase) {
    const mainInner = this.getMainContentInner();
    const mainContentLoaded = mainInner && mainInner.children.length > 0;

    const currentPhase = animated.getPhase();
    const loadingContent = this.getLoadingContent();
    const loadingVisible =
      loadingContent && !loadingContent.classList.contains("hidden");

    console.log(
      `[OverlayAnimator:${this.type}] onUpdated: phase=${currentPhase}, mainContentLoaded=${mainContentLoaded}, loadingVisible=${loadingVisible}`
    );

    // Handle content arrival
    if (mainContentLoaded && !animated.isAsyncReady) {
      animated.onAsyncDataReady();
      // For loading or visible phase with loading showing, trigger transition
      if (
        (currentPhase === "loading" || currentPhase === "visible") &&
        loadingVisible
      ) {
        this._transitionToContent(animated);
      }
      return;
    }

    // Edge case: visible phase with loading still showing
    if (mainContentLoaded && currentPhase === "visible" && loadingVisible) {
      this._transitionToContent(animated);
    }

    // Release size lock if it wasn't used (modal only)
    if (this._animatesSize) {
      this.releaseSizeLockIfNeeded();
    }
  }

  /**
   * Called when content arrives while enter animation is still running.
   */
  onContentReadyDuringEnter(syncedVar) {
    console.log(`[OverlayAnimator:${this.type}] onContentReadyDuringEnter`);
    this._transitionToContent(syncedVar);
  }

  /**
   * Unified transition to content state.
   */
  _transitionToContent(syncedVar) {
    const mainContent = this.getMainContentContainer();
    const mainInnerEl = this.getMainContentInner();
    const loadingContent = this.getLoadingContent();

    if (!this.panelContent || !mainInnerEl) {
      console.log(
        `[OverlayAnimator:${this.type}] _transitionToContent: missing elements`
      );
      return;
    }

    // 1. Capture and freeze loading state
    let loadingCurrentOpacity = "0";
    if (loadingContent) {
      loadingCurrentOpacity = getComputedStyle(loadingContent).opacity;
      loadingContent.style.transition = "none";
      loadingContent.offsetHeight;
      loadingContent.style.opacity = loadingCurrentOpacity;
    }

    // 2. Capture and freeze panel state
    const computedStyle = getComputedStyle(this.panelContent);
    const currentTransform = computedStyle.transform;
    const currentOpacity = this._panelFades ? computedStyle.opacity : "1";
    const currentWidth = parseFloat(computedStyle.width);
    const currentHeight = parseFloat(computedStyle.height);

    console.log(
      `[OverlayAnimator:${this.type}] _transitionToContent: transform=${currentTransform}, opacity=${currentOpacity}`
    );
    console.log(
      `[OverlayAnimator:${this.type}] _transitionToContent: wrapper.class="${this.el.className}", panel.class="${this.panelContent.className}"`
    );
    console.log(
      `[OverlayAnimator:${this.type}] _transitionToContent: mainContent.class="${mainContent?.className}", mainContent.hidden=${mainContent?.classList.contains('hidden')}`
    );

    // Freeze panel
    this.panelContent.style.transition = "none";
    this.panelContent.style.transform = currentTransform;
    if (this._panelFades) {
      this.panelContent.style.opacity = currentOpacity;
    }
    if (this._animatesSize) {
      this.panelContent.style.width = `${currentWidth}px`;
      this.panelContent.style.height = `${currentHeight}px`;
      this.panelContent.style.overflow = "hidden";
    }

    // Remove enter transition handler
    if (this._transitionHandler) {
      this.panelContent.removeEventListener(
        "transitionend",
        this._transitionHandler
      );
      this._transitionHandler = null;
    }

    // 3. Show main content at opacity 0
    if (mainContent) {
      this.js.removeClass(mainContent, "hidden");
      mainContent.classList.remove("hidden");
      mainContent.style.transition = "none";
      mainContent.style.opacity = "0";
      mainContent.offsetHeight;
    }

    // 4. Measure target size (modal only)
    let targetWidth = currentWidth;
    let targetHeight = currentHeight;
    if (this._animatesSize) {
      const lockedWidth = this.panelContent.style.width;
      const lockedHeight = this.panelContent.style.height;
      this.panelContent.style.visibility = "hidden";
      this.panelContent.style.width = "";
      this.panelContent.style.height = "";
      this.panelContent.offsetHeight;
      const targetStyle = getComputedStyle(this.panelContent);
      targetWidth = parseFloat(targetStyle.width);
      targetHeight = parseFloat(targetStyle.height);
      this.panelContent.style.width = lockedWidth;
      this.panelContent.style.height = lockedHeight;
      this.panelContent.offsetHeight;
      this.panelContent.style.visibility = "";
    }

    // 5. Set up transitions
    let panelTransitions = [`transform ${this.duration}ms ease-out`];
    if (this._panelFades) {
      panelTransitions.push(`opacity ${this.duration}ms ease-out`);
    }
    if (this._animatesSize) {
      panelTransitions.push(`width ${this.duration}ms ease-out`);
      panelTransitions.push(`height ${this.duration}ms ease-out`);
    }
    this.panelContent.style.transition = panelTransitions.join(", ");

    if (mainContent) {
      mainContent.style.transition = `opacity ${this.duration}ms ease-out`;
    }

    // Counter-fade loading
    // For modals: use panel opacity for counter-fade calculation
    // For flyovers: use loading's own opacity (panel doesn't fade)
    const referenceOpacity = this._panelFades
      ? parseFloat(currentOpacity)
      : parseFloat(loadingCurrentOpacity);
    const shouldFadeLoading = loadingContent && referenceOpacity >= 0.1;

    if (loadingContent) {
      loadingContent.style.opacity = loadingCurrentOpacity;
      if (shouldFadeLoading) {
        const loadingFadeDuration = this.duration * referenceOpacity;
        loadingContent.style.transition = `opacity ${loadingFadeDuration}ms ease-out`;
      } else {
        loadingContent.style.transition = "none";
      }
    }

    // Force reflow on each element
    this.panelContent.offsetHeight;
    if (mainContent) mainContent.offsetHeight;
    if (loadingContent) loadingContent.offsetHeight;

    // 6. Trigger animations
    this.panelContent.style.transform = this._openTransform;
    if (this._panelFades) {
      this.panelContent.style.opacity = "1";
    }
    if (this._animatesSize) {
      this.panelContent.style.width = `${targetWidth}px`;
      this.panelContent.style.height = `${targetHeight}px`;
    }
    if (mainContent) {
      mainContent.style.opacity = "1";
    }
    if (loadingContent) {
      loadingContent.style.opacity = "0";
      if (shouldFadeLoading) {
        const loadingFadeDuration = this.duration * referenceOpacity;
        setTimeout(() => {
          this.js.addClass(loadingContent, "hidden");
          loadingContent.style.removeProperty("transition");
        }, loadingFadeDuration);
      } else {
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
      if (this._animatesSize) {
        this.panelContent.style.removeProperty("width");
        this.panelContent.style.removeProperty("height");
        this.panelContent.style.removeProperty("overflow");
      }
      if (syncedVar?.getPhase() === "entering") {
        syncedVar.notifyTransitionEnd();
      }
    };
    this.panelContent.addEventListener("transitionend", cleanup);

    this._loadingFadedOut = true;
  }

  // --- Size Lock (Modal only) ---

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

  createGhostBeforePatch(originalElement) {
    const rect = originalElement.getBoundingClientRect();

    // Skip if element has zero dimensions (hidden, not laid out, or stale response)
    if (rect.width === 0 || rect.height === 0) {
      console.log(
        `[OverlayAnimator:${this.type}] createGhostBeforePatch: skipping - element has zero dimensions`
      );
      return;
    }

    this._preUpdateContentClone = originalElement.cloneNode(true);
    this._preUpdateContentClone.id = `${originalElement.id}_ghost`;
    const panelBg = this.panelContent
      ? getComputedStyle(this.panelContent).backgroundColor
      : "white";
    const borderRadius = this.panelContent
      ? getComputedStyle(this.panelContent).borderRadius
      : "0";

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
      borderRadius: borderRadius,
      transform: this._openTransform,
      opacity: this._panelFades ? "1" : undefined,
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

    originalElement.style.visibility = "hidden";
    if (this.overlay) this.overlay.style.visibility = "hidden";

    this._ghostInsertedInBeforeUpdate = true;
  }

  _setupGhostElementAnimation() {
    // If ghost was created from onBeforeElUpdated, animate it
    if (this._ghostInsertedInBeforeUpdate && this._preUpdateContentClone) {
      // Animate ghost overlay out
      if (this._ghostOverlay) {
        this._ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
        this._ghostOverlay.offsetHeight;
        this._ghostOverlay.style.opacity = "0";
      }

      // Animate ghost panel out
      const ghost = this._preUpdateContentClone;
      let ghostTransitions = [`transform ${this.duration}ms ease-out`];
      if (this._panelFades) {
        ghostTransitions.push(`opacity ${this.duration}ms ease-out`);
      }
      ghost.style.transition = ghostTransitions.join(", ");
      ghost.offsetHeight;
      ghost.style.transform = this._closedTransform;
      if (this._panelFades) {
        ghost.style.opacity = "0";
      }

      // Also animate the real panel out (hidden but needs reset)
      if (this.panelContent) {
        this.panelContent.style.transition = ghostTransitions.join(", ");
        this.panelContent.offsetHeight;
        this.panelContent.style.transform = this._closedTransform;
        if (this._panelFades) {
          this.panelContent.style.opacity = "0";
        }
      }

      // Schedule cleanup
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
    if (!this.panelContent) return;

    const rect = this.panelContent.getBoundingClientRect();

    // Skip if panel has zero dimensions (edge case - shouldn't happen normally)
    if (rect.width === 0 || rect.height === 0) {
      console.log(
        `[OverlayAnimator:${this.type}] _setupGhostElementAnimation: skipping - panel has zero dimensions`
      );
      return;
    }

    const panelBg = getComputedStyle(this.panelContent).backgroundColor;
    const borderRadius = getComputedStyle(this.panelContent).borderRadius;

    this.ghostElement = this.panelContent.cloneNode(true);
    this.ghostElement.removeAttribute("id");
    this.ghostElement.removeAttribute("phx-click");
    this.ghostElement.removeAttribute("phx-target");
    this.ghostElement.removeAttribute("phx-window-keydown");
    this.ghostElement.removeAttribute("phx-key");

    Object.assign(this.ghostElement.style, {
      position: "fixed",
      top: `${rect.top}px`,
      left: `${rect.left}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      margin: "0",
      pointerEvents: "none",
      zIndex: "9999",
      backgroundColor: panelBg,
      borderRadius: borderRadius,
      transform: this._openTransform,
      opacity: this._panelFades ? "1" : undefined,
    });

    document.body.appendChild(this.ghostElement);

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

      this._ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
      this._ghostOverlay.offsetHeight;
      this._ghostOverlay.style.opacity = "0";
    }

    // Hide real panel
    this.panelContent.style.visibility = "hidden";
    if (this.overlay) this.overlay.style.visibility = "hidden";

    // Animate ghost out
    requestAnimationFrame(() => {
      let ghostTransitions = [`transform ${this.duration}ms ease-out`];
      if (this._panelFades) {
        ghostTransitions.push(`opacity ${this.duration}ms ease-out`);
      }
      this.ghostElement.style.transition = ghostTransitions.join(", ");
      this.ghostElement.offsetHeight;
      requestAnimationFrame(() => {
        this.ghostElement.style.transform = this._closedTransform;
        if (this._panelFades) {
          this.ghostElement.style.opacity = "0";
        }
      });
    });

    // Schedule cleanup
    setTimeout(() => {
      if (this.ghostElement?.parentNode) {
        this.ghostElement.remove();
        this.ghostElement = null;
      }
      if (this._ghostOverlay?.parentNode) {
        this._ghostOverlay.remove();
        this._ghostOverlay = null;
      }
    }, this.duration + 50);
  }

  _cleanupCloseAnimation(instant = true) {
    const cleanup = (el) => {
      if (!el?.parentNode) return;
      if (instant) {
        el.remove();
      } else {
        el.style.transition = `opacity ${this.duration / 2}ms ease-out`;
        el.style.opacity = "0";
        setTimeout(() => el.parentNode && el.remove(), this.duration / 2);
      }
    };

    cleanup(this._preUpdateContentClone);
    this._preUpdateContentClone = null;

    cleanup(this._ghostOverlay);
    this._ghostOverlay = null;

    cleanup(this.ghostElement);
    this.ghostElement = null;

    this._ghostInsertedInBeforeUpdate = false;
  }

  // --- DOM Reset ---

  _resetDOM() {
    console.log(`[OverlayAnimator:${this.type}] _resetDOM`);

    this._sizeLockApplied = false;
    this._loadingFadedOut = false;
    this._ghostInsertedInBeforeUpdate = false;
    this._preUpdateContentClone = null;

    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener(
        "transitionend",
        this._transitionHandler
      );
      this._transitionHandler = null;
    }

    // Wrapper
    this.js.addClass(this.el, "invisible pointer-events-none");

    // Panel
    if (this.panelContent) {
      this.panelContent.style.visibility = "";
      this.panelContent.style.transform = this._closedTransform;
      if (this._panelFades) {
        this.panelContent.style.opacity = "0";
      }
      this.panelContent.style.removeProperty("transition");
      if (this._animatesSize) {
        this.panelContent.style.removeProperty("width");
        this.panelContent.style.removeProperty("height");
      }
    }

    // Overlay
    if (this.overlay) {
      this.overlay.style.visibility = "";
      this.overlay.style.opacity = "0";
      this.overlay.style.removeProperty("transition");
    }

    // Loading
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      this.js.addClass(loadingContent, "hidden opacity-0");
      loadingContent.style.removeProperty("opacity");
      loadingContent.style.removeProperty("transition");
    }

    // Main content
    const mainContent = this.getMainContentContainer();
    if (mainContent) {
      this.js.addClass(mainContent, "hidden");
    }
  }

  // --- Cleanup ---

  destroy() {
    this._cleanupCloseAnimation();
    if (this.panelContent && this._transitionHandler) {
      this.panelContent.removeEventListener(
        "transitionend",
        this._transitionHandler
      );
    }
  }
}

// Expose globally
window.Lavash = window.Lavash || {};
window.Lavash.OverlayAnimator = OverlayAnimator;

// Keep backwards compatibility aliases
window.Lavash.ModalAnimator = OverlayAnimator;
window.Lavash.FlyoverAnimator = OverlayAnimator;
