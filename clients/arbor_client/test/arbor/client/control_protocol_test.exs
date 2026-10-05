defmodule Arbor.Client.ControlProtocolTest do
  use ExUnit.Case, async: true
  alias Arbor.Client
  @engagement "eng_11111111111111111111111111111111"

  test "new operation payloads retain the host's canonical tags selectors and nil slots" do
    assert Client.conversation_payload(:activity, "human_owner", "agent_a", nil) ==
             ~s(["arbor.conversation.activity.v1","human_owner","agent_a",null,[null,null,null],null])

    assert Client.conversation_payload(:activity, "human_owner", "agent_a", nil,
             cursor: %{admitted_event_number: 4, command_id: "command_a"},
             limit: 50,
             control_timeout: 30_000,
             expected_engagement_id: @engagement
           ) ==
             ~s(["arbor.conversation.activity.v1","human_owner","agent_a",null,[[4,"command_a"],50,30000],"#{@engagement}"])

    assert Client.conversation_payload(:cancel, "human_owner", "agent_a", "command_a",
             control_timeout: 7_000,
             expected_engagement_id: @engagement
           ) ==
             ~s(["arbor.conversation.cancel.v1","human_owner","agent_a","command_a",[null,null,7000],"#{@engagement}"])

    assert Client.conversation_payload(:interactions, "human_owner", "agent_a", "command_a",
             expected_engagement_id: @engagement
           ) ==
             ~s(["arbor.conversation.interactions.v1","human_owner","agent_a","command_a","#{@engagement}"])

    assert Client.conversation_payload(:interaction_choice, "human_owner", "agent_a", choice(),
             expected_engagement_id: @engagement
           ) ==
             ~s(["arbor.conversation.interaction.choice.v1","human_owner","agent_a",["command_a","request_a","operation_a",1,"choice_a"],"#{@engagement}"])

    assert Client.conversation_payload(
             :interaction_approval,
             "human_owner",
             "agent_a",
             approval(),
             expected_engagement_id: @engagement
           ) ==
             ~s(["arbor.conversation.interaction.approval.v1","human_owner","agent_a",["command_a","request_a","operation_a",1,"rework","Explain the change"],"#{@engagement}"])
  end

  test "security regression controls reject extra proof fields duplicate keys and out of bounds selectors" do
    for {operation, input, opts} <- [
          {:activity, nil, [limit: 51]},
          {:activity, nil, [limit: 2, limit: 3]},
          {:activity, nil,
           [cursor: %{admitted_event_number: 1, command_id: "cmd", proof: "secret"}]},
          {:activity, nil, [cursor: %{admitted_event_number: 0, command_id: "cmd"}]},
          {:cancel, "command_a", [limit: 1]},
          {:cancel, "command_a", [control_timeout: 30_001]},
          {:interactions, "command_a", [session_token: "secret"]},
          {:interactions, "command_a", [expected_engagement_id: "eng_route"]},
          {:interaction_choice, Map.put(choice(), :proof, "secret"), []},
          {:interaction_choice, %{choice() | revision: 2}, []},
          {:interaction_choice, %{choice() | revision: 1.0}, []},
          {:activity, nil,
           [cursor: %{admitted_event_number: 9_223_372_036_854_775_808, command_id: "cmd"}]},
          {:interaction_choice, %{choice() | choice_id: String.duplicate("x", 257)}, []},
          {:interaction_approval, %{approval() | note: "unsafe\ncontrol"}, []},
          {:interaction_approval, %{approval() | note: String.duplicate("x", 1_025)}, []},
          {:interaction_approval, %{approval() | decision: :allow}, []}
        ] do
      assert {:error, :invalid_control_request} =
               Client.conversation_payload(operation, "human_owner", "agent_a", input, opts)
    end
  end

  test "fresh control signatures bind answer IDs revision choice and engagement without changing payload" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    identity = %{agent_id: "human_owner", private_key: private}

    first =
      Client.signed_operation(identity, "agent_a", :interaction_choice, choice(),
        expected_engagement_id: @engagement
      )
      |> Jason.decode!()

    second =
      Client.signed_operation(identity, "agent_a", :interaction_choice, choice(),
        expected_engagement_id: @engagement
      )
      |> Jason.decode!()

    assert first["payload"] == second["payload"]
    a = verify(first, public)
    b = verify(second, public)
    refute a["nonce"] == b["nonce"]

    changed =
      Client.conversation_payload(
        :interaction_choice,
        "human_owner",
        "agent_a",
        %{choice() | choice_id: "choice_b"},
        expected_engagement_id: @engagement
      )

    refute changed == first["payload"]
  end

  test "session control envelope contains operation bytes without caller supplied credentials" do
    payload =
      Client.conversation_payload(:cancel, "human_owner", "agent_a", "command_a",
        expected_engagement_id: @engagement
      )

    assert Jason.decode!(
             Client.session_operation("human_owner", "agent_a", :cancel, "command_a",
               expected_engagement_id: @engagement
             )
           ) ==
             %{"payload" => payload, "authentication" => "conversation_session"}

    assert {:error, :invalid_control_request} =
             Client.session_operation("human_owner", "agent_a", :cancel, "command_a",
               session_token: "secret"
             )
  end

  test "invalid signed controls refuse before creating an authorization envelope" do
    identity = %{agent_id: "human_owner", private_key: <<>>}

    assert {:error, :invalid_control_request} =
             Client.signed_operation(
               identity,
               "agent_a",
               :interaction_choice,
               Map.put(choice(), :callback, self())
             )
  end

  test "empty prompts and cancellation requests retain authoritative correlation and uncertainty" do
    prompts = %{
      "agent_id" => "agent_a",
      "engagement_id" => @engagement,
      "command_id" => "command_a",
      "interactions" => []
    }

    assert Client.decode(Jason.encode!(%{type: "conversation_interactions", data: prompts})) ==
             {:ok, {:conversation_interactions, prompts}}

    cancellation = %{
      "agent_id" => "agent_a",
      "engagement_id" => @engagement,
      "command_id" => "command_a",
      "cancellation" => %{"status" => "requested"},
      "termination_observation" => "unconfirmed"
    }

    assert Client.decode(Jason.encode!(%{type: "conversation_cancellation", data: cancellation})) ==
             {:ok, {:conversation_cancellation, cancellation}}
  end

  test "control response data is bounded independently of the socket's transcript budget" do
    assert {:error, :control_reply_too_large} =
             Client.decode(
               Jason.encode!(%{
                 type: "conversation_activity",
                 data: %{preview: String.duplicate("x", 131_585)}
               })
             )
  end

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

  defp verify(wire, public) do
    "Signature " <> encoded = wire["authorization"]
    auth = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
    payload = <<byte_size(wire["payload"])::32, wire["payload"]::binary>>
    caller = <<byte_size(auth["agent_id"])::32, auth["agent_id"]::binary>>
    timestamp = <<byte_size(auth["timestamp"])::32, auth["timestamp"]::binary>>
    message = payload <> caller <> timestamp <> Base.decode64!(auth["nonce"])

    assert :crypto.verify(:eddsa, :none, message, Base.decode64!(auth["signature"]), [
             public,
             :ed25519
           ])

    auth
  end
end
