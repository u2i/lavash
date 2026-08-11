/**
 * SyncedVar - Client-server state synchronization with optional animation.
 *
 * Models an eventually consistent variable with optimistic updates and
 * version tracking. Optionally drives a phase state machine for animated
 * open/close transitions (modals, flyovers, etc.).
 *
 * Basic usage:
 *   const counter = new SyncedVar(0, { onChange: (val, old, src) => {} });
 *   counter.setOptimistic(5);
 *   counter.set(5, pushFn);
 *
 * Animated usage:
 *   const modal = new SyncedVar(null, {
 *     animated: { duration: 200, async: "edit_form" },
 *     onChange: (val, old, src) => { hook.state.open = val; },
 *     onPhaseChange: (phase) => { hook.state.open_phase = phase; },
 *   });
 *   modal.setDelegate(overlayAnimator);
 *
 * Animation phases: idle -> entering -> [loading] -> visible -> exiting -> idle
 *
 * Delegate callbacks:
 *   onEntering(syncedVar)  - start enter animation
 *   onLoading(syncedVar)   - entered loading phase
 *   onVisible(syncedVar)   - fully visible
 *   onExiting(syncedVar)   - start exit animation
 *   onIdle(syncedVar)      - back to closed
 *   onSeedOpen(syncedVar)  - mount-time seed of a server-rendered-open value (instant styles)
 *   onAsyncReady(syncedVar) - async data arrived (loading or visible)
 *   onContentReadyDuringEnter(syncedVar) - async arrived during enter
 *   onUpdated(syncedVar, phase) - LiveView patch applied
 */

// Local copy of debug.js's gate: synced_var.js is evaluated standalone
// (no module system) by the Deno unit tests, so it must not import.
// Keep in sync with debug.js.
function debugEnabled() {
  return typeof window !== "undefined" && !!(window.Lavash && window.Lavash.debug);
}

const _UNSET = Symbol("no-server-value");

// --- Phase classes ---

class Phase {
  constructor(sv) { this.sv = sv; }
  get name() { return this._name; }
  onOpen() {}
  onClose() {}
  onAsyncReady() {}
  onTransitionEnd() {}
  onEnter() {}
  onExit() {}
}

class IdlePhase extends Phase {
  _name = "idle";
  onEnter() {
    this.sv._setPhase("idle");
    // Close protection is set when an optimistic null lands while a
    // value was visible — it shields the SyncedVar from late-arriving
    // stale "open" diffs from the server. Once we reach idle, the
    // close is fully done; any future non-null server value is a
    // legitimate fresh state (e.g. user reopened the modal). Without
    // this clear, a user-initiated reopen while the SyncedVar is
    // still in `exiting` would set _closeProtection=true (close
    // happens), exit completes → idle, then the server's diff for
    // the new open arrives and is rejected as "stale." Modal stays
    // closed despite the user explicitly opening it.
    this.sv._closeProtection = false;
    this.sv._notifyDelegate("onIdle");
  }
  onOpen() {
    this.sv._transitionTo(this.sv._phases.entering);
  }
}

class EnteringPhase extends Phase {
  _name = "entering";
  onEnter() {
    this.sv._setPhase("entering");
    this.sv._notifyDelegate("onEntering");
    // Fallback if no transitionend fires; scaled like the animation itself
    // so the debug speed knob keeps phases and visuals in sync (issue #28).
    this._timeout = setTimeout(
      () => this.onTransitionEnd(),
      this.sv._animDuration / animationSpeed() + 50
    );
  }
  onExit() {
    if (this._timeout) clearTimeout(this._timeout);
  }
  onTransitionEnd() {
    if (this._timeout) { clearTimeout(this._timeout); this._timeout = null; }
    if (this.sv._animAsync && !this.sv.isAsyncReady) {
      this.sv._transitionTo(this.sv._phases.loading);
    } else {
      this.sv._transitionTo(this.sv._phases.visible);
    }
  }
  onClose() {
    this.sv._transitionTo(this.sv._phases.exiting);
  }
  onAsyncReady() {
    this.sv.isAsyncReady = true;
    this.sv._notifyDelegate("onContentReadyDuringEnter");
  }
}

