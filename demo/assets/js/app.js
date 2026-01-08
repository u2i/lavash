// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
// morphdom for efficient DOM diffing (used by Shadow DOM components)
import morphdom from "../vendor/morphdom"
window.morphdom = morphdom
// Lavash optimistic UI library
import { SyncedVar, LavashOptimistic, ModalAnimator } from "lavash"
// Colocated hooks from Lavash library
import {hooks as lavashHooks} from "phoenix-colocated/lavash"
// Lavash optimistic functions - auto-generated at compile time via phoenix-colocated
import {optimistic as lavashOptimisticFns} from "phoenix-colocated/demo"

// Register Lavash on window for colocated hooks and generated optimistic functions
window.Lavash = window.Lavash || {};
window.Lavash.SyncedVar = SyncedVar;
window.Lavash.ModalAnimator = ModalAnimator;
window.Lavash.optimistic = lavashOptimisticFns || {};

// Merge hooks from Lavash library and app-specific hooks
const colocatedHooks = {
  ...lavashHooks,
  LavashOptimistic
}

// Lavash state - survives reconnects, lost on page refresh
let lavashState = {
  // Page-level state (LiveView)
  // Component state is stored under _components keyed by component ID
  _components: {}
}

// Listen for LiveView state sync events
window.addEventListener("phx:_lavash_sync", (e) => {
  lavashState = { ...lavashState, ...e.detail }
  console.debug("[Lavash] LiveView state synced:", lavashState)
})

// Listen for component state sync events
window.addEventListener("phx:_lavash_component_sync", (e) => {
  const { id, state } = e.detail
  lavashState._components[id] = { ...lavashState._components[id], ...state }
  console.debug(`[Lavash] Component ${id} state synced:`, lavashState._components[id])
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Note: LavashOptimistic uses getPendingCount() as a method (not a getter) because
// Phoenix LiveView's ViewHook constructor evaluates all enumerable properties,
// which would fail if a getter references uninitialized state like this.store
const liveSocketOpts = {
  longPollFallbackMs: 2500,
  params: () => ({ _csrf_token: csrfToken, _lavash_state: lavashState }),
  hooks: colocatedHooks,
};

const liveSocket = new LiveSocket("/live", Socket, liveSocketOpts);

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Latency simulation toggle (dev tool)
const LATENCY_OPTIONS = [0, 100, 500]
const setupLatencyToggle = () => {
  const btn = document.getElementById("latency-toggle")
  const label = document.getElementById("latency-label")
  if (!btn || !label) return

  const updateUI = (ms) => {
    btn.classList.toggle("bg-yellow-600", ms > 0)
    btn.classList.toggle("bg-gray-800", ms === 0)
    label.textContent = ms > 0 ? `Lag: ${ms}ms` : "Lag: off"
  }

  const applyLatency = (ms) => {
    if (ms > 0) {
      liveSocket.enableLatencySim(ms)
    } else {
      liveSocket.disableLatencySim()
    }
  }

  // Apply saved state
  const savedMs = parseInt(localStorage.getItem("phx:latency") || "0", 10)
  applyLatency(savedMs)
  updateUI(savedMs)

  // Handle toggle clicks - cycle through options
  btn.addEventListener("click", () => {
    const currentMs = parseInt(localStorage.getItem("phx:latency") || "0", 10)
    const currentIndex = LATENCY_OPTIONS.indexOf(currentMs)
    const nextIndex = (currentIndex + 1) % LATENCY_OPTIONS.length
    const nextMs = LATENCY_OPTIONS[nextIndex]

    if (nextMs > 0) {
      localStorage.setItem("phx:latency", nextMs.toString())
    } else {
      localStorage.removeItem("phx:latency")
    }
    applyLatency(nextMs)
    updateUI(nextMs)
  })
}
setupLatencyToggle()

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

