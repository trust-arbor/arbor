defmodule Arbor.Gateway.Chat.Socket do
  @moduledoc """
  WebSocket handler (the `WebSock` behaviour) for the Gateway chat API.

  The thin transport shell around `Arbor.Gateway.Chat.Protocol`. One socket per
  (authenticated human, agent): the client `attach`es to a `:user`-scoped
  engagement, `send`s turns, and receives streamed deltas + proactive
  notifications forwarded from the agent's `agent.*` signals.

  Cross-app reach (Manager / APIAgent / EngagementStore are at/above this app's
  level) goes through `bridge_call/3` runtime indirection — the same seam
  `Arbor.Gateway.MCP.Handler` uses; no compile-time deps added.

  NOTE: the WebSocket transport is not yet covered by an end-to-end test (needs a
  WS test client). The pure protocol (`Protocol`) is unit-tested; this shell wires
  it to the agent + signal bus.
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
    _ = bridge_call(agent_manager(), :cancel_turn, [agent_id])
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

  defp do_attach(agent_id, state) do
    case bridge_call(engagement_store(), :resolve_or_create, [
           agent_id,
           state.principal,
           [scope: :user, visibility: :private, owner_tenant: state.principal]
         ]) do
      {:ok, {:ok, engagement}} ->
        state = subscribe_signals(%{state | agent_id: agent_id, engagement_id: engagement.id})
        push({:engagement, %{id: engagement.id, transcript: []}}, state)

      _ ->
        push({:error, :attach_failed}, state)
    end
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
    text = Map.get(result, :text) || Map.get(result, "text") || ""
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
      try do
        apply(mod, :subscribe, ["agent.*", fn signal -> send(socket, {:chat_signal, signal}) end])
      rescue
        _ -> :ok
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

  defp signal_to_event(%{type: :stream_delta, data: data}) do
    if get(data, :source) == :turn do
      {:ok, {:delta, get(data, :text) || get(data, :delta) || ""}}
    else
      :ignore
    end
  end

  defp signal_to_event(_), do: :ignore

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # ── Agent turn (runtime indirection) ──────────────────────────────

  defp query_agent(agent_id, engagement_id, text) do
    with {:ok, pid, meta} <- bridge_value(agent_manager(), :find_agent, [agent_id]),
         host_pid when is_pid(host_pid) <- meta[:host_pid] || pid,
         user_message <- build_user_message(text, engagement_id) do
      bridge_value(agent_query(), :query, [host_pid, user_message])
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

  defp agent_query,
    do: Application.get_env(:arbor_gateway, :chat_agent_query, Arbor.Agent.APIAgent)

  defp signals_mod,
    do: Application.get_env(:arbor_gateway, :chat_signals, Arbor.Signals)

  defp capability_store,
    do:
      Application.get_env(:arbor_gateway, :chat_capability_store, Arbor.Security.CapabilityStore)
end