class LoadingPhase extends Phase {
  _name = "loading";
  onEnter() {
    this.sv._setPhase("loading");
    this.sv._notifyDelegate("onLoading");
  }
  onAsyncReady() {
    this.sv.isAsyncReady = true;
    this.sv._notifyDelegate("onAsyncReady");
    this.sv._transitionTo(this.sv._phases.visible);
  }
  onClose() {
    this.sv._transitionTo(this.sv._phases.exiting);
  }
}

class VisiblePhase extends Phase {
  _name = "visible";
  onEnter() {
    this.sv._setPhase("visible");
    this.sv._notifyDelegate("onVisible");
  }
  onClose() {
    this.sv._transitionTo(this.sv._phases.exiting);
  }
  onAsyncReady() {
    this.sv._notifyDelegate("onAsyncReady");
  }
}

class ExitingPhase extends Phase {
  _name = "exiting";
  onEnter() {
    this.sv._setPhase("exiting");
    this.sv._notifyDelegate("onExiting");
    // Fallback timeout scaled like the animation itself (issue #28).
    this._timeout = setTimeout(
      () => {
        this.sv._transitionTo(this.sv._phases.idle);
      },
      this.sv._animDuration / animationSpeed() + 50
    );
  }
  onExit() {
    if (this._timeout) clearTimeout(this._timeout);
  }
  onOpen() {
    this.sv._transitionTo(this.sv._phases.entering);
  }
}

/**
 * Debug: global animation speed multiplier (1 = normal, 0.1 = 10x slower,
 * 2 = 2x faster). Shared by OverlayAnimator's transition durations and the
 * phase machine's fallback timeouts so slowed-down animations and phase
 * transitions stay in sync (issue #28). Read at use time, so it can be
 * flipped live from the console:
 *
 *   window.Lavash.ANIMATION_SPEED = 0.1
 */
export function animationSpeed() {
  const s = globalThis.window?.Lavash?.ANIMATION_SPEED;
  return typeof s === "number" && s > 0 ? s : 1;
}

export function deepEqual(a, b) {
  if (a === b) return true;
  if (a == null || b == null) return a == b;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (Array.isArray(a) || Array.isArray(b)) return false;
  if (typeof a === "object" && typeof b === "object") {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    if (keysA.length !== keysB.length) return false;
    for (const key of keysA) {
      if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
      if (!deepEqual(a[key], b[key])) return false;
    }
    return true;
  }
  return false;
}

// --- SyncedVar ---

export class SyncedVar {
  /**
   * @param {any} initialValue
   * @param {Object} options
   * @param {Function} options.onChange - (newValue, oldValue, source) => void
   * @param {Object}  options.animated - { duration, async } or null
   * @param {Function} options.onPhaseChange - (phaseName) => void (for hook state/derives)
   */
  constructor(initialValue, options = {}) {
    this.value = initialValue;
    this.confirmedValue = initialValue;
    this.version = 0;
    this.confirmedVersion = 0;
    this.onChange = options.onChange || null;
    this.label = options.label || null; // for debug logging

    // Track last server value to count distinct server transitions (not duplicate patches)
    this._lastServerValue = _UNSET;

    // Animation
    this.animated = !!options.animated;
    if (this.animated) {
      this._animDuration = options.animated.duration || 200;
      this._animAsync = options.animated.async || null;
      this._onPhaseChange = options.onPhaseChange || null;
      this._delegate = null;
      this.isAsyncReady = false;
      this.phase = "idle";
      this._phases = {
        idle: new IdlePhase(this),
        entering: new EnteringPhase(this),
        loading: new LoadingPhase(this),
        visible: new VisiblePhase(this),
        exiting: new ExitingPhase(this),
      };
      this._currentPhase = null;
      this._transitionTo(this._phases.idle);
    }
  }

  // --- Value methods ---

