// Debug: Animation speed multiplier (1 = normal, 0.1 = 10x slower, 2 = 2x faster)
const ANIMATION_SPEED = 1;

/**
 * ModalAnimator - Modal-specific DOM manipulation as a SyncedVar delegate.
 *
 * This class implements the SyncedVar delegate interface for modal-specific
 * behavior including:
 * - Panel open/close animations (opacity, transform, size)
 * - Overlay fade in/out
 * - Ghost element creation for close animation
 * - Unified transition from loading→content (interrupts enter animation if needed)
 * - onBeforeElUpdated hook for content removal detection
 *
 * Usage (handled automatically by LavashModal hook):
 *
 *   const animator = new ModalAnimator(modalElement, {
 *     duration: 200,
 *     openField: 'product_id'
 *   });
 *
 *   // Set as delegate for SyncedVar (with animated config)
 *   syncedVar.setDelegate(animator);
 */

export class ModalAnimator {
  /**
   * Create a ModalAnimator.
   *
   * @param {HTMLElement} el - The modal wrapper element
   * @param {Object} config - Configuration options
   * @param {number} config.duration - Animation duration in ms (default: 200)
   * @param {string} config.openField - The open state field name (for logging)
   * @param {Object} config.js - LiveView JS commands interface (this.js() from hook)
   */
  constructor(el, config = {}) {
    this.el = el;
    this.config = config;
    // Apply speed multiplier: lower = slower (0.1 = 10x slower)
    this.duration = (config.duration || 200) / ANIMATION_SPEED;
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
    this._sizeLockApplied = false;
    this._transitionHandler = null;
    this._loadingFadedOut = false;
  }

  // --- SyncedVar Delegate Callbacks ---

  /**
   * Called when entering the "entering" phase.
   * Shows loading content and animates panel open.
   */
  onEntering(syncedVar) {
    console.log(`[ModalAnimator] onEntering called`);

    // Check if we're reopening from an interrupted close
    // If wrapper is still visible (not invisible), we're reopening before close completed
    const isReopen = !!this._ghostOverlay || !this.el.classList.contains("invisible");
    console.log(`[ModalAnimator] onEntering: isReopen=${isReopen}, hasGhostOverlay=${!!this._ghostOverlay}, wrapperVisible=${!this.el.classList.contains("invisible")}`);

    // If reopening, don't make wrapper invisible - just clean up and continue
    if (isReopen) {
      // Clean up any ghost elements with fade
      this._cleanupCloseAnimation(false);
      // Reset internal state but don't touch wrapper visibility
      this._sizeLockApplied = false;
      this._enteringLoadingRect = null;
      this._enterAnimationStartTime = null;
      this._loadingFadedOut = false;
      this._ghostInsertedInBeforeUpdate = false;
      this._preUpdateContentClone = null;
      // Clean up transition handler
      if (this.panelContent && this._transitionHandler) {
        this.panelContent.removeEventListener("transitionend", this._transitionHandler);
        this._transitionHandler = null;
      }
    } else {
      // Normal open from idle - full reset
      this._resetDOM(false);
    }

    // Make wrapper visible (structural classes via js for patch safety)
    this.js.removeClass(this.el, "invisible pointer-events-none");

    // Show loading content with fade-in (can be interrupted by content arriving)
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      this.js.removeClass(loadingContent, "hidden");
      // Start at opacity 0, animate to full opacity (inline styles for animation)
      loadingContent.style.opacity = "0";
      loadingContent.style.transition = `opacity ${this.duration}ms ease-out`;
      // Force reflow before changing opacity
      loadingContent.offsetHeight;
      loadingContent.style.opacity = "1";
    }

    // Capture loading skeleton rect NOW - after showing loading but BEFORE scale animation
    // Use offsetWidth/offsetHeight to get LAYOUT size (unaffected by CSS transforms)
    // getBoundingClientRect would give visual size (scaled), which causes mismatch when locking
    if (this.panelContent) {
      // Force layout to ensure loading content is rendered
      this.panelContent.offsetHeight;
      // Store layout dimensions (not affected by scale transform)
      this._enteringLoadingRect = {
        width: this.panelContent.offsetWidth,
        height: this.panelContent.offsetHeight
      };
      // Track when enter animation started for computing remaining time
      this._enterAnimationStartTime = performance.now();
    }

