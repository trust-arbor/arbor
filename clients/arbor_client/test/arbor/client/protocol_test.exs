defmodule Arbor.Client.ProtocolTest do
  use ExUnit.Case, async: true

  alias Arbor.Client.Protocol

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

      assert Protocol.decode(json) ==
               {:ok, {:engagement, %{id: "eng_1", transcript: [], display_name: nil}}}
    end

    test "engagement carries the agent display name when present" do
      json =
        ~s({"type":"engagement","engagement_id":"eng_1","transcript":[],"display_name":"River"})

      assert {:ok, {:engagement, %{display_name: "River"}}} = Protocol.decode(json)
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

  test "conversation payload is canonical and binds target, operation, text and cursors" do
    assert Protocol.conversation_payload(:submit, "human_owner", "agent_a", %{
             id: "stable",
             text: "hello"
           }) ==
             ~s(["arbor.conversation.v2","submit","human_owner","agent_a",["stable","hello"],[null,null,null],null])

    assert Protocol.conversation_payload(:history, "human_owner", "agent_a", nil,
             after: 12,
             through: 99,
             limit: 100
           ) ==
             ~s(["arbor.conversation.v2","history","human_owner","agent_a",null,[12,99,100],null])
  end

  test "an exact retry carries unchanged command bytes and an independently signed nonce" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    identity = %{agent_id: "human_owner", private_key: priv}
    command = %{id: "stable", text: "hello"}

    wires =
      for _ <- 1..2,
          do: Protocol.signed_operation(identity, "agent_a", :submit, command) |> Jason.decode!()

    assert Enum.uniq(Enum.map(wires, & &1["payload"])) |> length() == 1

    auths =
      Enum.map(wires, fn wire ->
        "Signature " <> encoded = wire["authorization"]
        auth = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
        nonce = Base.decode64!(auth["nonce"])
        signature = Base.decode64!(auth["signature"])

        message =
          protocol_len(wire["payload"]) <>
            protocol_len(identity.agent_id) <> protocol_len(auth["timestamp"]) <> nonce

        assert :crypto.verify(:eddsa, :none, message, signature, [pub, :ed25519])
        auth
      end)

    refute hd(auths)["nonce"] == List.last(auths)["nonce"]
  end

  test "ownership fence is part of the signed operation payload" do
    old_owner =
      Protocol.conversation_payload(
        :submit,
        "human_owner",
        "agent_a",
        %{id: "stable", text: "hello"},
        expected_engagement_id: "eng_11111111111111111111111111111111"
      )

    new_owner =
      Protocol.conversation_payload(
        :submit,
        "human_owner",
        "agent_a",
        %{id: "stable", text: "hello"},
        expected_engagement_id: "eng_22222222222222222222222222222222"
      )

    refute old_owner == new_owner
    assert List.last(Jason.decode!(old_owner)) == "eng_11111111111111111111111111111111"
  end

  test "bounded transcript windows use their own version and exact selector order" do
    options = [before: 41, through: 60, limit: 20, expected_engagement_id: "eng_current"]

    assert Arbor.Client.conversation_window_payload("human_owner", "agent_a", options) ==
             ~s(["arbor.conversation.window.v1","human_owner","agent_a",[41,null,60,20],"eng_current"])

    assert Protocol.conversation_payload(:window, "human_owner", "agent_a", nil, options) ==
             Arbor.Client.conversation_window_payload("human_owner", "agent_a", options)

    assert Protocol.conversation_window_payload("human_owner", "agent_a", after: 0, limit: 1) ==
             ~s(["arbor.conversation.window.v1","human_owner","agent_a",[null,0,null,1],null])

    assert Protocol.conversation_window_payload("human_owner", "agent_a") ==
             ~s(["arbor.conversation.window.v1","human_owner","agent_a",[null,null,null,null],null])
  end

  test "a signed window binds selectors and engagement without changing v2 history" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    identity = %{agent_id: "human_owner", private_key: priv}
    options = [before: 21, through: 40, limit: 20, expected_engagement_id: "eng_current"]

    wire =
      identity
      |> Arbor.Client.signed_operation("agent_a", :window, nil, options)
      |> Jason.decode!()

    assert wire["payload"] ==
             ~s(["arbor.conversation.window.v1","human_owner","agent_a",[21,null,40,20],"eng_current"])

    "Signature " <> encoded = wire["authorization"]
    auth = encoded |> Base.decode64!(padding: false) |> Jason.decode!()

    message =
      protocol_len(wire["payload"]) <>
        protocol_len(identity.agent_id) <>
        protocol_len(auth["timestamp"]) <> Base.decode64!(auth["nonce"])

    assert :crypto.verify(:eddsa, :none, message, Base.decode64!(auth["signature"]), [
             pub,
             :ed25519
           ])

    assert Protocol.conversation_payload(:history, "human_owner", "agent_a", nil,
             after: 0,
             through: 40,
             limit: 20,
             expected_engagement_id: "eng_current"
           ) ==
             ~s(["arbor.conversation.v2","history","human_owner","agent_a",null,[0,40,20],"eng_current"])
  end

  test "window replies preserve authoritative entries and independent navigation metadata" do
    page = %{
      "agent_id" => "agent_a",
      "engagement_id" => "eng_current",
      "entries" => [
        %{
          "id" => "host_message_17",
          "role" => "assistant",
          "content" => "Host-owned content",
          "timestamp" => "2026-10-02T00:00:00Z",
          "entry_ordinal" => 17
        }
      ],
      "head" => 40,
      "first" => 17,
      "last" => 17,
      "has_older" => true,
      "has_newer" => true
    }

    assert Arbor.Client.decode(Jason.encode!(%{"type" => "conversation_window", "data" => page})) ==
             {:ok, {:conversation_window, page}}
  end

  defp protocol_len(binary), do: <<byte_size(binary)::32, binary::binary>>
end
