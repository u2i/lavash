defmodule Lavash.Overlay.Modal.Helpers do
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
      // --- LavashModal Hook v3 ---
      // Uses AnimatedState from parent LavashOptimistic hook with ModalAnimator as delegate
      export default {
        mounted() {
          const id = this.el.id;
          console.log(`LavashModal v3 mounted: #${id}`);
          if (!id) {
            console.error("LavashModal: Hook element requires an ID.");
            return;
          }

          // Get shared classes from global Lavash namespace (loaded via app.js)
          // Must be accessed inside mounted() because colocated hooks load before app.js finishes
          const SyncedVar = window.Lavash?.SyncedVar;
          const ModalAnimator = window.Lavash?.ModalAnimator;
          const AnimatedState = window.Lavash?.AnimatedState;

          if (!SyncedVar) {
            console.error("LavashModal: SyncedVar not found. Ensure synced_var.js loads before modal hooks.");
            return;
          }
          if (!ModalAnimator) {
            console.error("LavashModal: ModalAnimator not found. Ensure modal_animator.js loads before modal hooks.");
            return;
          }
          if (!AnimatedState) {
            console.error("LavashModal: AnimatedState not found. Ensure animated_state.js loads before modal hooks.");
            return;
          }

          this.panelIdForLog = `#${id}`;
          this.duration = Number(this.el.dataset.duration) || 200;

          // Get the open field name
          this.openField = this.el.dataset.openField || "open";
          this.setterAction = `set_${this.openField}`;
          console.log(`LavashModal ${this.panelIdForLog}: openField=${this.openField}, setterAction=${this.setterAction}`);

          // Create ModalAnimator for DOM manipulation
          this.animator = new ModalAnimator(this.el, {
            duration: this.duration,
            openField: this.openField
          });

          // Get AnimatedState from parent LavashOptimistic hook
          const parentRoot = this.el.closest("[phx-hook='LavashOptimistic']");
          this._parentOptimisticHook = parentRoot?.__lavash_hook__;
          this.animatedState = this._parentOptimisticHook?.getAnimatedState?.(this.openField);

          if (this.animatedState) {
            // Set ModalAnimator as delegate for AnimatedState
            this.animatedState.setDelegate(this.animator);
            console.log(`LavashModal ${this.panelIdForLog}: Using AnimatedState from parent hook`);

            // Get the SyncedVar from AnimatedState
            this.openState = this.animatedState.syncedVar;
          } else {
            // Standalone mode - create our own AnimatedState
            // (This is for modals that manage their own state, not inside parent LavashOptimistic)
            console.log(`LavashModal ${this.panelIdForLog}: Standalone mode - creating own AnimatedState`);

            // Create AnimatedState with modal animator as delegate
            // The hook itself acts as a minimal "hook" interface for AnimatedState
            const config = {
              field: this.openField,
              phaseField: `${this.openField}_phase`,
              async: null,  // Modal handles async via its own async_result
              preserveDom: true,
              duration: this.duration
            };

            // Create a logging delegate to debug the state machine flow
            const loggingDelegate = {
              onEntering: (as) => {
                console.log(`🔵 [${this.panelIdForLog}] onEntering - phase will be 'entering'`);
                this.animator.onEntering(as);
              },
              onLoading: (as) => {
                console.log(`🟡 [${this.panelIdForLog}] onLoading - phase will be 'loading'`);
                this.animator.onLoading(as);
              },
              onVisible: (as) => {
                console.log(`🟢 [${this.panelIdForLog}] onVisible - phase will be 'visible'`);
                this.animator.onVisible(as);
              },
              onExiting: (as) => {
                console.log(`🟠 [${this.panelIdForLog}] onExiting - phase will be 'exiting'`);
                this.animator.onExiting(as);
              },
              onIdle: (as) => {
                console.log(`⚪ [${this.panelIdForLog}] onIdle - phase will be 'idle'`);
                this.animator.onIdle(as);
              },
              onAsyncReady: (as) => {
                console.log(`✅ [${this.panelIdForLog}] onAsyncReady - async data arrived (loading/visible)`);
                this.animator.onAsyncReady(as);
              },
              onContentReadyDuringEnter: (as) => {
                console.log(`⏳ [${this.panelIdForLog}] onContentReadyDuringEnter - content arrived during enter animation`);
                this.animator.onContentReadyDuringEnter(as);
              },
              onTransitionEnd: (as) => {
                console.log(`🏁 [${this.panelIdForLog}] onTransitionEnd - enter animation done`);
                this.animator.onTransitionEnd(as);
              }
            };

            // Create AnimatedState with logging delegate
            this.animatedState = new AnimatedState(config, this, loggingDelegate);

            // Get the SyncedVar from AnimatedState
            this.openState = this.animatedState.syncedVar;

            // Initialize with current server value
            const initialValue = JSON.parse(this.el.dataset.openValue || "null");
            if (initialValue != null) {
              // Modal starts open - set value without triggering animation
              // (the DOM already reflects the open state)
              this.openState.value = initialValue;
              this.openState.confirmedValue = initialValue;
            }
          }

          // IDs for onBeforeElUpdated callback
          this._mainContentId = `${id}-main_content`;
          this._mainContentInnerId = `${id}-main_content_inner`;

          // Register ourselves in global registry for onBeforeElUpdated callback
          window.__lavashModalInstances = window.__lavashModalInstances || {};
          window.__lavashModalInstances[this._mainContentId] = this;

          // Install global DOM callback for ghost element detection
          this._installDomCallback();

          // Listen for open-panel event
          this.el.addEventListener("open-panel", (e) => {
            console.log(`LavashModal ${this.panelIdForLog}: open-panel event received`, e.detail);
            const openValue = e.detail?.[this.openField] ?? e.detail?.value ?? true;
            this.openState.set(openValue, (p, cb) => {
              this.pushEventTo(this.el, this.setterAction, { ...p, value: openValue }, cb);
            });
          });

          // Listen for close-panel event
          this.el.addEventListener("close-panel", () => {
            console.log(`LavashModal ${this.panelIdForLog}: close-panel event received`);
            this.openState.set(null, (p, cb) => {
              this.pushEventTo(this.el, this.setterAction, { ...p, value: null }, cb);
            });
          });

          // Register modal state with parent hook (for future coordination)
          if (this._parentOptimisticHook?.registerModalState) {
            this._parentOptimisticHook.registerModalState(id, this.openField, this.openState);
          }
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

            if (modal) {
              // Check if modal is in a state where we should preserve content
              let shouldPreserve = false;
              if (modal.animatedState) {
                const phase = modal.animatedState.getPhase();
                shouldPreserve = phase === "visible" || phase === "loading";
              } else {
                // Standalone mode - check if modal is currently open
                shouldPreserve = modal.openState?.value != null;
              }

              if (shouldPreserve) {
                const innerId = modal._mainContentInnerId;
                const fromHasInner = fromEl.querySelector(`#${innerId}`);
                const toHasInner = toEl.querySelector(`#${innerId}`);

                if (fromHasInner && !toHasInner) {
                  // Content is being removed! Create ghost NOW before morphdom patches
                  console.log(`LavashModal ${modal.panelIdForLog}: onBeforeElUpdated detected content removal`);
                  modal.animator.createGhostBeforePatch(fromHasInner);
                }
              }
            }

            // Call original callback
            original(fromEl, toEl);
          };
        },

        beforeUpdate() {
          // Track previous server value to detect server-initiated changes
          this._previousServerValue = JSON.parse(this.el.dataset.openValue || "null");

          // Capture panel rect for FLIP animation (only in loading/visible phases)
          // During entering phase, capturePreUpdateRect will skip to avoid locking panel
          const isOpen = this._previousServerValue != null;
          if (this.animatedState) {
            const phase = this.animatedState.getPhase();
            if (phase === "visible" || phase === "entering" || phase === "loading") {
              this.animator.capturePreUpdateRect(phase);
            }
          } else if (isOpen) {
            // Standalone mode - always capture when open
            this.animator.capturePreUpdateRect("visible");
          }
        },

        updated() {
          // Parse the new server value from the data attribute
          const newServerValue = JSON.parse(this.el.dataset.openValue || "null");
          console.log(`LavashModal ${this.panelIdForLog}: updated - phase=${this.animatedState?.getPhase()}, newServerValue=${newServerValue}`);

          // Detect server-initiated state changes
          const prevWasOpen = this._previousServerValue != null;
          const nowIsOpen = newServerValue != null;

          if (prevWasOpen && !nowIsOpen) {
            // Server closed the modal
            this.openState.serverSet(null);
          } else if (!prevWasOpen && nowIsOpen) {
            // Server opened the modal
            this.openState.serverSet(newServerValue);
          }

          // Check if main content has actually loaded (has height)
          const mainInner = this.animator.getMainContentInner();
          const mainContentLoaded = mainInner && mainInner.offsetHeight > 10;

          // Notify state machine when content arrives - it handles the FLIP logic
          // based on current phase (entering vs loading vs visible)
          if (this.animatedState && mainContentLoaded && !this.animatedState.isAsyncReady) {
            console.log(`LavashModal ${this.panelIdForLog}: updated - content arrived, notifying state machine`);
            this.animatedState.onAsyncDataReady();
          }

          // For loading/visible phases, run FLIP directly (state machine already transitioned)
          if (this.animatedState) {
            const phase = this.animatedState.getPhase();
            const loadingContent = this.animator.getLoadingContent();
            const loadingVisible = loadingContent && !loadingContent.classList.contains("hidden");

            if (loadingVisible && mainContentLoaded && (phase === "loading" || phase === "visible")) {
              console.log(`LavashModal ${this.panelIdForLog}: updated - phase=${phase}, running FLIP`);
              this.animator._runFlipAnimation();
            }
          } else if (nowIsOpen && mainContentLoaded) {
            // Standalone mode - run FLIP when open and content loaded
            const loadingContent = this.animator.getLoadingContent();
            const loadingVisible = loadingContent && !loadingContent.classList.contains("hidden");
            if (loadingVisible) {
              console.log(`LavashModal ${this.panelIdForLog}: standalone updated - running FLIP`);
              this.animator._runFlipAnimation();
            }
          }

          // Always release size lock if it wasn't released by FLIP
          this.animator.releaseSizeLockIfNeeded();
        },

        destroyed() {
          // Clean up animator
          this.animator?.destroy();

          // Remove delegate from AnimatedState
          if (this.animatedState) {
            this.animatedState.setDelegate(null);
          }

          // Remove from global registry
          if (window.__lavashModalInstances && this._mainContentId) {
            delete window.__lavashModalInstances[this._mainContentId];
          }

          // Unregister from parent hook
          if (this._parentOptimisticHook?.unregisterModalState) {
            this._parentOptimisticHook.unregisterModalState(this.el.id);
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

      # Only render content when async data is ready.
      # The loading_content div in modal_chrome handles the loading state,
      # so we don't render anything here during loading - this enables FLIP animation
      # to work (loading_content height vs main_content height are different).
      ~H"""
      <.async_result :let={data} assign={@async_value}>
        <:loading></:loading>
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
