/**
 * FlipAnimator - Reusable FLIP (First-Last-Invert-Play) animation utility.
 *
 * FLIP is an animation technique for smooth transitions when an element's
 * size or position changes:
 * - First: Capture the initial state (position/size)
 * - Last: Let the DOM update to its final state
 * - Invert: Apply transforms to make it look like the old state
 * - Play: Remove transforms with a transition for smooth animation
 *
 * Usage:
 *
 *   const flip = new FlipAnimator(panelElement, {
 *     duration: 200,
 *     easing: 'ease-in-out'
 *   });
 *
 *   // Before DOM update
 *   flip.captureFirst();
 *
 *   // After DOM update, measure new content and animate
 *   flip.animateTo(newContentElement);
 *
 * Or with size lock for preventing flash during DOM patching:
 *
 *   // Before DOM update - locks element at current size
 *   flip.captureFirstAndLock();
 *
 *   // After DOM update
 *   flip.animateToContentSize(newContentElement, {
 *     onBeforeAnimate: () => swapContent()
 *   });
 */

export class FlipAnimator {
  /**
   * Create a FlipAnimator.
   *
   * @param {HTMLElement} element - The element to animate
   * @param {Object} config - Configuration options
   * @param {number} config.duration - Animation duration in ms (default: 200)
   * @param {string} config.easing - CSS easing function (default: 'ease-in-out')
   */
  constructor(element, config = {}) {
    this.element = element;
    this.duration = config.duration || 200;
    this.easing = config.easing || 'ease-in-out';

    // State
    this._firstRect = null;
    this._sizeLockApplied = false;
    this._transitionHandler = null;
  }

  /**
   * Capture the element's current rect (First step of FLIP).
   */
  captureFirst() {
    if (!this.element) return;
    this._firstRect = this.element.getBoundingClientRect();
  }

  /**
   * Capture rect AND lock element to current size.
   * Use this when you need to prevent visual changes during DOM patching.
   */
  captureFirstAndLock() {
    if (!this.element) return;

    this._firstRect = this.element.getBoundingClientRect();
    this._sizeLockApplied = true;

    // Lock to current size to prevent flash during DOM patch
    this.element.style.width = `${this._firstRect.width}px`;
    this.element.style.height = `${this._firstRect.height}px`;

    // Disable transitions during the update to prevent any flash
    this.element.style.transition = 'none';
  }

  /**
   * Check if a size lock is currently applied.
   */
  isSizeLocked() {
    return this._sizeLockApplied;
  }

  /**
   * Release size lock without animating.
   * Call this if you captured with lock but don't need to animate.
   */
  releaseSizeLock() {
    if (!this._sizeLockApplied) return;

    this._sizeLockApplied = false;
    this._firstRect = null;

    if (this.element) {
      this.element.style.removeProperty('width');
      this.element.style.removeProperty('height');
      this.element.style.removeProperty('transition');
    }
  }

  /**
   * Clear captured rect without releasing lock.
   * Call this if you captured without lock and don't need to animate.
   */
  clearCapture() {
    this._firstRect = null;
  }

  /**
   * Check if we have a captured rect (whether locked or not).
   */
  hasCapture() {
    return this._firstRect != null;
  }

  /**
   * Animate to a target size.
   *
   * @param {number} targetWidth - Target width in pixels
   * @param {number} targetHeight - Target height in pixels
   * @param {Object} options - Animation options
   * @param {Function} options.onBeforeAnimate - Called before animation starts
   * @param {Function} options.onComplete - Called when animation completes
   */
  animateTo(targetWidth, targetHeight, options = {}) {
    const { onBeforeAnimate, onComplete } = options;

    if (!this.element || !this._firstRect) {
      this.releaseSizeLock();
      return;
    }

    const firstRect = this._firstRect;
    this._firstRect = null;

    // Skip if size didn't change significantly
    if (
      Math.abs(firstRect.width - targetWidth) < 1 &&
      Math.abs(firstRect.height - targetHeight) < 1
    ) {
      this.releaseSizeLock();
      onComplete?.();
      return;
    }

    // Callback before animation (e.g., swap content visibility)
    onBeforeAnimate?.();

    // Mark as released since we're starting animation
    this._sizeLockApplied = false;

    // Animate to new size
    requestAnimationFrame(() => {
      // Re-enable transitions for the animation
      this.element.style.transition = '';
      this.element.style.transitionProperty = 'width, height';
      this.element.style.transitionDuration = `${this.duration}ms`;
      this.element.style.transitionTimingFunction = this.easing;
      this.element.style.width = `${targetWidth}px`;
      this.element.style.height = `${targetHeight}px`;

      // Clean up transition handler if exists
      if (this._transitionHandler) {
        this.element.removeEventListener('transitionend', this._transitionHandler);
      }

      this._transitionHandler = (e) => {
        if (e.target !== this.element) return;
        this.element.removeEventListener('transitionend', this._transitionHandler);
        this._transitionHandler = null;

        // Clean up styles
        this.element.style.removeProperty('transition-property');
        this.element.style.removeProperty('transition-duration');
        this.element.style.removeProperty('transition-timing-function');
        this.element.style.removeProperty('width');
        this.element.style.removeProperty('height');

        onComplete?.();
      };

      this.element.addEventListener('transitionend', this._transitionHandler);
    });
  }

  /**
   * Measure content element and animate to fit it.
   *
   * @param {HTMLElement} contentElement - Element to measure for target size
   * @param {Object} options - Animation options
   * @param {Function} options.onBeforeAnimate - Called before animation starts
   * @param {Function} options.onComplete - Called when animation completes
   */
  animateToContentSize(contentElement, options = {}) {
    if (!contentElement || !this.element) {
      this.releaseSizeLock();
      return;
    }

    // Measure the content's natural size
    let targetWidth = contentElement.scrollWidth;
    let targetHeight = contentElement.scrollHeight;

    // Account for container padding
    const containerStyle = getComputedStyle(this.element);
    const paddingX = parseFloat(containerStyle.paddingLeft) + parseFloat(containerStyle.paddingRight);
    const paddingY = parseFloat(containerStyle.paddingTop) + parseFloat(containerStyle.paddingBottom);

    targetWidth += paddingX;
    targetHeight += paddingY;

    this.animateTo(targetWidth, targetHeight, options);
  }

  /**
   * Clean up when done with this animator.
   */
  destroy() {
    this.releaseSizeLock();
    if (this.element && this._transitionHandler) {
      this.element.removeEventListener('transitionend', this._transitionHandler);
      this._transitionHandler = null;
    }
  }
}
