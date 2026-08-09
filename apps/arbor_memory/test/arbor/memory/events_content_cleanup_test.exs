defmodule Arbor.Memory.EventsContentCleanupTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.Events
  alias Arbor.Memory.Events.ContentCore
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Test.DurableEventLog
  alias Arbor.Memory.Test.SignalsCheckpointFake
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Signals
  alias Arbor.Signals.Store

  @moduletag :integration
  @moduletag spec: "VP-05D2C3I0C4D"

  @report_keys [:signals, :local_event_log, :historian, :maintenance_archive]
  @allowed_statuses [
    :absent,
    :present,
    :delete_succeeded_unverified,
    :delete_failed,
    :delete_indeterminate,
    :absence_indeterminate,
    :not_attempted_deadline
  ]

  setup do
    durable = unique_name(:c4d_hist_durable)
    hot = unique_name(:c4d_hist_hot)

    # Unique child ids required: multiple EventLog.ETS children cannot share the module id.
    start_supervised!(
      {ETS, name: durable, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: durable
    )

    start_supervised!(
      {ETS, name: hot, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: hot
    )

    durable_target = %{name: durable, backend: ETS, opts: []}
    hot_target = %{name: hot, backend: ETS, opts: []}

    # Register on_exit before each global env mutation.
    lease_env!(:arbor_historian, :durable_event_log_target, durable_target)
    lease_env!(:arbor_historian, :hot_event_log_target, hot_target)

    # Ensure dual_emit historian hot path has a live process under the hardcoded name.
    hardcoded = Arbor.Historian.EventLog.ETS

    case Process.whereis(hardcoded) do
      nil ->
        start_supervised!(
          {ETS, name: hardcoded, max_age_ms: :infinity, trim_interval_ms: :disabled},
          id: hardcoded
        )

      _pid ->
        :ok
    end

    {:ok, hist_durable: durable, hist_hot: hot, hist_durable_target: durable_target}
  end

  test "invalid agent_id and options fail before any authority call" do
    assert {:error, :invalid_agent_id} = Events.delete_agent_content("")
    assert {:error, :invalid_agent_id} = Events.agent_content_absent?("")
    assert {:error, :invalid_agent_id} = Events.delete_agent_content("ab\0c")
    assert {:error, :invalid_precondition} = Events.delete_agent_content("ok", timeout_ms: 0)
    assert {:error, :invalid_precondition} = Events.agent_content_absent?("ok", repo: true)

    # Malformed maintenance archive config is a precondition failure after admit.
    lease_env!(:arbor_memory, :maintenance_archive_target, %{invalid: true})

    assert {:error, :invalid_precondition} =
             Events.delete_agent_content("precondition_agent", timeout_ms: 1_000)

    assert {:error, :invalid_precondition} =
             Events.agent_content_absent?("precondition_agent", timeout_ms: 1_000)

    # 249-byte id is rejected before config resolution: same malformed sentinel would
    # yield :invalid_precondition if resolve_maintenance_archive ran.
    agent_249 = String.duplicate("x", 249)

    assert {:error, :invalid_agent_id} =
             Memory.delete_agent_event_content(agent_249, timeout_ms: 1_000)

    assert {:error, :invalid_agent_id} =
             Memory.agent_event_content_absent?(agent_249, timeout_ms: 1_000)

    assert {:error, :invalid_agent_id} = Events.delete_agent_content(agent_249)
    assert {:error, :invalid_agent_id} = Events.agent_content_absent?(agent_249)
  end

  test "public APIs accept exactly 248-byte agent id end-to-end", %{
    hist_durable: durable,
    hist_hot: hot
  } do
    agent_248 = String.duplicate("z", 248)
    assert byte_size(agent_248) == 248
    seed_all_authorities(agent_248)

    assert {:ok, false} = Memory.agent_event_content_absent?(agent_248, timeout_ms: 5_000)
    assert :ok = Memory.delete_agent_event_content(agent_248, timeout_ms: 5_000)
    assert {:ok, true} = Memory.agent_event_content_absent?(agent_248, timeout_ms: 5_000)
    assert_absent_on_all(agent_248, durable, hot)
  end

  test "facade delegates to Events for delete and absence" do
    agent = unique_agent("facade")
    seed_all_authorities(agent)

    assert {:ok, false} = Memory.agent_event_content_absent?(agent, timeout_ms: 5_000)
    assert :ok = Memory.delete_agent_event_content(agent, timeout_ms: 5_000)
    assert {:ok, true} = Memory.agent_event_content_absent?(agent, timeout_ms: 5_000)
  end

  test "absence is read-only, false before cleanup, true after; survivors remain", %{
    hist_durable: durable,
    hist_hot: hot
  } do
    target = unique_agent("target")
    prefix = target <> "_prefix"
    unrelated = unique_agent("unrelated")

    seed_all_authorities(target)
    seed_all_authorities(prefix)
    seed_all_authorities(unrelated)

    # Read-only absence leaves content in place.
    assert {:ok, false} = Events.agent_content_absent?(target, timeout_ms: 5_000)
    assert_present_on_all(target, durable, hot)
    assert_present_on_all(prefix, durable, hot)
    assert_present_on_all(unrelated, durable, hot)

    assert :ok = Events.delete_agent_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Events.agent_content_absent?(target, timeout_ms: 5_000)
    assert :ok = Events.delete_agent_content(target, timeout_ms: 5_000)

    assert_absent_on_all(target, durable, hot)
    assert_present_on_all(prefix, durable, hot)
    assert_present_on_all(unrelated, durable, hot)
  end

  test "historian-durable maintenance alias cleans exact stream and is idempotent", %{
    hist_durable: durable,
    hist_hot: hot,
    hist_durable_target: durable_target
  } do
    # Production-style alias: maintenance archive and Historian durable are the same target.
    lease_env!(:arbor_memory, :maintenance_archive_target, durable_target)

    target = unique_agent("alias")
    # Prefix-related and unrelated survivors: exact payload equality after target cleanup
    # fails both backend-wide purge and raw prefix purge defects.
    prefix = target <> "_prefix"
    unrelated = unique_agent("alias_unrel")

    seed_all_authorities(target)
    seed_all_authorities(prefix)
    seed_all_authorities(unrelated)

    stream = ContentCore.stream_id(target)
    prefix_stream = ContentCore.stream_id(prefix)
    unrelated_stream = ContentCore.stream_id(unrelated)

    # Alias shares durable with maintenance; snapshot every EventLog authority survivors touch.
    survivor_stores = [
      {:memory_events, ETS},
      {durable, ETS},
      {hot, ETS}
    ]

    prefix_before = snapshot_streams(survivor_stores, prefix_stream)
    unrelated_before = snapshot_streams(survivor_stores, unrelated_stream)
    refute prefix_before == []
    refute unrelated_before == []

    assert {:ok, false} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)
    assert :ok = Memory.delete_agent_event_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)
    # Second visit is safe and idempotent.
    assert :ok = Memory.delete_agent_event_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)

    assert {:ok, true} = Persistence.event_stream_absent?(durable, ETS, stream)
    assert_absent_on_all(target, durable, hot)

    # Survivors retain exact pre-cleanup event payloads on every authority store.
    assert snapshot_streams(survivor_stores, prefix_stream) == prefix_before
    assert snapshot_streams(survivor_stores, unrelated_stream) == unrelated_before
    assert {:ok, false} = Memory.agent_event_content_absent?(prefix, timeout_ms: 5_000)
    assert {:ok, false} = Memory.agent_event_content_absent?(unrelated, timeout_ms: 5_000)
    assert_present_on_all(prefix, durable, hot)
    assert_present_on_all(unrelated, durable, hot)
  end

  test "default memory_events maintenance alias still cleans exact stream only" do
    # Default maintenance archive aliases local :memory_events.
    lease_env!(:arbor_memory, :maintenance_archive_target, :delete)

    target = unique_agent("defalias")
    survivor = unique_agent("defalias_surv")
    seed_all_authorities(target)
    seed_all_authorities(survivor)

    assert {:ok, false} = Events.agent_content_absent?(target, timeout_ms: 5_000)
    assert :ok = Events.delete_agent_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Events.agent_content_absent?(target, timeout_ms: 5_000)
    assert {:ok, false} = Events.agent_content_absent?(survivor, timeout_ms: 5_000)
  end

  test "distinct maintenance archive target is cleaned independently", %{
    hist_durable: durable,
    hist_hot: hot
  } do
    # Distinct supported EventLog target (not the default :memory_events alias).
    archive_name = unique_name(:c4d_maint_archive)

    start_supervised!(
      {ETS, name: archive_name, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: archive_name
    )

    archive_target = %{name: archive_name, backend: ETS, opts: []}
    # DurableEventLog.lease_target! registers on_exit before mutation.
    DurableEventLog.lease_target!(archive_target)

    target = unique_agent("dist")
    # Prefix-related and unrelated survivors prove target-only deletion (not
    # backend-wide purge, not raw prefix purge) across normal + distinct archive.
    prefix = target <> "_prefix"
    unrelated = unique_agent("dist_unrel")

    seed_all_authorities(target)
    seed_all_authorities(prefix)
    seed_all_authorities(unrelated)

    target_stream = ContentCore.stream_id(target)
    prefix_stream = ContentCore.stream_id(prefix)
    unrelated_stream = ContentCore.stream_id(unrelated)

    seed_archive(archive_target, target_stream)
    seed_archive(archive_target, prefix_stream)
    seed_archive(archive_target, unrelated_stream)

    survivor_stores = [
      {:memory_events, ETS},
      {durable, ETS},
      {hot, ETS},
      {archive_name, ETS}
    ]

    prefix_before = snapshot_streams(survivor_stores, prefix_stream)
    unrelated_before = snapshot_streams(survivor_stores, unrelated_stream)
    refute prefix_before == []
    refute unrelated_before == []

    assert {:ok, false} =
             Persistence.event_stream_absent?(archive_name, ETS, target_stream)

    assert :ok = Memory.delete_agent_event_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)

    assert {:ok, true} =
             Persistence.event_stream_absent?(archive_name, ETS, target_stream)

    assert_absent_on_all(target, durable, hot)

    # Exact pre-cleanup survivor payloads retained on every store including the
    # distinct archive — backend-wide or prefix purge would fail these equals.
    assert snapshot_streams(survivor_stores, prefix_stream) == prefix_before
    assert snapshot_streams(survivor_stores, unrelated_stream) == unrelated_before
    assert_present_on_all(prefix, durable, hot)
    assert_present_on_all(unrelated, durable, hot)

    assert {:ok, false} =
             Persistence.event_stream_absent?(archive_name, ETS, prefix_stream)

    assert {:ok, false} =
             Persistence.event_stream_absent?(archive_name, ETS, unrelated_stream)
  end

  test "configured Signals checkpoint snapshot drops target and restart cannot resurrect", %{
    hist_durable: durable,
    hist_hot: hot
  } do
    fake_name = unique_name(:c4d_signals_cp)
    {:ok, _} = SignalsCheckpointFake.start_link(name: fake_name, mode: :ok)

    on_exit(fn ->
      SignalsCheckpointFake.stop(fake_name)
      # Leave Store healthy for later tests (live-only).
      restart_signals_store()
    end)

    lease_env!(:arbor_signals, :checkpoint_module, SignalsCheckpointFake)
    lease_env!(:arbor_signals, :checkpoint_store, fake_name)
    restart_signals_store()
    _ = Store.clear()

    target = unique_agent("cp_target")
    survivor = unique_agent("cp_surv")
    seed_all_authorities(target)
    seed_all_authorities(survivor)

    assert {:ok, false} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)
    assert :ok = Memory.delete_agent_event_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)

    # Inspect the actual saved checkpoint snapshot — not merely facade :ok.
    cp = SignalsCheckpointFake.get_snapshot(fake_name)
    assert is_map(cp)
    assert is_map(cp.signals)
    refute snapshot_has_agent?(cp, target)
    assert snapshot_has_agent?(cp, survivor)

    restart_signals_store()

    # Restart must not resurrect target; survivor remains; other authorities stay correct.
    assert {:ok, true} = Signals.memory_agent_content_absent?(target, timeout_ms: 2_000)
    assert {:ok, false} = Signals.memory_agent_content_absent?(survivor, timeout_ms: 2_000)
    assert_absent_on_all(target, durable, hot)
    assert_present_on_all(survivor, durable, hot)
    assert {:ok, true} = Memory.agent_event_content_absent?(target, timeout_ms: 5_000)
    assert {:ok, false} = Memory.agent_event_content_absent?(survivor, timeout_ms: 5_000)
  end

  test "closed cleanup_incomplete report covers source uncertainty and retries converge", %{
    hist_durable: durable
  } do
    target = unique_agent("retry")
    seed_all_authorities(target)

    # Force historian durable unavailable by pointing durable at a missing name.
    lease_env!(:arbor_historian, :durable_event_log_target, %{
      name: unique_name(:c4d_missing_durable),
      backend: ETS,
      opts: []
    })

    result = Events.delete_agent_content(target, timeout_ms: 5_000)

    assert {:error, {:cleanup_incomplete, ^target, report}} = result
    assert_closed_report(report)
    refute report.historian == :absent
    # Earlier authorities were attempted — not left as pure deadline seeds.
    assert report.signals in @allowed_statuses
    assert report.local_event_log in @allowed_statuses
    refute Enum.all?(Map.values(report), &(&1 == :not_attempted_deadline))

    # Restore healthy historian durable for retry convergence.
    lease_env!(:arbor_historian, :durable_event_log_target, %{
      name: durable,
      backend: ETS,
      opts: []
    })

    assert :ok = Events.delete_agent_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Events.agent_content_absent?(target, timeout_ms: 5_000)
  end

  test "public read-only source uncertainty returns closed absence_indeterminate without mutating durable",
       %{
         hist_durable: durable,
         hist_durable_target: durable_target
       } do
    alias Arbor.Memory.Test.IndeterminateEventLog

    # Seed a real durable source only — no Signals, local EventLog, hot, or archive.
    agent = unique_agent("src_uncert")
    stream = ContentCore.stream_id(agent)
    seed_historian(stream, durable)

    assert {:ok, seeded_before} = Persistence.read_stream(durable, ETS, stream)
    refute seeded_before == []

    # Redirect Historian durable to IndeterminateEventLog while leaving a healthy
    # empty maintenance authority later in traversal (default :memory_events).
    # Register on_exit restore before mutation (lease_env!).
    lease_env!(:arbor_historian, :durable_event_log_target, %{
      name: unique_name(:c4d_indet_durable),
      backend: IndeterminateEventLog,
      opts: []
    })

    result = Memory.agent_event_content_absent?(agent, timeout_ms: 5_000)

    assert {:error, {:absence_indeterminate, ^agent, report}} = result

    assert report == %{
             signals: :absent,
             local_event_log: :absent,
             historian: :absence_indeterminate,
             maintenance_archive: :absent
           }

    # Restore the real durable target; seeded events must be term-equal and present.
    lease_env!(:arbor_historian, :durable_event_log_target, durable_target)

    assert {:ok, seeded_after} = Persistence.read_stream(durable, ETS, stream)
    assert seeded_after == seeded_before
    assert {:ok, false} = Persistence.event_stream_absent?(durable, ETS, stream)
  end

  test "not_attempted_deadline appears when outer budget is exhausted early" do
    target = unique_agent("deadline")
    seed_all_authorities(target)

    # 1ms budget cannot complete four deletes + four verifies.
    result = Events.delete_agent_content(target, timeout_ms: 1)

    case result do
      :ok ->
        # Extremely fast machines may still finish; absence must hold.
        assert {:ok, true} = Events.agent_content_absent?(target, timeout_ms: 5_000)

      {:error, {:cleanup_incomplete, ^target, report}} ->
        assert_closed_report(report)

        assert Enum.any?(Map.values(report), fn status ->
                 status in [
                   :not_attempted_deadline,
                   :delete_indeterminate,
                   :absence_indeterminate
                 ]
               end)
    end
  end

  test "unrelated Memory domains and provenance are not removed" do
    alias Arbor.Contracts.Security.Taint

    target = unique_agent("domain")
    seed_all_authorities(target)
    payload = %{"kind" => "c4d_preserve"}

    {:ok, taint} =
      Taint.new(%{
        level: :trusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :verified,
        source: "c4d_event_content",
        chain: []
      })

    assert :ok = Provenance.put(:thinking_entry, target, "think_1", payload, taint)
    assert {:ok, ["think_1"]} = Provenance.list_item_ids(:thinking_entry, target)

    assert :ok = Events.delete_agent_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Events.agent_content_absent?(target, timeout_ms: 5_000)

    # Event-content cleanup must not remove provenance or other Memory domains.
    assert {:ok, ["think_1"]} = Provenance.list_item_ids(:thinking_entry, target)
    assert Process.whereis(Arbor.Memory.GoalStore)
    assert Process.whereis(Arbor.Memory.Thinking)
  end

  test "C3I1B ownership: post-cleanup dual_emit can repopulate content (no writer fence)" do
    # C4D does not fence writers. After successful cleanup, a later dual_emit
    # may reintroduce content. Stable erasure / mutation-admission fencing is
    # owned by later packet C3I1B — this test documents that expectation.
    target = unique_agent("refill")
    seed_all_authorities(target)

    assert :ok = Events.delete_agent_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Events.agent_content_absent?(target, timeout_ms: 5_000)

    assert :ok =
             Events.record_identity_changed(target, %{
               field: "values",
               old_value: [],
               new_value: ["returned"]
             })

    assert {:ok, false} = Events.agent_content_absent?(target, timeout_ms: 5_000)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_all_authorities(agent_id) do
    assert :ok =
             Events.record_identity_changed(agent_id, %{
               field: "values",
               old_value: ["a"],
               new_value: ["b"]
             })

    stream = ContentCore.stream_id(agent_id)
    # dual_emit writes local EventLog + Signals. Seed historian dual stores explicitly
    # so both Config targets hold the stream even when durable_emit only hits hardcoded hot.
    durable = Application.get_env(:arbor_historian, :durable_event_log_target).name
    hot = Application.get_env(:arbor_historian, :hot_event_log_target).name
    seed_historian(stream, durable)
    seed_historian(stream, hot)
    :ok
  end

  defp seed_historian(stream_id, name) do
    event = Event.new(stream_id, "identity_changed", %{"agent" => stream_id})
    assert {:ok, [_]} = Persistence.append(name, ETS, stream_id, event)
  end

  defp seed_archive(target, stream_id) do
    event = Event.new(stream_id, "archive.seed", %{"stream" => stream_id})

    assert {:ok, [_]} =
             Persistence.append(target.name, target.backend, stream_id, event, target.opts)
  end

  # Snapshot exact event lists for one stream across stores. Term equality of
  # the returned list-of-lists proves survivors retained pre-cleanup payloads.
  defp snapshot_streams(stores, stream_id) when is_list(stores) and is_binary(stream_id) do
    Enum.map(stores, fn {name, backend} ->
      assert {:ok, events} = Persistence.read_stream(name, backend, stream_id)
      refute events == []
      events
    end)
  end

  defp assert_present_on_all(agent_id, durable, hot) do
    stream = ContentCore.stream_id(agent_id)
    assert {:ok, false} = Signals.memory_agent_content_absent?(agent_id, timeout_ms: 2_000)

    assert {:ok, false} =
             Persistence.event_stream_absent?(:memory_events, ETS, stream)

    assert {:ok, false} = Persistence.event_stream_absent?(durable, ETS, stream)
    assert {:ok, false} = Persistence.event_stream_absent?(hot, ETS, stream)
  end

  defp assert_absent_on_all(agent_id, durable, hot) do
    stream = ContentCore.stream_id(agent_id)
    assert {:ok, true} = Signals.memory_agent_content_absent?(agent_id, timeout_ms: 2_000)

    assert {:ok, true} =
             Persistence.event_stream_absent?(:memory_events, ETS, stream)

    assert {:ok, true} = Persistence.event_stream_absent?(durable, ETS, stream)
    assert {:ok, true} = Persistence.event_stream_absent?(hot, ETS, stream)
  end

  defp assert_closed_report(report) when is_map(report) do
    assert Map.keys(report) |> Enum.sort() == Enum.sort(@report_keys)

    Enum.each(@report_keys, fn key ->
      assert Map.fetch!(report, key) in @allowed_statuses
    end)
  end

  defp snapshot_has_agent?(snapshot, agent_id) when is_map(snapshot) do
    signals = Map.get(snapshot, :signals) || Map.get(snapshot, "signals") || %{}

    Enum.any?(signals, fn {_id, signal} ->
      data =
        cond do
          is_struct(signal) -> Map.get(signal, :data) || %{}
          is_map(signal) -> Map.get(signal, :data) || Map.get(signal, "data") || %{}
          true -> %{}
        end

      Map.get(data, :agent_id) == agent_id or Map.get(data, "agent_id") == agent_id
    end)
  end

  defp restart_signals_store do
    supervisor = Arbor.Signals.Supervisor

    case Supervisor.terminate_child(supervisor, Store) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(supervisor, Store) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    {:ok, _} = Supervisor.start_child(supervisor, {Store, []})
    Process.sleep(20)
    :ok
  end

  defp lease_env!(app, key, :delete) do
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      restore_fetch_env(app, key, previous)
    end)

    Application.delete_env(app, key)
    :ok
  end

  defp lease_env!(app, key, value) do
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      restore_fetch_env(app, key, previous)
    end)

    Application.put_env(app, key, value)
    :ok
  end

  defp restore_fetch_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_fetch_env(app, key, :error), do: Application.delete_env(app, key)

  defp unique_agent(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