  /**
   * Seed a server-rendered initial value as *confirmed* state (issue #30).
   *
   * Unlike setOptimistic, this bumps no version — the var stays
   * non-pending, so the next server patch doesn't have to "confirm"
   * a value the server itself rendered. For animated vars with an
   * open (non-null) value, the phase machine jumps straight to
   * visible/loading with instant styles: a server-rendered-open
   * overlay is already open, so replaying the enter animation on
   * every mount (including reconnects) is visual noise.
   *
   * Provisional seeds (issue #72): append/upsert predictions seed
   * (never pend — the same-event re-read must replace, not fight, the
   * predicted rows), so `isPending` can't surface them. Pass
   * `{ provisional: true, changedIds: [...] }` to mark the var
   * unresolved until ANY server value arrives for its path — the
   * re-read is authoritative either way. `changedIds` records which
   * rows were predicted (client-minted or conflict-mutated) so the
   * DOM annotator can mark them individually.
   */
  seed(newValue, opts = {}) {
    const oldValue = this.value;
    this.value = newValue;
    this.confirmedValue = newValue;
    this._lastServerValue = newValue;
    if (opts.provisional) {
      this.isProvisional = true;
      this.provisionalIds = this.provisionalIds || new Set();
      for (const id of opts.changedIds || []) this.provisionalIds.add(id);
    }
    if (debugEnabled()) console.debug(`[SV:${this.label}] seed: ${JSON.stringify(oldValue)} → ${JSON.stringify(newValue)}, v=${this.version}, cv=${this.confirmedVersion}, provisional=${!!this.isProvisional}`);
    this.onChange?.(newValue, oldValue, "server");

    if (this.animated && newValue != null) {
      const targetName = this._animAsync && !this.isAsyncReady ? "loading" : "visible";
      // Bypass _transitionTo: entering the target phase through the
      // machine would notify the delegate's animated handler. Set the
      // phase directly and let the delegate apply final styles instantly.
      this._currentPhase = this._phases[targetName];
      this._setPhase(targetName);
      this._notifyDelegate("onSeedOpen");
    }
  }

  /**
   * Optimistic set without server push.
   * Returns true if value changed.
   */
  setOptimistic(newValue) {
    const oldValue = this.value;
    if (deepEqual(newValue, oldValue)) return false;
    if (!this.isPending) this._lastServerValue = _UNSET;
    this.version++;
    this.value = newValue;
    // Clear close protection when client sets a non-null value — deliberate reopen
    if (newValue != null) {
      this._closeProtection = false;
    }
    // Set close protection immediately when closing (null) from an open state.
    // This protects against stale server reopens even before the server confirms.
    if (newValue == null && oldValue != null) {
      this._closeProtection = true;
    }
    if (debugEnabled()) console.debug(`[SV:${this.label}] setOptimistic: ${JSON.stringify(oldValue)} → ${JSON.stringify(newValue)}, v=${this.version}, cv=${this.confirmedVersion}, closeProt=${!!this._closeProtection}`, new Error().stack?.split('\n').slice(1,4).join(' <- '));
    this._handleValueChange(newValue, oldValue, "optimistic");
    return true;
  }

  /**
   * Optimistic set + push to server.
   */
  set(newValue, pushFn, extraParams = {}) {
    const oldValue = this.value;
    if (deepEqual(newValue, oldValue)) return;
    if (!this.isPending) this._lastServerValue = _UNSET;
    this.version++;
    const v = this.version;
    this.value = newValue;
    // Set close protection immediately when closing — don't wait for server callback.
    // The callback may never fire (stale version) in rapid open/close cycles.
    if (newValue == null) {
      this._closeProtection = true;
    }
    if (debugEnabled()) console.debug(`[SV:${this.label}] set+push: ${JSON.stringify(oldValue)} → ${JSON.stringify(newValue)}, v=${v}, cv=${this.confirmedVersion}, closeProt=${!!this._closeProtection}`);
    this._handleValueChange(newValue, oldValue, "optimistic");

    pushFn?.({ ...extraParams, _version: v }, (reply) => {
      if (v !== this.version) {
        if (debugEnabled()) console.debug(`[SV:${this.label}] set callback STALE: pushed v=${v}, current v=${this.version}`);
        return;
      }
      this.confirmedVersion = v;
      this.confirmedValue = newValue;
      // Activate close protection: reject stale server reopens until the
      // close has fully propagated (next server null confirms it)
      if (newValue == null) {
        this._closeProtection = true;
      }
      if (debugEnabled()) console.debug(`[SV:${this.label}] set callback CONFIRMED: v=${v}, closeProt=${!!this._closeProtection}`);
      this.onChange?.(newValue, oldValue, "confirmed");
    });
  }

