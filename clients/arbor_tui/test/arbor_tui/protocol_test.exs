defmodule ArborTui.ProtocolTest do
  use ExUnit.Case, async: true

  alias ArborTui.Protocol

  describe "encode/1 (client → server)" do
    test "attach without engagement omits the field" do
      assert Jason.decode!(Protocol.encode({:attach, "agent_a", nil})) ==
               %{"type" => "attach", "agent_id" => "agent_a"}
    end

    test "attach with engagement includes it" do
      assert Jason.decode!(Protocol.encode({:attach, "agent_a", "eng_1"})) ==
               %{"type" => "attach", "agent_id" => "agent_a", "engagement_id" => "eng_1"}
    end

    test "send / cancel / list_engagements" do
      assert Jason.decode!(Protocol.encode({:send, "hi"})) == %{"type" => "send", "text" => "hi"}
      assert Jason.decode!(Protocol.encode(:cancel)) == %{"type" => "cancel"}
      assert Jason.decode!(Protocol.encode(:list_engagements)) == %{"type" => "list_engagements"}
    end
  end

  describe "decode/1 (server → client) — mirrors Arbor.Gateway.Chat.Protocol.encode/1" do
    test "engagement" do
      json = ~s({"type":"engagement","engagement_id":"eng_1","transcript":[]})
      assert Protocol.decode(json) == {:ok, {:engagement, %{id: "eng_1", transcript: []}}}
    end

    test "delta / message / turn_complete" do
      assert Protocol.decode(~s({"type":"delta","text":"to"})) == {:ok, {:delta, "to"}}

      assert Protocol.decode(~s({"type":"message","message":{"role":"assistant","content":"hi"}})) ==
               {:ok, {:message, %{"role" => "assistant", "content" => "hi"}}}

      assert Protocol.decode(~s({"type":"turn_complete","usage":{"tokens":3}})) ==
               {:ok, {:turn_complete, %{"tokens" => 3}}}
    end

    test "notification (the 💭 channel)" do
      assert Protocol.decode(~s({"type":"notification","text":"done","kind":"thought"})) ==
               {:ok, {:notification, %{text: "done", kind: "thought"}}}
    end

    test "error / unknown / garbage" do
      assert Protocol.decode(~s({"type":"error","reason":"unauthorized"})) ==
               {:ok, {:error, "unauthorized"}}

      assert Protocol.decode(~s({"type":"wat"})) == {:error, {:unknown_type, "wat"}}
      assert Protocol.decode("not json{") == {:error, :invalid_json}
    end

    test "HITL approval frames" do
      assert Protocol.decode(
               ~s({"type":"approval_request","proposal_id":"irq_1","tool":"shell","args":{"cmd":"ls"}})
             ) ==
               {:ok,
                {:approval_request,
                 %{proposal_id: "irq_1", tool: "shell", args: %{"cmd" => "ls"}}}}

      assert Protocol.decode(~s({"type":"approvals","approvals":[{"proposal_id":"irq_1"}]})) ==
               {:ok, {:approvals, [%{"proposal_id" => "irq_1"}]}}

      assert Protocol.decode(
               ~s({"type":"approval_resolved","proposal_id":"irq_1","status":"approve"})
             ) ==
               {:ok, {:approval_resolved, %{proposal_id: "irq_1", status: "approve"}}}
    end
  end

  describe "encode/1 — HITL commands" do
    test "approve / deny / list_approvals" do
      assert Jason.decode!(Protocol.encode({:approve, "irq_1"})) ==
               %{"type" => "approve", "proposal_id" => "irq_1"}

      assert Jason.decode!(Protocol.encode({:deny, "irq_1"})) ==
               %{"type" => "deny", "proposal_id" => "irq_1"}

      assert Jason.decode!(Protocol.encode(:list_approvals)) == %{"type" => "list_approvals"}
    end
  end
end
