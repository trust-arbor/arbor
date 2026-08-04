defmodule Arbor.Voice.EgressSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Test.EgressAuthorityFakes
  alias Arbor.Voice.Test.EgressAuthorityFakes.{AI, Security, Trust}

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals,
    TrackingResourceOwner
  }

  defmodule SelectorTransport do
    @moduledoc false
    @table :arbor_voice_p3_security_selector_transport

    def reset(frames) do
      ensure_table()
      :ets.insert(@table, {:frames, frames})
      :ok
    end

    def connect(opts) do
      _ = Keyword.fetch!(opts, :token)
      EgressAuthorityFakes.record(:transport_connect)
      {:ok, %{physical_frames: 0}}
    end

    def send_frame(state, frame) do
      EgressAuthorityFakes.record({:transport_send, frame["type"]})
      {:ok, %{state | physical_frames: state.physical_frames + 1}}
    end

    def recv_frame(state, _timeout) do
      ensure_table()

      case :ets.lookup(@table, :frames) do
        [{:frames, [frame | rest]}] ->
          :ets.insert(@table, {:frames, rest})
          {:ok, state, frame}

        _ ->
          {:error, :timeout}
      end
    end

    def close(state) do
      EgressAuthorityFakes.record({:transport_close, state.physical_frames})
      :ok
    end

    defp ensure_table do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _tid -> @table
      end
    end
  end

  defmodule OrderedRecorder do
    @moduledoc false

    def record(_agent_id, _message, _raw_text, _completed_at, _opts) do
      EgressAuthorityFakes.record(:transcript_record)
      {:ok, 2}
    end
  end

  setup do
    EgressAuthorityFakes.reset()

    previous_modules =
      for key <- [:ai_module, :security_module, :trust_module], into: %{} do
        {key, Application.fetch_env(:arbor_voice, key)}
      end

    Application.put_env(:arbor_voice, :ai_module, AI)
    Application.put_env(:arbor_voice, :security_module, Security)
    Application.put_env(:arbor_voice, :trust_module, Trust)

    on_exit(fn ->
      Enum.each(previous_modules, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_voice, key, value)
        {key, :error} -> Application.delete_env(:arbor_voice, key)
      end)
    end)

    SelectorTransport.reset([
      %{"type" => "response.output_text.delta", "delta" => "authorized"},
      %{"type" => "response.done"}
    ])

    {:ok, _engagement} =
      FakeEngagementStore.start(result: {:ok, %{id: "eng_p3_selector", agent_id: "agent"}})

    {:ok, ledger} = FakeLedger.start()
    {:ok, signals} = FakeSignals.start()
    {:ok, _recorder} = FakeCommsSession.start_recorder()

    %{ledger: ledger, signals: signals}
  end

  defp external_tracking_opts(extra \\ []) do
    [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      resource_owner: TrackingResourceOwner,
      backend: XaiRealtime,
      backend_opts: [
        transport: SelectorTransport,
        oauth_resolver: fn :xai -> {:ok, "startup-boundary-oauth-proof"} end
      ],
      session_token: "startup-boundary-human-proof",
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      resource_owner_opts: [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 200,
        max_recv_timeout_ms: 100
      ]
    ]
    |> Keyword.merge(extra)
  end

  defp revoke_events do
    Enum.filter(EgressAuthorityFakes.events(), &match?({:revoke, _capability_id}, &1))
  end

  @tag :security_regression
  @tag spec: "VOICE-17,VOICE-24"
  test "pre-acceptance owner start failure unwinds route and budget directly", %{ledger: ledger} do
    {:ok, owner_tracker} = TrackingResourceOwner.start_tracker(start_mode: :fail)

    assert {:error, :start_failed} =
             Voice.start_session(
               "user_pre_accept",
               "agent_pre_accept",
               external_tracking_opts()
             )

    assert TrackingResourceOwner.stats(owner_tracker).handoff_cleanup_keys |> MapSet.new() ==
             MapSet.new([:voice_realtime_route_capability, :budget_settlement])

    assert Enum.count(FakeLedger.calls(ledger), &match?({:release, _, _}, &1)) == 1
    assert [{:revoke, capability_id}] = revoke_events()
    assert %{revoked: true} = EgressAuthorityFakes.capability(capability_id)
  end

  @tag :security_regression
  @tag spec: "VOICE-17,VOICE-24"
  test "accepted owner start failure leaves route and budget exclusively with the lease", %{
    ledger: ledger
  } do
    clock_reads = :atomics.new(1, signed: false)

    monotonic_clock = fn ->
      _ = :atomics.add_get(clock_reads, 1, 1)
      5_000_000
    end

    {:ok, owner_tracker} = TrackingResourceOwner.start_tracker(start_mode: :accepted_fail)

    assert {:error, :start_failed} =
             Voice.start_session(
               "user_accepted",
               "agent_accepted",
               external_tracking_opts(monotonic_clock: monotonic_clock)
             )

    stats = TrackingResourceOwner.stats(owner_tracker)

    assert stats.handoff_cleanup_keys |> MapSet.new() ==
             MapSet.new([:voice_realtime_route_capability, :budget_settlement])

    assert stats.accepted_failures == 1
    assert stats.cleanup_runs == 2
    assert stats.closes == 0
    assert Enum.count(FakeLedger.calls(ledger), &match?({:release, _, _}, &1)) == 1
    assert length(revoke_events()) == 1
    # Construction plus lease cleanup; direct Session unwind would read again.
    assert :atomics.get(clock_reads, 1) == 2
  end

  @tag :security_regression
  @tag :p3_parent_selector
  @tag spec: "VOICE-17"
  test "security regression: valid exact authority permits physical effects but a substitute cap does not" do
    user_id = "user_p3_selector"
    agent_id = "agent_p3_selector"

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      backend: XaiRealtime,
      backend_opts: [
        transport: SelectorTransport,
        oauth_resolver: fn :xai ->
          EgressAuthorityFakes.record(:oauth_resolve)
          {:ok, "selector-token-never-recorded"}
        end
      ],
      session_token: "selector-human-proof-never-recorded",
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      resource_owner_opts: [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 200,
        max_recv_timeout_ms: 100
      ]
    ]

    assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
    assert {:ok, "authorized"} = Voice.text_turn(user_id, agent_id, "first")

    [route_capability] =
      EgressAuthorityFakes.active_capabilities()
      |> Enum.filter(&(&1.kind == :route))

    assert route_capability.resource_uri =~
             ~r|\Aarbor://voice/realtime/xai/session_[0-9a-f]{32}\z|

    assert {:ok, substitute_id} =
             EgressAuthorityFakes.replace_with_substitute(route_capability.id)

    events_before_denial = EgressAuthorityFakes.events()
    physical_before_denial = physical_send_count(events_before_denial)

    assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "second")
    assert {:error, :not_found} = Voice.stop_session(key)

    events = EgressAuthorityFakes.events()
    assert physical_send_count(events) == physical_before_denial
    assert {:transport_close, 3} in events

    assert_order(events, [
      {:trust_effect, :trusted},
      {:security_effect, :connect, route_capability.id},
      :oauth_resolve,
      :transport_connect,
      {:trust_effect, :trusted},
      {:security_effect, :configure, route_capability.id},
      {:transport_send, "session.update"},
      {:security_effect, :text_item, route_capability.id},
      {:trust_effect, :untrusted},
      :disclosure_validate,
      {:transport_send, "conversation.item.create"},
      {:security_effect, :text_response, route_capability.id},
      {:trust_effect, :untrusted},
      :disclosure_validate,
      {:transport_send, "response.create"}
    ])

    denial_authorizations =
      Enum.filter(events, fn
        {:authorize, ^agent_id, resource, :text_item, auth_opts} ->
          resource == route_capability.resource_uri and
            Keyword.get(auth_opts, :exact_capability_id) == route_capability.id

        _ ->
          false
      end)

    assert length(denial_authorizations) == 2
    assert EgressAuthorityFakes.capability(route_capability.id) == nil
    assert %{id: ^substitute_id, revoked: false} = EgressAuthorityFakes.capability(substitute_id)

    inspected = inspect({Voice.session_status(key), events})
    refute inspected =~ "selector-token-never-recorded"
    refute inspected =~ "selector-human-proof-never-recorded"
    refute inspected =~ "first"
    refute inspected =~ "second"
  end

  @tag spec: "VOICE-17"
  test "registered external turn retains only its lease and drains before presentation", %{
    signals: signals
  } do
    user_id = "user_lease_only"
    agent_id = "agent_lease_only"
    {:ok, owner_tracker} = TrackingResourceOwner.start_tracker()

    speech_output = fn _spoken ->
      EgressAuthorityFakes.record(:speech_output)
      :ok
    end

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      resource_owner: TrackingResourceOwner,
      backend: XaiRealtime,
      backend_opts: [
        transport: SelectorTransport,
        oauth_resolver: fn :xai -> {:ok, "lease-only-oauth-proof"} end
      ],
      session_token: "lease-only-human-proof",
      transcript_recorder: OrderedRecorder,
      speech_output: speech_output,
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      resource_owner_opts: [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 200,
        max_recv_timeout_ms: 100
      ]
    ]

    assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
    SelectorTransport.reset([])
    task = Task.async(fn -> Voice.text_turn(user_id, agent_id, "lease-only text") end)

    assert_eventually(fn ->
      Enum.any?(EgressAuthorityFakes.events(), &match?({:transport_send, "response.create"}, &1))
    end)

    assert [{session, _value}] = Registry.lookup(Arbor.Voice.Registry, key)
    %{turn: turn} = :sys.get_state(session)
    refute Map.has_key?(turn, :authority)
    assert %Redacted{} = turn.lease

    lease = Redacted.value(turn.lease)

    [route_capability] =
      EgressAuthorityFakes.active_capabilities()
      |> Enum.filter(&(&1.kind == :route))

    assert Map.keys(lease) |> MapSet.new() ==
             MapSet.new([:kind, :turn_id, :disclosure_capability_id, :cleanup_key])

    refute contains_function?(lease)
    refute Map.has_key?(:sys.get_state(session), :settlement)

    inspected_status = inspect({Voice.session_status(key), :sys.get_status(session)})

    for secret <- [
          route_capability.id,
          lease.disclosure_capability_id,
          "lease-only-oauth-proof",
          "lease-only-human-proof",
          "lease-only text"
        ] do
      refute inspected_status =~ secret
    end

    refute inspected_status =~ "#Function"

    SelectorTransport.reset([
      %{"type" => "response.output_text.delta", "delta" => "lease complete"},
      %{"type" => "response.done"}
    ])

    assert {:ok, "lease complete"} = Task.await(task, 3_000)
    EgressAuthorityFakes.record(:public_reply_observed)

    events = EgressAuthorityFakes.events()
    assert_before(events, {:revoke, lease.disclosure_capability_id}, :transcript_record)
    assert_before(events, :transcript_record, :speech_output)
    assert_before(events, :speech_output, :public_reply_observed)

    inspected_signals = inspect(FakeSignals.emissions(signals))

    for secret <- [
          route_capability.id,
          lease.disclosure_capability_id,
          "lease-only-oauth-proof",
          "lease-only-human-proof",
          "lease-only text",
          "lease complete"
        ] do
      refute inspected_signals =~ secret
    end

    assert :ok = Voice.stop_session(key)

    stats = TrackingResourceOwner.stats(owner_tracker)
    assert stats.registers == 1
    assert stats.removes == 0
  end

  @tag spec: "VOICE-17"
  test "registered unpublished turn activation failure drains only through the exact barrier" do
    {:ok, owner_tracker} = TrackingResourceOwner.start_tracker(activate_mode: :fail)

    assert {:ok, key} =
             Voice.start_session(
               "user_activation_fail",
               "agent_activation_fail",
               external_tracking_opts()
             )

    event_count_before_turn = EgressAuthorityFakes.events() |> length()

    assert {:error, :turn_failed} =
             Voice.text_turn("user_activation_fail", "agent_activation_fail", "not published")

    disclosure_id =
      EgressAuthorityFakes.capabilities()
      |> Map.values()
      |> Enum.find_value(fn
        %{kind: :disclosure, id: id} -> id
        _other -> nil
      end)

    assert is_binary(disclosure_id)

    turn_events = EgressAuthorityFakes.events() |> Enum.drop(event_count_before_turn)
    assert Enum.count(turn_events, &(&1 == {:revoke, disclosure_id})) == 1
    assert %{revoked: true} = EgressAuthorityFakes.capability(disclosure_id)

    stats = TrackingResourceOwner.stats(owner_tracker)
    assert stats.registers == 1
    assert stats.activates == 1
    assert stats.fences == 1
    assert stats.removes == 0
    assert {:ok, %{state: :ready}} = Voice.session_status(key)
    assert :ok = Voice.stop_session(key)
  end

  @tag spec: "VOICE-17"
  test "failed pre-registration revoke is transferred while route cleanup remains pending" do
    user_id = "user_provisional_cleanup"
    agent_id = "agent_provisional_cleanup"
    {:ok, owner_tracker} = TrackingResourceOwner.start_tracker()

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      resource_owner: TrackingResourceOwner,
      backend: XaiRealtime,
      backend_opts: [
        transport: SelectorTransport,
        oauth_resolver: fn :xai -> {:ok, "provisional-cleanup-token-never-recorded"} end
      ],
      session_token: "provisional-human-proof-never-recorded",
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      resource_owner_opts: [
        close_timeout_ms: 100,
        cleanup_ready_timeout_ms: 20,
        cleanup_attempts: 1,
        cleanup_per_attempt_timeout_ms: 20,
        max_recv_timeout_ms: 100
      ]
    ]

    assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
    owner = TrackingResourceOwner.owner(owner_tracker)
    owner_ref = Process.monitor(owner)
    assert is_pid(owner) and Process.alive?(owner)
    physical_before_turn = physical_send_count(EgressAuthorityFakes.events())

    on_exit(fn ->
      # The fake Store is linked to the test process and may already have
      # exited before ExUnit runs on_exit callbacks. Reset recreates it with a
      # recovered revoke path so retained cleanup can deterministically drain.
      EgressAuthorityFakes.reset(modes: [revoke: :ok])
      _ = Voice.stop_session(key)

      unless await_process_exit(owner, 2_000) do
        _ = DynamicSupervisor.terminate_child(Arbor.Voice.ResourceSupervisor, owner)
        _ = await_process_exit(owner, 2_000)
      end
    end)

    # The first registration is the normal turn handoff; the second transfers
    # the still-Session-owned provisional closure before authoritative close.
    TrackingResourceOwner.set_register_mode(owner_tracker, {:sequence, [:fail, :ok]})
    EgressAuthorityFakes.set_mode(:revoke, {:return, {:error, :revoke_blocked}})

    assert {:error, :cleanup_pending} = Voice.text_turn(user_id, agent_id, "never sent")
    assert {:error, :not_found} = Voice.session_status(key)
    assert Process.alive?(owner)
    assert TrackingResourceOwner.stats(owner_tracker).registers == 2

    active = EgressAuthorityFakes.active_capabilities()
    assert Enum.count(active, &(&1.kind == :route)) == 1
    assert Enum.count(active, &(&1.kind == :disclosure)) == 1

    retained_cleanup_keys =
      owner
      |> :sys.get_state()
      |> Map.fetch!(:cleanups)
      |> Arbor.Voice.Redacted.value()
      |> Map.keys()

    assert Enum.count(retained_cleanup_keys, fn
             {:voice_turn, _turn_id} -> true
             {:voice_provisional_cleanup, {:voice_turn, _turn_id}} -> true
             _other -> false
           end) == 1

    assert Enum.any?(retained_cleanup_keys, &match?({:voice_turn, _}, &1))
    refute Enum.any?(retained_cleanup_keys, &match?({:voice_provisional_cleanup, _}, &1))

    events_while_blocked = EgressAuthorityFakes.events()
    assert Enum.any?(events_while_blocked, &match?({:revoke, _}, &1))
    assert physical_send_count(events_while_blocked) == physical_before_turn

    # ResourceOwner outlives Session and keeps retrying both pending authority
    # obligations. Once revocation recovers, it can truthfully terminate.
    EgressAuthorityFakes.set_mode(:revoke, :ok)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 2_000

    assert Enum.all?(EgressAuthorityFakes.capabilities(), fn {_id, capability} ->
             capability.revoked
           end)

    inspected =
      inspect({EgressAuthorityFakes.events(), TrackingResourceOwner.stats(owner_tracker)})

    refute inspected =~ "provisional-cleanup-token-never-recorded"
    refute inspected =~ "provisional-human-proof-never-recorded"
    refute inspected =~ "never sent"
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "no-lost-obligation regression: owner-down retains failed provisional cleanup until recovery" do
    user_id = "user_provisional_owner_down"
    agent_id = "agent_provisional_owner_down"

    {:ok, owner_tracker} =
      TrackingResourceOwner.start_tracker(register_mode: :fail, adopt_mode: :owner_down)

    assert {:ok, key} =
             Voice.start_session(user_id, agent_id, external_tracking_opts())

    assert [{session, _value}] = Registry.lookup(Arbor.Voice.Registry, key)
    owner = TrackingResourceOwner.owner(owner_tracker)
    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    on_exit(fn ->
      EgressAuthorityFakes.reset(modes: [revoke: :ok])

      if Process.alive?(session) do
        _ = DynamicSupervisor.terminate_child(Arbor.Voice.SessionSupervisor, session)
      end

      if Process.alive?(owner) do
        _ = DynamicSupervisor.terminate_child(Arbor.Voice.ResourceSupervisor, owner)
      end
    end)

    EgressAuthorityFakes.set_mode(:revoke, {:return, {:error, :transient_revoke}})
    attempts_before_owner_down = length(revoke_events())

    assert {:error, :cleanup_pending} =
             Voice.text_turn(user_id, agent_id, "provisional cleanup must survive")

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert Process.alive?(session)
    assert [{^session, _value}] = Registry.lookup(Arbor.Voice.Registry, key)
    assert {:error, :not_found} = Voice.session_status(key)

    state = :sys.get_state(session)
    assert %Redacted{} = state.provisional_turn_authority
    assert is_reference(state.provisional_cleanup_retry_token)

    stats = TrackingResourceOwner.stats(owner_tracker)
    assert stats.registers == 2
    assert stats.adopts == 1

    assert_eventually(fn ->
      if Process.alive?(session) do
        current = :sys.get_state(session)

        match?(%Redacted{}, current.provisional_turn_authority) and
          length(revoke_events()) >= attempts_before_owner_down + 7
      else
        false
      end
    end)

    assert Process.alive?(session)
    retry_token = :sys.get_state(session).provisional_cleanup_retry_token
    assert is_reference(retry_token)

    disclosure_id =
      EgressAuthorityFakes.capabilities()
      |> Map.values()
      |> Enum.find_value(fn
        %{kind: :disclosure, id: id} -> id
        _other -> nil
      end)

    assert is_binary(disclosure_id)
    assert %{revoked: false} = EgressAuthorityFakes.capability(disclosure_id)

    EgressAuthorityFakes.set_mode(:revoke, :ok)
    send(session, {:retry_provisional_cleanup, retry_token})

    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, :cleanup_pending}},
                   2_000

    assert %{revoked: true} = EgressAuthorityFakes.capability(disclosure_id)
    assert_eventually(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end)
  end

  defp physical_send_count(events) do
    Enum.count(events, &match?({:transport_send, _}, &1))
  end

  defp contains_function?(term) when is_function(term), do: true

  defp contains_function?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} -> contains_function?(key) or contains_function?(value) end)
  end

  defp contains_function?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.any?(&contains_function?/1)
  end

  defp contains_function?(term) when is_list(term), do: Enum.any?(term, &contains_function?/1)
  defp contains_function?(_term), do: false

  defp assert_before(events, first, second) do
    first_index = Enum.find_index(events, &(&1 == first))
    second_index = Enum.find_index(events, &(&1 == second))
    assert is_integer(first_index), "missing #{inspect(first)} in #{inspect(events)}"
    assert is_integer(second_index), "missing #{inspect(second)} in #{inspect(events)}"
    assert first_index < second_index
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp await_process_exit(pid, timeout_ms) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> true
      after
        timeout_ms ->
          _ = Process.demonitor(ref, [:flush])
          not Process.alive?(pid)
      end
    else
      true
    end
  end

  defp assert_order(events, expected) do
    simplified = Enum.map(events, &simplify_event/1)

    {_tail, found} =
      Enum.reduce(expected, {simplified, []}, fn wanted, {remaining, found} ->
        case Enum.split_while(remaining, &(&1 != wanted)) do
          {_skipped, [^wanted | tail]} ->
            {tail, [wanted | found]}

          {_skipped, []} ->
            flunk("missing ordered event #{inspect(wanted)} in #{inspect(simplified)}")
        end
      end)

    assert Enum.reverse(found) == expected
  end

  defp simplify_event({:trust, _agent_id, _tier, opts}),
    do: {:trust_effect, Keyword.get(opts, :egress_taint)}

  defp simplify_event({:authorize, _agent_id, _resource, effect, opts}),
    do: {:security_effect, effect, Keyword.get(opts, :exact_capability_id)}

  defp simplify_event({:disclosure_validate, _agent_id, _id, _opts}),
    do: :disclosure_validate

  defp simplify_event(event), do: event
end
