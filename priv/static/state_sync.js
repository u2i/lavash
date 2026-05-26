/**
 * Layer-2 (state) client runtime.
 *
 * Owns the reconnect-survival cache and its server-event listeners.
 * Nothing in here knows about SyncedVar, the optimistic pipeline, or
 * the concerns architecture — this module would still work in a
 * lavash deployment that opted out of layer 4 entirely.
 *
 * ## What lives here
 *
 *   - `lavashState` — a single in-memory object that mirrors the
 *     server's `from: :socket` state per-page + per-component. Updated
 *     by `phx:_lavash_sync` (page) and `phx:_lavash_component_sync`
 *     (component) events the server emits via `push_event/3` whenever
 *     a socket-mode field changes.
 *
 *   - `getState()` — returns the live object so it can be passed to
 *     `LiveSocket.params._lavash_state` on reconnect. The server's
 *     `Lavash.State.hydrate_socket/3` reads it as connect_params and
 *     re-seeds the freshly-mounted LV.
 *
 * ## What this is NOT
 *
 *   - It is not an optimistic store. Values here are server-confirmed
 *     only — the listeners fire AFTER the server has written the new
 *     value and pushed the sync event.
 *
 *   - It is not browser-persistent. Page refresh wipes it; only
 *     websocket reconnect (where the LV process restarts but the tab
 *     keeps its JS context) gets the replay.
 *
 *   - It is not cross-tab. Each tab has its own object.
 *
 * ## Usage
 *
 *     import { getState } from "lavash";   // re-exported from index
 *
 *     new LiveSocket("/live", Socket, {
 *       params: () => ({ _csrf_token: csrf, _lavash_state: getState() })
 *     });
 *
 * Importing this module is enough to install the listeners — they're
 * a side effect of module load. App.js doesn't need to call anything
 * to "activate" the sync; just import lavash and the listeners are
 * live before any LiveSocket connects.
 */

const lavashState = {
  _components: {}
};

window.addEventListener("phx:_lavash_sync", (e) => {
  Object.assign(lavashState, e.detail);
});

window.addEventListener("phx:_lavash_component_sync", (e) => {
  const { id, state } = e.detail;
  lavashState._components[id] = { ...lavashState._components[id], ...state };
});

/**
 * Returns the lavashState object for the LiveSocket params callback.
 *
 *     new LiveSocket(..., {
 *       params: () => ({ _csrf_token: csrf, _lavash_state: getState() })
 *     });
 */
export function getState() {
  return lavashState;
}
