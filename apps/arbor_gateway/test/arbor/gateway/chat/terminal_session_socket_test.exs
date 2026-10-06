defmodule Arbor.Gateway.Chat.TerminalSessionSocketTest.Security do
  @moduledoc false
  def claim_terminal_session(credential) do
    send(self(), {:session_claimed, self()})

    case Process.get(:session_claim, verify_terminal_session(credential)) do
      {:ok, binding} -> {:ok, Map.delete(binding, :session_token)}
      other -> other
    end
  end

  def verify_terminal_session(credential) do
    if credential == Process.get(:session_credential),
      do: Process.get(:session_binding, {:error, :unauthorized}),
      else: {:error, :unauthorized}
  end
end

defmodule Arbor.Gateway.Chat.TerminalSessionSocketTest.Host do
  @moduledoc false
  @engagement "eng_11111111111111111111111111111111"
  def conversation_history(principal, target, opts),
    do: result(:history, principal, target, nil, opts)

  def conversation_window(principal, target, opts),
    do: result(:window, principal, target, nil, opts)

  def submit_conversation_command(principal, target, input, opts),
    do: result(:submit, principal, target, input, opts)

  def conversation_command(principal, target, input, opts),
    do: result(:command, principal, target, input, opts)

  def conversation_events(principal, target, input, opts),
    do: result(:events, principal, target, input, opts)

  defp result(operation, principal, target, input, opts) do
    send(self(), {:terminal_dispatch, operation, principal, target, input, opts})

    case Process.get(:lose_after_call) do
      :revoked ->
        Process.put(:session_binding, {:error, :unauthorized})

      :invalid_binding ->
        {:ok, binding} = Process.get(:session_binding)

        Process.put(
          :session_binding,
          {:ok, %{binding | lifetime: :invalid}}
        )

      :remapped ->
        {:ok, binding} = Process.get(:session_binding)
        Process.put(:session_binding, {:ok, %{binding | owner: "human_other_owner"}})

      _ ->
        :ok
    end

    case Process.get(:host_result) do
      nil ->
        {:ok,
         %{
           engagement_id: @engagement,
           entries: [%{content: "private-result"}],
           id: "stable_command",
           status: :dispatch_started
         }}

      result ->
        result
    end
  end
end

