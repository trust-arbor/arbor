defmodule Arbor.Gateway.Chat.SocketTest.Host do
  # Frame-boundary collaborator: real Ed25519 proofs and one-use nonces, with
  # deterministic owned history and revocation. Agent/Security integration is
  # separately qualified through their public facades, not claimed by this fake.
  alias Arbor.Contracts.Security.SignedRequest

  def conversation_history(caller, target, opts) do
    with :ok <- authenticate(:history, caller, target, nil, opts) do
      {:ok,
       %{
         engagement_id: Process.get(:engagement_id, "eng_11111111111111111111111111111111"),
         entries: [%{id: "one", role: "user", content: "owned", entry_ordinal: 1}],
         cursor: 1,
         head: 1,
         has_more: false
       }}
    end
  end

  def submit_conversation_command(caller, target, command, opts) do
    with :ok <- authenticate(:submit, caller, target, command, opts) do
      case Process.get({:command, command.id}) do
        nil ->
          send(self(), {:dispatch, command.id})
          saved = Map.put(command, :status, :dispatch_started)
          Process.put({:command, command.id}, saved)
          {:ok, saved}

        %{text: text} = saved when text == command.text ->
          {:ok, saved}

        _ ->
          {:error, :command_conflict}
      end
    end
  end

  def conversation_command(caller, target, id, opts) do
    with :ok <- authenticate(:command, caller, target, id, opts),
         command when is_map(command) <- Process.get({:command, id}) do
      {:ok, command}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def conversation_events(caller, target, cursor, opts) do
    with :ok <- authenticate(:events, caller, target, cursor, opts) do
      {:ok,
       %{
         events: [],
         cursor: 0,
         head: 0,
         has_more: false,
         engagement_id: Process.get(:engagement_id, "eng_11111111111111111111111111111111")
       }}
    end
  end

  defp authenticate(operation, caller, target, input, opts) do
    proof = Keyword.fetch!(opts, :signed_request)

    {:ok, expected} =
      Arbor.Agent.conversation_request_payload(
        operation,
        caller,
        target,
        input,
        Keyword.drop(opts, [:signed_request])
      )

    pub = Process.get({:key, caller})

    valid =
      pub && proof.agent_id == caller && proof.payload == expected &&
        not Process.get(:revoked, false) && not Process.get({:nonce, proof.nonce}, false) &&
        :crypto.verify(:eddsa, :none, SignedRequest.signing_payload(proof), proof.signature, [
          pub,
          :ed25519
        ])

    if valid do
      Process.put({:nonce, proof.nonce}, true)
      expected = Keyword.get(opts, :expected_engagement_id)
      actual = Process.get(:engagement_id, "eng_11111111111111111111111111111111")

      cond do
        not is_nil(expected) and expected != actual ->
          {:error, :conversation_scope_changed}

        Process.get(:unsupported_capability, false) ->
          {:error, :unsupported_conversation_capability}

        true ->
          :ok
      end
    else
      {:error, :unauthorized}
    end
  end
end

