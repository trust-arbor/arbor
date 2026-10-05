defmodule Arbor.Gateway.Chat.NoticeProtocolTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.Protocol

  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"
  @maximum 9_223_372_036_854_775_807

  test "security regression supported window precedes the separately decoded exact notice request" do
    {:ok, window} =
      Arbor.Agent.conversation_request_payload(:window, "human_owner", "agent_a", nil, limit: 20)

    assert {:ok, %{operation: :window, opts: [limit: 20]}} =
             Protocol.decode_session(session_frame(window))

    {:ok, notices} =
      Arbor.Agent.conversation_notice_request_payload("human_owner", "agent_a",
        before: 4,
        through: 3,
        limit: 2,
        expected_engagement_id: @engagement
      )

    assert Jason.decode!(notices) == [
             "arbor.conversation.notices.v1",
             "human_owner",
             "agent_a",
             [4, 3, 2],
             @engagement
           ]

    assert {:ok, decoded} = Protocol.decode_session(session_frame(notices))
    assert decoded.operation == :notices
    assert decoded.caller == "human_owner"
    assert decoded.target == "agent_a"
    assert decoded.input == nil

    assert Map.new(decoded.opts) == %{
             before: 4,
             through: 3,
             limit: 2,
             expected_engagement_id: @engagement
           }

    assert {:ok, ^notices} =
             Arbor.Agent.conversation_notice_request_payload(
               decoded.caller,
               decoded.target,
               decoded.opts
             )
  end

  test "optional notice selectors and exact positive bounds round trip without imposing cursor order" do
    for caller <- ["human_owner", "agent_reader"],
        selectors <- [
          [],
          [before: 1, through: 1, limit: 1],
          [before: @maximum, through: 1, limit: 50]
        ] do
      opts = Keyword.put(selectors, :expected_engagement_id, @engagement)
      {:ok, payload} = Arbor.Agent.conversation_notice_request_payload(caller, "agent_a", opts)
      assert {:ok, request} = Protocol.decode_session(session_frame(payload))
      assert request.caller == caller
      assert Map.new(request.opts) == Map.new(opts)

      assert {:ok, ^payload} =
               Arbor.Agent.conversation_notice_request_payload(caller, "agent_a", request.opts)
    end
  end

  test "security regression notice grammar rejects malformed bounds principals missing fence and extras" do
    valid = ["arbor.conversation.notices.v1", "human_owner", "agent_a", [2, 1, 1], @engagement]

    malformed =
      [
        Enum.take(valid, 4),
        valid ++ ["extra"],
        List.replace_at(valid, 0, "arbor.conversation.notices.v2"),
        List.replace_at(valid, 3, [nil, nil]),
        List.replace_at(valid, 3, [nil, nil, nil, "extra"]),
        List.replace_at(valid, 3, %{"limit" => 1}),
        List.replace_at(valid, 4, nil),
        List.replace_at(valid, 4, "eng_route"),
        List.replace_at(valid, 4, "eng_" <> String.duplicate("A", 32)),
        List.replace_at(valid, 4, @engagement <> "\n")
      ] ++
        for(
          {index, values} <- [
            {1, [nil, 1, "owner", "human_", "human_owner\n", String.duplicate("x", 257)]},
            {2,
             [nil, "human_owner", "agent_", "agent_a\n", "agent_" <> String.duplicate("a", 251)]}
          ],
          value <- values,
          do: List.replace_at(valid, index, value)
        ) ++
        for(
          index <- [0, 1],
          value <- [-1, 0, 1.0, "1", @maximum + 1],
          do: List.replace_at(valid, 3, List.replace_at([2, 1, 1], index, value))
        ) ++
        for(
          value <- [-1, 0, 1.0, "1", 51],
          do: List.replace_at(valid, 3, [2, 1, value])
        )

    for request <- malformed do
      assert {:error, :unauthorized} =
               Protocol.decode_session(session_frame(Jason.encode!(request)))
    end
  end

  test "security regression notice envelopes reject duplicate keys extra authority and oversized input" do
    {:ok, payload} =
      Arbor.Agent.conversation_notice_request_payload("human_owner", "agent_a",
        expected_engagement_id: @engagement
      )

    valid = Jason.decode!(session_frame(payload))

    duplicate =
      "{\"payload\":" <>
        Jason.encode!(payload) <>
        ",\"payload\":" <>
        Jason.encode!(payload) <> ",\"authentication\":\"conversation_session\"}"

    for frame <- [
          duplicate,
          Jason.encode!(Map.put(valid, "session_token", "private")),
          Jason.encode!(Map.put(valid, "authentication", "other")),
          Jason.encode!(Map.put(valid, "payload", Jason.decode!(payload))),
          String.duplicate(" ", 262_145) <> session_frame(payload)
        ] do
      assert {:error, :unauthorized} = Protocol.decode_session(frame)
    end

    {_, key} = :crypto.generate_key(:eddsa, :ed25519)
    signed = Jason.decode!(signed_frame(payload, "human_owner", key))

    for frame <- [
          Jason.encode!(Map.put(signed, "authentication", "conversation_session")),
          Jason.encode!(Map.put(signed, "proof", "extra")),
          "{\"payload\":" <>
            Jason.encode!(payload) <>
            ",\"payload\":\"other\",\"authorization\":" <>
            Jason.encode!(signed["authorization"]) <> "}"
        ] do
      assert {:error, :unauthorized} = Protocol.decode_authenticated(frame)
    end
  end

  test "signed notice decode retains its original proof without consuming the nonce" do
    {_, key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, payload} =
      Arbor.Agent.conversation_notice_request_payload("human_owner", "agent_a",
        limit: 1,
        expected_engagement_id: @engagement
      )

    wire = signed_frame(payload, "human_owner", key)
    assert {:ok, first} = Protocol.decode_authenticated(wire)
    assert {:ok, second} = Protocol.decode_authenticated(wire)
    assert first == second
    assert first.operation == :notices
    assert first.proof.payload == payload
    assert first.proof.agent_id == "human_owner"
    refute Map.has_key?(first, :caller)
  end

  test "security regression notice payload caller must match the signed envelope identity" do
    {_, key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, payload} =
      Arbor.Agent.conversation_notice_request_payload("human_owner", "agent_a",
        expected_engagement_id: @engagement
      )

    frame = Jason.decode!(signed_frame(payload, "human_owner", key))
    forged = payload |> Jason.decode!() |> List.replace_at(1, "human_foreign") |> Jason.encode!()

    assert {:error, :unauthorized} =
             Protocol.decode_authenticated(Jason.encode!(Map.put(frame, "payload", forged)))
  end

  test "notice reply encoding retains the closed host page rather than adding window routing fields" do
    page = %{
      owner_id: "human_owner",
      target_agent_id: "agent_a",
      engagement_id: @engagement,
      notices: [],
      head: 0,
      through: 0,
      has_older: false,
      next_before: nil,
      complete: true
    }

    assert Jason.decode!(Protocol.encode({:conversation_notices, page})) == %{
             "type" => "conversation_notices",
             "data" => Jason.decode!(Jason.encode!(page))
           }

    assert Jason.decode!(Protocol.encode({:error, :notice_subject_required})) == %{
             "type" => "error",
             "reason" => "notice_subject_required"
           }
  end

  defp session_frame(payload),
    do: Jason.encode!(%{payload: payload, authentication: "conversation_session"})

  defp signed_frame(payload, caller, key) do
    {:ok, proof} = SignedRequest.sign(payload, caller, key)

    auth = %{
      agent_id: proof.agent_id,
      timestamp: DateTime.to_iso8601(proof.timestamp),
      nonce: Base.encode64(proof.nonce),
      signature: Base.encode64(proof.signature)
    }

    Jason.encode!(%{
      payload: payload,
      authorization: "Signature " <> Base.encode64(Jason.encode!(auth), padding: false)
    })
  end
end