defmodule Arbor.Gateway.Chat.TerminalSessionSocketTest do
  use ExUnit.Case, async: false
  alias Arbor.Gateway.Chat.{Protocol, Socket}
  @moduletag :fast
  @credential String.duplicate("c", 43)
  @proof "server-only-session-proof"
  @engagement "eng_11111111111111111111111111111111"

  setup do
    old =
      Map.new(
        [:terminal_login_security, :chat_agent_facade],
        &{&1, Application.fetch_env(:arbor_gateway, &1)}
      )

    Application.put_env(:arbor_gateway, :terminal_login_security, __MODULE__.Security)
    Application.put_env(:arbor_gateway, :chat_agent_facade, __MODULE__.Host)

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:arbor_gateway, key, value)
          :error -> Application.delete_env(:arbor_gateway, key)
        end
      end
    end)

    binding = %{
      principal: "human_owner",
      target: "agent_a",
      owner: "human_canonical",
      session_token: @proof,
      lifetime: :connection
    }

    Process.put(:session_binding, {:ok, binding})
    Process.put(:session_credential, @credential)

    {:ok, state} =
      Socket.init(
        binding
        |> Map.delete(:session_token)
        |> Map.put(:credential, @credential)
        |> Map.put(:auth_mode, :conversation_session)
      )

    # :sensitive is a process flag, not a Process.info/2 item. Its setter returns
    # the previous value, proving Socket.init/1 enabled it before this test reset.
    assert Process.flag(:sensitive, false) == true
    %{state: state, binding: binding}
  end

  defp frame(operation, input \\ nil, caller \\ "human_owner", target \\ "agent_a", opts \\ []) do
    opts =
      if operation != :history,
        do: Keyword.put_new(opts, :expected_engagement_id, @engagement),
        else: opts

    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(operation, caller, target, input, opts)

    Jason.encode!(%{payload: payload, authentication: "conversation_session"})
  end

  defp drive(frame, state) do
    case Socket.handle_in({frame, [opcode: :text]}, state) do
      {:push, [{:text, json}], state} -> {Jason.decode!(json), state}
      {:stop, :normal, 1008, [{:text, json}], state} -> {Jason.decode!(json), state}
    end
  end

  defp attach(state) do
    {%{"type" => "conversation_history"}, attached} = drive(frame(:history), state)
    assert_receive {:terminal_dispatch, :history, _, _, _, _}
    attached
  end

  test "session operations use only server-held human proof and the exact binding", %{
    state: state
  } do
    state = attach(state)

    for {operation, input} <- [
          history: nil,
          window: nil,
          submit: %{id: "stable_command", text: "hello"},
          command: "stable_command",
          events: 0
        ] do
      {event, _} =
        drive(
          frame(operation, input, "human_owner", "agent_a", expected_engagement_id: @engagement),
          state
        )

      assert event["type"] in [
               "conversation_history",
               "conversation_window",
               "conversation_command",
               "conversation_events"
             ]

      assert_receive {:terminal_dispatch, ^operation, "human_owner", "agent_a", ^input, opts}
      assert opts[:session_token] == @proof
      refute Keyword.has_key?(opts, :signed_request)
      assert opts[:expected_engagement_id] == @engagement
    end
  end

  test "security regression: modes and closed session frame keys cannot be mixed", %{state: state} do
    {:ok, signed_state} = Socket.init(%{principal: "human_owner"})
    {%{"type" => "error", "reason" => "unauthorized"}, _} = drive(frame(:history), signed_state)
    original = Jason.decode!(frame(:history))

    for wire <- [
          Map.put(original, "authorization", "Signature invalid"),
          Map.delete(original, "authentication"),
          Map.put(original, "authentication", "other"),
          Map.put(original, "credential", @credential),
          Map.put(original, "session_token", @proof),
          %{payload: original["payload"], authorization: "Signature invalid"}
        ] do
      assert {%{"reason" => "unauthorized"}, _} = drive(Jason.encode!(wire), state)
    end

    duplicate =
      "{\"authentication\":\"other\",\"authentication\":\"conversation_session\",\"payload\":" <>
        Jason.encode!(original["payload"]) <> "}"

    assert {:error, :unauthorized} = Protocol.decode_session(duplicate)
    assert {:error, :unauthorized} = Protocol.decode_session(String.duplicate("x", 262_145))
    refute_receive {:terminal_dispatch, _, _, _, _, _}
  end

  test "security regression: principal and target spoofing fails before facade dispatch", %{
    state: state
  } do
    for {caller, target} <- [{"human_other", "agent_a"}, {"human_owner", "agent_b"}] do
      assert {%{"reason" => "unauthorized"}, _} =
               drive(frame(:history, nil, caller, target), state)
    end

    refute_receive {:terminal_dispatch, _, _, _, _, _}
  end

  test "security regression: revocation before every operation prevents dispatch", %{state: state} do
    state = attach(state)
    Process.put(:session_binding, {:error, :unauthorized})

    for {operation, input} <- [
          history: nil,
          window: nil,
          submit: %{id: "stable_command", text: "hello"},
          command: "stable_command",
          events: 0
        ] do
      assert {%{"reason" => "unauthorized"}, invalid} = drive(frame(operation, input), state)
      assert invalid.invalidated?
    end

    refute_receive {:terminal_dispatch, _, _, _, _, _}
  end

  test "security regression: authority loss or owner change after admission withholds every result",
       %{
         state: initial,
         binding: binding
       } do
    for loss <- [:revoked, :invalid_binding, :remapped],
        {operation, input} <- [
          history: nil,
          window: nil,
          submit: %{id: "stable_command", text: "hello"},
          command: "stable_command",
          events: 0
        ] do
      Process.put(:session_binding, {:ok, binding})
      Process.delete(:lose_after_call)

      {:ok, state} =
        Socket.init(
          binding
          |> Map.delete(:session_token)
          |> Map.put(:credential, @credential)
          |> Map.put(:auth_mode, :conversation_session)
        )

      Process.flag(:sensitive, false)
      state = if operation == :history, do: state, else: attach(state)
      Process.put(:lose_after_call, loss)
      {event, retired} = drive(frame(operation, input), state)
      assert event == %{"type" => "error", "reason" => "unauthorized"}
      assert_receive {:terminal_dispatch, ^operation, _, _, _, _}
      assert retired.invalidated?
      assert retired.agent_id == nil and retired.engagement_id == nil
      assert :ets.info(state.credential_table) == :undefined
    end

    Socket.terminate(:normal, initial)
  end

  test "security regression: revoked post-call rejection is not a definitive no-effect result", %{
    state: state
  } do
    state = attach(state)
    Process.put(:lose_after_call, :revoked)
    Process.put(:host_result, {:error, :command_conflict})
    {event, _} = drive(frame(:submit, %{id: "stable_command", text: "hello"}), state)
    assert event == %{"type" => "error", "reason" => "unauthorized"}
    assert_receive {:terminal_dispatch, :submit, _, _, _, _}
  end

  test "security regression: stopped-target rejection keeps server proof private and rechecks authority",
       %{state: state} do
    state = attach(state)
    command = %{id: "stopped_command", text: "keep this draft"}
    Process.put(:host_result, {:error, :agent_not_running})
    {event, attached} = drive(frame(:submit, command), state)

    assert event == %{
             "type" => "conversation_rejected",
             "data" => %{"id" => "stopped_command", "reason" => "agent_not_running"}
           }

    assert attached == state
    assert_receive {:terminal_dispatch, :submit, "human_owner", "agent_a", ^command, opts}
    assert opts[:session_token] == @proof
    assert opts[:expected_engagement_id] == @engagement
    refute Keyword.has_key?(opts, :signed_request)
    refute inspect(event) =~ @proof
    refute inspect(event) =~ @credential

    Process.put(:lose_after_call, :revoked)
    {event, retired} = drive(frame(:submit, command), attached)
    assert event == %{"type" => "error", "reason" => "unauthorized"}
    assert retired.invalidated?
    assert retired.agent_id == nil and retired.engagement_id == nil
    assert :ets.info(attached.credential_table) == :undefined
    assert_receive {:terminal_dispatch, :submit, "human_owner", "agent_a", ^command, _}
  end

  test "an unknown submit result remains an uncorrelated error", %{state: state} do
    state = attach(state)
    Process.put(:host_result, {:error, :conversation_unavailable})
    {event, attached} = drive(frame(:submit, %{id: "unknown_command", text: "hello"}), state)
    assert event == %{"type" => "error", "reason" => "conversation_unavailable"}
    assert attached == state
    assert_receive {:terminal_dispatch, :submit, _, _, _, _}
    Socket.terminate(:normal, attached)
  end

  test "initial window attaches a human session without replaying transcript history", %{
    state: state
  } do
    Process.put(
      :host_result,
      {:ok,
       %{
         engagement_id: @engagement,
         entries: [],
         head: 0,
         first: 0,
         last: 0,
         has_older: false,
         has_newer: false
       }}
    )

    {event, attached} = drive(frame(:window, nil, "human_owner", "agent_a", limit: 20), state)
    assert event["type"] == "conversation_window"
    assert event["data"]["agent_id"] == "agent_a"
    assert attached.agent_id == "agent_a" and attached.engagement_id == @engagement
    assert_receive {:terminal_dispatch, :window, "human_owner", "agent_a", nil, opts}
    assert opts[:session_token] == @proof
    assert opts[:limit] == 20
    refute_receive {:terminal_dispatch, :history, _, _, _, _}
    Socket.terminate(:normal, attached)
  end

  test "security regression: attachment fences remain required and ownership changes retire scope",
       %{state: state} do
    state = attach(state)
    wrong = "eng_22222222222222222222222222222222"

    {event, retired} =
      drive(
        frame(:submit, %{id: "stable_command", text: "hello"}, "human_owner", "agent_a",
          expected_engagement_id: wrong
        ),
        state
      )

    assert event["reason"] == "conversation_scope_changed"
    assert retired.invalidated?
    refute_receive {:terminal_dispatch, _, _, _, _, _}
    assert {%{"reason" => "unauthorized"}, _} = drive(frame(:history), retired)
  end

  test "credential and HMAC proof stay outside callback status state and retire with socket", %{
    state: state
  } do
    serialized = :erlang.term_to_binary(state)
    refute :binary.match(serialized, @credential) != :nomatch
    refute :binary.match(serialized, @proof) != :nomatch
    refute inspect(state) =~ @credential
    refute inspect(state) =~ @proof
    assert :ok = Socket.terminate(:normal, state)
    assert :ets.info(state.credential_table) == :undefined
    assert {:ok, _} = __MODULE__.Security.verify_terminal_session(@credential)
  end

  test "claim happens during socket init and a rejected takeover never acquires a table", %{
    binding: binding
  } do
    assert_receive {:session_claimed, owner}
    assert owner == self()
    Process.put(:session_claim, {:error, :unauthorized})

    assert {:stop, :normal, 1008, [_], refused} =
             Socket.init(
               binding
               |> Map.delete(:session_token)
               |> Map.put(:credential, @credential)
               |> Map.put(:auth_mode, :conversation_session)
             )

    assert refused.credential_table == nil
    refute inspect(refused) =~ @credential
    assert {:ok, _} = __MODULE__.Security.verify_terminal_session(@credential)
  end

  test "security regression: only the exact pong challenge settles its current timer", %{
    state: state
  } do
    {:push, [{:ping, challenge}], waiting} =
      Socket.handle_info({:terminal_ping, state.keepalive.tag}, state)

    assert byte_size(challenge) == 16
    assert {:ok, ^waiting} = Socket.handle_control({<<0>>, [opcode: :pong]}, waiting)
    assert {:ok, ^waiting} = Socket.handle_info({:terminal_pong_timeout, make_ref()}, waiting)
    assert {:ok, next} = Socket.handle_control({challenge, [opcode: :pong]}, waiting)
    assert next.keepalive.challenge == nil
    refute next.keepalive.tag == waiting.keepalive.tag

    assert {:ok, ^next} =
             Socket.handle_info({:terminal_pong_timeout, waiting.keepalive.tag}, next)

    Socket.terminate(:normal, next)
  end

  test "a dispatched call invalidates a queued old pong timeout without replaying the operation",
       %{state: state} do
    {:push, [{:ping, challenge}], waiting} =
      Socket.handle_info({:terminal_ping, state.keepalive.tag}, state)

    {event, returned} = drive(frame(:history), waiting)
    assert event["type"] == "conversation_history"
    assert_receive {:terminal_dispatch, :history, _, _, _, _}
    refute returned.keepalive.tag == waiting.keepalive.tag

    assert {:ok, ^returned} =
             Socket.handle_info({:terminal_pong_timeout, waiting.keepalive.tag}, returned)

    assert {:ok, settled} = Socket.handle_control({challenge, [opcode: :pong]}, returned)
    refute_receive {:terminal_dispatch, _, _, _, _, _}
    Socket.terminate(:normal, settled)
  end

  test "authority loss at keepalive closes the socket and clears private authority", %{
    state: state
  } do
    Process.put(:session_binding, {:error, :unauthorized})

    assert {:stop, :normal, 1008, [{:text, json}], closed} =
             Socket.handle_info({:terminal_ping, state.keepalive.tag}, state)

    assert Jason.decode!(json) == %{"type" => "error", "reason" => "unauthorized"}
    assert closed.keepalive == nil and closed.credential_table == nil
    assert :ets.info(state.credential_table) == :undefined
    refute_receive {:terminal_dispatch, _, _, _, _, _}
  end

  test "legacy commands and agent-wide signals stay unavailable for sessions", %{state: state} do
    state = attach(state)
    slash = %{id: "slash", text: "/model other"}

    assert {:error, :invalid_command} =
             Arbor.Agent.conversation_request_payload(:submit, "human_owner", "agent_a", slash,
               expected_engagement_id: @engagement
             )

    envelope = frame(:submit, %{slash | text: "ordinary message"}) |> Jason.decode!()

    # A raw caller can bypass the public payload builder; Gateway must refuse it.
    payload =
      envelope["payload"]
      |> Jason.decode!()
      |> List.update_at(4, fn [id, _text] -> [id, slash.text] end)
      |> Jason.encode!()

    assert {%{"type" => "error", "reason" => "server_commands_unavailable"}, _} =
             drive(envelope |> Map.put("payload", payload) |> Jason.encode!(), state)

    refute_receive {:terminal_dispatch, _, _, _, _, _}
    assert {:ok, ^state} = Socket.handle_info({:chat_signal, %{text: "foreign"}}, state)
  end
end
