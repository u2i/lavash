// Generated JS render function with Shadow DOM + morphdom
// This hook is generated from Lavash.Components.TemplatedChipSet at compile time

export default {
  mounted() {
    console.log("[TemplatedChipSet] mounted!", this.el.id);

    this.state = JSON.parse(this.el.dataset.lavashState || "{}");
    console.log("[TemplatedChipSet] initial state:", this.state);

    this.pending = {};
    this.serverVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);
    this.clientVersion = this.serverVersion;

    // Create Shadow DOM for isolation from LiveView patching
    this.shadow = this.el.attachShadow({ mode: 'open' });
    console.log("[TemplatedChipSet] shadow DOM attached");

    // Copy styles into shadow DOM (inherit from light DOM)
    this.injectStyles();

    // Create render container inside shadow
    this.container = document.createElement('div');
    this.shadow.appendChild(this.container);

    // Initial render
    this.render();

    // Handle clicks - use shadow root for event delegation
    this.shadow.addEventListener("click", this.handleClick.bind(this), true);
  },

  injectStyles() {
    console.log("[TemplatedChipSet] injecting styles...");

    // Method 1: Try to adopt stylesheets (works in Chrome/Edge)
    if (document.adoptedStyleSheets && document.adoptedStyleSheets.length > 0) {
      try {
        this.shadow.adoptedStyleSheets = [...document.adoptedStyleSheets];
        console.log("[TemplatedChipSet] adopted stylesheets:", this.shadow.adoptedStyleSheets.length);
        return;
      } catch (e) {
        console.log("[TemplatedChipSet] adoptedStyleSheets failed:", e);
      }
    }

    // Method 2: Clone link tags for external stylesheets
    const links = document.querySelectorAll('link[rel="stylesheet"]');
    console.log("[TemplatedChipSet] cloning", links.length, "stylesheet links");
    links.forEach(link => {
      const clone = link.cloneNode(true);
      this.shadow.appendChild(clone);
    });

    // Method 3: Clone inline styles
    const styles = document.querySelectorAll('style');
    console.log("[TemplatedChipSet] cloning", styles.length, "inline styles");
    styles.forEach(style => {
      const clone = style.cloneNode(true);
      this.shadow.appendChild(clone);
    });
  },

  handleClick(e) {
    console.log("[TemplatedChipSet] click event on:", e.target);

    const target = e.target.closest("[data-optimistic]");
    if (!target) {
      console.log("[TemplatedChipSet] no data-optimistic target found");
      return;
    }

    const actionName = target.dataset.optimistic;
    const value = target.dataset.optimisticValue;
    console.log("[TemplatedChipSet] action:", actionName, "value:", value);

    // Run optimistic update
    this.runOptimisticAction(actionName, value);

    // Send event to LiveComponent via pushEventTo
    // pushEventTo needs a selector - use the hook element itself which has the phx-target
    console.log("[TemplatedChipSet] pushing event to server via this.el");
    // Use this.el as the target - LiveView will use its phx-target attribute
    this.pushEventTo(this.el, "toggle", { val: value });
  },

  runOptimisticAction(actionName, value) {
    this.clientVersion++;

    // Default array toggle action
    if (actionName.startsWith("toggle_")) {
      const field = actionName.replace("toggle_", "");
      const current = this.state[field] || [];
      if (current.includes(value)) {
        this.state[field] = current.filter(v => v !== value);
      } else {
        this.state[field] = [...current, value];
      }
      this.pending[field] = this.state[field];
    }

    this.render();
  },

  render() {
    console.log("[TemplatedChipSet] render() called, state:", this.state);

    const state = this.state;

    // Build new DOM in a fragment
    const root = document.createElement('div');

    const wrapper = document.createElement('div');
    wrapper.className = "flex flex-wrap gap-2";

    const values = state.values || [];
    const labels = state.labels || {};
    const selected = state.selected || [];

    console.log("[TemplatedChipSet] rendering values:", values, "selected:", selected);

    for (const v of values) {
      const btn = document.createElement('button');
      btn.setAttribute("type", "button");
      btn.className = selected.includes(v) ? state.active_class : state.inactive_class;
      btn.dataset.optimistic = "toggle_selected";
      btn.dataset.optimisticValue = v;

      // Humanize the label if not in labels map
      const label = labels[v] || this.humanize(v);
      btn.textContent = label;

      wrapper.appendChild(btn);
    }

    root.appendChild(wrapper);

    // Use morphdom to efficiently diff and patch
    if (window.morphdom) {
      morphdom(this.container, root, {
        childrenOnly: false,
        onBeforeElUpdated: (fromEl, toEl) => {
          // Preserve focus state
          if (fromEl === document.activeElement) {
            return false;
          }
          return true;
        }
      });
    } else {
      // Fallback: replace innerHTML
      this.container.innerHTML = root.innerHTML;
    }
  },

  humanize(str) {
    return str
      .replace(/_/g, ' ')
      .split(' ')
      .map(word => word.charAt(0).toUpperCase() + word.slice(1))
      .join(' ');
  },

  updated() {
    console.log("[TemplatedChipSet] updated() called");
    const serverState = JSON.parse(this.el.dataset.lavashState || "{}");
    const newServerVersion = parseInt(this.el.dataset.lavashVersion || "0", 10);

    console.log("[TemplatedChipSet] server state:", serverState);
    console.log("[TemplatedChipSet] server version:", newServerVersion, "client version:", this.clientVersion);

    if (newServerVersion >= this.clientVersion) {
      this.serverVersion = newServerVersion;
      this.state = { ...serverState };
      this.pending = {};
      console.log("[TemplatedChipSet] accepted server state");
    } else {
      for (const [key, serverValue] of Object.entries(serverState)) {
        if (!(key in this.pending)) {
          this.state[key] = serverValue;
        }
      }
      console.log("[TemplatedChipSet] merged with pending");
    }

    this.render();
  },

  destroyed() {
    this.shadow.removeEventListener("click", this.handleClick.bind(this), true);
  }
};