  /**
   * Server-initiated change.
   *
   * For animated vars: always accepts (server is authoritative for open/close).
   * For plain vars: rejects when client has pending ops, unless server
   * confirms the same value we optimistically set.
   *
   * Returns true if value changed.
   */
  serverSet(newValue) {
    // Any server arrival for this path resolves a provisional seed —
    // the same-event re-read is authoritative whether it confirms the
    // predicted rows or replaces them (issue #72).
    if (this.isProvisional) {
      this.isProvisional = false;
      this.provisionalIds = null;
      if (debugEnabled()) console.debug(`[SV:${this.label}] provisional RESOLVED by server value`);
    }
    if (this.animated) {
      return this._serverSetAnimated(newValue);
    }
    return this._serverSetPlain(newValue);
  }

  _serverSetPlain(newValue) {
    if (this.isPending) {
      const matches = deepEqual(newValue, this.value);
      if (matches) {
        // Increment confirmedVersion by 1 per match, NOT jump to this.version.
        // With rapid open/close cycles, the server sends a sequence of values
        // (e.g., [true, null, true, null, true]). A single matching "true" shouldn't
        // confirm ALL pending changes — only one. This prevents premature confirmation
        // that would leave the state unprotected against stale values still in the pipeline.
        this.confirmedVersion++;
        this.confirmedValue = newValue;
        if (newValue == null && !this.isPending) {
          this._closeProtection = true;
        }
        if (debugEnabled()) console.debug(`[SV:${this.label}] serverPlain CONFIRMED (pending match, incremental): v=${this.version}, cv=${this.confirmedVersion}, value=${JSON.stringify(newValue)}, stillPending=${this.isPending}, closeProt=${!!this._closeProtection}`);
      } else {
        if (debugEnabled()) console.debug(`[SV:${this.label}] serverPlain REJECTED (pending, no match): v=${this.version}, cv=${this.confirmedVersion}, server=${JSON.stringify(newValue)}, client=${JSON.stringify(this.value)}, closeProt=${!!this._closeProtection}`);
      }
      this._lastServerValue = newValue;
      return false;
    }
    this._lastServerValue = newValue;
    const oldValue = this.value;

    if (deepEqual(newValue, oldValue)) {
      if (debugEnabled()) console.debug(`[SV:${this.label}] serverPlain NO-OP (same value): ${JSON.stringify(newValue)}, closeProt=${!!this._closeProtection}`);
      return false;
    }

    if (this._closeProtection && newValue != null) {
      if (debugEnabled()) console.debug(`[SV:${this.label}] serverPlain BLOCKED (close protection): server=${JSON.stringify(newValue)}, client=${JSON.stringify(oldValue)}`);
      return false;
    }

    this.value = newValue;
    this.confirmedValue = newValue;
    if (debugEnabled()) console.debug(`[SV:${this.label}] serverPlain ACCEPTED: ${JSON.stringify(oldValue)} → ${JSON.stringify(newValue)}`);
    this._handleValueChange(newValue, oldValue, "server");
    return true;
  }

