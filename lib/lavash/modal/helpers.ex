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
  attr(:myself, :any, required: true, doc: "The component's @myself")
  attr(:close_on_escape, :boolean, default: true)
  attr(:close_on_backdrop, :boolean, default: true)
  attr(:max_width, :atom, default: :md)
  attr(:duration, :integer, default: 200)
  slot(:inner_block, required: true)
  slot(:loading, doc: "Loading content shown during optimistic open")

  def modal_chrome(assigns) do
    max_width_class = Map.get(@max_width_classes, assigns.max_width, "max-w-md")
    duration = assigns.duration

    # Build the close command: dispatch close-panel (triggers animation) + push close event
    on_close =
      JS.dispatch("close-panel", to: "##{assigns.id}")
      |> JS.push("close", target: assigns.myself)

    # Show animation - applied when modal opens
    # Elements start at opacity-0, transition TO visible state
    show_modal_js =
      JS.transition(
        {"transition-all duration-#{duration} ease-out", "opacity-0 scale-95",
         "opacity-100 scale-100"},
        time: duration,
        to: "##{assigns.id}-panel_content",
        blocking: false
      )
      |> JS.transition(
        {"transition-opacity duration-#{duration} ease-out", "opacity-0", "opacity-50"},
        time: duration,
        to: "##{assigns.id}-overlay",
        blocking: false
      )

    # Hide animation - targets elements by ID, called via execJS from hook
    hide_modal_js =
      JS.transition(
        {"transition-all duration-#{duration} ease-out", "opacity-100 scale-100",
         "opacity-0 scale-95"},
        time: duration,
        to: "##{assigns.id}-panel_content",
        blocking: false
      )
      |> JS.transition(
        {"transition-opacity duration-#{duration} ease-out", "opacity-50", "opacity-0"},
        time: duration,
        to: "##{assigns.id}-overlay",
        blocking: false
      )

    # Show loading animation - use direct class manipulation like OptimisticPanel
    show_loading_js =
      JS.remove_class("hidden", to: "##{assigns.id}-loading_content")
      |> JS.remove_class("opacity-0", to: "##{assigns.id}-loading_content")
      |> JS.add_class("opacity-100", to: "##{assigns.id}-loading_content")

    # Hide loading animation - transition out then add hidden class
    hide_loading_js =
      JS.transition(
        {"transition-opacity duration-#{duration}", "opacity-100", "opacity-0"},
        time: duration,
        to: "##{assigns.id}-loading_content",
        blocking: false
      )
      |> JS.add_class("hidden", to: "##{assigns.id}-loading_content")
      |> JS.transition(
        {"transition-opacity duration-#{duration}", "opacity-0", "opacity-100"},
        time: duration,
        to: "##{assigns.id}-main_content",
        blocking: false
      )

    assigns =
      assigns
      |> assign(:max_width_class, max_width_class)
      |> assign(:on_close, on_close)
      |> assign(:show_modal_js, show_modal_js)
      |> assign(:hide_modal_js, hide_modal_js)
      |> assign(:show_loading_js, show_loading_js)
      |> assign(:hide_loading_js, hide_loading_js)
      |> assign(:is_open, assigns.open != nil)

    ~H"""
    <%!-- Wrapper for hook - always present, client controls visibility via class --%>
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center pointer-events-none invisible"
      phx-hook=".LavashModal"
      phx-mounted={JS.ignore_attributes("class")}
      data-duration={@duration}
      data-open={to_string(@is_open)}
      data-show-modal={@show_modal_js}
      data-hide-modal={@hide_modal_js}
      data-show-loading={@show_loading_js}
      data-hide-loading={@hide_loading_js}
    >
      <%!-- Backdrop overlay - client controls opacity --%>
      <div
        id={"#{@id}-overlay"}
        phx-mounted={JS.ignore_attributes("class")}
        class="absolute inset-0 bg-black opacity-0"
        phx-click={@close_on_backdrop && @on_close}
      />

      <%!-- Panel - client controls opacity/scale via JS commands --%>
      <div
        id={"#{@id}-panel_content"}
        phx-mounted={JS.ignore_attributes("class")}
        class={"inline-grid z-10 bg-base-100 rounded-lg shadow-xl overflow-hidden #{@max_width_class} w-full opacity-0 scale-95"}
        phx-click="noop"
        phx-target={@myself}
        phx-window-keydown={@close_on_escape && @on_close}
        phx-key={@close_on_escape && "Escape"}
      >
        <%!-- Loading content - client controls hidden/opacity --%>
        <div
          :if={@loading != []}
          id={"#{@id}-loading_content"}
          phx-mounted={JS.ignore_attributes("class")}
          class="row-start-1 col-start-1 hidden opacity-0 pointer-events-none"
        >
          {render_slot(@loading)}
        </div>
        <%!-- Main content - stacked via grid --%>
        <div
          id={"#{@id}-main_content"}
          data-active-if-open={to_string(@is_open)}
          class="row-start-1 col-start-1"
        >
          <div :if={@is_open} id={"#{@id}-main_content_inner"}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LavashModal">
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
          this.modal.closeInitiator = null;
          this.modal.el.classList.remove("invisible", "pointer-events-none");

          // Show loading and animate panel open
          this.modal.liveSocket.execJS(this.modal.el, this.modal.el.dataset.showLoading);
          this.modal.liveSocket.execJS(this.modal.el, this.modal.el.dataset.showModal);

          if (this.modal.panelContent && this.modal.onOpenTransitionEndEvent) {
            this._transitionHandler = (e) => {
              // Only respond to panel_content transitions, not children
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
        onServerRequestsOpen() {
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
          this.modal.closeInitiator = null;
          this.modal.el.classList.remove("invisible");

          if (isNonOptimistic) {
            this.modal.liveSocket.execJS(
              this.modal.el,
              this.modal.el.dataset.showModal,
            );
          }
        }
        onRequestClose() {
          this.modal.closeInitiator = "user";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsClose() {
          // Server requested close - animate out
          this.modal.closeInitiator = "server";
          this.modal.transitionTo(this.modal.states.closing);
        }
        onServerRequestsOpen() {
          // Server data arrived while already in open state - run the flip animation
          console.log(`LavashModal OpenState.onServerRequestsOpen: running flip animation`);
          this.modal.runFlipAnimation(
            this.modal.getMainContentInner ? this.modal.getMainContentInner() : null,
            this.modal.getLoadingContent ? this.modal.getLoadingContent() : null,
          );
        }
        onUpdate() {
          // Also check on any update in case content changed
          if (this.modal.getLoadingContent() && !this.modal.getLoadingContent().classList.contains("hidden")) {
            console.log(`LavashModal OpenState.onUpdate: loading still visible, running flip animation`);
            this.modal.runFlipAnimation(
              this.modal.getMainContentInner ? this.modal.getMainContentInner() : null,
              this.modal.getLoadingContent ? this.modal.getLoadingContent() : null,
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
        onRequestOpen() {
          this.modal.transitionTo(this.modal.states.closingWaitingThenOpen);
        }
        onServerRequestsClose() {
          this.modal.closeInitiator = "server";
          this.modal.transitionTo(this.modal.states.closed);
        }
      }

      class ClosingWaitingThenOpenState extends ModalState {
        onServerRequestsClose() {
          // Server confirmed close, now re-open fresh
          this.modal._resetDOM();
          this.modal.transitionTo(this.modal.states.opening);
        }
        onServerRequestsOpen() {
          // Server already has the new open state - reset and open
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
            closingWaitingThenOpen: new ClosingWaitingThenOpenState(this),
          };
          this.currentState = null;
          this.transitionTo(this.states.closed);

          this.el.addEventListener("open-panel", () => {
            console.log(`LavashModal ${this.panelIdForLog}: open-panel event received`);
            this.processPanelEvent("REQUEST_OPEN");
          });
          this.el.addEventListener("close-panel", () => {
            console.log(`LavashModal ${this.panelIdForLog}: close-panel event received`);
            this.processPanelEvent("REQUEST_CLOSE");
          });
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

        getImpliedServerEvent() {
          const newMainState = this.getMainContentContainer().dataset.activeIfOpen === "true";

          if (!this.previousMainState && newMainState) {
            return "SERVER_REQUESTS_OPEN";
          } else if (this.previousMainState && !newMainState) {
            return "SERVER_REQUESTS_CLOSE";
          }
          return null;
        },

        beforeUpdate() {
          this.previousMainState = this.getMainContentContainer().dataset.activeIfOpen === "true";

          // Capture content for potential close animation BEFORE LiveView patches DOM
          const mainContentInner = this.getMainContentInner();
          if (this.currentState?.name === "open" && mainContentInner) {
            this._preUpdateContentClone = mainContentInner.cloneNode(true);
          } else {
            this._preUpdateContentClone = null;
          }

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
          console.log(`LavashModal updated(): currentState = ${this.currentState?.name}, previousMainState = ${this.previousMainState}`);
          const eventToHandle = this.getImpliedServerEvent();
          console.log(`LavashModal updated(): eventToHandle = ${eventToHandle}`);
          if (eventToHandle) {
            this.processPanelEvent(eventToHandle);
          }

          this.currentState.onUpdate();
        },

        _setupGhostElementAnimation() {
          const originalMainContentInner = this.getMainContentInner();

          // Use pre-captured clone if live content is gone (server already patched DOM)
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

          if (this.el.dataset.hideModal && this.liveSocket) {
            requestAnimationFrame(() => {
              this.liveSocket.execJS(this.ghostElement, this.el.dataset.hideModal);
            });
          }
        },

        _cleanupCloseAnimation() {
          if (this.ghostElement?.parentNode) {
            this.ghostElement.remove();
          }
          this.ghostElement = null;
        },

        _resetDOM() {
          // Reset all client-owned DOM state to closed/invisible
          this.closeInitiator = null;
          this._cleanupCloseAnimation();
          this._flipPreRect = null;

          // Wrapper - use invisible class (ignore_attributes prevents server patches)
          this.el.classList.add("invisible", "pointer-events-none");

          // Panel - reset to initial closed state and clear FLIP animation leftovers
          if (this.panelContent) {
            this.panelContent.classList.remove("opacity-100", "scale-100", "transition-all", "ease-in-out", "origin-center", "transition-none");
            this.panelContent.classList.add("opacity-0", "scale-95");
            this.panelContent.style.removeProperty("transform");
            this.panelContent.style.removeProperty("transition-duration");
            this.panelContent.style.removeProperty("--flip-translate-x");
            this.panelContent.style.removeProperty("--flip-translate-y");
            this.panelContent.style.removeProperty("--flip-scale-x");
            this.panelContent.style.removeProperty("--flip-scale-y");
            this.panelContent.style.removeProperty("--flip-duration");
          }

          // Overlay
          if (this.overlay) {
            this.overlay.classList.remove("opacity-50");
            this.overlay.classList.add("opacity-0");
          }

          // Loading - clear FLIP animation leftovers
          const loadingContent = this.getLoadingContent();
          if (loadingContent) {
            loadingContent.classList.add("hidden", "opacity-0");
            loadingContent.classList.remove("opacity-100");
            loadingContent.style.removeProperty("transform");
            loadingContent.style.removeProperty("transition");
            loadingContent.style.removeProperty("transform-origin");
          }
        },

        runFlipAnimation(mainInnerEl, loadEl) {
          console.log(`LavashModal runFlipAnimation: mainInnerEl=${!!mainInnerEl}, loadEl=${!!loadEl}, _flipPreRect=${!!this._flipPreRect}`);

          // Always hide loading if loadEl exists, even without flip animation
          if (loadEl && !loadEl.classList.contains("hidden")) {
            console.log(`LavashModal runFlipAnimation: hiding loading`);
            this.liveSocket.execJS(this.el, this.el.dataset.hideLoading);
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
          if (this.ghostElement?.parentNode) {
            this.ghostElement.remove();
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
    on_close =
      JS.dispatch("close-panel", to: "##{assigns.id}")
      |> JS.push("close", target: assigns.myself)

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
