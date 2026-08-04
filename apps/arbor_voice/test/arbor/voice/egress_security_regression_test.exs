defmodule Arbor.Voice.EgressSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Backend.XaiRealtime
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

    {:ok, _ledger} = FakeLedger.start()
    {:ok, _signals} = FakeSignals.start()
    {:ok, _recorder} = FakeCommsSession.start_recorder()

    :ok
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

    # The first registration is the normal turn handoff; the second is the
    # terminal transfer retry. The retry succeeds through the configured
    # facade, and concrete adoption must verify rather than duplicate it.
    TrackingResourceOwner.set_register_mode(owner_tracker, {:sequence, [:fail, :ok]})
    EgressAuthorityFakes.set_mode(:revoke, {:return, {:error, :revoke_blocked}})

    assert {:error, :not_found} = Voice.text_turn(user_id, agent_id, "never sent")
    assert {:error, :not_found} = Voice.session_status(key)
    assert Process.alive?(owner)
    assert TrackingResourceOwner.stats(owner_tracker).registers >= 3

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

  defp physical_send_count(events) do
    Enum.count(events, &match?({:transport_send, _}, &1))
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