  _serverSetAnimated(newValue) {
    const oldValue = this.value;

    if (this.isPending) {
      const matches = deepEqual(newValue, this.value);
      if (matches) {
        // Increment confirmedVersion by 1 per match, NOT jump to this.version.
        // Same rationale as _serverSetPlain: with rapid open/close cycles,
        // multiple server responses arrive in quick succession. A single matching
        // value from an early response shouldn't confirm ALL pending changes,
        // or the next stale null would be accepted and trigger a close.
        this.confirmedVersion++;
        this.confirmedValue = newValue;
        // Note: we do NOT re-set _closeProtection here even when newValue
        // is null. setOptimistic already set it at close-click time, and
        // IdlePhase.onEnter clears it when the exit animation finishes.
        // Re-setting it here would defeat the idle-clear — by the time
        // serverAnim confirms the close, the user might have already
        // requested a reopen (via a non-optimistic action that the
        // SyncedVar can't see), and the server's eventual reopen diff
        // would be wrongly blocked. The setOptimistic+idle-clear pair
        // already provides the bounce protection we need.
        if (debugEnabled()) console.debug(`[SV:${this.label}] serverAnim CONFIRMED (pending match, incremental): v=${this.version}, cv=${this.confirmedVersion}, value=${JSON.stringify(newValue)}, phase=${this.phase}, stillPending=${this.isPending}, closeProt=${!!this._closeProtection}`);
      } else {
        if (debugEnabled()) console.debug(`[SV:${this.label}] serverAnim REJECTED (pending, no match): v=${this.version}, cv=${this.confirmedVersion}, server=${JSON.stringify(newValue)}, client=${JSON.stringify(this.value)}, phase=${this.phase}, closeProt=${!!this._closeProtection}`);
      }
      this._lastServerValue = newValue;
      return false;
    }

    this._lastServerValue = newValue;
    this.confirmedVersion = this.version;
    this.confirmedValue = newValue;

    if (deepEqual(newValue, oldValue)) {
      if (debugEnabled()) console.debug(`[SV:${this.label}] serverAnim NO-OP (same value): ${JSON.stringify(newValue)}, phase=${this.phase}, closeProt=${!!this._closeProtection}`);
      return false;
    }

    if (this._closeProtection && newValue != null) {
      if (debugEnabled()) console.debug(`[SV:${this.label}] serverAnim BLOCKED (close protection): server=${JSON.stringify(newValue)}, client=${JSON.stringify(oldValue)}, phase=${this.phase}`);
      return false;
    }

    // DIAGNOSTIC: Detect server-initiated close while overlay is visually open.
    // This is the "bouncing" bug — a stale null accepted after all pending cleared.
    const openPhase = this.phase === "entering" || this.phase === "loading" || this.phase === "visible";
    if (newValue == null && oldValue != null && openPhase) {
      // Bounce-class diagnostic (stale server close racing an open).
      // Kept behind the debug flag as a warning: the close-protection +
      // versioning work made this path expected-rare rather than a
      // production alarm (issue #32).
      if (debugEnabled()) console.warn(`[SV:${this.label}] SERVER CLOSE ACCEPTED while phase=${this.phase} — possible stale server value (flyover bounce class). server=${JSON.stringify(newValue)}, client=${JSON.stringify(oldValue)}, v=${this.version}, cv=${this.confirmedVersion}, closeProt=${!!this._closeProtection}`);
    }

    this.value = newValue;
    if (debugEnabled()) console.debug(`[SV:${this.label}] serverAnim ACCEPTED: ${JSON.stringify(oldValue)} → ${JSON.stringify(newValue)}, phase=${this.phase}`);
    this._handleValueChange(newValue, oldValue, "server");
    return true;
  }

  get isPending() {
    return this.version !== this.confirmedVersion;
  }

  /**
   * "Is the truth on screen?" predicate (issue #72; #63 wants the same
   * answer for navigation guarding): an optimistic set the server
   * hasn't echoed yet, OR a provisional (append/upsert) seed awaiting
   * the same-event re-read.
   *
   * NOT simply isPending: version counts client MUTATIONS while the
   * incremental pending-match confirm counts server PATCHES (the
   * anti-bounce rule for rapid toggles), so debounced typing — many
   * mutations, one push — leaves cv < v long after the server echoed
   * the final value. That protection gap is deliberate for merge
   * semantics, but as a sync indicator it reads "stuck syncing" while
   * client and server agree. Unresolved therefore means: pending AND
   * the server's last word differs from the value on screen.
   */
  get isUnresolved() {
    if (this.isProvisional) return true;
    if (!this.isPending) return false;
    return this._lastServerValue === _UNSET || !deepEqual(this.value, this._lastServerValue);
  }

  getValue() {
    return this.value;
  }

  // --- Animation methods (no-op when not animated) ---

  setDelegate(delegate) {
    if (this.animated) this._delegate = delegate;
  }

  getPhase() {
    if (!this.animated) return null;
    return this._currentPhase ? this._currentPhase.name : "idle";
  }

  isAnimating() {
    if (!this.animated) return false;
    const p = this.getPhase();
    return p === "entering" || p === "exiting";
  }

  onAsyncDataReady() {
    if (!this.animated) return;
    this.isAsyncReady = true;
    this._currentPhase?.onAsyncReady();
  }

  notifyTransitionEnd() {
    if (!this.animated) return;
    this._currentPhase?.onTransitionEnd?.();
  }

  destroy() {
    if (this.animated && this._currentPhase) {
      this._currentPhase.onExit();
    }
    this._delegate = null;
  }

  // --- Internal ---

  _handleValueChange(newValue, oldValue, source) {
    this.onChange?.(newValue, oldValue, source);

    if (this.animated && source !== "confirmed") {
      const wasOpen = oldValue != null;
      const isOpen = newValue != null;
      if (isOpen && !wasOpen) {
        if (debugEnabled()) console.debug(`[SV:${this.label}] _handleValueChange: OPENING (source=${source}), phase=${this.phase}`);
        this.isAsyncReady = false;
        this._currentPhase?.onOpen();
      } else if (!isOpen && wasOpen) {
        if (debugEnabled()) console.debug(`[SV:${this.label}] _handleValueChange: CLOSING (source=${source}), phase=${this.phase}`);
        this._currentPhase?.onClose();
      }
    }
  }

