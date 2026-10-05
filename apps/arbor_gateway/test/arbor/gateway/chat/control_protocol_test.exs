defmodule Arbor.Gateway.Chat.ControlProtocolTest do
  use ExUnit.Case, async: true
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.Protocol
  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"

  test "authenticated controls decode exact host payloads and retain every bound selector" do
    for {operation, input, opts} <- [
          {:activity, nil,
           [
             cursor: %{admitted_event_number: 4, command_id: "command_a"},
             limit: 50,
             control_timeout: 30_000
           ]},
          {:cancel, "command_a", [control_timeout: 7_000]},
          {:interactions, "command_a", []},
          {:interaction_choice, choice(), []},
          {:interaction_approval, approval(), []}
        ] do
      opts = Keyword.put(opts, :expected_engagement_id, @engagement)
      {:ok, payload} = payload(operation, input, opts)

      assert {:ok, decoded} =
               Protocol.decode_session(
                 Jason.encode!(%{payload: payload, authentication: "conversation_session"})
               )

      assert decoded.operation == operation
      assert decoded.caller == "human_owner"
      assert decoded.target == "agent_a"

      expected_input =
        if operation == :interaction_approval, do: %{input | decision: "rework"}, else: input

      assert decoded.input == expected_input
      assert Map.new(decoded.opts) == Map.new(opts)
      assert {:ok, proof_payload} = payload(operation, decoded.input, decoded.opts)
      assert proof_payload == payload
    end
  end

  test "security regression control grammar rejects extras malformed identifiers bounds and protected answer ambiguity" do
    valid = [
      "arbor.conversation.interaction.choice.v1",
      "human_owner",
      "agent_a",
      ["command_a", "request_a", "operation_a", 1, "choice_a"],
      @engagement
    ]

    for request <- [
          valid ++ ["extra-proof"],
          List.replace_at(valid, 3, %{"command_id" => "command_a", "proof" => "secret"}),
          List.replace_at(valid, 3, ["command_a", "request_a", "operation_a", 2, "choice_a"]),
          List.replace_at(valid, 3, ["command_a", "request_a", "operation_a", 1.0, "choice_a"]),
          [
            "arbor.conversation.activity.v1",
            "human_owner",
            "agent_a",
            nil,
            [[9_223_372_036_854_775_808, "cmd"], 5, nil],
            @engagement
          ],
          List.replace_at(valid, 3, [
            "command_a",
            "request_a",
            "operation_a",
            1,
            String.duplicate("x", 257)
          ]),
          List.replace_at(valid, 1, "foreign"),
          List.replace_at(valid, 4, "eng_route"),
          [
            "arbor.conversation.activity.v1",
            "human_owner",
            "agent_a",
            nil,
            [nil, 51, nil],
            @engagement
          ],
          [
            "arbor.conversation.activity.v1",
            "human_owner",
            "agent_a",
            nil,
            [[0, "cmd"], 5, nil],
            @engagement
          ],
          [
            "arbor.conversation.cancel.v1",
            "human_owner",
            "agent_a",
            "cmd",
            [nil, 5, nil],
            @engagement
          ],
          [
            "arbor.conversation.cancel.v1",
            "human_owner",
            "agent_a",
            "cmd",
            [nil, nil, 30_001],
            @engagement
          ],
          [
            "arbor.conversation.interaction.approval.v1",
            "human_owner",
            "agent_a",
            ["cmd", "request", "operation", 1, "allow", ""],
            @engagement
          ],
          [
            "arbor.conversation.interaction.approval.v1",
            "human_owner",
            "agent_a",
            ["cmd", "request", "operation", 1, "approve", "control\n"],
            @engagement
          ]
        ] do
      assert {:error, :unauthorized} =
               Protocol.decode_session(
                 Jason.encode!(%{
                   payload: Jason.encode!(request),
                   authentication: "conversation_session"
                 })
               )
    end
  end

  test "security regression signed envelope duplicate payload authorization and nested identity keys are rejected" do
    {_, private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(:history, "human_owner", "agent_a", nil, [])

    wire = signed(payload, private)
    auth = Jason.decode!(wire)["authorization"]
    "Signature " <> encoded = auth
    auth_json = Base.decode64!(encoded, padding: false)

    duplicate_auth =
      "{\"agent_id\":\"human_foreign\"," <> binary_part(auth_json, 1, byte_size(auth_json) - 1)

    duplicate_header = "Signature " <> Base.encode64(duplicate_auth, padding: false)

    duplicate_auth_last =
      binary_part(auth_json, 0, byte_size(auth_json) - 1) <> ",\"agent_id\":\"human_foreign\"}"

    duplicate_header_last = "Signature " <> Base.encode64(duplicate_auth_last, padding: false)

    for duplicate <- [
          "{\"payload\":" <>
            Jason.encode!(payload) <>
            ",\"payload\":\"other\",\"authorization\":" <> Jason.encode!(auth) <> "}",
          "{\"payload\":" <>
            Jason.encode!(payload) <>
            ",\"authorization\":" <> Jason.encode!(auth) <> ",\"authorization\":\"other\"}",
          Jason.encode!(%{payload: payload, authorization: duplicate_header_last}),
          "{\"payload\":\"other\",\"payload\":" <>
            Jason.encode!(payload) <> ",\"authorization\":" <> Jason.encode!(auth) <> "}",
          "{\"payload\":" <>
            Jason.encode!(payload) <>
            ",\"authorization\":\"other\",\"authorization\":" <> Jason.encode!(auth) <> "}",
          Jason.encode!(%{payload: payload, authorization: duplicate_header})
        ] do
      assert {:error, :unauthorized} = Protocol.decode_authenticated(duplicate)
    end

    assert {:ok, %{operation: :history}} = Protocol.decode_authenticated(wire)
  end

  test "signed answer payload decode never consumes or changes its nonce" do
    {_, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, payload} = payload(:interaction_choice, choice(), expected_engagement_id: @engagement)
    wire = signed(payload, private)
    assert {:ok, %{proof: first, input: input}} = Protocol.decode_authenticated(wire)
    assert {:ok, %{proof: second, input: ^input}} = Protocol.decode_authenticated(wire)
    assert first == second
    assert first.payload == payload
    assert input == choice()
  end

  defp payload(operation, input, opts) when operation in [:activity, :cancel],
    do: Arbor.Agent.conversation_request_payload(operation, "human_owner", "agent_a", input, opts)

  defp payload(operation, input, opts),
    do:
      Arbor.Agent.conversation_interaction_request_payload(
        operation,
        "human_owner",
        "agent_a",
        input,
        Keyword.get(opts, :expected_engagement_id)
      )

  defp choice,
    do: %{
      command_id: "command_a",
      request_id: "request_a",
      operation_id: "operation_a",
      revision: 1,
      choice_id: "choice_a"
    }

  defp approval,
    do: %{
      command_id: "command_a",
      request_id: "request_a",
      operation_id: "operation_a",
      revision: 1,
      decision: :rework,
      note: "Explain the change"
    }

  defp signed(payload, private) do
    {:ok, proof} = SignedRequest.sign(payload, "human_owner", private)

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
