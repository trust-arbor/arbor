defmodule Arbor.Orchestrator.SessionBoundedSteeringSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.SteeringMessage
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Identifiers
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Builders

  @turn_dot """
  digraph Turn {
    graph [goal="Bounded steering test"]
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "arbor_bounded_steering_#{unique}")
    turn_path = Path.join(root, "turn.dot")
    File.mkdir_p!(root)
    File.write!(turn_path, @turn_dot)

    {:ok, session} =
      Session.start_link(
        session_id: "session_bounded_steering_#{unique}",
        agent_id: "agent_bounded_steering_#{unique}",
        turn_dot: turn_path,
        config: %{"stream" => false}
      )

    on_exit(fn ->
      if Process.alive?(session), do: GenServer.stop(session)
      File.rm_rf(root)
    end)

    %{session: session}
  end

  test "security regression: same authenticated engagement returns source-owned envelopes",
       %{session: session} do
    engagement_id = Identifiers.generate_id("eng_")
    principal_id = "human_bounded_same_engagement"
    active_authority = authority!(principal_id)
    queued_authority = authority!(principal_id)
    caller = live_from()
    unknown_caller = live_from()

    queued_message =
      user_message("private steering content", engagement_id, principal_id, :voice)
      |> Map.put(:transport_metadata, %{
        message_id: "caller_steer_id",
        taint: %Taint{level: :trusted}
      })

    unknown_transport_message =
      user_message("unknown transport content", engagement_id, principal_id, %{
        caller: "controlled"
      })

    token =
      put_active(session,
        engagement_id: engagement_id,
        authority: active_authority,
        principal_id: principal_id,
        queue: [
          {queued_message, queued_authority, caller},
          {unknown_transport_message, authority!(principal_id), unknown_caller}
        ]
      )

    boundary = {make_ref(), 1}

    assert {:ok,
            [
              %SteeringMessage{} = steering,
              %SteeringMessage{} = unknown_transport_steering
            ]} =
             take_steering(session, token, engagement_id, boundary)

    assert steering.engagement_id == engagement_id
    assert steering.content == queued_message.content
    assert steering.message_id =~ ~r/^steer_[0-9a-f]{32}$/
    refute steering.message_id == "caller_steer_id"

    assert %Taint{
             level: :untrusted,
             sensitivity: :internal,
             sanitizations: 0,
             confidence: :unverified,
             source: "session_steering_voice",
             chain: ["session_steering"]
           } = steering.taint

    refute inspect(steering.taint) =~ queued_message.content
    assert unknown_transport_steering.taint.source == "session_steering_unknown"
    refute inspect(unknown_transport_steering.taint) =~ unknown_transport_message.content

    internal = :sys.get_state(session)
    assert internal.turn_queue == []
    assert internal.steer_froms == [caller, unknown_caller]
    assert internal.steering_message_count == 2

    assert internal.steering_byte_count ==
             byte_size(queued_message.content) + byte_size(unknown_transport_message.content)

    assert MapSet.member?(internal.steering_boundaries, boundary)

    public = Session.get_state(session)
    assert Map.get(public, :turn_token) == nil
    assert Map.get(public, :steering_boundaries) == nil
    assert Map.get(public, :steering_message_count) == nil
    assert Map.get(public, :steering_byte_count) == nil
  end

  test "cross-engagement head is retained while an eligible later entry is accepted", %{
    session: session
  } do
    engagement_id = Identifiers.generate_id("eng_")
    foreign_engagement_id = Identifiers.generate_id("eng_")
    principal_id = "human_bounded_queue_scan"
    active_authority = authority!(principal_id)
    foreign_from = live_from()
    eligible_from = live_from()

    foreign =
      {user_message("foreign", foreign_engagement_id, principal_id), authority!(principal_id),
       foreign_from}

    eligible =
      {user_message("eligible", engagement_id, principal_id), authority!(principal_id),
       eligible_from}

    token =
      put_active(session,
        engagement_id: engagement_id,
        authority: active_authority,
        principal_id: principal_id,
        queue: [foreign, eligible]
      )

    assert {:ok, [%SteeringMessage{content: "eligible"}]} =
             take_steering(session, token, engagement_id, {make_ref(), 1})

    internal = :sys.get_state(session)
    assert internal.turn_queue == [foreign]
    assert internal.steer_froms == [eligible_from]
  end

  test "security regression: nil, principal, and extended authority mismatches remain queued", %{
    session: session
  } do
    engagement_id = Identifiers.generate_id("eng_")
    principal_id = "human_bounded_authority"
    active_authority = authority!(principal_id)
    nil_from = live_from()
    mismatch_from = live_from()
    forged_from = live_from()
    eligible_from = live_from()

    forged_authority =
      principal_id
      |> authority!()
      |> Map.from_struct()
      |> Map.put(:__struct__, TurnAuthority)
      |> Map.put(:caller_extension, :forged)

    nil_entry =
      {user_message("nil authority route claim", engagement_id, nil), nil, nil_from}

    mismatch_entry =
      {user_message("wrong principal", engagement_id, "human_bounded_other"),
       authority!("human_bounded_other"), mismatch_from}

    forged_entry =
      {user_message("extended authority", engagement_id, principal_id), forged_authority,
       forged_from}

    eligible_entry =
      {user_message("valid authority", engagement_id, principal_id), authority!(principal_id),
       eligible_from}

    token =
      put_active(session,
        engagement_id: engagement_id,
        authority: active_authority,
        principal_id: principal_id,
        queue: [nil_entry, mismatch_entry, forged_entry, eligible_entry]
      )

    assert {:ok, [%SteeringMessage{content: "valid authority"}]} =
             take_steering(session, token, engagement_id, {make_ref(), 1})

    internal = :sys.get_state(session)
    assert internal.turn_queue == [nil_entry, mismatch_entry, forged_entry]
    assert internal.steer_froms == [eligible_from]
  end

  test "duplicate, stale, and malformed boundaries fail closed", %{session: session} do
    engagement_id = Identifiers.generate_id("eng_")
    token = put_active(session, engagement_id: engagement_id)
    first_boundary = {make_ref(), 1}

    assert :none = take_steering(session, token, engagement_id, first_boundary)

    queued = {user_message("later", engagement_id), nil, live_from()}
    put_queue(session, [queued])

    assert :none = take_steering(session, token, engagement_id, first_boundary)
    assert :none = take_steering(session, make_ref(), engagement_id, {make_ref(), 2})
    assert :none = take_steering(session, token, engagement_id, {make_ref(), 0})
    assert :none = take_steering(session, token, engagement_id, {:not_a_reference, 1})
    assert :none = take_steering(session, token, engagement_id, {make_ref(), 1, :extra})

    assert :sys.get_state(session).turn_queue == [queued]

    assert {:ok, [%SteeringMessage{content: "later"}]} =
             take_steering(session, token, engagement_id, {make_ref(), 2})

    assert MapSet.size(:sys.get_state(session).steering_boundaries) == 2
  end

  test "dead and cancelled entries are removed without starving a live entry", %{
    session: session
  } do
    engagement_id = Identifiers.generate_id("eng_")
    dead_pid = spawn(fn -> Process.sleep(:infinity) end)
    dead_monitor = Process.monitor(dead_pid)
    Process.exit(dead_pid, :kill)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead_pid, :killed}

    cancelled_from = live_from()
    live_from = live_from()

    cancelled_message =
      user_message("cancelled", engagement_id)
      |> Map.put(:transport_metadata, %{task_id: "task_cancelled_steering"})

    queue = [
      {user_message("dead", engagement_id), nil, {dead_pid, make_ref()}},
      {cancelled_message, nil, cancelled_from},
      {user_message("live", engagement_id), nil, live_from}
    ]

    token =
      put_active(session,
        engagement_id: engagement_id,
        queue: queue,
        cancelled_task_ids: %{"task_cancelled_steering" => true}
      )

    assert {:ok, [%SteeringMessage{content: "live"}]} =
             take_steering(session, token, engagement_id, {make_ref(), 1})

    assert_receive {cancelled_tag, {:error, :cancelled}}
    assert cancelled_tag == elem(cancelled_from, 1)
    assert :sys.get_state(session).turn_queue == []
  end

  test "boundary and turn message and byte overflow remain queued", %{session: session} do
    engagement_id = Identifiers.generate_id("eng_")

    count_entries =
      Enum.map(1..5, fn index ->
        {user_message("count-#{index}", engagement_id), nil, live_from()}
      end)

    token = put_active(session, engagement_id: engagement_id, queue: count_entries)

    assert {:ok, first_batch} =
             take_steering(session, token, engagement_id, {make_ref(), 1})

    assert length(first_batch) == SteeringMessage.max_messages_per_boundary()
    assert length(:sys.get_state(session).turn_queue) == 1

    assert {:ok, [%SteeringMessage{content: "count-5"}]} =
             take_steering(session, token, engagement_id, {make_ref(), 2})

    byte_content = String.duplicate("b", 20_000)

    first_byte_entry = {user_message(byte_content, engagement_id), nil, live_from()}
    second_byte_entry = {user_message(byte_content, engagement_id), nil, live_from()}
    third_byte_entry = {user_message("x", engagement_id), nil, live_from()}

    token =
      put_active(session,
        engagement_id: engagement_id,
        queue: [first_byte_entry, second_byte_entry, third_byte_entry]
      )

    assert {:ok, [%SteeringMessage{content: ^byte_content}]} =
             take_steering(session, token, engagement_id, {make_ref(), 1})

    assert :sys.get_state(session).turn_queue == [second_byte_entry, third_byte_entry]

    assert {:ok, [%SteeringMessage{content: ^byte_content}, %SteeringMessage{content: "x"}]} =
             take_steering(session, token, engagement_id, {make_ref(), 2})

    turn_entries =
      Enum.map(1..17, fn index ->
        {user_message("turn-#{index}", engagement_id), nil, live_from()}
      end)

    token = put_active(session, engagement_id: engagement_id, queue: turn_entries)

    for sequence <- 1..4 do
      assert {:ok, batch} =
               take_steering(session, token, engagement_id, {make_ref(), sequence})

      assert length(batch) == 4
    end

    assert :none = take_steering(session, token, engagement_id, {make_ref(), 5})
    assert length(:sys.get_state(session).turn_queue) == 1

    max_content = String.duplicate("x", SteeringMessage.max_bytes_per_boundary())

    byte_turn_entries =
      Enum.map(1..5, fn _ -> {user_message(max_content, engagement_id), nil, live_from()} end)

    token = put_active(session, engagement_id: engagement_id, queue: byte_turn_entries)

    for sequence <- 1..4 do
      assert {:ok, [_]} =
               take_steering(session, token, engagement_id, {make_ref(), sequence})
    end

    assert :none = take_steering(session, token, engagement_id, {make_ref(), 5})
    assert length(:sys.get_state(session).turn_queue) == 1
  end

  test "128-boundary ceiling and reset are process-local and exact-once", %{session: session} do
    engagement_id = Identifiers.generate_id("eng_")
    token = put_active(session, engagement_id: engagement_id)
    attempt_ref = make_ref()

    for sequence <- 1..SteeringMessage.max_boundaries_per_turn() do
      assert :none = take_steering(session, token, engagement_id, {attempt_ref, sequence})
    end

    steering_from = live_from()
    put_queue(session, [{user_message("over ceiling", engagement_id), nil, steering_from}])

    assert :none =
             take_steering(
               session,
               token,
               engagement_id,
               {attempt_ref, SteeringMessage.max_boundaries_per_turn() + 1}
             )

    assert length(:sys.get_state(session).turn_queue) == 1

    token =
      put_active(session,
        engagement_id: engagement_id,
        queue: [{user_message("owned once", engagement_id), nil, steering_from}]
      )

    boundary = {make_ref(), 1}
    assert {:ok, [_]} = take_steering(session, token, engagement_id, boundary)
    assert :none = take_steering(session, token, engagement_id, boundary)
    assert :ok = Session.cancel_turn(session)

    assert_receive {steering_tag, {:error, :cancelled}}
    assert steering_tag == elem(steering_from, 1)
    refute_receive {^steering_tag, _}, 20

    reset = :sys.get_state(session)
    assert reset.steering_boundaries == MapSet.new()
    assert reset.steering_message_count == 0
    assert reset.steering_byte_count == 0
    assert reset.steer_froms == []
  end

  test "Builders installs only a process-local arity-1 live-turn closure", %{session: session} do
    engagement_id = Identifiers.generate_id("eng_")
    caller = live_from()

    token =
      put_active(session,
        engagement_id: engagement_id,
        queue: [{user_message("through builder", engagement_id), nil, caller}]
      )

    parent = self()

    :sys.replace_state(session, fn state ->
      live_opts =
        Builders.build_engine_opts(state, %{"safe" => "value"},
          source: :turn,
          steering_binding: {token, engagement_id}
        )

      heartbeat_opts =
        Builders.build_engine_opts(state, %{"safe" => "value"}, source: :heartbeat)

      unbound_turn_opts =
        Builders.build_engine_opts(state, %{"safe" => "value"}, source: :turn)

      send(parent, {:builder_opts, live_opts, heartbeat_opts, unbound_turn_opts})
      state
    end)

    assert_receive {:builder_opts, live_opts, heartbeat_opts, unbound_turn_opts}

    assert is_function(live_opts[:steer_check], 1)
    refute Keyword.has_key?(live_opts, :steering_binding)
    refute Keyword.has_key?(live_opts, :turn_token)
    assert live_opts[:initial_values] == %{"safe" => "value"}
    refute Map.has_key?(live_opts[:initial_values], "session.steer_check")
    refute Keyword.has_key?(heartbeat_opts, :steer_check)
    refute Keyword.has_key?(unbound_turn_opts, :steer_check)

    assert {:ok, [%SteeringMessage{content: "through builder"}]} =
             live_opts[:steer_check].({make_ref(), 1})

    :sys.replace_state(session, &Map.put(&1, :turn_token, make_ref()))
    assert :none = live_opts[:steer_check].({make_ref(), 2})
  end

  defp put_active(session, opts) do
    token = Keyword.get(opts, :turn_token, make_ref())
    engagement_id = Keyword.get(opts, :engagement_id)
    authority = Keyword.get(opts, :authority)
    principal_id = Keyword.get(opts, :principal_id)
    queue = Keyword.get(opts, :queue, [])
    cancelled_task_ids = Keyword.get(opts, :cancelled_task_ids, %{})

    active_message =
      user_message("active", engagement_id, principal_id, :voice)

    :sys.replace_state(session, fn state ->
      Map.merge(state, %{
        phase: :processing,
        turn_in_flight: true,
        turn_from: nil,
        turn_user_message: active_message,
        turn_authority: authority,
        turn_token: token,
        current_engagement_id: engagement_id,
        turn_queue: queue,
        steer_froms: [],
        cancelled_task_ids: cancelled_task_ids,
        cancelled_task_id_order: Map.keys(cancelled_task_ids),
        steering_boundaries: MapSet.new(),
        steering_message_count: 0,
        steering_byte_count: 0
      })
    end)

    token
  end

  defp put_queue(session, queue) do
    :sys.replace_state(session, &Map.put(&1, :turn_queue, queue))
  end

  defp user_message(content, engagement_id, principal_id \\ nil, transport \\ :voice) do
    message =
      if is_binary(principal_id) do
        UserMessage.from_voice(content, sender_id: principal_id)
      else
        UserMessage.from_string(content)
      end

    %{message | engagement_id: engagement_id, transport: transport}
  end

  defp authority!(principal_id) do
    assert {:ok, authority} =
             TurnAuthority.new(%{
               turn_id: Identifiers.generate_id("turn_"),
               authenticated_principal_id: principal_id,
               disclosure_capability_id: nil
             })

    authority
  end

  defp live_from, do: {self(), make_ref()}

  # Base-compatible selector: base has only the unbound arity-1 API and returns
  # bare content. Candidate returns the locked typed batch, so failures on base
  # are behavioral rather than missing-module or test-compilation failures.
  defp take_steering(session, turn_token, engagement_id, boundary) do
    if function_exported?(Session, :take_steering, 4) do
      apply(Session, :take_steering, [session, turn_token, engagement_id, boundary])
    else
      apply(Session, :take_steering, [session])
    end
  end
end
