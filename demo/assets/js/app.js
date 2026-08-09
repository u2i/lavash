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

// Lavash: import the decorator factory + helpers. Importing `lavash`
// also installs the layer-2 sync listeners (`phx:_lavash_sync` etc.)
// as a side effect, so we don't need to wire those up manually.
import { lavash, defaultConcerns, getHooks, getState, registerColocated } from "lavash"

// Generated optimistic fns — auto-extracted at compile time by
// phoenix-colocated, exported by each manifest under `optimistic`,
// keyed by module name. They MUST be registered into the lavash
// runtime: a bare side-effect import registers nothing, and every
// optimistic action silently degrades to a server round-trip.
import * as lavashColocated from "phoenix-colocated/lavash"
import * as demoColocated from "phoenix-colocated/demo"
registerColocated(lavashColocated)
registerColocated(demoColocated)

// Plain LiveView demo hooks (hand-coded, no DSL)
import PlainCounter from "./plain_counter_hook.js"

// Build the lavash decorator with the standard concern bundle.
const decorator = lavash({ concerns: defaultConcerns })

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({ _csrf_token: csrfToken, _lavash_state: getState() }),
  hooks: getHooks(decorator, { PlainCounter }),
});

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