    // Animate panel open (all animation via inline styles)
    if (this.panelContent) {
      // Check current state before animating
      const currentScale = getComputedStyle(this.panelContent).transform;
      const currentOpacity = getComputedStyle(this.panelContent).opacity;
      const alreadyVisible = parseFloat(currentOpacity) > 0.5;
      console.log(`[ModalAnimator] onEntering: before transition, opacity=${currentOpacity}, transform=${currentScale}, alreadyVisible=${alreadyVisible}`);

      if (alreadyVisible) {
        // Panel is already visible (reopen case) - don't animate scale, just ensure it's at full opacity/scale
        this.panelContent.style.opacity = "1";
        this.panelContent.style.transform = "scale(1)";
        this.panelContent.style.transition = "none";
        // Still need to notify transition end since we're skipping the animation
        setTimeout(() => syncedVar.notifyTransitionEnd(), 0);
      } else {
        // Force starting state with inline styles
        this.panelContent.style.opacity = "0";
        this.panelContent.style.transform = "scale(0.95)";
        // Force reflow to apply starting state
        this.panelContent.offsetHeight;

        // Set transition and animate to visible state
        this.panelContent.style.transition = `opacity ${this.duration}ms ease-out, transform ${this.duration}ms ease-out`;
        this.panelContent.offsetHeight;
        this.panelContent.style.opacity = "1";
        this.panelContent.style.transform = "scale(1)";

        // Set up transition end handler - wait for TRANSFORM specifically
        // Opacity and transform animate together, but we need to wait for transform
        // to complete before transitioning state (transform defines the visual "open" state)
        this._transitionHandler = (e) => {
          console.log(`[ModalAnimator] transitionend fired, property=${e.propertyName}, target=${e.target === this.panelContent ? 'panelContent' : 'other'}`);
          if (e.target !== this.panelContent) return;
          // Only proceed when transform completes (not opacity)
          if (e.propertyName !== "transform") return;
          this.panelContent.removeEventListener("transitionend", this._transitionHandler);
          this._transitionHandler = null;
          // Notify SyncedVar that transition completed
          syncedVar.notifyTransitionEnd();
        };
        this.panelContent.addEventListener("transitionend", this._transitionHandler);
      }
    }

