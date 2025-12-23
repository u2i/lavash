defmodule Lavash.Modal.Helpers do
  @moduledoc """
  Helper components for modal rendering.

  These components provide the modal chrome (backdrop, container, escape handling)
  while letting the user define the content.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @max_width_classes %{
    sm: "max-w-sm",
    md: "max-w-md",
    lg: "max-w-lg",
    xl: "max-w-xl",
    "2xl": "max-w-2xl"
  }

  @doc """
  Renders modal chrome around content with optimistic close animations.

  Uses a JavaScript hook that creates a "ghost" copy of the modal content
  and animates it out, providing smooth transitions even though LiveView
  removes the real element immediately.

  ## Attributes

  - `id` - Unique ID for the modal (required)
  - `open` - Controls visibility. Modal shows when truthy.
  - `myself` - The component's @myself for targeting events
  - `close_on_escape` - Whether to close on escape key (default: true)
  - `close_on_backdrop` - Whether to close on backdrop click (default: true)
  - `max_width` - Maximum width: :sm, :md, :lg, :xl, :"2xl" (default: :md)
  - `duration` - Animation duration in ms (default: 200)

  ## Example

      <.modal_chrome id="edit-modal" open={@product_id} myself={@myself}>
        <h2>Edit Product</h2>
        <.form ...>...</.form>
      </.modal_chrome>
  """
  attr(:id, :string, required: true, doc: "Unique ID for the modal")
  attr(:open, :any, required: true, doc: "Controls visibility (truthy = open)")
  attr(:open_field, :atom, default: :open, doc: "The name of the open state field")
  attr(:myself, :any, required: true, doc: "The component's @myself")
  attr(:close_on_escape, :boolean, default: true)
  attr(:close_on_backdrop, :boolean, default: true)
  attr(:max_width, :atom, default: :md)
  attr(:duration, :integer, default: 200)
  slot(:inner_block, required: true)
  slot(:loading, doc: "Loading content shown during optimistic open")

  def modal_chrome(assigns) do
    max_width_class = Map.get(@max_width_classes, assigns.max_width, "max-w-md")

    # Build the close command: just dispatch close-panel event
    # The hook will use pushEvent with cycle tracking to send the close to the server
    on_close = JS.dispatch("close-panel", to: "##{assigns.id}")

    # All modal chrome animations are now handled by the hook via direct classList manipulation
    # since all chrome elements have JS.ignore_attributes(["class", "style"])

    assigns =
      assigns
      |> assign(:max_width_class, max_width_class)
      |> assign(:on_close, on_close)
      |> assign(:is_open, assigns.open != nil)

    ~H"""
    <%!-- Wrapper for hook - always present, client controls visibility via class --%>
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center pointer-events-none invisible"
      phx-hook=".LavashModal"
      phx-mounted={JS.ignore_attributes(["class", "style"])}
      phx-target={@myself}
      data-duration={@duration}
      data-open={to_string(@is_open)}
      data-open-field={@open_field}
      data-open-value={Jason.encode!(@open)}
    >
      <%!-- Backdrop overlay - client controls opacity and visibility --%>
      <div
        id={"#{@id}-overlay"}
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class="absolute inset-0 bg-black opacity-0"
        phx-click={@close_on_backdrop && @on_close}
      />

      <%!-- Panel - client controls opacity/scale/transform via JS commands --%>
      <div
        id={"#{@id}-panel_content"}
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class={"inline-grid z-10 bg-base-100 rounded-lg shadow-xl overflow-hidden #{@max_width_class} w-full opacity-0 scale-95"}
        phx-click="noop"
        phx-target={@myself}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "Escape"}
      >
        <%!-- Loading content - client controls visibility via class/style --%>
        <div
          :if={@loading != []}
          id={"#{@id}-loading_content"}
          phx-mounted={JS.ignore_attributes(["class", "style"])}
          class="row-start-1 col-start-1 hidden opacity-0 pointer-events-none"
        >
          {render_slot(@loading)}
        </div>
        <%!-- Main content - client controls opacity via class/style --%>
        <div
          id={"#{@id}-main_content"}
          phx-mounted={JS.ignore_attributes(["class", "style"])}
          data-active-if-open={to_string(@is_open)}
          class="row-start-1 col-start-1"
        >
          <div :if={@is_open} id={"#{@id}-main_content_inner"}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LavashModal">
      // --- SyncedVar: Client-server state synchronization ---
      // Models an eventually consistent variable with optimistic updates.
      // Exposed globally as window.Lavash.SyncedVar for use by other hooks.
      const SyncedVar = (() => {
        // Return existing class if already defined (avoid duplication)
        if (window.Lavash?.SyncedVar) return window.Lavash.SyncedVar;

        class SyncedVar {
          constructor(initialValue, onChange) {
            this.value = initialValue;           // optimistic client value
            this.confirmedValue = initialValue;  // last server-confirmed value
            this.version = 0;
            this.confirmedVersion = 0;
            this.onChange = onChange;            // callback: (newValue, oldValue, source) => void
          }

          // Optimistically set value and push to server
          // pushFn: (params, replyCallback) => void
          set(newValue, pushFn, extraParams = {}) {
            const oldValue = this.value;
            if (newValue === oldValue) return;

            this.version++;
            const v = this.version;
            this.value = newValue;

            // Notify of optimistic change
            this.onChange?.(newValue, oldValue, 'optimistic');

            // Push to server with version tracking
            pushFn?.({ ...extraParams, _version: v }, (reply) => {
              if (v !== this.version) {
                // Stale response - a newer operation has started
                return;
              }
              this.confirmedVersion = v;
              this.confirmedValue = newValue;
              this.onChange?.(newValue, oldValue, 'confirmed');
            });
          }

          // Server-initiated change (e.g., from form save)
          // Only accepts if client has no pending operations
          serverSet(newValue) {
            if (this.confirmedVersion !== this.version) {
              // Client has pending operations - ignore server change
              return false;
            }
            const oldValue = this.value;
            if (newValue === oldValue) return false;

            this.value = newValue;
            this.confirmedValue = newValue;
            this.onChange?.(newValue, oldValue, 'server');
            return true;
          }

          get isPending() {
            return this.version !== this.confirmedVersion;
          }
        }

        // Expose globally for other hooks
        window.Lavash = window.Lavash || {};
        window.Lavash.SyncedVar = SyncedVar;
        return SyncedVar;
      })()

      // --- Base State Class ---
      class ModalState {
        constructor(modal) {
          this.modal = modal;
        }

        get name() {
          return this.constructor.name
            .substring(0, this.constructor.name.length - "State".length)
            .toLowerCase();
        }

        onRequestOpen() {}
        onRequestClose() {}
        onServerRequestsOpen() {}
        onServerRequestsClose() {}
        onPanelOpenTransitionEnd() {}
        onEnter() {}
        onExit() {}
        onUpdate() {}
      }

      // --- Concrete State Implementations ---
      class ClosedState extends ModalState {
        onEnter() {
          this.modal._resetDOM();
        }
        onRequestOpen() {
          this.modal.transitionTo(this.modal.states.opening);
        }
        onServerRequestsOpen() {
          // Server requested open while closed - go through opening state to show loading
          this.modal.transitionTo(this.modal.states.opening);
        }
      }

      class OpeningState extends ModalState {
        onEnter() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState.onEnter`);
          // Reset DOM state before opening to clear any leftovers from previous close
          this.modal._resetDOM();

          this.modal.closeInitiator = null;
          this.modal.el.classList.remove("invisible", "pointer-events-none");

          // Show loading content (direct classList manipulation)
          const loadingContent = this.modal.getLoadingContent();
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState showing loading, loadingContent=`, loadingContent);
          if (loadingContent) {
            loadingContent.classList.remove("hidden", "opacity-0");
            loadingContent.classList.add("opacity-100");
            console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState loading classes after show:`, loadingContent.className);
          }

          // Animate panel open (classList with Tailwind transition classes)
          if (this.modal.panelContent) {
            this.modal.panelContent.classList.add("transition-all", "duration-200", "ease-out");
            // Force reflow
            this.modal.panelContent.offsetHeight;
            // Animate to visible state
            this.modal.panelContent.classList.remove("opacity-0", "scale-95");
            this.modal.panelContent.classList.add("opacity-100", "scale-100");
          }

          // Animate overlay open (classList with Tailwind transition classes)
          if (this.modal.overlay) {
            this.modal.overlay.classList.add("transition-opacity", "duration-200", "ease-out");
            // Force reflow
            this.modal.overlay.offsetHeight;
            // Animate to visible state
            this.modal.overlay.classList.remove("opacity-0");
            this.modal.overlay.classList.add("opacity-50");
          }

          if (this.modal.panelContent && this.modal.onOpenTransitionEndEvent) {
            this._transitionHandler = (e) => {
              // Only respond to panel_content transitions, not children
              if (e.target !== this.modal.panelContent) return;
              console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState transitionend fired`);
              this.modal.panelContent.removeEventListener("transitionend", this._transitionHandler);
              this.modal.onOpenTransitionEndEvent();
            };
            this.modal.panelContent.addEventListener("transitionend", this._transitionHandler);
          }
        }
        onExit() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState.onExit`);
          if (this.modal.panelContent && this._transitionHandler) {
            this.modal.panelContent.removeEventListener("transitionend", this._transitionHandler);
          }
        }
        onPanelOpenTransitionEnd() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState.onPanelOpenTransitionEnd`);
          this.modal.transitionTo(this.modal.states.open);
        }
        onRequestClose() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState.onRequestClose`);
          this.modal.closeInitiator = "user";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsClose() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState.onServerRequestsClose - STALE? This might be from a previous close cycle`);
          this.modal.closeInitiator = "server";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsOpen() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpeningState.onServerRequestsOpen`);
          this.modal.transitionTo(this.modal.states.openingServerArrived);
        }
      }

      class OpeningServerArrivedState extends ModalState {
        onEnter() {
          this._panelTransitionComplete = false;
          // Re-attach transition end listener
          if (this.modal.panelContent && this.modal.onOpenTransitionEndEvent) {
            this._transitionHandler = (e) => {
              if (e.target !== this.modal.panelContent) return;
              this.modal.panelContent.removeEventListener("transitionend", this._transitionHandler);
              this.modal.onOpenTransitionEndEvent();
            };
            this.modal.panelContent.addEventListener("transitionend", this._transitionHandler);
          }
        }
        onExit() {
          if (this.modal.panelContent && this._transitionHandler) {
            this.modal.panelContent.removeEventListener("transitionend", this._transitionHandler);
          }
        }
        onPanelOpenTransitionEnd() {
          this._panelTransitionComplete = true;
          // Panel is now visible, run flip animation to transition from loading to content
          this.modal.runFlipAnimation(
            this.modal.getMainContentInner ? this.modal.getMainContentInner() : null,
            this.modal.getLoadingContent ? this.modal.getLoadingContent() : null,
          );
          this.modal.transitionTo(this.modal.states.open);
        }
        onRequestClose() {
          this.modal.closeInitiator = "user";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsClose() {
          this.modal.closeInitiator = "server";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onUpdate() {
          // Only run flip if panel transition already completed
          if (this._panelTransitionComplete) {
            this.modal.runFlipAnimation(
              this.modal.getMainContentInner ? this.modal.getMainContentInner() : null,
              this.modal.getLoadingContent ? this.modal.getLoadingContent() : null,
            );
          }
        }
      }

      class OpenState extends ModalState {
        onEnter(isNonOptimistic = false) {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpenState.onEnter, isNonOptimistic=${isNonOptimistic}`);
          this.modal.closeInitiator = null;
          this.modal.el.classList.remove("invisible");

          if (isNonOptimistic) {
            // Animate panel open (classList with Tailwind transition classes)
            if (this.modal.panelContent) {
              this.modal.panelContent.classList.add("transition-all", "duration-200", "ease-out");
              this.modal.panelContent.offsetHeight;
              this.modal.panelContent.classList.remove("opacity-0", "scale-95");
              this.modal.panelContent.classList.add("opacity-100", "scale-100");
            }
            // Animate overlay open
            if (this.modal.overlay) {
              this.modal.overlay.classList.add("transition-opacity", "duration-200", "ease-out");
              this.modal.overlay.offsetHeight;
              this.modal.overlay.classList.remove("opacity-0");
              this.modal.overlay.classList.add("opacity-50");
            }
          }
        }
        onRequestClose() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpenState.onRequestClose`);
          this.modal.closeInitiator = "user";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsClose() {
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpenState.onServerRequestsClose - could be stale from previous close cycle`);
          // Server requested close - animate out
          this.modal.closeInitiator = "server";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsOpen() {
          // Server data arrived while already in open state - run the flip animation
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpenState.onServerRequestsOpen: running flip animation`);
          this.modal.runFlipAnimation(
            this.modal.getMainContentInner ? this.modal.getMainContentInner() : null,
            this.modal.getLoadingContent ? this.modal.getLoadingContent() : null,
          );
        }
        onUpdate() {
          // Also check on any update in case content changed
          const loadingContent = this.modal.getLoadingContent();
          const loadingVisible = loadingContent && !loadingContent.classList.contains("hidden");
          console.log(`LavashModal ${this.modal.panelIdForLog}: OpenState.onUpdate, loadingVisible=${loadingVisible}`);
          if (loadingVisible) {
            console.log(`LavashModal ${this.modal.panelIdForLog}: OpenState.onUpdate: loading still visible, running flip animation`);
            this.modal.runFlipAnimation(
              this.modal.getMainContentInner ? this.modal.getMainContentInner() : null,
              loadingContent,
            );
          }
        }
      }

      class ClosingState extends ModalState {
        onEnter() {
          // Immediately disable pointer events so clicks pass through during close animation
          this.modal.el.classList.add("pointer-events-none");

          if (this.modal.panelContent && this.modal.onOpenTransitionEndEvent) {
            this.modal.panelContent.removeEventListener(
              "transitionend",
              this.modal.onOpenTransitionEndEvent,
            );
          }

          this.modal._setupGhostElementAnimation();
          this.modal.transitionTo(this.modal.states.closingWaitingForServer);
        }
      }

      class ClosingWaitingForServerState extends ModalState {
        onEnter() {
          // Transition to closed after animation completes
          this._closeTimeout = setTimeout(() => {
            if (this.modal.currentState === this) {
              this.modal.transitionTo(this.modal.states.closed);
            }
          }, this.modal.duration + 50); // animation duration + buffer
        }
        onExit() {
          if (this._closeTimeout) {
            clearTimeout(this._closeTimeout);
            this._closeTimeout = null;
          }
        }
        onRequestOpen() {
          // User wants to reopen during close animation - reset and start opening
          // Cycle tracking ensures the stale close response is ignored
          this.modal._resetDOM();
          this.modal.transitionTo(this.modal.states.opening);
        }
      }

      // --- LavashModal Hook v2 ---
      export default {
        mounted() {
          const id = this.el.id;
          console.log(`LavashModal v2 mounted: #${id}`);
          if (!id) {
            console.error("LavashModal: Hook element requires an ID.");
            return;
          }

          this.panelIdForLog = `#${id}`;
          this.panelContent = this.el.querySelector(`#${id}-panel_content`);
          this.overlay = this.el.querySelector(`#${id}-overlay`);
          this.getMainContentContainer = () => this.el.querySelector(`#${id}-main_content`);
          this.getMainContentInner = () => this.el.querySelector(`#${id}-main_content_inner`);
          this.getLoadingContent = () => this.el.querySelector(`#${id}-loading_content`);

          this.ghostElement = null;
          this.closeInitiator = null;
          this.duration = Number(this.el.dataset.duration) || 200;

          // Get the open field name and derive the setter action name
          // e.g., open_field="product_id" -> setterAction="set_product_id"
          this.openField = this.el.dataset.openField || "open";
          this.setterAction = `set_${this.openField}`;
          console.log(`LavashModal ${this.panelIdForLog}: openField=${this.openField}, setterAction=${this.setterAction}`);

          // Parse the initial server-side value (null, or the open value like a product_id)
          const initialValue = JSON.parse(this.el.dataset.openValue || "null");

          // SyncedVar for open state - tracks the actual value (not boolean)
          // Value is null when closed, or the open_field value (e.g., product_id) when open
          this.openState = new SyncedVar(initialValue, (newValue, oldValue, source) => {
            console.log(`LavashModal ${this.panelIdForLog}: openState changed: ${oldValue} -> ${newValue} (${source})`);
            const wasOpen = oldValue != null;
            const isOpen = newValue != null;

            if (isOpen && !wasOpen) {
              // Opening
              if (source === 'optimistic') {
                this.processPanelEvent("REQUEST_OPEN");
              } else if (source === 'confirmed') {
                this.processPanelEvent("SERVER_REQUESTS_OPEN");
              } else if (source === 'server') {
                // Server-initiated open (rare case)
                this.processPanelEvent("REQUEST_OPEN");
              }
            } else if (!isOpen && wasOpen) {
              // Closing
              if (source === 'optimistic') {
                this.processPanelEvent("REQUEST_CLOSE");
              } else if (source === 'server') {
                // Server-initiated close (e.g., form save)
                this.processPanelEvent("SERVER_REQUESTS_CLOSE");
              }
              // 'confirmed' close doesn't need special handling - timeout handles transition
            }
          });

          // IDs we watch for in the global onBeforeElUpdated callback
          this._mainContentId = `${id}-main_content`;
          this._mainContentInnerId = `${id}-main_content_inner`;

          // Register ourselves in a global registry so the callback can find us
          window.__lavashModalInstances = window.__lavashModalInstances || {};
          window.__lavashModalInstances[this._mainContentId] = this;

          // Wrap the global onBeforeElUpdated callback to detect content removal
          this._installDomCallback();

          this.onOpenTransitionEndEvent = () => {
            this.processPanelEvent("PANEL_OPEN_TRANSITION_END");
          };

          this.states = {
            closed: new ClosedState(this),
            opening: new OpeningState(this),
            openingServerArrived: new OpeningServerArrivedState(this),
            open: new OpenState(this),
            closing: new ClosingState(this),
            closingWaitingForServer: new ClosingWaitingForServerState(this),
          };
          this.currentState = null;
          this.transitionTo(this.states.closed);

          // Listen for open-panel event - set the value from event detail
          this.el.addEventListener("open-panel", (e) => {
            console.log(`LavashModal ${this.panelIdForLog}: open-panel event received`, e.detail);
            // Extract the open field value from event detail
            // e.g., for open_field="product_id", look for detail.product_id
            const openValue = e.detail?.[this.openField] ?? e.detail?.value ?? true;
            this.openState.set(openValue, (p, cb) => {
              // Push to set_<open_field> with {value: <openValue>}
              this.pushEventTo(this.el, this.setterAction, { ...p, value: openValue }, cb);
            });
          });

          // Listen for close-panel event - set the value to null
          this.el.addEventListener("close-panel", () => {
            console.log(`LavashModal ${this.panelIdForLog}: close-panel event received`);
            this.openState.set(null, (p, cb) => {
              // Push to set_<open_field> with {value: null}
              this.pushEventTo(this.el, this.setterAction, { ...p, value: null }, cb);
            });
          });
        },

        _installDomCallback() {
          // Only install once globally
          if (window.__lavashModalDomCallbackInstalled) return;
          window.__lavashModalDomCallbackInstalled = true;

          const original = this.liveSocket.domCallbacks.onBeforeElUpdated;
          this.liveSocket.domCallbacks.onBeforeElUpdated = (fromEl, toEl) => {
            // Check if any registered modal cares about this element
            const instances = window.__lavashModalInstances || {};
            const modal = instances[fromEl.id];

            if (modal && modal.currentState?.name === "open") {
              const innerId = modal._mainContentInnerId;
              const fromHasInner = fromEl.querySelector(`#${innerId}`);
              const toHasInner = toEl.querySelector(`#${innerId}`);

              if (fromHasInner && !toHasInner) {
                // Content is being removed! Create ghost NOW before morphdom patches
                console.log(`LavashModal ${modal.panelIdForLog}: onBeforeElUpdated detected content removal`);
                modal._createGhostBeforePatch(fromHasInner);
              }
            }

            // Call original callback
            original(fromEl, toEl);
          };
        },

        _createGhostBeforePatch(originalElement) {
          // Clone the content that's about to be removed
          this._preUpdateContentClone = originalElement.cloneNode(true);
          this._preUpdateContentClone.id = `${originalElement.id}_ghost`;

          // Get the original's position for fixed positioning on body
          const rect = originalElement.getBoundingClientRect();

          // Get the panel's computed background to apply to ghost
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

          // Insert ghost on document.body - completely outside morphdom's reach
          document.body.appendChild(this._preUpdateContentClone);

          // Also create a ghost overlay on body so it fades out smoothly
          console.log(`LavashModal ${this.panelIdForLog}: overlay =`, this.overlay);
          if (this.overlay) {
            const overlayOpacity = getComputedStyle(this.overlay).opacity;
            console.log(`LavashModal ${this.panelIdForLog}: creating ghost overlay with opacity ${overlayOpacity}`);
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

          // Hide the original so when morphdom removes it, there's no flash
          originalElement.style.visibility = "hidden";

          // Hide the original overlay - now safe because we ignore style attribute
          if (this.overlay) {
            this.overlay.style.visibility = "hidden";
          }

          this._ghostInsertedInBeforeUpdate = true;
          console.log(`LavashModal ${this.panelIdForLog}: Ghost inserted via onBeforeElUpdated on body`);
        },

        transitionTo(newState, ...entryArgs) {
          const oldStateName = this.currentState ? this.currentState.name : "initial";
          const panelId = this.panelIdForLog || "UNKNOWN";
          console.log(`LavashModal ${panelId}: ${oldStateName} -> ${newState.name}`);
          if (this.currentState) {
            this.currentState.onExit();
          }
          this.currentState = newState;
          if (this.currentState) {
            this.currentState.onEnter(...entryArgs);
          }
        },

        processPanelEvent(eventName) {
          const camelCaseEventName = eventName
            .toLowerCase()
            .split("_")
            .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
            .join("");
          const handlerMethodName = `on${camelCaseEventName}`;
          if (this.currentState[handlerMethodName]) {
            this.currentState[handlerMethodName]();
          }
        },

        beforeUpdate() {
          // Track previous server value to detect server-initiated changes (e.g., from form save)
          this._previousServerValue = JSON.parse(this.el.dataset.openValue || "null");

          // Capture panel rect for FLIP animation when transitioning from loading to content
          // Only capture, never clear here - clearing happens in _resetDOM() and runFlipAnimation()
          if (
            this.currentState &&
            (this.currentState.name === "open" || this.currentState.name === "opening") &&
            this.getLoadingContent() &&
            this.panelContent
          ) {
            this._flipPreRect = this.panelContent.getBoundingClientRect();
          }
        },

        updated() {
          // Parse the new server value from the data attribute
          const newServerValue = JSON.parse(this.el.dataset.openValue || "null");
          console.log(`LavashModal ${this.panelIdForLog}: updated called - currentState = ${this.currentState?.name}, openState.value=${this.openState.value}, newServerValue=${newServerValue}, isPending=${this.openState.isPending}`);

          // Detect server-initiated state change (e.g., from form save closing the modal)
          // SyncedVar.serverSet() will only accept if no pending operations
          const prevWasOpen = this._previousServerValue != null;
          const nowIsOpen = newServerValue != null;

          if (prevWasOpen && !nowIsOpen && this.currentState?.name === "open") {
            // Server closed the modal - use serverSet to update if no pending ops
            this.openState.serverSet(null);
          } else if (!prevWasOpen && nowIsOpen && this.currentState?.name === "closed") {
            // Server opened the modal (rare) - use serverSet to update
            this.openState.serverSet(newServerValue);
          }

          this.currentState.onUpdate();
        },

        _setupGhostElementAnimation() {
          // Check if ghost was already inserted via onBeforeElUpdated (server-initiated close)
          if (this._ghostInsertedInBeforeUpdate && this._preUpdateContentClone) {
            console.log(`LavashModal ${this.panelIdForLog}: Using ghost from onBeforeElUpdated`);
            // Ghost is already in DOM (on document.body) - animate it directly
            this.ghostElement = this._preUpdateContentClone;
            this._preUpdateContentClone = null;
            this._ghostInsertedInBeforeUpdate = false;

            // Animate the ghost overlay (also on body) - use Tailwind classes
            if (this._ghostOverlay) {
              this._ghostOverlay.classList.add("transition-opacity", "duration-200", "ease-out");
              // Force reflow
              this._ghostOverlay.offsetHeight;
              this._ghostOverlay.style.opacity = "0";
            }

            // Animate the ghost directly with Tailwind transition classes
            // The ghost is on body with fixed positioning, so animate opacity and scale
            requestAnimationFrame(() => {
              this.ghostElement.classList.add("transition-all", "duration-200", "ease-out", "origin-center");

              // Force reflow
              this.ghostElement.offsetHeight;

              // Animate out
              requestAnimationFrame(() => {
                this.ghostElement.style.opacity = "0";
                this.ghostElement.style.transform = "scale(0.95)";
              });
            });
            return;
          }

          // Fallback: ghost not inserted via callback (e.g., user-initiated close via button)
          const originalMainContentInner = this.getMainContentInner();

          if (!originalMainContentInner && !this._preUpdateContentClone) {
            return;
          }

          if (originalMainContentInner) {
            this.ghostElement = originalMainContentInner.cloneNode(true);
            originalMainContentInner.remove();
          } else {
            // Use the clone we captured before the update
            this.ghostElement = this._preUpdateContentClone;
            this._preUpdateContentClone = null;
          }

          this.ghostElement.removeAttribute("phx-remove");
          Object.assign(this.ghostElement.style, {
            pointerEvents: "none",
            zIndex: "61",
          });

          const mainContentContainer = this.getMainContentContainer();
          if (mainContentContainer) {
            mainContentContainer.appendChild(this.ghostElement);
          } else if (this.panelContent) {
            this.panelContent.appendChild(this.ghostElement);
          } else {
            this.ghostElement = null;
            return;
          }

          // Animate the ghost element out with Tailwind transition classes
          requestAnimationFrame(() => {
            this.ghostElement.classList.add("transition-all", "duration-200", "ease-out", "origin-center");
            this.ghostElement.offsetHeight;
            this.ghostElement.style.opacity = "0";
            this.ghostElement.style.transform = "scale(0.95)";
          });

          // Also animate the panel (white background) out
          if (this.panelContent) {
            this.panelContent.classList.add("transition-all", "duration-200", "ease-out");
            this.panelContent.offsetHeight;
            this.panelContent.classList.remove("opacity-100", "scale-100");
            this.panelContent.classList.add("opacity-0", "scale-95");
          }

          // Also animate the overlay if present
          if (this.overlay) {
            this.overlay.classList.add("transition-opacity", "duration-200", "ease-out");
            this.overlay.offsetHeight;
            this.overlay.classList.remove("opacity-50");
            this.overlay.classList.add("opacity-0");
          }
        },

        _cleanupCloseAnimation() {
          if (this.ghostElement?.parentNode) {
            this.ghostElement.remove();
          }
          this.ghostElement = null;

          if (this._ghostOverlay?.parentNode) {
            this._ghostOverlay.remove();
          }
          this._ghostOverlay = null;
        },

        _resetDOM() {
          console.log(`LavashModal ${this.panelIdForLog}: _resetDOM called`);
          // Reset all client-owned DOM state to closed/invisible
          this.closeInitiator = null;
          this._cleanupCloseAnimation();
          this._flipPreRect = null;
          this._ghostInsertedInBeforeUpdate = false;
          this._preUpdateContentClone = null;

          // Wrapper - use invisible class (ignore_attributes prevents server patches)
          this.el.classList.add("invisible", "pointer-events-none");

          // Panel - reset to initial closed state, clear transition and FLIP animation leftovers
          if (this.panelContent) {
            // Remove all transition-related classes (including dynamic duration classes)
            this.panelContent.classList.remove(
              "opacity-100", "scale-100",
              "transition-all", "transition-opacity", "transition-none",
              "ease-out", "ease-in-out", "origin-center"
            );
            // Also remove any duration-* classes
            [...this.panelContent.classList].filter(c => c.startsWith("duration-")).forEach(c => {
              this.panelContent.classList.remove(c);
            });
            this.panelContent.classList.add("opacity-0", "scale-95");
            this.panelContent.style.removeProperty("transform");
            this.panelContent.style.removeProperty("transition-duration");
            this.panelContent.style.removeProperty("--flip-translate-x");
            this.panelContent.style.removeProperty("--flip-translate-y");
            this.panelContent.style.removeProperty("--flip-scale-x");
            this.panelContent.style.removeProperty("--flip-scale-y");
            this.panelContent.style.removeProperty("--flip-duration");
          }

          // Overlay - reset visibility, opacity, and transition classes
          if (this.overlay) {
            this.overlay.style.visibility = "";
            this.overlay.classList.remove("opacity-50", "transition-opacity", "ease-out");
            [...this.overlay.classList].filter(c => c.startsWith("duration-")).forEach(c => {
              this.overlay.classList.remove(c);
            });
            this.overlay.classList.add("opacity-0");
          }

          // Loading - clear FLIP animation leftovers
          const loadingContent = this.getLoadingContent();
          console.log(`LavashModal ${this.panelIdForLog}: _resetDOM loadingContent=`, loadingContent, `classes before:`, loadingContent?.className);
          if (loadingContent) {
            loadingContent.classList.add("hidden", "opacity-0");
            loadingContent.classList.remove("opacity-100", "transition-opacity", "ease-out");
            [...loadingContent.classList].filter(c => c.startsWith("duration-")).forEach(c => {
              loadingContent.classList.remove(c);
            });
            loadingContent.style.removeProperty("transform");
            loadingContent.style.removeProperty("transition");
            loadingContent.style.removeProperty("transform-origin");
            console.log(`LavashModal ${this.panelIdForLog}: _resetDOM loadingContent classes after:`, loadingContent.className);
          }
        },

        runFlipAnimation(mainInnerEl, loadEl) {
          console.log(`LavashModal runFlipAnimation: mainInnerEl=${!!mainInnerEl}, loadEl=${!!loadEl}, _flipPreRect=${!!this._flipPreRect}`);

          // Always hide loading if loadEl exists, even without flip animation
          if (loadEl && !loadEl.classList.contains("hidden")) {
            console.log(`LavashModal runFlipAnimation: hiding loading`);
            // Hide loading with transition (classList with Tailwind classes)
            loadEl.classList.add("transition-opacity", "duration-200");
            loadEl.offsetHeight;
            loadEl.classList.remove("opacity-100");
            loadEl.classList.add("opacity-0");
            // Add hidden class after transition
            setTimeout(() => {
              loadEl.classList.add("hidden");
              loadEl.classList.remove("transition-opacity", "duration-200");
            }, 200);
            // Also show main content
            const mainContent = this.getMainContentContainer();
            if (mainContent) {
              mainContent.classList.add("transition-opacity", "duration-200");
              mainContent.offsetHeight;
              mainContent.classList.remove("opacity-0");
              mainContent.classList.add("opacity-100");
            }
          }

          if (!this.currentState || !this._flipPreRect || !this.panelContent || !loadEl) {
            this._flipPreRect = null;
            return;
          }

          const firstRect = this._flipPreRect;
          const lastRect = this.panelContent.getBoundingClientRect();
          this._flipPreRect = null;

          if (
            Math.abs(firstRect.width - lastRect.width) < 1 &&
            Math.abs(firstRect.height - lastRect.height) < 1
          )
            return;

          const sX = lastRect.width === 0 ? 1 : firstRect.width / lastRect.width;
          const sY = lastRect.height === 0 ? 1 : firstRect.height / lastRect.height;
          const dX = firstRect.left - lastRect.left + (firstRect.width - lastRect.width) / 2;
          const dY = firstRect.top - lastRect.top + (firstRect.height - lastRect.height) / 2;

          loadEl.style.transition = "none";
          loadEl.style.transform = `scale(${1 / sX},${1 / sY})`;
          loadEl.style.transformOrigin = "top left";

          this.panelContent.style.setProperty("--flip-translate-x", `${dX}px`);
          this.panelContent.style.setProperty("--flip-translate-y", `${dY}px`);
          this.panelContent.style.setProperty("--flip-scale-x", sX);
          this.panelContent.style.setProperty("--flip-scale-y", sY);
          this.panelContent.style.setProperty("--flip-duration", `${this.duration}ms`);

          this.panelContent.classList.add("transition-none", "origin-center");
          this.panelContent.style.transform = `translate(var(--flip-translate-x), var(--flip-translate-y)) scale(var(--flip-scale-x), var(--flip-scale-y))`;

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
              { once: true },
            );
          });
        },

        destroyed() {
          // Clean up ghost if present
          if (this.ghostElement?.parentNode) {
            this.ghostElement.remove();
          }

          // Remove from global registry
          if (window.__lavashModalInstances && this._mainContentId) {
            delete window.__lavashModalInstances[this._mainContentId];
          }
        },
      };
      </script>
    </div>
    """
  end

  @doc """
  A close button for modal headers using DaisyUI button classes.

  The button dispatches a `close-panel` event to trigger the ghost animation,
  then pushes the "close" event to the server.

  ## Example

      <div class="flex justify-between">
        <h2>Title</h2>
        <.modal_close_button id={@__modal_id__} myself={@myself} />
      </div>
  """
  attr(:id, :string, required: true, doc: "The modal ID (for targeting the close-panel event)")
  attr(:myself, :any, required: true)
  attr(:class, :string, default: "btn btn-sm btn-circle btn-ghost absolute right-2 top-2")

  def modal_close_button(assigns) do
    # Only dispatch close-panel event - the hook handles the server push via SyncedVar
    on_close = JS.dispatch("close-panel", to: "##{assigns.id}")

    assigns = assign(assigns, :on_close, on_close)

    ~H"""
    <button
      type="button"
      phx-click={@on_close}
      class={@class}
      aria-label="Close"
    >
      ✕
    </button>
    """
  end

  @doc """
  Default loading template for modals.

  Shows a DaisyUI skeleton loader while content loads.
  """
  def default_loading(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="skeleton h-6 w-1/3"></div>
      <div class="skeleton h-10 w-full"></div>
      <div class="skeleton h-10 w-full"></div>
    </div>
    """
  end

  @doc """
  Renders modal content with async_result wrapping if a form is specified.

  This component handles the async loading state automatically:
  - If `form_field` is specified, wraps content in `<.async_result>`
  - Shows loading template while the form data loads
  - Passes the unwrapped form to the render function
  """
  attr(:assigns, :map, required: true, doc: "The full assigns map")

  attr(:async_assign, :atom,
    required: true,
    doc: "The async assign to wrap with async_result (or nil)"
  )

  attr(:render, :any, required: true, doc: "Function (assigns) -> HEEx")
  attr(:loading, :any, required: true, doc: "Function (assigns) -> HEEx for loading state")

  def modal_content(assigns) do
    if assigns.async_assign do
      # Get the async assign value
      async_value = Map.get(assigns.assigns, assigns.async_assign)

      assigns =
        assigns
        |> assign(:async_value, async_value)
        |> assign(:inner_assigns, assigns.assigns)
        |> assign(:render_fn, assigns.render)

      ~H"""
      <.async_result :let={data} assign={@async_value}>
        <:loading>
          {@loading.(@inner_assigns)}
        </:loading>
        <% render_assigns = assign(@inner_assigns, :form, data) %>
        {@render_fn.(render_assigns)}
      </.async_result>
      """
    else
      # No async assign, just render directly
      ~H"""
      {@render.(@assigns)}
      """
    end
  end
end
