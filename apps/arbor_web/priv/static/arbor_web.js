// ArborWeb Foundation JavaScript
// Shared LiveView hooks for Arbor dashboards.
//
// Usage in consuming apps:
//   import { ArborWebHooks } from "/assets/arbor_web.js";
//   let liveSocket = new LiveSocket("/live", Socket, {
//     hooks: { ...ArborWebHooks, ...MyAppHooks }
//   });

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// ── Hook Definitions ────────────────────────────────────────────────

export const ArborWebHooks = {};

/**
 * ScrollToBottom - Auto-scroll a container to the bottom on mount and update.
 * Useful for chat messages, log tails, etc.
 *
 * Usage: <div id="messages" phx-hook="ScrollToBottom">...</div>
 */
ArborWebHooks.ScrollToBottom = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  updated() {
    this.el.scrollTop = this.el.scrollHeight;
  }
};

/**
 * ClearOnSubmit - Clear a form after successful submission.
 * Listens for the "clear_form" event from the server.
 *
 * Usage: <form phx-hook="ClearOnSubmit" phx-submit="send">...</form>
 * Server: push_event(socket, "clear_form", %{})
 */
ArborWebHooks.ClearOnSubmit = {
  mounted() {
    this.handleEvent("clear_form", () => {
      this.el.reset();
    });
  }
};

/**
 * EventTimeline - Auto-scroll to top for new events (newest-first timeline).
 *
 * Usage: <div id="timeline" phx-hook="EventTimeline">...</div>
 */
ArborWebHooks.EventTimeline = {
  mounted() {
    this.scrollToTop();
  },
  updated() {
    this.scrollToTop();
  },
  scrollToTop() {
    this.el.scrollTop = 0;
  }
};

/**
 * ResizablePanel - Persist panel dimensions to localStorage.
 * Saves width/height on resize and restores on mount/update.
 *
 * Usage: <div id="sidebar" phx-hook="ResizablePanel" style="resize: horizontal; overflow: auto;">...</div>
 */
ArborWebHooks.ResizablePanel = {
  mounted() {
    const id = this.el.id;
    const savedWidth = localStorage.getItem(`aw-panel-w-${id}`);
    const savedHeight = localStorage.getItem(`aw-panel-h-${id}`);

    if (savedWidth) this.el.style.width = savedWidth;
    if (savedHeight) this.el.style.height = savedHeight;

    this.observer = new ResizeObserver(entries => {
      for (let entry of entries) {
        const w = entry.contentRect.width;
        const h = entry.contentRect.height;
        if (w > 0 && h > 0) {
          localStorage.setItem(`aw-panel-w-${id}`, this.el.style.width);
          localStorage.setItem(`aw-panel-h-${id}`, this.el.style.height);
        }
      }
    });
    this.observer.observe(this.el);
  },
  updated() {
    const id = this.el.id;
    const savedWidth = localStorage.getItem(`aw-panel-w-${id}`);
    const savedHeight = localStorage.getItem(`aw-panel-h-${id}`);

    if (savedWidth) this.el.style.width = savedWidth;
    if (savedHeight) this.el.style.height = savedHeight;
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  }
};

/**
 * NodeHexagon - Animate hexagon node cards on update.
 * Adds a brief 'updated' class for CSS transitions.
 *
 * Usage: <div id={"node-#{id}"} phx-hook="NodeHexagon">...</div>
 */
ArborWebHooks.NodeHexagon = {
  updated() {
    this.el.classList.add("aw-updated");
    setTimeout(() => {
      this.el.classList.remove("aw-updated");
    }, 300);
  }
};

// ── Default Initialization ──────────────────────────────────────────
// When loaded directly (not imported), initialize LiveView automatically.

if (typeof window !== "undefined" && !window.__arborWebImportOnly) {
  let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  let liveSocket = new LiveSocket("/live", Socket, {
    params: {_csrf_token: csrfToken},
    hooks: ArborWebHooks
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;

  window.addEventListener("phx:disconnected", () => {
    console.log("[ArborWeb] LiveView disconnected");
  });

  window.addEventListener("phx:connected", () => {
    console.log("[ArborWeb] LiveView connected");
  });
}
