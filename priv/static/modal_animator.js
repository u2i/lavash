/**
 * ModalAnimator - Modal-specific DOM manipulation as a SyncedVar delegate.
 *
 * This class implements the SyncedVar delegate interface for modal-specific
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

    // FLIP animation state
    this._flipPreRect = null;
    this._sizeLockApplied = false;

    // Transition handler reference
    this._transitionHandler = null;
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
      this._flipPreRect = null;
      this._sizeLockApplied = false;
      this._pendingFlipRect = null;
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

    // Make wrapper visible
    this.el.classList.remove("invisible", "pointer-events-none");

    // Show loading content with fade-in (can be interrupted by content arriving)
    const loadingContent = this.getLoadingContent();
    if (loadingContent) {
      loadingContent.classList.remove("hidden");
      // Start at opacity 0, animate to full opacity
      loadingContent.classList.add("opacity-0");
      loadingContent.classList.add("transition-opacity");
      loadingContent.style.transitionDuration = `${this.duration}ms`;
      // Force reflow before changing opacity
      loadingContent.offsetHeight;
      loadingContent.classList.remove("opacity-0");
      loadingContent.classList.add("opacity-100");
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

    // Animate panel open
    if (this.panelContent) {
      // Check current state before animating
      const currentScale = getComputedStyle(this.panelContent).transform;
      const currentOpacity = getComputedStyle(this.panelContent).opacity;
      console.log(`[ModalAnimator] onEntering: before transition, opacity=${currentOpacity}, transform=${currentScale}`);

      // CRITICAL: Force starting state with inline styles to ensure transition will fire
      // This handles the case where classes might already be in the wrong state
      this.panelContent.style.opacity = "0";
      this.panelContent.style.transform = "scale(0.95)";
      // Remove any conflicting classes
      this.panelContent.classList.remove("opacity-100", "scale-100", "opacity-0", "scale-95");
      // Force reflow to apply starting state
      this.panelContent.offsetHeight;

      // Now set up the transition
      this.panelContent.classList.add("transition-all", "duration-200", "ease-out");
      // Force another reflow
      this.panelContent.offsetHeight;

      // Animate to visible state by removing inline styles and adding target classes
      this.panelContent.style.removeProperty("opacity");
      this.panelContent.style.removeProperty("transform");
      this.panelContent.classList.add("opacity-100", "scale-100");

      // Set up transition end handler
      this._transitionHandler = (e) => {
        console.log(`[ModalAnimator] transitionend fired, property=${e.propertyName}, target=${e.target === this.panelContent ? 'panelContent' : 'other'}`);
        if (e.target !== this.panelContent) return;
        this.panelContent.removeEventListener("transitionend", this._transitionHandler);
        this._transitionHandler = null;
        // Notify SyncedVar that transition completed
        syncedVar.notifyTransitionEnd();
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
  onLoading(_syncedVar) {
    // Panel is already open, just waiting for content
  }

  /**
   * Called when entering the "visible" phase.
   * Modal is fully open and visible.
   */
  onVisible(_syncedVar) {
    console.log(`[ModalAnimator] onVisible called, _pendingFlipRect=${JSON.stringify(this._pendingFlipRect)}`);
    // Panel is now fully visible
    this.el.classList.remove("invisible");

    // Check if there's a pending FLIP animation queued from the entering phase
    // This happens when content arrives before the enter transition completes
    if (this._pendingFlipRect) {
      console.log(`[ModalAnimator] onVisible: running queued FLIP animation`);
      // Use the captured loading rect as the "from" size
      this._flipPreRect = this._pendingFlipRect;
      this._pendingFlipRect = null;
      this._runFlipAnimation();
    }
  }

  /**
   * Called when entering the "exiting" phase.
   * Sets up ghost element and animates close.
   */
  onExiting(_syncedVar) {

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
    this._resetDOM();
    this._cleanupCloseAnimation();
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

    // Handle content arrival during entering phase
    // Notify state machine so it can call onContentReadyDuringEnter
    if (mainContentLoaded && currentPhase === "entering" && !animated.isAsyncReady) {
      console.log(`[ModalAnimator] onUpdated: content ready during entering phase, calling onAsyncDataReady`);
      animated.onAsyncDataReady();
      console.log(`[ModalAnimator] onUpdated: after onAsyncDataReady in entering, phase=${animated.getPhase()}, isAsyncReady=${animated.isAsyncReady}`);
      // onContentReadyDuringEnter locks the panel size and queues FLIP for onVisible
      // Do NOT release the size lock here - FLIP needs it to animate from loading size to content size
      return;
    }

    // For loading phase with content ready, notify state machine to transition to visible
    // This handles the case where transitionend fired before async data arrived,
    // putting us in loading phase, but then detectAsyncFieldsReady() didn't trigger
    // because the data was already cached (oldValue == newValue).
    if (mainContentLoaded && currentPhase === "loading" && !animated.isAsyncReady) {
      console.log(`[ModalAnimator] onUpdated: calling onAsyncDataReady for loading phase with content ready`);
      animated.onAsyncDataReady();
      console.log(`[ModalAnimator] onUpdated: after onAsyncDataReady, phase=${animated.getPhase()}, isAsyncReady=${animated.isAsyncReady}`);
      // Don't return - fall through to run FLIP animation since we're now visible with content ready
    }

    // For loading/visible phases with content ready, run FLIP animation
    if (mainContentLoaded && (currentPhase === "loading" || currentPhase === "visible")) {
      // Content is ready - run FLIP if loading is still visible
      if (loadingVisible) {
        this._runFlipAnimation();
      }
    }

    // Always release size lock if it wasn't released by FLIP
    this.releaseSizeLockIfNeeded();
  }

  /**
   * Called when content arrives while enter animation is still running.
   * Captures the loading skeleton rect NOW so we can animate from it
   * after the enter transition completes.
   */
  onContentReadyDuringEnter(_syncedVar) {
    console.log(`[ModalAnimator] onContentReadyDuringEnter called, _enteringLoadingRect=${JSON.stringify(this._enteringLoadingRect)}`);
    // Capture the loading rect immediately - this is the "first" rect for FLIP
    // We must capture it now before any more DOM updates overwrite _flipPreRect
    this._queueFlipWithLoadingRect();
    console.log(`[ModalAnimator] onContentReadyDuringEnter: after queueFlip, _pendingFlipRect=${JSON.stringify(this._pendingFlipRect)}`);

    // CRITICAL: Lock the panel to the loading skeleton size BEFORE showing main content
    // This prevents the panel from immediately resizing when content is revealed
    // We'll animate the size change later in _runFlipAnimation (via onVisible)
    if (this.panelContent && this._enteringLoadingRect) {
      console.log(`[ModalAnimator] onContentReadyDuringEnter: locking panel to loading size ${this._enteringLoadingRect.width}x${this._enteringLoadingRect.height}`);
      this.panelContent.style.width = `${this._enteringLoadingRect.width}px`;
      this.panelContent.style.height = `${this._enteringLoadingRect.height}px`;
      this.panelContent.style.overflow = "hidden";
      this._sizeLockApplied = true;
    }

    // Show main content underneath loading, but fade it in to avoid flash
    // This creates a proper crossfade where main content fades in as loading fades out
    // Panel is locked so it won't resize yet
    const mainContent = this.getMainContentContainer();
    if (mainContent && mainContent.classList.contains("hidden")) {
      console.log(`[ModalAnimator] onContentReadyDuringEnter: fading in main content underneath loading`);
      // Start at opacity 0
      mainContent.classList.remove("hidden");
      mainContent.classList.add("opacity-0");
      mainContent.style.transition = "none";
      mainContent.offsetHeight; // Force reflow

      // Calculate fade duration - sync with loading fade-out
      const elapsed = this._enterAnimationStartTime
        ? performance.now() - this._enterAnimationStartTime
        : 0;
      const fadeInDuration = Math.max(50, this.duration - elapsed);

      // Fade in
      mainContent.style.transition = `opacity ${fadeInDuration}ms ease-out`;
      mainContent.offsetHeight;
      mainContent.classList.remove("opacity-0");
      mainContent.classList.add("opacity-100");

      // Clean up transition after complete
      setTimeout(() => {
        mainContent.style.removeProperty("transition");
      }, fadeInDuration);
    }

    // Now fade out loading to reveal main content
    const loadEl = this.getLoadingContent();
    if (loadEl && !loadEl.classList.contains("hidden")) {
      const elapsed = this._enterAnimationStartTime
        ? performance.now() - this._enterAnimationStartTime
        : 0;
      // Fade should complete when enter animation completes (duration - elapsed)
      const remainingEnterTime = Math.max(50, this.duration - elapsed);
      const fadeOutDuration = remainingEnterTime;
      console.log(`[ModalAnimator] onContentReadyDuringEnter: elapsed=${elapsed}, remainingEnterTime=${remainingEnterTime}, fadeOutDuration=${fadeOutDuration}`);

      const currentOpacity = getComputedStyle(loadEl).opacity;
      loadEl.style.transition = "none";
      loadEl.style.opacity = currentOpacity;
      loadEl.offsetHeight;

      loadEl.style.transition = `opacity ${fadeOutDuration}ms ease-out`;
      loadEl.offsetHeight;
      loadEl.style.opacity = "0";

      setTimeout(() => {
        loadEl.classList.add("hidden");
        loadEl.classList.remove("transition-opacity", "opacity-100");
        loadEl.classList.add("opacity-0");
        loadEl.style.removeProperty("transition");
        loadEl.style.removeProperty("transition-duration");
        loadEl.style.removeProperty("opacity");
      }, fadeOutDuration);

      // Mark that we already handled the loading fade-out
      this._loadingFadedOut = true;
    }
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
   * Capture panel rect before update for FLIP animation.
   * Call this in beforeUpdate() of the hook.
   *
   * @param {string} phase - Current animation phase from SyncedVar
   */
  capturePreUpdateRect(phase) {
    // Don't overwrite if we already have a pending FLIP queued
    if (this._pendingFlipRect) {
      return;
    }

    // During entering phase with content already arrived, lock to entering rect
    // to prevent visual jump when DOM patches
    // IMPORTANT: Do NOT set transition:none here - the scale animation needs to complete!
    if (phase === "entering" && this._enteringLoadingRect) {
      // Lock to the original entering loading rect (before scale animation)
      // This keeps the panel at the skeleton size visually while scale animates
      this._sizeLockApplied = true;
      this.panelContent.style.width = `${this._enteringLoadingRect.width}px`;
      this.panelContent.style.height = `${this._enteringLoadingRect.height}px`;
      // Don't touch transition - let scale animation continue!
      return;
    }

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
   * Queue a FLIP animation to run after enter transition completes.
   * Uses the loading rect captured at the START of entering phase.
   * Called when content arrives during the "entering" phase.
   */
  _queueFlipWithLoadingRect() {
    // Only queue once - if we already have a pending rect, don't overwrite
    if (this._pendingFlipRect) {
      return;
    }

    // Use the rect captured at the start of entering (the canonical loading skeleton size)
    // This is immune to any DOM updates that happen during the entering phase
    if (this._enteringLoadingRect) {
      this._pendingFlipRect = this._enteringLoadingRect;
    } else {
      // Fallback - capture now (less ideal)
      const loadEl = this.getLoadingContent();
      if (this.panelContent && loadEl) {
        this._pendingFlipRect = this.panelContent.getBoundingClientRect();
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
   * Call this after content arrives (in onAsyncReady or updated).
   * Uses internal _flipPreRect captured by capturePreUpdateRect().
   */
  _runFlipAnimation() {
    const loadEl = this.getLoadingContent();
    const mainInnerEl = this.getMainContentInner();
    const mainContent = this.getMainContentContainer();

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
        mainContent.classList.remove("hidden", "opacity-0");
        mainContent.classList.add("opacity-100");
      }
      return;
    }

    const firstRect = this._flipPreRect;
    this._flipPreRect = null;

    // Check if main content is already visible (e.g., shown by onContentReadyDuringEnter setTimeout)
    const mainContentAlreadyVisible = mainContent && mainContent.classList.contains("opacity-100");
    console.log(`[ModalAnimator] _runFlipAnimation: mainContentAlreadyVisible=${mainContentAlreadyVisible}`);

    // Unhide main content so we can measure it (it was hidden in _resetDOM)
    // Only set opacity-0 if it's not already visible - otherwise we'd cause a blink
    if (mainContent && !mainContentAlreadyVisible) {
      mainContent.classList.remove("hidden");
      mainContent.classList.add("opacity-0");
    } else if (mainContent) {
      // Just ensure it's not hidden for measurement
      mainContent.classList.remove("hidden");
    }

    // Measure the new content size while panel is still locked at old size
    // We measure the main content inner element to get the natural size
    let targetWidth = firstRect.width;
    let targetHeight = firstRect.height;

    if (mainInnerEl) {
      // Force layout to get accurate measurements
      mainInnerEl.offsetHeight;
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
    console.log(`[ModalAnimator] _runFlipAnimation: firstRect=${firstRect.width}x${firstRect.height}, target=${targetWidth}x${targetHeight}`)

    // If target height is 0 or very small, main content hasn't loaded yet - skip FLIP
    // This happens when async data hasn't arrived (mainInnerEl exists but is empty)
    if (targetHeight < 10) {
      // DON'T release size lock or swap content - wait for next update with actual content
      // But DO restore the flipPreRect so we can try again
      this._flipPreRect = firstRect;
      return;
    }

    // Skip size animation if size didn't change significantly
    if (
      Math.abs(firstRect.width - targetWidth) < 1 &&
      Math.abs(firstRect.height - targetHeight) < 1
    ) {
      console.log(`[ModalAnimator] _runFlipAnimation: sizes similar, skipping animation`);
      releaseSizeLock();
      // Still swap content visibility
      if (loadEl && !loadEl.classList.contains("hidden")) {
        loadEl.classList.add("hidden", "opacity-0");
        loadEl.classList.remove("opacity-100");
      }
      if (mainContent) {
        mainContent.classList.remove("hidden", "opacity-0");
        mainContent.classList.add("opacity-100");
      }
      return;
    }
    console.log(`[ModalAnimator] _runFlipAnimation: animating size change`);

    // Show main content instantly (it's behind loading in the grid)
    if (mainContent) {
      mainContent.classList.remove("hidden", "opacity-0");
      mainContent.classList.add("opacity-100");
    }
    // Fade out loading content - if panel is still fading in, fade out quickly
    // to counteract the partial fade-in that already happened
    // Skip if we already started fading in onContentReadyDuringEnter
    if (loadEl && !loadEl.classList.contains("hidden") && !this._loadingFadedOut) {
      // Fade out loading at 2x the rate the panel is fading in
      // This makes the apparent fade-out mirror the apparent fade-in
      // (loading opacity × panel opacity decays at the same rate it grew)
      let fadeOutDuration = this.duration;
      if (this._enterAnimationStartTime) {
        const elapsed = performance.now() - this._enterAnimationStartTime;
        // Fade out in half the elapsed time (2x speed), capped at full duration for late arrivals
        // Ensure minimum 100ms to avoid jarring blink when data arrives quickly
        fadeOutDuration = Math.max(100, Math.min(elapsed / 2, this.duration));
      }

      // Interrupt current fade-in transition and start fade-out with new duration
      // First, capture current computed opacity and kill the transition
      const currentOpacity = getComputedStyle(loadEl).opacity;

      loadEl.style.transition = "none";
      loadEl.style.opacity = currentOpacity; // Lock at current value
      loadEl.offsetHeight; // Force reflow

      // Now start fade-out with calculated duration
      loadEl.style.transition = `opacity ${fadeOutDuration}ms ease-out`;
      loadEl.offsetHeight; // Force reflow
      loadEl.style.opacity = "0";
      // Hide after fade completes to remove from layout
      setTimeout(() => {
        loadEl.classList.add("hidden");
        loadEl.classList.remove("transition-opacity", "opacity-100");
        loadEl.classList.add("opacity-0");
        loadEl.style.removeProperty("transition");
        loadEl.style.removeProperty("transition-duration");
        loadEl.style.removeProperty("opacity");
      }, fadeOutDuration);
    }

    // Mark size lock as released since we're starting animation
    this._sizeLockApplied = false;

    // Animate to new size
    // First, ensure panel is at the "from" size and force a reflow
    const currentWidth = this.panelContent.style.width;
    const currentHeight = this.panelContent.style.height;
    console.log(`[ModalAnimator] _runFlipAnimation: current inline size=${currentWidth}x${currentHeight}, animating to ${targetWidth}x${targetHeight}`);

    // Clear any existing transitions and ensure we're at the starting size
    this.panelContent.style.transition = "none";
    this.panelContent.style.width = `${firstRect.width}px`;
    this.panelContent.style.height = `${firstRect.height}px`;
    this.panelContent.offsetHeight; // Force reflow

    requestAnimationFrame(() => {
      // Now set up the transition and animate to target
      this.panelContent.style.transition = "";
      if (this.overlay) {
        this.overlay.style.transition = "";
      }

      this.panelContent.classList.add("transition-all", "ease-in-out");
      this.panelContent.style.transitionDuration = `${this.duration}ms`;

      // Force another reflow before setting target
      this.panelContent.offsetHeight;

      console.log(`[ModalAnimator] _runFlipAnimation: setting target size ${targetWidth}x${targetHeight}`);
      this.panelContent.style.width = `${targetWidth}px`;
      this.panelContent.style.height = `${targetHeight}px`;

      this.panelContent.addEventListener(
        "transitionend",
        (e) => {
          if (e.target !== this.panelContent) return;
          console.log(`[ModalAnimator] _runFlipAnimation: size transition complete`);
          this.panelContent.classList.remove("transition-all", "ease-in-out");
          this.panelContent.style.removeProperty("transition-duration");
          this.panelContent.style.removeProperty("width");
          this.panelContent.style.removeProperty("height");
          this.panelContent.style.removeProperty("overflow");
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

    // Clean up animations - fade ghost overlay if reopening to avoid flash
    this._cleanupCloseAnimation(!isReopen);
    this._flipPreRect = null;
    this._sizeLockApplied = false;
    this._pendingFlipRect = null;
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

    // Loading - reset to hidden (will be shown in onEntering)
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

    // Main content - hide so panel measures only loading skeleton on next open
    // This is critical for FLIP: we need the panel to start at loading size, not content size
    // The server will eventually remove main_content_inner, but that may not have arrived yet
    const mainContent = this.getMainContentContainer();
    if (mainContent) {
      mainContent.classList.add("hidden");
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
