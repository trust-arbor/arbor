defmodule Arbor.Gateway.Chat.ControlSocketTest.Security do
  @moduledoc false
  def claim_terminal_session(credential) do
    with {:ok, binding} <- verify_terminal_session(credential) do
      {:ok, Map.delete(binding, :session_token)}
    end
  end

  def verify_terminal_session(credential) do
    if credential == String.duplicate("c", 43) and Process.get(:lease_valid, true) do
      number = Process.get(:proof_number, 0) + 1
      Process.put(:proof_number, number)
      token = "server-only-fresh-proof-#{number}"
      Process.put(:latest_proof, token)

      {:ok,
       %{
         principal: "human_owner",
         target: "agent_a",
         owner: "human_owner",
         lifetime: :connection,
         session_token: token
       }}
    else
      {:error, :unauthorized}
    end
  end
end

defmodule Arbor.Gateway.Chat.ControlSocketTest.Host do
  @moduledoc false
  # A frame-boundary collaborator with real signatures, one-use nonces and
  # server-issued session proof. Real Agent source/approval authority is covered
  # by its own journey tests; this fixture makes no execution-authority claim.
  alias Arbor.Contracts.Security.SignedRequest
  @engagement "eng_11111111111111111111111111111111"

  def conversation_history(caller, target, opts),
    do:
      result(:history, caller, target, nil, opts, %{
        engagement_id: @engagement,
        entries: [],
        cursor: 0,
        head: 0,
        has_more: false
      })

  def conversation_activity(caller, target, opts),
    do:
      result(:activity, caller, target, nil, opts, %{
        engagement_id: @engagement,
        commands: [],
        has_more: false,
        next_cursor: nil
      })

  def cancel_conversation_command(caller, target, id, opts),
    do:
      result(:cancel, caller, target, id, opts, %{
        engagement_id: @engagement,
        command_id: id,
        cancellation: %{status: :requested},
        termination_observation: :unconfirmed
      })

  def conversation_interactions(caller, target, id, opts),
    do:
      result(:interactions, caller, target, id, opts, %{
        engagement_id: @engagement,
        command_id: id,
        interactions: []
      })

  def answer_conversation_choice(caller, target, input, opts) do
    value =
      input
      |> Map.take([:command_id, :request_id, :operation_id, :revision])
      |> Map.merge(%{engagement_id: @engagement, status: :responded})

    result(:interaction_choice, caller, target, input, opts, value)
  end

  def answer_conversation_approval(caller, target, input, opts) do
    send(self(), {:approval_facade_called, caller, target})
    Arbor.Agent.answer_conversation_approval(caller, target, input, opts)
  end

  defp result(operation, caller, target, input, opts, value) do
    with :ok <- authenticate(operation, caller, target, input, opts) do
      send(self(), {:control_dispatch, operation, caller, target, input, opts})
      if Process.get(:lose_after_call), do: Process.put(:lease_valid, false)
      {:ok, Process.get(:host_control_result, value)}
    end
  end

  defp authenticate(operation, caller, target, input, opts) do
    expected =
      if operation in [:history, :activity, :cancel],
        do:
          Arbor.Agent.conversation_request_payload(
            operation,
            caller,
            target,
            input,
            Keyword.drop(opts, [:signed_request, :session_token])
          ),
        else:
          Arbor.Agent.conversation_interaction_request_payload(
            operation,
            caller,
            target,
            input,
            Keyword.get(opts, :expected_engagement_id)
          )

    with {:ok, payload} <- expected,
         false <- Process.get(:revoked, false),
         true <- proof?(caller, payload, opts) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp proof?(caller, payload, opts) do
    case Keyword.fetch(opts, :signed_request) do
      {:ok, proof} ->
        public = Process.get({:key, caller})

        valid =
          is_binary(public) and proof.agent_id == caller and proof.payload == payload and
            not Process.get({:nonce, proof.nonce}, false) and
            :crypto.verify(:eddsa, :none, SignedRequest.signing_payload(proof), proof.signature, [
              public,
              :ed25519
            ])

        if valid, do: Process.put({:nonce, proof.nonce}, true)
        valid

      :error ->
        Keyword.get(opts, :session_token) == Process.get(:latest_proof)
    end
  end
end

