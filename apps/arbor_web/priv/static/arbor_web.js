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
 * InfiniteScrollUp - Load older messages when scrolling to top.
 * Pushes "load-more-messages" event when scrollTop < 100px.
 * Handles "messages-loaded" event to maintain scroll position.
 *
 * Usage: <div id="messages-container" phx-hook="InfiniteScrollUp">...</div>
 */
ArborWebHooks.InfiniteScrollUp = {
  mounted() {
    this.loading = false;
    this.el.addEventListener("scroll", () => this.onScroll());
    this.handleEvent("messages-loaded", (payload) => {
      this.loading = false;
    });
  },
  updated() {
    // After DOM update from stream_insert at: 0, restore scroll position
    if (this._savedScrollHeight) {
      const newScrollHeight = this.el.scrollHeight;
      const delta = newScrollHeight - this._savedScrollHeight;
      if (delta > 0) {
        this.el.scrollTop = this._savedScrollTop + delta;
      }
      this._savedScrollHeight = null;
      this._savedScrollTop = null;
    }
  },
  onScroll() {
    if (this.loading) return;
    if (this.el.scrollTop < 100) {
      this.loading = true;
      // Save current scroll state before new items are prepended
      this._savedScrollHeight = this.el.scrollHeight;
      this._savedScrollTop = this.el.scrollTop;
      this.pushEvent("load-more-messages", {});
    }
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

/**
 * ResizableColumns - Drag-to-resize column layout.
 * Attach to the grid container. Expects data-col-sizes for initial sizes.
 * Inserts drag handles between columns and persists sizes to localStorage.
 *
 * Usage: <div id="chat-grid" phx-hook="ResizableColumns"
 *          data-col-count="3" data-col-min="150"
 *          style="display: grid; grid-template-columns: 20% 1fr 30%;">
 */
ArborWebHooks.ResizableColumns = {
  mounted() {
    this.setupColumnResizing();
  },
  updated() {
    this.restoreSizes();
  },
  destroyed() {
    if (this._handles) {
      this._handles.forEach(h => h.remove());
    }
  },

  setupColumnResizing() {
    const grid = this.el;
    const id = grid.id;
    const minSize = parseInt(grid.dataset.colMin || "120");
    const children = Array.from(grid.children);
    if (children.length < 2) return;

    // Restore saved sizes or use current
    const saved = localStorage.getItem(`aw-cols-${id}`);
    if (saved) {
      grid.style.gridTemplateColumns = saved;
    }

    this._handles = [];

    // Create drag handles between columns
    for (let i = 0; i < children.length - 1; i++) {
      const handle = document.createElement("div");
      handle.style.cssText = `
        width: 6px; cursor: col-resize; background: transparent;
        transition: background 0.15s; z-index: 10; margin: 0 -3px;
        display: flex; align-items: center; justify-content: center;
      `;
      handle.addEventListener("mouseenter", () => {
        handle.style.background = "rgba(100, 149, 237, 0.4)";
      });
      handle.addEventListener("mouseleave", () => {
        if (!this._dragging) handle.style.background = "transparent";
      });

      handle.addEventListener("mousedown", (e) => this.startDrag(e, grid, i, minSize, id));
      children[i].after(handle);
      this._handles.push(handle);
    }
  },

  startDrag(e, grid, colIndex, minSize, id) {
    e.preventDefault();
    this._dragging = true;
    const startX = e.clientX;
    const gridRect = grid.getBoundingClientRect();
    const cols = getComputedStyle(grid).gridTemplateColumns.split(" ").map(parseFloat);
    const totalWidth = gridRect.width;

    const onMove = (e) => {
      const dx = e.clientX - startX;
      const newCols = [...cols];

      // Adjust the column to the left and right of the handle
      // Columns include handle slots, so real columns are at even indices
      // But our grid has handles inserted as DOM children, not grid items
      // The grid-template-columns still refers to the original 3 columns
      const leftIdx = colIndex;
      const rightIdx = colIndex + 1;

      if (leftIdx < newCols.length && rightIdx < newCols.length) {
        const newLeft = Math.max(minSize, cols[leftIdx] + dx);
        const newRight = Math.max(minSize, cols[rightIdx] - dx);
        newCols[leftIdx] = newLeft;
        newCols[rightIdx] = newRight;
        grid.style.gridTemplateColumns = newCols.map(c => `${c}px`).join(" ");
      }
    };

    const onUp = () => {
      this._dragging = false;
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      // Persist
      localStorage.setItem(`aw-cols-${id}`, grid.style.gridTemplateColumns);
    };

    document.body.style.userSelect = "none";
    document.body.style.cursor = "col-resize";
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  },

  restoreSizes() {
    const id = this.el.id;
    const saved = localStorage.getItem(`aw-cols-${id}`);
    if (saved) {
      this.el.style.gridTemplateColumns = saved;
    }
  }
};

/**
 * ResizableRows - Drag-to-resize row layout within a flex column.
 * Attach to a flex column container. Inserts horizontal drag handles
 * between children and lets users resize panel heights.
 *
 * Usage: <div id="left-panels" phx-hook="ResizableRows" data-row-min="40"
 *          style="display: flex; flex-direction: column;">
 */
ArborWebHooks.ResizableRows = {
  mounted() {
    this.setupRowResizing();
  },
  destroyed() {
    if (this._handles) {
      this._handles.forEach(h => h.remove());
    }
  },

  setupRowResizing() {
    const container = this.el;
    const id = container.id;
    const minSize = parseInt(container.dataset.rowMin || "40");
    const children = Array.from(container.children).filter(
      c => c.style.display !== "none" && !c.dataset.resizeHandle
    );
    if (children.length < 2) return;

    // Restore saved sizes
    const saved = localStorage.getItem(`aw-rows-${id}`);
    if (saved) {
      try {
        const sizes = JSON.parse(saved);
        children.forEach((child, i) => {
          if (sizes[i]) {
            child.style.flex = "0 0 auto";
            child.style.height = sizes[i] + "px";
          }
        });
      } catch(e) { /* ignore parse errors */ }
    }

    this._handles = [];

    for (let i = 0; i < children.length - 1; i++) {
      const handle = document.createElement("div");
      handle.dataset.resizeHandle = "true";
      handle.style.cssText = `
        height: 6px; cursor: row-resize; background: transparent;
        transition: background 0.15s; flex-shrink: 0;
      `;
      handle.addEventListener("mouseenter", () => {
        handle.style.background = "rgba(100, 149, 237, 0.4)";
      });
      handle.addEventListener("mouseleave", () => {
        if (!this._dragging) handle.style.background = "transparent";
      });

      handle.addEventListener("mousedown", (e) => this.startDrag(e, container, children, i, minSize, id));
      children[i].after(handle);
      this._handles.push(handle);
    }
  },

  startDrag(e, container, children, rowIndex, minSize, id) {
    e.preventDefault();
    this._dragging = true;
    const startY = e.clientY;
    const topEl = children[rowIndex];
    const botEl = children[rowIndex + 1];
    const startTopH = topEl.getBoundingClientRect().height;
    const startBotH = botEl.getBoundingClientRect().height;

    const onMove = (e) => {
      const dy = e.clientY - startY;
      const newTopH = Math.max(minSize, startTopH + dy);
      const newBotH = Math.max(minSize, startBotH - dy);
      topEl.style.flex = "0 0 auto";
      topEl.style.height = newTopH + "px";
      botEl.style.flex = "0 0 auto";
      botEl.style.height = newBotH + "px";
    };

    const onUp = () => {
      this._dragging = false;
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      // Persist
      const sizes = children.map(c => c.getBoundingClientRect().height);
      localStorage.setItem(`aw-rows-${id}`, JSON.stringify(sizes));
    };

    document.body.style.userSelect = "none";
    document.body.style.cursor = "row-resize";
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
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