defmodule Arbor.Gateway.Chat.SocketTest do
  use ExUnit.Case, async: false
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.Socket
  @moduletag :fast

  setup do
    old = Application.get_env(:arbor_gateway, :chat_agent_facade)
    Application.put_env(:arbor_gateway, :chat_agent_facade, __MODULE__.Host)

    on_exit(fn ->
      if old,
        do: Application.put_env(:arbor_gateway, :chat_agent_facade, old),
        else: Application.delete_env(:arbor_gateway, :chat_agent_facade)
    end)

    {pub, key} = :crypto.generate_key(:eddsa, :ed25519)
    Process.put({:key, "human_owner"}, pub)
    {:ok, state} = Socket.init(%{principal: "human_owner"})
    %{state: state, key: key}
  end

  defp frame(operation, input, key, target \\ "agent_a", opts \\ []) do
    opts =
      if operation != :history,
        do:
          Keyword.put_new(opts, :expected_engagement_id, "eng_11111111111111111111111111111111"),
        else: opts

    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(operation, "human_owner", target, input, opts)

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
    {:push, [{:text, json}], state} = Socket.handle_in({frame, [opcode: :text]}, state)
    {Jason.decode!(json), state}
  end

  test "authenticated reconnect returns owned durable transcript", %{state: state, key: key} do
    for _ <- 1..2 do
      {event, attached} = drive(frame(:history, nil, key), state)

      assert event["data"]["entries"] == [
               %{"id" => "one", "role" => "user", "content" => "owned", "entry_ordinal" => 1}
             ]

      assert attached.agent_id == "agent_a"
    end
  end

  test "security regression: attached socket cannot submit an unsigned legacy send", %{
    state: state
  } do
    {event, _} =
      drive(Jason.encode!(%{type: "send", text: "stolen"}), %{state | agent_id: "agent_a"})

    assert event == %{"type" => "error", "reason" => "unauthorized"}
    refute_receive {:dispatch, _}
  end

  test "security regression: revocation after attach gates every operation", %{
    state: state,
    key: key
  } do
    {_, state} = drive(frame(:history, nil, key), state)
    Process.put(:revoked, true)

    for {operation, input} <- [
          history: nil,
          events: 0,
          command: "existing",
          submit: %{id: "new", text: "hello"}
        ] do
      {event, _} =
        drive(
          frame(operation, input, key, "agent_a",
            expected_engagement_id: "eng_11111111111111111111111111111111"
          ),
          state
        )

      assert event == %{"type" => "error", "reason" => "unauthorized"}
    end

    refute_receive {:dispatch, _}
  end

  test "security regression: foreign proof, replay, changed operation and target fail", %{
    state: state,
    key: key
  } do
    original =
      frame(:history, nil, key, "agent_a",
        expected_engagement_id: "eng_11111111111111111111111111111111"
      )

    {_, attached} = drive(original, state)
    assert {%{"reason" => "unauthorized"}, _} = drive(original, attached)

    for payload <- [
          [
            "arbor.conversation.v2",
            "events",
            "human_owner",
            "agent_a",
            0,
            [nil, nil, nil],
            "eng_11111111111111111111111111111111"
          ],
          [
            "arbor.conversation.v2",
            "history",
            "human_owner",
            "agent_b",
            nil,
            [nil, nil, nil],
            "eng_11111111111111111111111111111111"
          ],
          [
            "arbor.conversation.v2",
            "history",
            "human_foreign",
            "agent_a",
            nil,
            [nil, nil, nil],
            "eng_11111111111111111111111111111111"
          ]
        ] do
      # Each tamper starts from a fresh, never-consumed nonce.
      wire =
        frame(:history, nil, key)
        |> Jason.decode!()
        |> Map.put("payload", Jason.encode!(payload))
        |> Jason.encode!()

      assert {%{"type" => "error", "reason" => reason}, _} = drive(wire, attached)
      assert reason in ["unauthorized", "conversation_scope_changed"]
    end
  end

  test "exact retry with a fresh proof preserves command id without redispatch", %{
    state: state,
    key: key
  } do
    {_, state} = drive(frame(:history, nil, key), state)
    command = %{id: "stable_command", text: "hello"}
    {event, state} = drive(frame(:submit, command, key), state)
    assert event["data"]["status"] == "dispatch_started"
    assert_receive {:dispatch, "stable_command"}
    assert {^event, _} = drive(frame(:submit, command, key), state)
    refute_receive {:dispatch, _}

    assert {%{"type" => "conversation_rejected", "data" => %{"reason" => "command_conflict"}}, _} =
             drive(frame(:submit, %{command | text: "changed"}, key), state)
  end

  test "security regression: no agent-wide signals disclose messages or approvals", %{
    state: state
  } do
    attached = Map.put(state, :agent_id, "agent_a")

    assert {:ok, ^attached} =
             Socket.handle_info(
               {:chat_signal,
                %{
                  category: :agent,
                  type: :stream_delta,
                  data: %{agent_id: "agent_a", source: :turn, text: "another user's content"}
                }},
               attached
             )
  end

  test "legacy controls fail closed and server slash commands report unavailable", %{
    state: state,
    key: key
  } do
    {_, state} = drive(frame(:history, nil, key), state)

    assert {%{"reason" => "server_commands_unavailable"}, _} =
             drive(frame(:submit, %{id: "slash", text: "/model other"}, key), state)

    for type <- ["cancel", "list_engagements", "list_approvals", "approve", "deny"] do
      assert {%{"reason" => "unauthorized"}, _} = drive(Jason.encode!(%{type: type}), state)
    end
  end

  test "security regression: remapped ownership rejects pending retry and requires new attachment",
       %{state: state, key: key} do
    {_, attached} = drive(frame(:history, nil, key), state)
    Process.put(:engagement_id, "eng_22222222222222222222222222222222")

    {event, invalidated} =
      drive(frame(:submit, %{id: "pending", text: "old owner's draft"}, key), attached)

    assert event == %{"type" => "error", "reason" => "conversation_scope_changed"}
    assert invalidated.invalidated?
    assert invalidated.engagement_id == nil
    refute_receive {:dispatch, _}

    assert {%{"reason" => "conversation_scope_changed"}, _} =
             drive(frame(:history, nil, key), invalidated)
  end

  test "security regression: a client fence cannot replace the pinned engagement", %{
    state: state,
    key: key
  } do
    {_, attached} = drive(frame(:history, nil, key), state)

    proof =
      frame(:submit, %{id: "route", text: "do not route"}, key, "agent_a",
        expected_engagement_id: "eng_22222222222222222222222222222222"
      )

    assert {%{"reason" => "conversation_scope_changed"}, _} = drive(proof, attached)
    refute_receive {:dispatch, _}
  end

  test "definitive submit rejection identifies the command while poll failures do not", %{
    state: state,
    key: key
  } do
    {_, attached} = drive(frame(:history, nil, key), state)
    Process.put(:unsupported_capability, true)

    assert {%{
              "type" => "conversation_rejected",
              "data" => %{"id" => "rejected", "reason" => "unsupported_conversation_capability"}
            }, _} =
             drive(frame(:submit, %{id: "rejected", text: "not admitted"}, key), attached)

    assert {%{"type" => "error", "reason" => "unsupported_conversation_capability"}, _} =
             drive(frame(:events, 0, key), attached)

    refute_receive {:dispatch, _}
  end
end