defmodule Arbor.Gateway.Chat.ControlSocketTest do
  use ExUnit.Case, async: false
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.Socket
  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"

  setup do
    previous =
      Map.new(
        [:chat_agent_facade, :terminal_login_security],
        &{&1, Application.fetch_env(:arbor_gateway, &1)}
      )

    Application.put_env(:arbor_gateway, :chat_agent_facade, __MODULE__.Host)
    Application.put_env(:arbor_gateway, :terminal_login_security, __MODULE__.Security)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arbor_gateway, key, value)
          :error -> Application.delete_env(:arbor_gateway, key)
        end
      end
    end)

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    Process.put({:key, "human_owner"}, public)
    {:ok, state} = Socket.init(%{principal: "human_owner"})
    %{state: state, key: private}
  end

  test "security regression ambiguous signed frame cannot read private history", %{
    state: state,
    key: key
  } do
    for valid_first <- [true, false] do
      wire = Jason.decode!(frame(:history, nil, key))

      payloads =
        if valid_first,
          do: "\"payload\":" <> Jason.encode!(wire["payload"]) <> ",\"payload\":\"other\"",
          else: "\"payload\":\"other\",\"payload\":" <> Jason.encode!(wire["payload"])

      duplicate =
        "{" <> payloads <> ",\"authorization\":" <> Jason.encode!(wire["authorization"]) <> "}"

      assert {%{"reason" => "unauthorized"}, _} = drive(duplicate, state)
      refute_receive {:control_dispatch, :history, _, _, _, _}
    end
  end

  test "signed activity cancellation and empty prompts preserve authenticated correlation", %{
    state: state,
    key: key
  } do
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}

    for {operation, input, type} <- [
          {:activity, nil, "conversation_activity"},
          {:cancel, "command_a", "conversation_cancellation"},
          {:interactions, "command_a", "conversation_interactions"},
          {:interaction_choice, choice(), "conversation_interaction_answer"}
        ] do
      {reply, _} = drive(frame(operation, input, key), attached)
      assert reply["type"] == type
      assert reply["data"]["agent_id"] == "agent_a"
      assert reply["data"]["engagement_id"] == @engagement
      assert_receive {:control_dispatch, ^operation, "human_owner", "agent_a", ^input, opts}
      assert opts[:expected_engagement_id] == @engagement
      assert %SignedRequest{} = opts[:signed_request]
      refute reply["data"]["proof"]

      if operation == :cancel do
        assert reply["data"]["cancellation"]["status"] == "requested"
        assert reply["data"]["termination_observation"] == "unconfirmed"
      end

      if operation == :interactions, do: assert(reply["data"]["interactions"] == [])
    end
  end

  test "security regression answer replay tampering subject target and fence fail before a second dispatch",
       %{state: state, key: key} do
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}
    original = frame(:interaction_choice, choice(), key)
    {%{"type" => "conversation_interaction_answer"}, _} = drive(original, attached)
    assert_receive {:control_dispatch, :interaction_choice, _, _, _, _}
    assert {%{"reason" => "unauthorized"}, _} = drive(original, attached)

    for {index, value} <- [
          {1, "human_foreign"},
          {2, "agent_b"},
          {3, ["command_a", "request_a", "operation_a", 1, "choice_b"]},
          {4, "eng_22222222222222222222222222222222"}
        ] do
      wire = Jason.decode!(frame(:interaction_choice, choice(), key))

      tampered =
        wire["payload"] |> Jason.decode!() |> List.replace_at(index, value) |> Jason.encode!()

      {reply, _} = drive(wire |> Map.put("payload", tampered) |> Jason.encode!(), attached)
      assert reply["reason"] in ["unauthorized", "conversation_scope_changed"]
    end

    refute_receive {:control_dispatch, :interaction_choice, _, _, _, _}
  end

  test "security regression revocation gates every new signed operation", %{
    state: state,
    key: key
  } do
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}
    Process.put(:revoked, true)

    for {operation, input} <- [
          activity: nil,
          cancel: "command_a",
          interactions: "command_a",
          interaction_choice: choice()
        ] do
      assert {%{"reason" => "unauthorized"}, _} = drive(frame(operation, input, key), attached)
    end

    refute_receive {:control_dispatch, _, _, _, _, _}
  end

  test "security regression controls need attachment and cannot route to another pinned scope", %{
    state: state,
    key: key
  } do
    assert {%{"reason" => "not_attached"}, _} = drive(frame(:activity, nil, key), state)
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}

    for wire <- [
          frame(:cancel, "command_a", key, "agent_b"),
          frame(
            :interactions,
            "command_a",
            key,
            "agent_a",
            "eng_22222222222222222222222222222222"
          )
        ] do
      assert {%{"reason" => "conversation_scope_changed"}, _} = drive(wire, attached)
    end

    refute_receive {:control_dispatch, _, _, _, _, _}
  end

  test "security regression malformed host scope answer IDs private proof and oversized results are withheld",
       %{state: state, key: key} do
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}

    base =
      Map.take(choice(), [:command_id, :request_id, :operation_id, :revision])
      |> Map.put(:engagement_id, @engagement)

    for value <- [
          %{base | engagement_id: "eng_22222222222222222222222222222222"},
          %{base | operation_id: "other"},
          %{base | revision: 2},
          %{base | revision: 1.0},
          Map.put(base, :nested, %{session_token: "private"}),
          Map.put(base, :preview, String.duplicate("x", 131_585))
        ] do
      Process.put(:host_control_result, value)

      assert {%{"reason" => "conversation_unavailable"}, _} =
               drive(frame(:interaction_choice, choice(), key), attached)

      assert_receive {:control_dispatch, :interaction_choice, _, _, _, _}
    end
  end

  test "foreign or duplicate prompt and activity identities are withheld", %{
    state: state,
    key: key
  } do
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}

    prompt = %{
      command_id: "foreign_command",
      request_id: "request_a",
      operation_id: "operation_a",
      revision: 1
    }

    for {operation, input, value} <- [
          {:interactions, "command_a",
           %{engagement_id: @engagement, command_id: "command_a", interactions: [prompt]}},
          {:interactions, "command_a",
           %{
             engagement_id: @engagement,
             command_id: "command_a",
             interactions: [
               %{prompt | command_id: "command_a"},
               %{prompt | command_id: "command_a"}
             ]
           }},
          {:activity, nil,
           %{engagement_id: @engagement, commands: [%{command_id: "same"}, %{command_id: "same"}]}}
        ] do
      Process.put(:host_control_result, value)

      assert {%{"reason" => "conversation_unavailable"}, _} =
               drive(frame(operation, input, key), attached)

      assert_receive {:control_dispatch, ^operation, _, _, _, _}
    end
  end

  test "signed approval reaches the public host gate and cannot substitute for a human session",
       %{state: state, key: key} do
    {_, attached} = drive(frame(:history, nil, key), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}

    assert {%{"type" => "error", "reason" => "invalid_opts"}, _} =
             drive(frame(:interaction_approval, approval(), key), attached)

    assert_receive {:approval_facade_called, "human_owner", "agent_a"}
    refute_receive {:control_dispatch, :interaction_approval, _, _, _, _}
  end

  test "terminal controls use a fresh server held proof and terminal approval never reaches host" do
    state = terminal_state()
    {_, attached} = drive(session_frame(:history, nil), state)
    assert_receive {:control_dispatch, :history, _, _, _, _}

    tokens =
      for {operation, input} <- [
            activity: nil,
            cancel: "command_a",
            interactions: "command_a",
            interaction_choice: choice()
          ] do
        {reply, _} = drive(session_frame(operation, input), attached)
        assert reply["type"] != "error"
        assert_receive {:control_dispatch, ^operation, "human_owner", "agent_a", ^input, opts}
        refute Keyword.has_key?(opts, :signed_request)
        opts[:session_token]
      end

    assert length(Enum.uniq(tokens)) == 4

    assert {%{"reason" => "approval_answer_required"}, _} =
             drive(session_frame(:interaction_approval, approval()), attached)

    refute_receive {:approval_facade_called, _, _}
    Socket.terminate(:normal, attached)
  end

  test "security regression terminal revocation after control admission withholds its result" do
    for {operation, input} <- [
          activity: nil,
          cancel: "command_a",
          interactions: "command_a",
          interaction_choice: choice()
        ] do
      Process.put(:lease_valid, true)
      Process.delete(:lose_after_call)
      {_, attached} = drive(session_frame(:history, nil), terminal_state())
      assert_receive {:control_dispatch, :history, _, _, _, _}
      Process.put(:lose_after_call, true)
      {%{"reason" => "unauthorized"}, closed} = drive(session_frame(operation, input), attached)
      assert closed.invalidated?
      assert_receive {:control_dispatch, ^operation, _, _, _, _}
    end
  end

  defp terminal_state do
    {:ok, state} =
      Socket.init(%{
        auth_mode: :conversation_session,
        credential: String.duplicate("c", 43),
        principal: "human_owner",
        target: "agent_a",
        owner: "human_owner",
        lifetime: :connection
      })

    state
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
      decision: :approve,
      note: ""
    }

  defp payload(operation, input, fence) when operation in [:history, :activity, :cancel],
    do:
      Arbor.Agent.conversation_request_payload(operation, "human_owner", "agent_a", input,
        expected_engagement_id: fence
      )

  defp payload(operation, input, fence),
    do:
      Arbor.Agent.conversation_interaction_request_payload(
        operation,
        "human_owner",
        "agent_a",
        input,
        fence
      )

  defp session_frame(operation, input) do
    {:ok, payload} = payload(operation, input, @engagement)
    Jason.encode!(%{payload: payload, authentication: "conversation_session"})
  end

  defp frame(operation, input, key, target \\ "agent_a", fence \\ @engagement) do
    {:ok, payload} = payload(operation, input, fence)

    payload =
      if target == "agent_a",
        do: payload,
        else: payload |> Jason.decode!() |> List.replace_at(2, target) |> Jason.encode!()

    {:ok, proof} = SignedRequest.sign(payload, "human_owner", key)

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

  defp drive(frame, state) do
    case Socket.handle_in({frame, [opcode: :text]}, state) do
      {:push, [{:text, json}], state} -> {Jason.decode!(json), state}
      {:stop, :normal, 1008, [{:text, json}], state} -> {Jason.decode!(json), state}
    end
  end
end
