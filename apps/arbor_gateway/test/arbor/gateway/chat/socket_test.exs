# End-to-end test of the chat WebSocket handler at the FRAME level: it drives the
# real Arbor.Gateway.Chat.Socket callbacks (init/handle_in/handle_info) — exercising
# Protocol decode → handler logic → outbound frames + the agent/signal wiring —
# with fakes injected for the cross-app collaborators. The cowboy WS-upgrade glue
# (WebSockAdapter) is thin framework wiring tested separately; this covers the logic.

defmodule Arbor.Gateway.Chat.SocketTest.FakeEngagementStore do
  alias Arbor.Contracts.Comms.Engagement

  def resolve_or_create(agent_id, _principal, _opts) do
    {:ok, Engagement.new(agent_id: agent_id, id: "eng_test", scope: :user)}
  end

  def list_for_agent(agent_id) do
    [Engagement.new(agent_id: agent_id, id: "eng_test", scope: :user, visibility: :private)]
  end
end

defmodule Arbor.Gateway.Chat.SocketTest.FakeManager do
  # The turn is driven through the Session (meta[:session_pid]); the pid just
  # needs to be live since the fake Session ignores it.
  def find_agent(_agent_id), do: {:ok, self(), %{host_pid: self(), session_pid: self()}}
end

defmodule Arbor.Gateway.Chat.SocketTest.FakeSession do
  def send_message(_session_pid, user_message) do
    {:ok, %{text: "echo:" <> user_message.content, usage: %{tokens: 1}}}
  end
end

defmodule Arbor.Gateway.Chat.SocketTest.FakeSignals do
  # No-op so the handler doesn't subscribe to the real bus during the test.
  def subscribe(_pattern, _handler), do: :ok
end

# The chat gate is a capability-presence check (find_authorizing), so the fakes
# stand in for the CapabilityStore: Allow = holds a valid cap, Deny = none.
defmodule Arbor.Gateway.Chat.SocketTest.AllowSecurity do
  def find_authorizing(_principal, _uri), do: {:ok, :cap}
end

defmodule Arbor.Gateway.Chat.SocketTest.DenySecurity do
  def find_authorizing(_principal, _uri), do: {:error, :not_found}
  # security_mod().grant/1 (ensure_approver_capability) — no-op in tests.
  def grant(_opts), do: :ok
end

# Consensus stubs for HITL approvals. Default list_pending is empty so attach
# stays a single (engagement) frame; a per-test override returns a pending one.
defmodule Arbor.Gateway.Chat.SocketTest.FakeConsensus do
  def list_pending, do: []
end

defmodule Arbor.Gateway.Chat.SocketTest.FakeConsensusPending do
  def list_pending,
    do: [%{id: "irq_1", proposer: "agent_a", metadata: %{tool: "shell", args: %{"cmd" => "ls"}}}]
end

defmodule Arbor.Gateway.Chat.SocketTest.FakeCoordinator do
  def force_approve(_id, _actor), do: {:ok, :approved}
  def force_reject(_id, _actor), do: {:ok, :rejected}
end

# InteractionRouter stub — "irq_…" ids resolve here (the live node's :ask path).
defmodule Arbor.Gateway.Chat.SocketTest.FakeInteractionRouter do
  def respond(_request_id, _response, _metadata), do: :ok
  def pending, do: []
end

defmodule Arbor.Gateway.Chat.SocketTest.FakeInteractionRouterPending do
  def respond(_request_id, _response, _metadata), do: :ok

  def pending,
    do: [
      %{
        request_id: "irq_2",
        agent_id: "agent_a",
        kind: :approval,
        resource_uri: "arbor://shell/exec/ls",
        metadata: %{}
      }
    ]
end

