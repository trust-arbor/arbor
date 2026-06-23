defmodule Arbor.Gateway.Chat.Socket do
  @moduledoc """
  WebSocket handler (the `WebSock` behaviour) for the Gateway chat API.

  The thin transport shell around `Arbor.Gateway.Chat.Protocol`. One socket per
  (authenticated human, agent): the client `attach`es to a `:user`-scoped
  engagement, `send`s turns, and receives streamed deltas + proactive
  notifications forwarded from the agent's `agent.*` signals.

  Cross-app reach (Manager / Session / EngagementStore are at/above this app's
  level) goes through `bridge_call/3` runtime indirection — the same seam
  `Arbor.Gateway.MCP.Handler` uses; no compile-time deps added. The turn is
  driven through the agent's **Session** (`send_message`), not APIAgent directly,
  so it runs the engagement-aware DOT turn pipeline (tool scoping + transcript
  swap) rather than a bare LLM call.

  Testing: the handler is covered frame-level by `socket_test.exs` (real callbacks,
  fakes for collaborators), and the cowboy WS upgrade + SignedRequest auth + frame
  round-trip were validated by a live `Mint.WebSocket` smoke (which caught the
  pending-approval gate bug → the capability-presence gate below). The standing
  live-transport integration test will be the escript + term_ui client.
  """

  @behaviour WebSock

  require Logger

  alias Arbor.Gateway.Chat.Protocol

  @impl true
  def init(state) do
    # state carries %{principal: <authenticated human id>} from the router upgrade.
    {:ok, Map.merge(%{agent_id: nil, engagement_id: nil, subscribed?: false}, state)}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Protocol.decode(text) do
      {:ok, command} -> handle_command(command, state)
      {:error, reason} -> push({:error, reason}, state)
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  # ── Commands ──────────────────────────────────────────────────────

  defp handle_command({:attach, %{agent_id: agent_id}}, state) when is_binary(agent_id) do
    # Capability gate: the authenticated human must be authorized to chat with
    # this agent. Fail-closed — no capability ⇒ no attach (and thus no reach into
    # the agent's unified memory). The grant policy (who holds
    # arbor://chat/agent/<id>) is set by the operator; see gateway-chat-api.md.
    if authorized_to_chat?(state.principal, agent_id) do
      do_attach(agent_id, state)
    else
      push({:error, :unauthorized}, state)
    end
  end

  defp handle_command({:attach, _}, state), do: push({:error, :missing_agent_id}, state)

  defp handle_command({:send, _text}, %{agent_id: nil} = state),
    do: push({:error, :not_attached}, state)

  defp handle_command({:send, text}, state) do
    socket = self()
    %{agent_id: agent_id, engagement_id: engagement_id} = state

    # Run the turn off-socket so streamed deltas (via signals) flow while it runs.
    Task.start(fn ->
      result = query_agent(agent_id, engagement_id, text)
      send(socket, {:query_result, result})
    end)

    {:ok, state}
  end

  defp handle_command(:cancel, %{agent_id: agent_id} = state) when is_binary(agent_id) do
    case bridge_value(agent_manager(), :find_agent, [agent_id]) do
      {:ok, _pid, %{session_pid: session_pid}} when is_pid(session_pid) ->
        bridge_call(session_mod(), :cancel_turn, [session_pid])

      _ ->
        :ok
    end

    {:ok, state}
  end

  defp handle_command(:cancel, state), do: {:ok, state}

  defp handle_command(:list_engagements, %{agent_id: agent_id} = state)
       when is_binary(agent_id) do
    case bridge_call(engagement_store(), :list_for_agent, [agent_id]) do
      {:ok, list} when is_list(list) ->
        push({:engagements, Enum.map(list, &%{id: &1.id, visibility: &1.visibility})}, state)

      _ ->
        push({:engagements, []}, state)
    end
  end

  defp handle_command(:list_engagements, state), do: push({:engagements, []}, state)

  # ── HITL approvals ────────────────────────────────────────────────

  defp handle_command(:list_approvals, %{agent_id: agent_id} = state) when is_binary(agent_id) do
    push({:approvals, pending_approvals(agent_id)}, state)
  end

  defp handle_command(:list_approvals, state), do: push({:approvals, []}, state)

  defp handle_command({:approve, proposal_id}, %{agent_id: agent_id} = state)
       when is_binary(agent_id) do
    resolve_approval(:approve, proposal_id, state)
  end

  defp handle_command({:deny, proposal_id}, %{agent_id: agent_id} = state)
       when is_binary(agent_id) do
    resolve_approval(:deny, proposal_id, state)
  end

  defp handle_command({op, _id}, state) when op in [:approve, :deny],
    do: push({:error, :not_attached}, state)

  # "irq_…" ids come from the InteractionRouter; everything else is a Consensus
  # proposal. (The live node escalates :ask approvals through the router, so this
  # is the path the TUI actually exercises — mirrors the orchestrator's await.)
  defp resolve_approval(op, proposal_id, state) do
    if interaction_request?(proposal_id) do
      resolve_via_router(op, proposal_id, state)
    else
      resolve_via_consensus(op, proposal_id, state)
    end
  end

  defp interaction_request?(id) when is_binary(id), do: String.starts_with?(id, "irq")
  defp interaction_request?(_), do: false

  defp resolve_via_router(op, request_id, state) do
    response = if op == :approve, do: :approved, else: :rejected

    case bridge_call(interaction_router(), :respond, [
           request_id,
           response,
           %{actor: state.principal}
         ]) do
      {:ok, :ok} ->
        push({:approval_resolved, %{proposal_id: request_id, status: op}}, state)

      _ ->
        push({:error, :approval_failed}, state)
    end
  end

  defp resolve_via_consensus(op, proposal_id, state) do
    fun = if op == :approve, do: :force_approve, else: :force_reject

    case bridge_call(consensus_coordinator(), fun, [proposal_id, state.principal]) do
      {:ok, {:ok, _}} ->
        push({:approval_resolved, %{proposal_id: proposal_id, status: op}}, state)

      {:ok, :ok} ->
        push({:approval_resolved, %{proposal_id: proposal_id, status: op}}, state)

      _ ->
        push({:error, :approval_failed}, state)
    end
  end

  defp do_attach(agent_id, state) do
    case bridge_call(engagement_store(), :resolve_or_create, [
           agent_id,
           state.principal,
           [scope: :user, visibility: :private, owner_tenant: state.principal]
         ]) do
      {:ok, {:ok, engagement}} ->
        # The principal must hold the consensus-admin capability to approve/deny
        # tool calls (mirrors ChatLive's ensure_dashboard_approver_capability).
        ensure_approver_capability(state.principal)
        state = subscribe_signals(%{state | agent_id: agent_id, engagement_id: engagement.id})
        push_attach_frames(engagement, state)

      _ ->
        push({:error, :attach_failed}, state)
    end
  end

  # Engagement frame + any already-pending approvals (so a reconnecting client
  # sees tool calls still awaiting its decision).
  defp push_attach_frames(engagement, state) do
    {frames, state} = event_frames({:engagement, %{id: engagement.id, transcript: []}}, state)

    case pending_approvals(state.agent_id) do
      [] ->
        {:push, frames, state}

      pending ->
        {extra, state} = event_frames({:approvals, pending}, state)
        {:push, frames ++ extra, state}
    end
  end

  # Pending approvals come from BOTH paths so a (re)connecting client sees every
  # tool call awaiting its decision regardless of which backend escalated it.
  defp pending_approvals(agent_id) do
    consensus_pending(agent_id) ++ interaction_pending(agent_id)
  end

  defp consensus_pending(agent_id) do
    case bridge_call(consensus_mod(), :list_pending, []) do
      {:ok, proposals} when is_list(proposals) ->
        proposals
        |> Enum.filter(fn p -> Map.get(p, :proposer) == agent_id end)
        |> Enum.map(&approval_view/1)

      _ ->
        []
    end
  end

  defp interaction_pending(agent_id) do
    case bridge_call(interaction_router(), :pending, []) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.filter(fn i ->
          Map.get(i, :agent_id) == agent_id and Map.get(i, :kind) == :approval
        end)
        |> Enum.map(&interaction_view/1)

      _ ->
        []
    end
  end

  defp approval_view(proposal) do
    meta = Map.get(proposal, :metadata) || %{}

    %{
      proposal_id: Map.get(proposal, :id),
      tool: get(meta, :tool) || get(meta, :action) || get(meta, :resource) || "tool",
      args: get(meta, :args) || get(meta, :params) || %{}
    }
  end

  # Render an InteractionRouter interaction (struct or map) as an approval view.
  # The interaction has no friendly tool name — its resource_uri / description is
  # the most specific thing to show the operator.
  defp interaction_view(interaction) do
    %{
      proposal_id: to_string(Map.get(interaction, :request_id)),
      tool:
        to_string(
          Map.get(interaction, :resource_uri) || Map.get(interaction, :description) || "tool"
        ),
      args: Map.get(interaction, :metadata) || %{}
    }
  end

  # Look the full interaction up by request_id to build a rich approval_request
  # (the `interaction.*` signal only carries ids). Falls back to the signal data.
  defp interaction_approval_view(request_id, data) do
    case bridge_call(interaction_router(), :pending, []) do
      {:ok, list} when is_list(list) ->
        case Enum.find(list, fn i -> Map.get(i, :request_id) == request_id end) do
          nil -> fallback_approval_view(request_id, data)
          interaction -> interaction_view(interaction)
        end

      _ ->
        fallback_approval_view(request_id, data)
    end
  end

  defp fallback_approval_view(request_id, data) do
    %{
      proposal_id: to_string(request_id),
      tool: to_string(get(data, :kind) || "approval"),
      args: %{}
    }
  end

  defp ensure_approver_capability(principal) do
    bridge_call(security_mod(), :grant, [
      [
        principal: principal,
        resource: "arbor://consensus/admin",
        constraints: %{},
        metadata: %{source: :chat_tui}
      ]
    ])

    :ok
  end

  # Fail-closed capability-PRESENCE check: does the principal hold a VALID
  # capability authorizing arbor://chat/agent/<id>? Uses find_authorizing (checks
  # expiry/not_before, resource match incl. wildcards, signature, delegation;
  # revoked caps are gone from the store) rather than the full authorize/4
  # pipeline. Deliberate: the owner-scoped grant (made at agent creation) IS the
  # authorization — there's nothing to HITL-approve. The authorize/4 pipeline is
  # for gating what an AGENT may DO (trust tiers + ApprovalGuard escalation), and
  # the live smoke showed it escalates a human cap-holder to :pending_approval.
  # The principal is already cryptographically authenticated at the WS upgrade
  # (SignedRequestAuth); this is purely "do they hold the cap?". Output egress is
  # gated at the message/notify layer, not inbound attach.
  defp authorized_to_chat?(principal, agent_id) do
    case bridge_call(capability_store(), :find_authorizing, [
           principal,
           "arbor://chat/agent/#{agent_id}"
         ]) do
      {:ok, {:ok, _cap}} -> true
      _ -> false
    end
  end

  # ── Async results + forwarded signals ─────────────────────────────

  @impl true
  def handle_info({:query_result, {:ok, %{} = result}}, state) do
    # Session.send_message returns an %Arbor.Contracts.Pipeline.Response{} whose
    # text lives in :content. (:text/"text" kept as fallbacks for other shapes.)
    text =
      Map.get(result, :content) || Map.get(result, :text) || Map.get(result, "text") || ""

    usage = Map.get(result, :usage) || Map.get(result, "usage") || %{}

    state
    |> push_event({:message, %{role: "assistant", content: text}})
    |> then(fn {:push, frames, st} ->
      {extra, st} = event_frames({:turn_complete, usage}, st)
      {:push, frames ++ extra, st}
    end)
  end

  def handle_info({:query_result, {:error, reason}}, state),
    do: push({:error, reason}, state)

  def handle_info({:chat_signal, signal}, state) do
    if signal_for_agent?(signal, state.agent_id) do
      case signal_to_event(signal) do
        {:ok, event} -> push(event, state)
        :ignore -> {:ok, state}
      end
    else
      {:ok, state}
    end
  rescue
    _ -> {:ok, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ── Signal subscription + mapping ─────────────────────────────────

  defp subscribe_signals(%{subscribed?: true} = state), do: state

  defp subscribe_signals(state) do
    socket = self()
    mod = signals_mod()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :subscribe, 2) do
      handler = fn signal -> send(socket, {:chat_signal, signal}) end

      # agent.* = deltas/notifications/tool-use for this agent;
      # security.authorization_pending = HITL tool-approval via the Consensus path;
      # interaction.requested/queued = HITL tool-approval via the InteractionRouter
      # path (the one the live node actually uses — see resolve_approval). The
      # Socket subscribing to the interaction signal IS the TUI's "adapter": it
      # surfaces the prompt and responds via InteractionRouter.respond, so the
      # TUI is a first-class approval surface alongside the dashboard.
      for pattern <- [
            "agent.*",
            "security.authorization_pending",
            "interaction.requested",
            "interaction.queued"
          ] do
        try do
          apply(mod, :subscribe, [pattern, handler])
        rescue
          _ -> :ok
        end
      end
    end

    %{state | subscribed?: true}
  end

  defp signal_for_agent?(%{data: data}, agent_id) when is_map(data) and is_binary(agent_id) do
    (get(data, :agent_id) || get(data, :principal_id)) == agent_id
  end

  defp signal_for_agent?(_, _), do: false

  defp signal_to_event(%{type: :notification, data: data}),
    do:
      {:ok,
       {:notification, %{text: get(data, :text) || "", kind: get(data, :kind) || :notification}}}

  # Tool invocation (live, from the turn's ToolLoop) → a `tool_use` frame so the
  # client can render it inline (⚡). `:tool_call_started` fires as each tool is
  # dispatched; data carries the tool name + the argument keys.
  defp signal_to_event(%{type: :tool_call_started, data: data}) do
    name = to_string(get(data, :tool) || get(data, :name) || get(data, :tool_name) || "")

    # Skip blank-name tool calls — these come from models that emit textual
    # tool-call syntax (e.g. a <tool_code> block) that mis-parses into an
    # empty-named call rather than a structured tool_call.
    if name == "" do
      :ignore
    else
      {:ok, {:tool_use, %{name: name, args: get(data, :arg_keys) || []}}}
    end
  end

  defp signal_to_event(%{type: :stream_delta, data: data}) do
    if get(data, :source) == :turn do
      {:ok, {:delta, get(data, :text) || get(data, :delta) || ""}}
    else
      :ignore
    end
  end

  # HITL (InteractionRouter path): an approval interaction was requested for this
  # agent. The signal carries only ids (request_id/kind/agent_id) — not the tool
  # or args — so look the full interaction up in the registry to render the prompt.
  defp signal_to_event(%{category: :interaction, type: type, data: data})
       when type in [:requested, :queued] do
    request_id = get(data, :request_id)

    cond do
      is_nil(request_id) -> :ignore
      get(data, :kind) != :approval -> :ignore
      true -> {:ok, {:approval_request, interaction_approval_view(request_id, data)}}
    end
  end

  # HITL: a tool call needs the human's approval. Surface it as an
  # approval_request so the client can prompt (y)es / (n)o / (a)lways.
  defp signal_to_event(%{type: :authorization_pending, data: data}) do
    case get(data, :proposal_id) do
      nil ->
        :ignore

      proposal_id ->
        {:ok,
         {:approval_request,
          %{
            proposal_id: to_string(proposal_id),
            tool:
              to_string(get(data, :tool) || get(data, :action) || get(data, :resource) || "tool"),
            args: get(data, :args) || get(data, :params) || %{}
          }}}
    end
  end

  defp signal_to_event(_), do: :ignore

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # ── Agent turn (runtime indirection) ──────────────────────────────

  # Drive the turn through the agent's SESSION (the single-mind engagement
  # holder), not APIAgent.query directly. The Session runs the DOT turn pipeline
  # — which scopes tools via ToolDisclosure (the direct path dumped the full
  # ~170-tool catalog, overflowing the provider's 128 cap) — and routes the
  # engagement_id (carried in the UserMessage) through maybe_switch_engagement,
  # so the engagement substrate is actually exercised. The reply shape
  # ({:ok, %{text:, usage:}}) matches what handle_info/{:query_result} expects.
  defp query_agent(agent_id, engagement_id, text) do
    with {:ok, _pid, meta} <- bridge_value(agent_manager(), :find_agent, [agent_id]),
         session_pid when is_pid(session_pid) <- meta[:session_pid],
         user_message <- build_user_message(text, engagement_id) do
      bridge_value(session_mod(), :send_message, [session_pid, user_message])
    else
      _ -> {:error, :agent_not_found}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_user_message(text, engagement_id) do
    Arbor.Contracts.Session.UserMessage.from_string(text)
    |> Arbor.Contracts.Session.UserMessage.with_engagement(engagement_id)
  end

  # ── Frame helpers ─────────────────────────────────────────────────

  defp push(event, state) do
    {frames, state} = event_frames(event, state)
    {:push, frames, state}
  end

  defp push_event(state, event) do
    {frames, state} = event_frames(event, state)
    {:push, frames, state}
  end

  defp event_frames(event, state), do: {[{:text, Protocol.encode(event)}], state}

  # ── bridge_call (mirror of MCP.Handler's runtime indirection) ─────

  # Returns {:ok, result} | {:error, reason}; never raises.
  defp bridge_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      {:ok, apply(module, function, args)}
    else
      {:error, :not_available}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Like bridge_call but returns the bare result (or raises into the caller's
  # rescue) — used inside `with` where we already guard.
  defp bridge_value(module, function, args) do
    if Code.ensure_loaded?(module), do: apply(module, function, args), else: :not_available
  end

  # Cross-app collaborators, config-resolved (real modules by default) so tests
  # can inject fakes — same pattern as the engagement persistence backend.
  defp engagement_store,
    do: Application.get_env(:arbor_gateway, :chat_engagement_store, Arbor.Comms.EngagementStore)

  defp agent_manager,
    do: Application.get_env(:arbor_gateway, :chat_agent_manager, Arbor.Agent.Manager)

  defp session_mod,
    do: Application.get_env(:arbor_gateway, :chat_session, Arbor.Orchestrator.Session)

  defp signals_mod,
    do: Application.get_env(:arbor_gateway, :chat_signals, Arbor.Signals)

  defp capability_store,
    do:
      Application.get_env(:arbor_gateway, :chat_capability_store, Arbor.Security.CapabilityStore)

  # HITL: Consensus holds pending tool-approval proposals; Coordinator resolves
  # them; Security grants the approver capability.
  defp consensus_mod,
    do: Application.get_env(:arbor_gateway, :chat_consensus, Arbor.Consensus)

  defp consensus_coordinator,
    do:
      Application.get_env(
        :arbor_gateway,
        :chat_consensus_coordinator,
        Arbor.Consensus.Coordinator
      )

  defp security_mod,
    do: Application.get_env(:arbor_gateway, :chat_security, Arbor.Security)

  # HITL (InteractionRouter path): surfaces + resolves :ask approvals on the live
  # node. The Socket subscribes to its `interaction.*` signals and responds via
  # `respond/3`; the orchestrator's executor awaits the matching response topic.
  defp interaction_router,
    do:
      Application.get_env(
        :arbor_gateway,
        :chat_interaction_router,
        Arbor.Comms.InteractionRouter
      )
end
