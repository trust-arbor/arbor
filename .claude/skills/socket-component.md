---
description: >
  Generate a socket-first delegate component for Phoenix LiveView. This pattern manages
  state on the LiveView's socket rather than using a full Phoenix.LiveComponent. The
  component module provides mount, update, and function component functions that the
  LiveView delegates to.
triggers:
  - component
  - LiveComponent
  - child component
  - delegate component
  - socket component
  - function component
  - extract component
  - new component
---

# Socket-First Delegate Component

## Pattern Overview

This pattern replaces `Phoenix.LiveComponent` with a simpler approach: a plain
`Phoenix.Component` module that manages state directly on the parent LiveView's socket
through delegate functions. Events are namespaced to avoid collisions when composing
multiple components in a single LiveView.

## Pattern Structure

### 1. Component Module (`lib/arbor_dashboard/components/<name>_component.ex`)

A module using `Phoenix.Component` that provides:

- **`mount(socket, initial_args)`** — Initializes state by assigning to the socket. Called from the LiveView's `mount/3`.
- **`update_<name>(socket, event_string)`** — One or more update function clauses, pattern-matched on the event string. Called from the LiveView's `handle_event/3`. Returns the updated socket.
- **Function components** — Render functions with `attr`/`slot` declarations and HEEx templates. Events use a namespace prefix like `"<name>:<action>"` in `phx-click` and similar bindings.

Example:

```elixir
defmodule Arbor.Dashboard.Components.AgentPanelComponent do
  use Phoenix.Component

  alias Arbor.Dashboard.Cores.AgentConnection

  def mount(socket, agent_data) do
    connection = if agent_data, do: AgentConnection.new(agent_data), else: nil

    socket
    |> assign(:agent_connection, connection)
    |> assign(:agent_expanded, false)
  end

  def update_panel(socket, "select", %{"id" => agent_id}) do
    # Look up agent, update connection
    assign(socket, :agent_connection, AgentConnection.new(lookup(agent_id)))
  end

  def update_panel(socket, "toggle_expand") do
    assign(socket, :agent_expanded, !socket.assigns.agent_expanded)
  end

  attr :connection, :map, required: true
  attr :expanded, :boolean, default: false
  def agent_panel(assigns) do
    ~H"""
    <div class="agent-panel">
      <h3>{AgentConnection.show_name(@connection)}</h3>
      <p>{AgentConnection.show_status(@connection)}</p>
      <button phx-click="agent:toggle_expand">Details</button>
    </div>
    """
  end
end
```

### 2. LiveView (`lib/arbor_dashboard/live/<name>_live.ex`)

A LiveView that delegates to components:

- **`mount/3`** — Pipes socket through each component's `mount/2`.
- **`handle_event/3`** — Pattern matches the namespace prefix and delegates to the component's update function.
- **`render/1`** — Uses the component module's function components.

Example:

```elixir
defmodule Arbor.Dashboard.ChatLive do
  use Arbor.Dashboard, :live_view

  alias Arbor.Dashboard.Components.{ChatInputComponent, MessageListComponent,
                                     AgentPanelComponent}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> ChatInputComponent.mount(%{})
     |> MessageListComponent.mount([])
     |> AgentPanelComponent.mount(nil)}
  end

  def handle_event("input:" <> event, params, socket) do
    {:noreply, ChatInputComponent.update_input(socket, event, params)}
  end

  def handle_event("messages:" <> event, params, socket) do
    {:noreply, MessageListComponent.update_messages(socket, event, params)}
  end

  def handle_event("agent:" <> event, params, socket) do
    {:noreply, AgentPanelComponent.update_panel(socket, event, params)}
  end

  # Signal/PubSub routing to appropriate component
  def handle_info({:query_result, tag, result}, socket) do
    {:noreply, MessageListComponent.handle_query_result(socket, tag, result)}
  end
end
```

## Composability

Multiple socket-first components coexist in a single LiveView. Each namespaces its events,
and the LiveView mounts and delegates to each independently:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> ComponentA.mount(args_a)
   |> ComponentB.mount(args_b)
   |> ComponentC.mount(args_c)}
end

def handle_event("a:" <> event, params, socket) do
  {:noreply, ComponentA.update_a(socket, event, params)}
end

def handle_event("b:" <> event, params, socket) do
  {:noreply, ComponentB.update_b(socket, event, params)}