defmodule Arbor.Gateway.Chat.SocketTest do
  use ExUnit.Case, async: false

  alias Arbor.Gateway.Chat.Socket

  alias Arbor.Gateway.Chat.SocketTest.{
    AllowSecurity,
    FakeEngagementStore,
    FakeManager,
    FakeSession,
    FakeSignals
  }

  @moduletag :fast

  setup do
    Application.put_env(:arbor_gateway, :chat_engagement_store, FakeEngagementStore)
    Application.put_env(:arbor_gateway, :chat_agent_manager, FakeManager)
    Application.put_env(:arbor_gateway, :chat_session, FakeSession)
    Application.put_env(:arbor_gateway, :chat_signals, FakeSignals)
    Application.put_env(:arbor_gateway, :chat_capability_store, AllowSecurity)

    Application.put_env(
      :arbor_gateway,
      :chat_consensus,
      Arbor.Gateway.Chat.SocketTest.FakeConsensus
    )

    Application.put_env(
      :arbor_gateway,
      :chat_consensus_coordinator,
      Arbor.Gateway.Chat.SocketTest.FakeCoordinator
    )

    # security_mod (grant) — DenySecurity also defines grant/1.
    Application.put_env(
      :arbor_gateway,
      :chat_security,
      Arbor.Gateway.Chat.SocketTest.DenySecurity
    )

    Application.put_env(
      :arbor_gateway,
      :chat_interaction_router,
      Arbor.Gateway.Chat.SocketTest.FakeInteractionRouter
    )

    on_exit(fn ->
      for k <- [
            :chat_engagement_store,
            :chat_agent_manager,
            :chat_session,
            :chat_signals,
            :chat_capability_store,
            :chat_consensus,
            :chat_consensus_coordinator,
            :chat_security,
            :chat_interaction_router
          ] do
        Application.delete_env(:arbor_gateway, k)
      end
    end)

    {:ok, state} = Socket.init(%{principal: "human_1"})
    %{state: state}
  end

  # Drive a text frame through the handler; return {result_tag, decoded_events, state}.
  defp send_frame(map, state) do
    json = Jason.encode!(map)

    case Socket.handle_in({json, [opcode: :text]}, state) do
      {:push, frames, st} -> {:push, decode_frames(frames), st}
      {:ok, st} -> {:ok, [], st}
    end
  end

  defp decode_frames(frames) do
    Enum.map(frames, fn {:text, json} -> Jason.decode!(json) end)
  end

  defp attach(state, agent_id \\ "agent_a") do
    {:push, [event], st} = send_frame(%{type: "attach", agent_id: agent_id}, state)
    assert event["type"] == "engagement"
    st
  end

  describe "attach" do
    test "resolves a :user engagement and replies with an engagement frame", %{state: state} do
      {:push, [event], st} = send_frame(%{type: "attach", agent_id: "agent_a"}, state)

      assert event == %{"type" => "engagement", "engagement_id" => "eng_test", "transcript" => []}
      assert st.agent_id == "agent_a"
      assert st.engagement_id == "eng_test"
      assert st.subscribed?
    end

    test "missing agent_id → error frame", %{state: state} do
      {:push, [event], _} = send_frame(%{type: "attach"}, state)
      assert event["type"] == "error"
    end

    test "capability gate: an unauthorized principal cannot attach (fail-closed)", %{state: state} do
      Application.put_env(
        :arbor_gateway,
        :chat_capability_store,
        Arbor.Gateway.Chat.SocketTest.DenySecurity
      )

      {:push, [event], st} = send_frame(%{type: "attach", agent_id: "agent_a"}, state)

      assert event == %{"type" => "error", "reason" => "unauthorized"}
      # not attached / not subscribed — no reach into the agent
      assert st.agent_id == nil
      refute st.subscribed?
    end
  end

  describe "send" do
    test "runs the turn off-socket; result comes back as message + turn_complete", %{state: state} do
      st = attach(state)

      # send returns {:ok, _} immediately (turn runs in a Task that messages us)
      {:ok, [], st} = send_frame(%{type: "send", text: "hello"}, st)

      assert_receive {:query_result, {:ok, %{text: "echo:hello"}}}, 1_000

      # Feed the result back through the handler (as the live socket process would).
      {:push, frames, _} = Socket.handle_info({:query_result, {:ok, %{text: "echo:hello"}}}, st)
      events = decode_frames(frames)
      types = Enum.map(events, & &1["type"])
      assert "message" in types
      assert "turn_complete" in types

      message = Enum.find(events, &(&1["type"] == "message"))
      assert message["message"]["content"] == "echo:hello"
    end

    test "send before attach → :not_attached error", %{state: state} do
      {:push, [event], _} = send_frame(%{type: "send", text: "hi"}, state)
      assert event == %{"type" => "error", "reason" => "not_attached"}
    end
  end

  describe "invalid frames" do
    test "garbage → error frame", %{state: state} do
      {:push, [event], _} =
        case Socket.handle_in({"not json{", [opcode: :text]}, state) do
          {:push, frames, st} -> {:push, decode_frames(frames), st}
        end

      assert event["type"] == "error"
    end
  end

  describe "forwarded signals" do
    test "a :notification for the attached agent becomes a notification frame", %{state: state} do
      st = attach(state, "agent_a")

      signal = %{
        type: :notification,
        data: %{agent_id: "agent_a", text: "thinking…", kind: :thought}
      }

      {:push, frames, _} = Socket.handle_info({:chat_signal, signal}, st)

      assert [%{"type" => "notification", "text" => "thinking…", "kind" => "thought"}] =
               decode_frames(frames)
    end

    test "a signal for a different agent is ignored", %{state: state} do
      st = attach(state, "agent_a")
      signal = %{type: :notification, data: %{agent_id: "agent_OTHER", text: "x", kind: :n}}
      assert {:ok, ^st} = Socket.handle_info({:chat_signal, signal}, st)
    end
  end

  describe "list_engagements" do
    test "returns the agent's engagements", %{state: state} do
      st = attach(state, "agent_a")
      {:push, [event], _} = send_frame(%{type: "list_engagements"}, st)

      assert event["type"] == "engagements"
      assert [%{"id" => "eng_test"}] = event["engagements"]
    end
  end

  describe "HITL approvals" do
    test "an authorization_pending signal becomes an approval_request frame", %{state: state} do
      st = attach(state, "agent_a")

      signal = %{
        type: :authorization_pending,
        data: %{
          principal_id: "agent_a",
          proposal_id: "irq_1",
          tool: "shell",
          args: %{"cmd" => "ls"}
        }
      }

      {:push, frames, _} = Socket.handle_info({:chat_signal, signal}, st)

      assert [%{"type" => "approval_request", "proposal_id" => "irq_1", "tool" => "shell"}] =
               decode_frames(frames)
    end

    test "an interaction.requested signal becomes an approval_request frame", %{state: state} do
      st = attach(state, "agent_a")

      # Set the pending interaction AFTER attach so the engagement frame stays
      # clean; the Socket looks the interaction up when the signal arrives.
      Application.put_env(
        :arbor_gateway,
        :chat_interaction_router,
        Arbor.Gateway.Chat.SocketTest.FakeInteractionRouterPending
      )

      # The interaction signal carries only ids — the Socket looks the full
      # interaction up in the router registry to render tool + args.
      signal = %{
        category: :interaction,
        type: :requested,
        data: %{request_id: "irq_2", kind: :approval, agent_id: "agent_a"}
      }

      {:push, frames, _} = Socket.handle_info({:chat_signal, signal}, st)

      assert [%{"type" => "approval_request", "proposal_id" => "irq_2", "tool" => tool}] =
               decode_frames(frames)

      assert tool == "arbor://shell/exec/ls"
    end

    test "approve of an irq_ id resolves via the InteractionRouter", %{state: state} do
      st = attach(state, "agent_a")
      {:push, [event], _} = send_frame(%{type: "approve", proposal_id: "irq_1"}, st)

      assert event == %{
               "type" => "approval_resolved",
               "proposal_id" => "irq_1",
               "status" => "approve"
             }
    end

    test "deny of an irq_ id resolves via the InteractionRouter", %{state: state} do
      st = attach(state, "agent_a")
      {:push, [event], _} = send_frame(%{type: "deny", proposal_id: "irq_1"}, st)

      assert event["type"] == "approval_resolved"
      assert event["status"] == "deny"
    end

    test "approve of a non-irq id resolves via Consensus", %{state: state} do
      st = attach(state, "agent_a")
      {:push, [event], _} = send_frame(%{type: "approve", proposal_id: "prop_1"}, st)

      assert event == %{
               "type" => "approval_resolved",
               "proposal_id" => "prop_1",
               "status" => "approve"
             }
    end

    test "list_approvals returns the agent's pending proposals", %{state: state} do
      st = attach(state, "agent_a")
      # Override Consensus to return a pending proposal for this agent.
      Application.put_env(
        :arbor_gateway,
        :chat_consensus,
        Arbor.Gateway.Chat.SocketTest.FakeConsensusPending
      )

      {:push, [event], _} = send_frame(%{type: "list_approvals"}, st)

      assert event["type"] == "approvals"
      assert [%{"proposal_id" => "irq_1", "tool" => "shell"}] = event["approvals"]
    end
  end
end