  _transitionTo(newPhase) {
    if (!this.animated) return;
    const old = this._currentPhase ? this._currentPhase.name : "init";
    if (debugEnabled()) console.debug(`[SV:${this.label}] PHASE: ${old} → ${newPhase.name}`);
    if (this._currentPhase) this._currentPhase.onExit();
    this._currentPhase = newPhase;
    this._currentPhase.onEnter();
  }

  _setPhase(name) {
    if (!this.animated) return;
    this.phase = name;
    this._onPhaseChange?.(name);
  }

  _notifyDelegate(method) {
    if (!this.animated) return;
    try {
      this._delegate?.[method]?.(this);
    } catch (e) {
      console.error(`[SyncedVar] delegate ${method} error:`, e);
    }
  }
}

// --- SyncedVarStore ---

export class SyncedVarStore {
  constructor() {
    this.vars = {};
    this._animatedConfigs = {}; // path -> { animated, onPhaseChange }
  }

  /**
   * Register animated config for a path.
   * When a SyncedVar is later created for this path (via get()),
   * it will automatically be created with animation support.
   */
  registerAnimated(path, config) {
    this._animatedConfigs[path] = config;
  }

  /**
   * Get or create a SyncedVar for a path.
   * @param {string} path
   * @param {any} initialValue
   * @param {Object|Function} options - { onChange } or onChange callback
   */
  get(path, initialValue = undefined, options = null) {
    if (!this.vars[path]) {
      const opts = typeof options === "function"
        ? { onChange: options }
        : (options || {});
      // Auto-label with path for debug logging
      if (!opts.label) opts.label = path;
      // Merge in animated config if registered for this path
      const animConfig = this._animatedConfigs[path];
      if (animConfig) {
        Object.assign(opts, animConfig);
      }
      this.vars[path] = new SyncedVar(initialValue, opts);
    }
    return this.vars[path];
  }

  has(path) {
    return path in this.vars;
  }

  get hasPending() {
    return Object.values(this.vars).some(v => v.isPending);
  }

  get hasUnresolved() {
    return Object.values(this.vars).some(v => v.isUnresolved);
  }

  getPendingPaths() {
    return Object.entries(this.vars)
      .filter(([_, v]) => v.isPending)
      .map(([p]) => p);
  }

  getUnresolvedPaths() {
    return Object.entries(this.vars)
      .filter(([_, v]) => v.isUnresolved)
      .map(([p]) => p);
  }

  isPending(path) {
    return this.vars[path]?.isPending ?? false;
  }

  isUnresolved(path) {
    return this.vars[path]?.isUnresolved ?? false;
  }

  provisionalIds(path) {
    return this.vars[path]?.provisionalIds || null;
  }

  clearPending(path) {
    const v = this.vars[path];
    if (v) v.confirmedVersion = v.version;
  }

  toState() {
    const state = {};
    for (const [path, sv] of Object.entries(this.vars)) {
      setNestedValue(state, path, sv.value);
    }
    return state;
  }

  /**
   * Update vars from server state.
   * Each var's serverSet handles accept/reject based on its own policy.
   */
  serverUpdate(serverState) {
    const flat = flattenState(serverState);
    for (const [path, value] of Object.entries(flat)) {
      if (this.vars[path]) {
        this.vars[path].serverSet(value);
      }
    }
  }

  getValue(path) {
    return this.vars[path]?.value;
  }
}

// --- Helpers ---

function setNestedValue(obj, path, value) {
  const parts = path.split(".");
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const p = parts[i];
    if (!(p in cur) || typeof cur[p] !== "object") cur[p] = {};
    cur = cur[p];
  }
  cur[parts[parts.length - 1]] = value;
}

function flattenState(obj, prefix = "") {
  const result = {};
  for (const [key, value] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      Object.assign(result, flattenState(value, path));
    } else {
      result[path] = value;
    }
  }
  return result;
}

// --- Expose globally ---

window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.SyncedVarStore = SyncedVarStore;

export default SyncedVar;