    // Animate overlay open (inline styles)
    if (this.overlay) {
      this.overlay.style.transition = `opacity ${this.duration}ms ease-out`;
      this.overlay.offsetHeight;
      this.overlay.style.opacity = "0.5";
    }
  }

  /**
   * Called when entering the "loading" phase.
   * Panel is open but waiting for async data.
   */
  onLoading(_syncedVar) {
    // Panel is already open, just waiting for content
  }

  /**
   * Called when entering the "visible" phase.
   * Modal is fully open and visible.
   */
  onVisible(_syncedVar) {
    console.log(`[ModalAnimator] onVisible called`);
    // Panel is now fully visible (ensure structural class removed via js)
    this.js.removeClass(this.el, "invisible");
    // Content transition is handled by _transitionToContent when content arrives
  }

  /**
   * Called when entering the "exiting" phase.
   * Sets up ghost element and animates close.
   */
  onExiting(_syncedVar) {

    // Disable pointer events immediately (structural class via js)
    this.js.addClass(this.el, "pointer-events-none");

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
   * Note: FLIP animation is now triggered from the hook's updated() method
   * using the rect stored on the SyncedVar, not from here.
   */
  onAsyncReady(_syncedVar) {
    // FLIP animation is handled by the hook's updated() method
    // which has access to the pre-captured rect on the SyncedVar
  }

  /**
   * Called by LavashOptimistic after a LiveView update.
   * Handles modal-specific post-update logic like FLIP animations.
   *
   * @param {AnimatedState} animated - The animated state manager
   * @param {string} _phase - Current animation phase (unused, we get fresh phase from syncedVar)
   */
  onUpdated(animated, _phase) {
    // Check if main content has actually loaded
    // We check for children rather than height, because main_content may be hidden
    // (we hide it in _resetDOM so panel measures only loading skeleton)
    const mainInner = this.getMainContentInner();
    const mainContentLoaded = mainInner && mainInner.children.length > 0;

    const currentPhase = animated.getPhase();
    const loadingContent = this.getLoadingContent();
    const loadingVisible = loadingContent && !loadingContent.classList.contains("hidden");

    console.log(`[ModalAnimator] onUpdated: phase=${currentPhase}, mainContentLoaded=${mainContentLoaded}, loadingVisible=${loadingVisible}, isAsyncReady=${animated.isAsyncReady}`);

    // Handle content arrival - use unified transition approach
    // This works for entering, loading, and visible phases
    if (mainContentLoaded && !animated.isAsyncReady) {
      console.log(`[ModalAnimator] onUpdated: content ready during ${currentPhase} phase, calling onAsyncDataReady`);
      animated.onAsyncDataReady();
      console.log(`[ModalAnimator] onUpdated: after onAsyncDataReady, phase=${animated.getPhase()}, isAsyncReady=${animated.isAsyncReady}`);
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

    // Release size lock if it wasn't used
    this.releaseSizeLockIfNeeded();
  }

  /**
   * Called when content arrives while enter animation is still running.
   * Interrupts the enter animation and transitions directly to final content state.
   */
  onContentReadyDuringEnter(syncedVar) {
    console.log(`[ModalAnimator] onContentReadyDuringEnter called`);
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
      console.log(`[ModalAnimator] _transitionToContent: missing elements, skipping`);
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

    // Now capture and freeze panel
    const computedStyle = getComputedStyle(this.panelContent);
    const currentOpacity = computedStyle.opacity;
    const currentTransform = computedStyle.transform;
    const currentWidth = parseFloat(computedStyle.width);
    const currentHeight = parseFloat(computedStyle.height);

    console.log(`[ModalAnimator] _transitionToContent: current state - opacity=${currentOpacity}, transform=${currentTransform}, size=${currentWidth}x${currentHeight}`);
    console.log(`[ModalAnimator] _transitionToContent: loading opacity when content arrives: ${loadingCurrentOpacity}`);

    // 2. Freeze panel to current state
    this.panelContent.style.transition = "none";
    this.panelContent.style.opacity = currentOpacity;
    this.panelContent.style.transform = currentTransform;
    this.panelContent.style.width = `${currentWidth}px`;
    this.panelContent.style.height = `${currentHeight}px`;
    this.panelContent.style.overflow = "hidden";

    // Remove enter transition handler since we're taking over
    if (this._transitionHandler) {
      this.panelContent.removeEventListener("transitionend", this._transitionHandler);
      this._transitionHandler = null;
    }

    // 3. Measure target content size BEFORE starting any animations
    // Temporarily remove size constraints to measure natural CSS-defined size
    // Use visibility:hidden to prevent flash during measurement
    // Show main content (hidden) so it contributes to size calculation
    if (mainContent) {
      this.js.removeClass(mainContent, "hidden");
      mainContent.classList.remove("hidden");
      mainContent.style.opacity = "0";
    }

    const lockedWidth = this.panelContent.style.width;
    const lockedHeight = this.panelContent.style.height;
    this.panelContent.style.visibility = "hidden";
    this.panelContent.style.width = "";
    this.panelContent.style.height = "";
    this.panelContent.offsetHeight; // Force reflow
    const targetStyle = getComputedStyle(this.panelContent);
    const targetWidth = parseFloat(targetStyle.width);
    const targetHeight = parseFloat(targetStyle.height);
    console.log(`[ModalAnimator] _transitionToContent: target size=${targetWidth}x${targetHeight}`);
    // Re-apply lock for animation
    this.panelContent.style.width = lockedWidth;
    this.panelContent.style.height = lockedHeight;
    this.panelContent.offsetHeight; // Force reflow
    this.panelContent.style.visibility = "";

    // 4. Start ALL animations together in the same frame
    // Panel: opacity, transform, width, height
    // Content: fade in
    // Loading: fade out
    this.panelContent.style.transition = `opacity ${this.duration}ms ease-out, transform ${this.duration}ms ease-out, width ${this.duration}ms ease-out, height ${this.duration}ms ease-out`;
    if (mainContent) {
      mainContent.style.transition = `opacity ${this.duration}ms ease-out`;
    }
    // Counter-fade loading to negate the panel's fade-in effect
    //
    // Problem: Loading is INSIDE the panel, so apparent_loading = panel_opacity × loading_opacity
    // As panel fades in (0→1), loading appears to fade in too, even at opacity 1.
    //
    // Ideal: To fade apparent_loading linearly from P to 0 while panel goes P to 1:
    //   loading(t) = P × (1 - t/T) / (P + (1-P) × t/T)
    // This is non-linear and can't be done with CSS transitions.
    //
    // Approximation: Set loading to panel's current opacity, then fade it to 0 faster.
    // - At content arrival: panel=P, we set loading=P, so apparent = P × P = P²
    // - This causes a slight dip (P² < P), but it's barely noticeable
    // - Loading fades to 0 over duration×P, reaching 0 while panel is still fading
    // - Result: apparent loading quickly fades to 0, then stays at 0
    //
    // For zero-latency (P≈0): loading is hidden immediately, content just fades in
    // For high-latency (P≈1): loading crossfades naturally with content
    const panelOpacityNum = parseFloat(currentOpacity);
    const shouldFadeLoading = loadingContent && panelOpacityNum >= 0.1;

    if (loadingContent) {
      // Set loading's actual opacity to panel's opacity so apparent stays constant momentarily
      loadingContent.style.opacity = currentOpacity;
      if (shouldFadeLoading) {
        // Fade loading out faster than panel fades in, so apparent fades to 0
        // Use half the duration so loading reaches 0 while panel is still fading
        const loadingFadeDuration = this.duration * panelOpacityNum;
        loadingContent.style.transition = `opacity ${loadingFadeDuration}ms ease-out`;
      } else {
        loadingContent.style.transition = "none";
      }
    }

    // Force reflow to apply transitions before changing values
    this.panelContent.offsetHeight;

    // Now trigger all animations simultaneously
    this.panelContent.style.opacity = "1";
    this.panelContent.style.transform = "scale(1)";
    this.panelContent.style.width = `${targetWidth}px`;
    this.panelContent.style.height = `${targetHeight}px`;
    if (mainContent) {
      mainContent.style.opacity = "1";
    }
    if (loadingContent) {
      loadingContent.style.opacity = "0";
      if (shouldFadeLoading) {
        const loadingFadeDuration = this.duration * panelOpacityNum;
        // Hide after fade completes
        setTimeout(() => {
          this.js.addClass(loadingContent, "hidden");
          loadingContent.style.removeProperty("transition");
        }, loadingFadeDuration);
      } else {
        // Hide immediately since panel is barely visible
        this.js.addClass(loadingContent, "hidden");
        loadingContent.style.removeProperty("transition");
      }
    }

    // Clean up after animation
    const cleanup = (e) => {
      if (e.target !== this.panelContent) return;
      // Wait for transform to complete (last property)
      if (e.propertyName !== "transform") return;
      this.panelContent.removeEventListener("transitionend", cleanup);
      this.panelContent.style.removeProperty("transition");
      this.panelContent.style.removeProperty("width");
      this.panelContent.style.removeProperty("height");
      this.panelContent.style.removeProperty("overflow");
      console.log(`[ModalAnimator] _transitionToContent: animation complete`);
      // Notify state machine if still in entering phase
      if (syncedVar && syncedVar.getPhase() === "entering") {
        syncedVar.notifyTransitionEnd();
      }
    };
    this.panelContent.addEventListener("transitionend", cleanup);

    // Mark that we've handled the content transition
    this._loadingFadedOut = true;
  }

  /**
   * Called when enter transition completes (forwarded from onEntering handler).
   * This is for internal tracking, SyncedVar handles the phase transition.
   */
  onTransitionEnd(_syncedVar) {
    // SyncedVar handles the phase transition
  }

  // --- FLIP Animation Support ---

  /**
   * Lock panel size before update to prevent visual jump during DOM patches.
   * Call this in beforeUpdate() of the hook.
   *
   * @param {string} phase - Current animation phase from SyncedVar
   */
  capturePreUpdateRect(phase) {
    // Only lock size if panel is visible and we're in an animated state
    if (!this.panelContent || phase === "idle") {
      return;
    }

    // Lock panel to current LAYOUT size to prevent flash during DOM patch
    // Use computedStyle (not getBoundingClientRect) because we need layout size, not visual size
    // Visual size includes transform scaling, which would cause double-scaling when we set it as layout width
    const style = getComputedStyle(this.panelContent);
    this._sizeLockApplied = true;
    this.panelContent.style.width = style.width;
    this.panelContent.style.height = style.height;
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
  }

  /**
   * Set up ghost element animation for close.
   */
  _setupGhostElementAnimation() {
    // Check if ghost was already inserted via onBeforeElUpdated
    if (this._ghostInsertedInBeforeUpdate && this._preUpdateContentClone) {
      this.ghostElement = this._preUpdateContentClone;
      this._preUpdateContentClone = null;
      this._ghostInsertedInBeforeUpdate = false;

      // Animate ghost overlay out (inline styles)
      if (this._ghostOverlay) {
        this._ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
        this._ghostOverlay.offsetHeight;
        this._ghostOverlay.style.opacity = "0";
      }

      // Animate ghost panel out (inline styles)
      requestAnimationFrame(() => {
        this.ghostElement.style.transition = `opacity ${this.duration}ms ease-out, transform ${this.duration}ms ease-out`;
        this.ghostElement.style.transformOrigin = "center";
        this.ghostElement.offsetHeight;
        requestAnimationFrame(() => {
          this.ghostElement.style.opacity = "0";
          this.ghostElement.style.transform = "scale(0.95)";
        });
      });

      // Also animate the real panel out (it's hidden but we need it reset for next open)
      if (this.panelContent) {
        this.panelContent.style.transition = `opacity ${this.duration}ms ease-out, transform ${this.duration}ms ease-out`;
        this.panelContent.offsetHeight;
        this.panelContent.style.opacity = "0";
        this.panelContent.style.transform = "scale(0.95)";
      }

      // Schedule ghost cleanup after animation completes
      setTimeout(() => {
        if (this.ghostElement?.parentNode) {
          this.ghostElement.remove();
          this.ghostElement = null;
        }
        if (this._ghostOverlay?.parentNode) {
          this._ghostOverlay.remove();
          this._ghostOverlay = null;
        }
      }, this.duration + 50); // Small buffer to ensure animation completes
      return;
    }

    // Fallback: create ghost from current panel (user-initiated close)
    // Clone entire panel and position on document.body so it survives wrapper becoming invisible
    if (!this.panelContent) {
      return;
    }

    const rect = this.panelContent.getBoundingClientRect();
    const panelBg = getComputedStyle(this.panelContent).backgroundColor;
    const borderRadius = getComputedStyle(this.panelContent).borderRadius;

    // Clone the panel
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
      opacity: "1",
      transform: "scale(1)",
    });

    // Insert ghost on document.body (outside the modal wrapper)
    document.body.appendChild(this.ghostElement);

    // Create ghost overlay on document.body
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

      // Animate ghost overlay out
      this._ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
      this._ghostOverlay.offsetHeight;
      this._ghostOverlay.style.opacity = "0";
    }

    // Hide the real panel immediately (ghost is now visible in its place)
    this.panelContent.style.visibility = "hidden";
    if (this.overlay) {
      this.overlay.style.visibility = "hidden";
    }

    // Animate ghost panel out
    requestAnimationFrame(() => {
      this.ghostElement.style.transition = `opacity ${this.duration}ms ease-out, transform ${this.duration}ms ease-out`;
      this.ghostElement.offsetHeight;
      requestAnimationFrame(() => {
        this.ghostElement.style.opacity = "0";
        this.ghostElement.style.transform = "scale(0.95)";
      });
    });

    // Schedule ghost cleanup after animation completes
    setTimeout(() => {
      if (this.ghostElement?.parentNode) {
        this.ghostElement.remove();
        this.ghostElement = null;
      }
      if (this._ghostOverlay?.parentNode) {
        this._ghostOverlay.remove();
        this._ghostOverlay = null;
      }
    }, this.duration + 50); // Small buffer to ensure animation completes
  }

  /**
   * Clean up ghost elements after close animation.
   * @param {boolean} instant - If true, remove instantly. If false, fade out first.
   */
  _cleanupCloseAnimation(instant = true) {
    if (this.ghostElement?.parentNode) {
      this.ghostElement.remove();
    }
    this.ghostElement = null;

    if (this._ghostOverlay?.parentNode) {
      if (instant) {
        this._ghostOverlay.remove();
        this._ghostOverlay = null;
      } else {
        // Fade out the ghost overlay to avoid flash when reopening
        const ghostOverlay = this._ghostOverlay;
        this._ghostOverlay = null; // Clear reference so we don't try to remove again
        ghostOverlay.style.transition = `opacity ${this.duration}ms ease-out`;
        ghostOverlay.style.opacity = "0";
        setTimeout(() => {
          if (ghostOverlay.parentNode) {
            ghostOverlay.remove();
          }
        }, this.duration);
      }
    } else {
      this._ghostOverlay = null;
    }
  }

  // --- DOM Reset ---

  /**
   * Reset all DOM state to closed/invisible.
   * @param {boolean} isReopen - If true, this is a reopen from exiting phase, fade ghost overlay
   */
  _resetDOM(isReopen = false) {
    // Only clean up ghost animations if reopening (interrupting close animation)
    // For normal close→idle transitions, the scheduled cleanup in _setupGhostElementAnimation handles it
    if (isReopen) {
      this._cleanupCloseAnimation(false); // Fade out ghost overlay
    }
    this._sizeLockApplied = false;
    this._enteringLoadingRect = null;
    this._enterAnimationStartTime = null;
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
      this.panelContent.style.opacity = "0";
      this.panelContent.style.transform = "scale(0.95)";
      this.panelContent.style.removeProperty("transition");
      this.panelContent.style.removeProperty("width");
      this.panelContent.style.removeProperty("height");
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
      this.js.addClass(loadingContent, "hidden");
      loadingContent.style.opacity = "0";
      loadingContent.style.removeProperty("transition");
    }

    // Main content - hide so panel shows loading skeleton on next open
    const mainContent = this.getMainContentContainer();
    if (mainContent) {
      this.js.addClass(mainContent, "hidden");
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