end
```

## Arbor Dashboard Conventions

1. Components live in `lib/arbor_dashboard/components/`
2. Pure cores live in `lib/arbor_dashboard/cores/`
3. Event namespaces use the component's domain: `"chat:"`, `"agent:"`, `"memory:"`, `"signals:"`
4. Components that need data from GenServers should receive it as parameters, not fetch it themselves
5. Components should use pure cores (CRC pattern) for business logic
6. Keep `handle_info` routing in the LiveView — components provide handler functions the LiveView delegates to

## When to Extract a Component

Signs a LiveView section should become a socket-first component:
1. **Distinct UI section** with its own events (sidebar, panel, form)
2. **Reusable across LiveViews** (agent card appears in chat + agents page)
3. **Independent state** that doesn't interact with other sections on every event
4. **LiveView exceeds ~200 lines** — start splitting

## Instructions

1. Identify the component name and responsibilities from the user's request.
2. Determine which assigns the component needs to manage.
3. Generate the component module with `mount/2`, `update_<name>/2` clauses, and function components.
4. Use `attr` and `slot` declarations. Namespace all events with `"<name>:<action>"`.
5. Update the parent LiveView to delegate mount, events, and handle_info to the component.
6. If the component needs pure business logic, create a corresponding core module using the CRC pattern.
7. Run `mix compile` to verify.
<!-- applied-learning: separate-admission-acknowledgement-from-refresh-and-clear-only-the-acknowledged-draft -->
<a id="applied-learning-separate-admission-acknowledgement-from-refresh-and-clear-only-the-acknowledged-draft"></a>
**Separate admission acknowledgement from refresh, and clear only the acknowledged draft.** An accepted command followed by a failed history read is still accepted. Clear its ambiguous-submission buffer on acknowledgement, expose the refresh error separately, and never leave the same submitted draft ready to send under a new ID. A late acknowledgement must clear only matching submitted text or draft version, preserving newer edits in both server state and the focused browser input. Security-driven private-state clearing remains unconditional (found 2026-09-27 while qualifying shared ConversationKit web/terminal sessions).

<!-- applied-learning: exercise-native-input-and-browser-hooks-not-only-framework-events -->
<a id="applied-learning-exercise-native-input-and-browser-hooks-not-only-framework-events"></a>
**Exercise native input and browser hooks, not only framework events.** A callback test that invokes chat:send does not prove Enter submits. Breeze 0.5.3 single-line input requires the view to handle unconsumed Enter despite a br-submit attribute; its input content slot and explicit width also affect rendering. Test real Unicode key input, resize and submit behavior. Phoenix may retain a focused input despite changed assigns, so explicit conditional acknowledgement hooks and unconditional private-data clearing must also be checked in the browser (found 2026-09-27 during the Arbor adapter renderer qualification).

For a manual-test handoff, exercise the actual signed-in account through target
selection and verify that the intended controls are enabled. A signed-in header
does not prove current token validity, a listed profile does not prove chat
permission, and a “Resume” label does not prove a lifecycle operation. Verify
session proof at HTTP entry, LiveView mount/reconnect and callback boundaries;
retain separate resource authorization. Inspect the framework's actual logging
path before trusting parameter filters: the pinned LiveView mount logger
inspects sessions directly, so all routed views need the supported logging
control and a behavioral credential-sentinel test. Include the setup's actual
permission grant in readiness verification: an empty audit delivery queue does
not prove retained-identity admission headroom, and a successful profile create
may still have a failed best-effort owner grant (2026-09-27 voice preview
handoff correction).

Verify each framework's public assign API before reusing familiar syntax.
Breeze 0.5.3 assigns a term with `assign/2`; extend a renderer's assigns map with
`Map.put/3`. Render Phoenix ARIA booleans as explicit `"true"` or `"false"`
strings and assert the actual HTML attribute values, rather than assuming
ordinary boolean-attribute semantics (2026-10-01 structured-question comparison).

Inspect every relevant conditional render branch before declaring a documented
control label stale. On 2026-10-05 the running-agent branch showed “Chat” while
the stopped-agent branch correctly showed the guide's “View conversation”.
Match the documented action to its state instead of changing a correct guide
from one observed branch.

<!-- applied-learning: conclude-interface-comparisons-with-one-delivery-choice-per-surface -->
<a id="applied-learning-conclude-interface-comparisons-with-one-delivery-choice-per-surface"></a>
**Conclude interface comparisons with one delivery choice per surface.** When the user wants a selected stack, finish the spike with a concrete choice based on required capabilities and implementation cost; retain alternatives as evidence rather than implying ongoing feature parity. Preserve replaceable adapter boundaries without multiplying maintained implementations. Distinguish measured extension reuse from inferred agent authoring ease: fewer source lines do not prove fewer tokens, iterations or defects. Before promoting a prototype into a reusable library, compare existing projects at that same abstraction level; a successful renderer spike proves feasibility, not a missing ecosystem capability. Qualify remaining requirements on the selected stack, reopening the choice for material new evidence such as a close existing implementation (user clarification and prior-art review on 2026-09-27 after the ConversationKit renderer experiments).

<!-- applied-learning: clear-pending-liveview-stream-inserts-when-revoking-private-state -->
<a id="applied-learning-clear-pending-liveview-stream-inserts-when-revoking-private-state"></a>
**Clear pending LiveView stream inserts when revoking private state.** When a read or scope check fails after stream inserts were queued in the same render, remove those inserts before resetting the stream. Phoenix stream reset alone can still deliver the queued private rows. Regress the actual rendered DOM as well as assigns, and ignore unscoped signal payloads rather than using them to refill an authorized view. (found 2026-09-27 while converging production ChatLive onto authenticated durable history).
