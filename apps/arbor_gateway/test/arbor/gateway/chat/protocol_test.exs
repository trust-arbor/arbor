defmodule Arbor.Gateway.Chat.ProtocolTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.Chat.Protocol

  @moduletag :fast

  describe "decode/1" do
    test "attach (with and without engagement_id)" do
      assert {:ok, {:attach, %{agent_id: "agent_a", engagement_id: nil}}} =
               Protocol.decode(~s({"type":"attach","agent_id":"agent_a"}))

      assert {:ok, {:attach, %{agent_id: "agent_a", engagement_id: "eng_1"}}} =
               Protocol.decode(~s({"type":"attach","agent_id":"agent_a","engagement_id":"eng_1"}))
    end

    test "send requires text" do
      assert {:ok, {:send, "hello"}} = Protocol.decode(~s({"type":"send","text":"hello"}))
      assert {:error, :missing_text} = Protocol.decode(~s({"type":"send"}))
    end

    test "cancel and list_engagements" do
      assert {:ok, :cancel} = Protocol.decode(~s({"type":"cancel"}))
      assert {:ok, :list_engagements} = Protocol.decode(~s({"type":"list_engagements"}))
    end

    test "unknown type, missing type, and invalid json" do
      assert {:error, {:unknown_type, "frobnicate"}} =
               Protocol.decode(~s({"type":"frobnicate"}))

      assert {:error, :missing_type} = Protocol.decode(~s({"text":"hi"}))
      assert {:error, :invalid_json} = Protocol.decode("not json{")
    end
  end

  describe "encode/1" do
    test "each event type encodes to a typed JSON object" do
      assert decode_type(Protocol.encode({:delta, "hi"})) == {"delta", %{"text" => "hi"}}

      assert {"engagement", m} =
               decode_type(Protocol.encode({:engagement, %{id: "eng_1", transcript: []}}))

      assert m["engagement_id"] == "eng_1"
      assert m["transcript"] == []

      assert {"notification", m} =
               decode_type(Protocol.encode({:notification, %{text: "thinking…", kind: :thought}}))

      assert m["text"] == "thinking…"
      assert m["kind"] == "thought"

      assert {"message", m} =
               decode_type(Protocol.encode({:message, %{role: "assistant", content: "hi"}}))

      assert m["message"]["role"] == "assistant"

      assert {"turn_complete", _} = decode_type(Protocol.encode({:turn_complete, %{tokens: 1}}))
      assert {"error", %{"reason" => "boom"}} = decode_type(Protocol.encode({:error, "boom"}))
      # non-binary reasons are stringified, not crashed
      assert {"error", %{"reason" => r}} = decode_type(Protocol.encode({:error, {:x, 1}}))
      assert is_binary(r)
    end

    test "round-trips a notification as valid JSON" do
      json = Protocol.encode({:notification, %{text: "done", kind: :progress}})
      assert {:ok, %{"type" => "notification"}} = Jason.decode(json)
    end
  end

  test "distinct window payload decodes latest older and newer session requests" do
    for {bounds, opts} <- [
          {[nil, nil, nil, nil], []},
          {[8, nil, 10, 2], [before: 8, through: 10, limit: 2]},
          {[nil, 3, 10, 2], [after: 3, through: 10, limit: 2]}
        ] do
      payload =
        Jason.encode!(["arbor.conversation.window.v1", "human_owner", "agent_a", bounds, nil])

      wire = Jason.encode!(%{payload: payload, authentication: "conversation_session"})

      assert {:ok,
              %{
                operation: :window,
                caller: "human_owner",
                target: "agent_a",
                input: nil,
                opts: ^opts
              }} = Protocol.decode_session(wire)
    end
  end

  test "security regression window grammar rejects mixed selectors malformed bounds and v2 reinterpretation" do
    for bounds <- [
          [1, 0, nil, 20],
          [0, nil, nil, 20],
          [nil, -1, nil, 20],
          [nil, nil, nil, 101],
          [nil, nil, nil, 0],
          [3, nil, 2, 20],
          [nil, 3, 2, 20],
          ["1", nil, nil, 20]
        ] do
      payload =
        Jason.encode!(["arbor.conversation.window.v1", "human_owner", "agent_a", bounds, nil])

      assert {:error, :unauthorized} =
               Protocol.decode_session(
                 Jason.encode!(%{payload: payload, authentication: "conversation_session"})
               )
    end

    payload =
      Jason.encode!([
        "arbor.conversation.v2",
        "window",
        "human_owner",
        "agent_a",
        nil,
        [nil, nil, 20],
        nil
      ])

    assert {:error, :unauthorized} =
             Protocol.decode_session(
               Jason.encode!(%{payload: payload, authentication: "conversation_session"})
             )
  end

  test "window response retains its distinct type and closed data envelope" do
    data = %{
      agent_id: "agent_a",
      engagement_id: "eng_11111111111111111111111111111111",
      entries: [],
      head: 0,
      first: 0,
      last: 0,
      has_older: false,
      has_newer: false
    }

    assert {"conversation_window", %{"data" => actual}} =
             decode_type(Protocol.encode({:conversation_window, data}))

    assert actual == Jason.decode!(Jason.encode!(data))
  end

  defp decode_type(json) do
    {:ok, %{"type" => type} = m} = Jason.decode(json)
    {type, Map.delete(m, "type")}
  end
end
