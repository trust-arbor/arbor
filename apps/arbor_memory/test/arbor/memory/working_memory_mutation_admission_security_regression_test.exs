defmodule Arbor.Memory.WorkingMemoryMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for WorkingMemoryStore caller-held admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (missing admission gate), not a compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Signals
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Memory.WorkingMemory
  alias Arbor.Memory.WorkingMemoryStore
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1E"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @working_memory_ets :arbor_working_memory
  @namespace "working_memory"
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :wm_sec_ma_fake
  @timestamp ~U[2026-08-04 12:00:00Z]
  @projection_domains [
    :working_memory_base,
    :working_memory_aggregate,
    :working_memory_thought,
    :working_memory_goal,
    :working_memory_skill,
    :working_memory_concern,
    :working_memory_curiosity
  ]

  setup do
    ensure_durable_store!()
    ensure_working_memory_ets!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "post-drain save, create/load, read repair, compatibility delete, and snapshots are denied" do
    agent_id = unique_agent("mut")
    create_id = unique_agent("create")
    taint = taint(:trusted, "wm_sec_mut")
    wm = put_thought(new_wm(agent_id), "t1", "seed before drain")

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, taint)
    assert {:ok, exported} = WorkingMemoryStore.export_working_memory_provenance_snapshot(agent_id)
    before = durable_bytes_and_revision!(agent_id)
    before_sidecars = sidecar_inventory(agent_id)
    before_signals = recent_wm_signals(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:ok, _create_fence} = MutationAdmission.drain(create_id)
    strip_projection!(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.save_working_memory(agent_id, wm)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, taint)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.load_working_memory_tainted(create_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.get_working_memory_tainted(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.delete_working_memory(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.export_working_memory_provenance_snapshot(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.import_working_memory_provenance_snapshot(agent_id, exported)

    assert durable_bytes_and_revision!(agent_id) == before
    assert [] = :ets.lookup(@working_memory_ets, agent_id)
    assert sidecar_inventory(agent_id) == empty_sidecar_inventory()
    assert durable_absent?(create_id)
    assert [] = :ets.lookup(@working_memory_ets, create_id)
    assert sidecar_inventory(create_id) == empty_sidecar_inventory()
    assert recent_wm_signals(agent_id) == before_signals
    assert recent_wm_signals(create_id) == []
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert before_sidecars != empty_sidecar_inventory()

    assert :ok = WorkingMemoryStore.delete_agent_content(agent_id)
    assert :ok = WorkingMemoryStore.delete_agent_content(create_id)
  end

  test "post-drain get/load/export cannot migrate a legacy raw or wrapper record" do
    raw_id = unique_agent("legacy_raw")
    wrap_id = unique_agent("legacy_wrap")

    assert :ok = seed_legacy_raw!(raw_id, "legacy raw thought")
    assert :ok = seed_legacy_wrapper!(wrap_id, "legacy wrapper thought")
    raw_before = durable_bytes_and_revision!(raw_id)
    wrap_before = durable_bytes_and_revision!(wrap_id)
    refute wrapper_version?(elem(raw_before, 0), 2)
    refute wrapper_version?(elem(wrap_before, 0), 2)

    assert {:ok, _fence} = MutationAdmission.drain(raw_id)
    assert {:ok, _fence} = MutationAdmission.drain(wrap_id)

    for agent_id <- [raw_id, wrap_id] do
      assert {:error, {:working_memory_store, :store_unavailable}} =
               WorkingMemoryStore.get_working_memory_tainted(agent_id)

      assert {:error, {:working_memory_store, :store_unavailable}} =
               WorkingMemoryStore.load_working_memory_tainted(agent_id)

      assert {:error, {:working_memory_store, :store_unavailable}} =
               WorkingMemoryStore.export_working_memory_provenance_snapshot(agent_id)

      assert [] = :ets.lookup(@working_memory_ets, agent_id)
      assert sidecar_inventory(agent_id) == empty_sidecar_inventory()
    end

    assert durable_bytes_and_revision!(raw_id) == raw_before
    assert durable_bytes_and_revision!(wrap_id) == wrap_before
    assert :ok = WorkingMemoryStore.delete_agent_content(raw_id)
    assert :ok = WorkingMemoryStore.delete_agent_content(wrap_id)
  end

  test "open-gate legacy raw and v1 wrapper migration succeed and leave no root" do
    raw_id = unique_agent("legacy_open_raw")
    wrap_id = unique_agent("legacy_open_wrap")
    assert :ok = seed_legacy_raw!(raw_id, "open-gate legacy thought")
    assert :ok = seed_legacy_wrapper!(wrap_id, "open-gate wrapper thought")
    refute wrapper_version?(durable_data!(raw_id), 2)
    refute wrapper_version?(durable_data!(wrap_id), 2)

    assert {:ok, raw_read} = WorkingMemoryStore.get_working_memory_tainted(raw_id)
    assert {:ok, wrap_read} = WorkingMemoryStore.get_working_memory_tainted(wrap_id)
    assert %WorkingMemory{} = raw_read.value.value
    assert %WorkingMemory{} = wrap_read.value.value
    assert wrapper_version?(durable_data!(raw_id), 2)
    assert wrapper_version?(durable_data!(wrap_id), 2)
    assert [{^raw_id, _raw_wm}] = :ets.lookup(@working_memory_ets, raw_id)
    assert [{^wrap_id, _wrap_wm}] = :ets.lookup(@working_memory_ets, wrap_id)
    assert sidecar_inventory(raw_id) != empty_sidecar_inventory()
    assert sidecar_inventory(wrap_id) != empty_sidecar_inventory()
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(raw_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(wrap_id)

    assert :ok = WorkingMemoryStore.delete_working_memory(raw_id)
    assert :ok = WorkingMemoryStore.delete_working_memory(wrap_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(raw_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(wrap_id)
  end

  test "admitted lock wait is visible to drain and settles before fence" do
    assert_admission_gate!()
    agent_id = unique_agent("lock")
    wm = put_thought(new_wm(agent_id), "lock-thought", "blocked then saved")
    parent = self()

    holder = hold_agent_lock!(agent_id)
    _mutator = spawn_tracked(fn -> send(parent, {:mut_done, save_raw(agent_id, wm)}) end)
    await_root_visible!(agent_id)

    _drain_pid =
      spawn_tracked(fn ->
        send(parent, {:drain_done, MutationAdmission.drain(agent_id, timeout_ms: 10_000)})
      end)

    await_draining_with_root!(agent_id)
    refute_received {:drain_done, _}
    refute_received {:mut_done, _}

    release_agent_lock!(holder)
    {mut_result, drain_result} = await_mut_and_drain!()

    assert mut_result == :ok
    assert {:ok, _fence} = drain_result
    assert durable_present?(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert :ok = WorkingMemoryStore.delete_agent_content(agent_id)
  end

  test "caller death before lock entry converges the root with no effect" do
    assert_admission_gate!()
    agent_id = unique_agent("death")
    wm = put_thought(new_wm(agent_id), "death-thought", "must not persist")
    parent = self()

    holder = hold_agent_lock!(agent_id)

    mutator =
      spawn_tracked(fn ->
        send(parent, {:mut_started, self()})
        send(parent, {:mut_done, save_raw(agent_id, wm)})
      end)

    assert_receive {:mut_started, ^mutator}, 2_000
    await_root_visible!(agent_id)

    _drain_pid =
      spawn_tracked(fn ->
        send(parent, {:drain_done, MutationAdmission.drain(agent_id, timeout_ms: 10_000)})
      end)

    await_draining_with_root!(agent_id)
    refute_received {:drain_done, _}

    mon = Process.monitor(mutator)
    Process.exit(mutator, :kill)
    assert_receive {:DOWN, ^mon, :process, ^mutator, :killed}, 2_000
    assert_receive {:drain_done, {:ok, _fence}}, 10_000
    refute_received {:mut_done, _}

    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@working_memory_ets, agent_id)
    assert sidecar_inventory(agent_id) == empty_sidecar_inventory()
    assert recent_wm_signals(agent_id) == []
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    release_agent_lock!(holder)
    assert durable_absent?(agent_id)
  end

  test "later public caller cannot borrow an earlier root after drain begins" do
    assert_admission_gate!()
    agent_id = unique_agent("reuse")
    other_id = unique_agent("isolated")
    wm = put_thought(new_wm(agent_id), "reuse-thought", "in-flight")
    later = put_thought(new_wm(agent_id), "later-thought", "must not land")
    other_wm = put_thought(new_wm(other_id), "other-thought", "isolated ok")
    parent = self()

    assert :ok = WorkingMemoryStore.save_working_memory(agent_id, wm)
    assert {:ok, exported} = WorkingMemoryStore.export_working_memory_provenance_snapshot(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    holder = hold_agent_lock!(agent_id)
    _mutator = spawn_tracked(fn -> send(parent, {:mut_done, save_raw(agent_id, later)}) end)
    await_root_visible!(agent_id)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    _drain_pid =
      spawn_tracked(fn ->
        send(parent, {:drain_done, MutationAdmission.drain(agent_id, timeout_ms: 10_000)})
      end)

    await_draining_with_root!(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.save_working_memory(agent_id, later)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.get_working_memory_tainted(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.load_working_memory_tainted(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.delete_working_memory(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.export_working_memory_provenance_snapshot(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.import_working_memory_provenance_snapshot(agent_id, exported)

    assert {:ok, %{active_roots: 1, gate: :draining}} = MutationAdmission.status(agent_id)
    assert :ok = WorkingMemoryStore.save_working_memory(other_id, other_wm)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(other_id)
    assert durable_present?(other_id)

    release_agent_lock!(holder)
    {_mut_result, drain_result} = await_mut_and_drain!()
    assert {:ok, _fence} = drain_result
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert :ok = WorkingMemoryStore.delete_agent_content(agent_id)
    assert :ok = WorkingMemoryStore.delete_working_memory(other_id)
  end

  test "malformed working memory, taint, options, and snapshot are rejected before admission" do
    agent_id = unique_agent("malformed")
    wm = new_wm(agent_id)
    foreign = new_wm(unique_agent("foreign"))
    parent = self()
    holder = hold_agent_lock!(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, {:working_memory_store, :invalid_working_memory}} =
             WorkingMemoryStore.save_working_memory(agent_id, :not_a_memory)

    assert {:error, {:working_memory_store, :invalid_working_memory}} =
             WorkingMemoryStore.save_working_memory(agent_id, foreign)

    assert {:error, {:working_memory_store, :invalid_provenance}} =
             WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, :not_a_taint)

    assert {:error, {:working_memory_store, :invalid_request}} =
             WorkingMemoryStore.load_working_memory_tainted(agent_id, %{})

    assert {:error, {:working_memory_store, :invalid_provenance_snapshot}} =
             WorkingMemoryStore.import_working_memory_provenance_snapshot(agent_id, %{
               "snapshot_kind" => "arbor_working_memory_provenance"
             })

    assert {:error, {:working_memory_store, :invalid_agent_id}} =
             WorkingMemoryStore.save_working_memory("", wm)

    assert {:error, {:working_memory_store, :invalid_agent_id}} =
             WorkingMemoryStore.save_working_memory(String.duplicate("z", 300), wm)

    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@working_memory_ets, agent_id)
    assert sidecar_inventory(agent_id) == empty_sidecar_inventory()
    assert recent_wm_signals(agent_id) == []
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    refute_received {:mut_done, _}

    _probe = spawn_tracked(fn -> send(parent, {:mut_done, save_raw(agent_id, wm)}) end)
    await_root_visible!(agent_id)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)
    refute_received {:mut_done, _}

    release_agent_lock!(holder)
    assert_receive {:mut_done, :ok}, 10_000
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    assert {:error, {:working_memory_store, :invalid_working_memory}} =
             WorkingMemoryStore.save_working_memory(agent_id, :not_a_memory)

    assert {:error, {:working_memory_store, :invalid_provenance}} =
             WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, :not_a_taint)

    assert {:error, {:working_memory_store, :invalid_request}} =
             WorkingMemoryStore.load_working_memory_tainted(agent_id, %{})

    assert {:error, {:working_memory_store, :invalid_provenance_snapshot}} =
             WorkingMemoryStore.import_working_memory_provenance_snapshot(agent_id, %{})

    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert :ok = WorkingMemoryStore.delete_agent_content(agent_id)
  end

  test "post-drain validation, absence, and content-only cleanup remain available" do
    agent_id = unique_agent("cleanup")
    taint = taint(:trusted, "wm_sec_cleanup")
    wm = put_thought(new_wm(agent_id), "c1", "cleanup seed")

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, taint)
    assert {:ok, exported} = WorkingMemoryStore.export_working_memory_provenance_snapshot(agent_id)
    sidecars_before = sidecar_inventory(agent_id)
    assert sidecars_before != empty_sidecar_inventory()

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    assert :ok = WorkingMemoryStore.validate_working_memory_provenance_snapshot(agent_id, exported)
    assert WorkingMemoryStore.working_memory_provenance_snapshot?(exported)
    assert {:ok, false} = WorkingMemoryStore.agent_content_absent?(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.delete_working_memory(agent_id)

    assert :ok = WorkingMemoryStore.delete_agent_content(agent_id)
    assert :ok = WorkingMemoryStore.delete_agent_content(agent_id)
    assert {:ok, true} = WorkingMemoryStore.agent_content_absent?(agent_id)
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@working_memory_ets, agent_id)
    assert sidecar_inventory(agent_id) == sidecars_before
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp unique_agent(label), do: "wm_sec_#{label}_#{System.unique_integer([:positive])}"

  defp new_wm(agent_id), do: WorkingMemory.new(agent_id, rebuild_from_signals: false)

  defp put_thought(wm, id, content) do
    %{
      wm
      | recent_thoughts: [
          %{
            id: id,
            content: content,
            timestamp: @timestamp,
            cached_tokens: 1,
            referenced_date: nil
          }
        ]
    }
  end

  defp taint(level, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end

  defp save_raw(agent_id, wm), do: WorkingMemoryStore.save_working_memory(agent_id, wm)

  defp seed_legacy_raw!(agent_id, content) do
    legacy = %{
      "agent_id" => agent_id,
      "recent_thoughts" => [content],
      "active_goals" => [%{"description" => "legacy goal"}],
      "active_skills" => [%{"name" => "legacy skill", "body" => "legacy body"}],
      "concerns" => ["legacy concern"],
      "curiosity" => ["legacy curiosity"],
      "version" => 3
    }

    assert :ok = MemoryStore.persist(@namespace, agent_id, legacy)
    :ok
  end

  defp seed_legacy_wrapper!(agent_id, content) do
    label = taint(:derived, "legacy-wrapper")
    thought_id = "legacy-wrapper-thought"
    wm = put_thought(new_wm(agent_id), thought_id, content)

    payload =
      wm
      |> WorkingMemory.serialize()
      |> Map.drop(["concern_ids", "curiosity_ids"])

    thought_payload = Enum.find(payload["recent_thoughts"], &(&1["id"] == thought_id))
    base_payload = Map.drop(payload, ["recent_thoughts", "active_goals", "active_skills"])

    wrapper = %{
      "version" => 1,
      "payload" => payload,
      "provenance" => %{
        "base" => durable_entry(base_payload, label),
        "aggregate" => durable_entry(payload, label),
        "recent_thoughts" => %{thought_id => durable_entry(thought_payload, label)},
        "active_goals" => %{},
        "active_skills" => %{}
      }
    }

    assert :ok = MemoryStore.persist(@namespace, agent_id, wrapper, taint: label)
    :ok
  end

  defp durable_entry(payload, taint) do
    assert {:ok, envelope} = TaintEnvelope.new(payload, taint)
    assert {:ok, persisted} = TaintEnvelope.to_map(envelope)
    %{"envelope" => persisted, "status" => "verified"}
  end

  defp wrapper_version?(data, version) when is_map(data), do: data["version"] == version
  defp wrapper_version?(_data, _version), do: false

  defp durable_present?(agent_id) do
    match?(
      {:ok, _value, _status, _record, _location},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
    )
  end

  defp durable_absent?(agent_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
    )
  end

  defp durable_data!(agent_id) do
    {data, _revision, _bytes} = durable_bytes_and_revision!(agent_id)
    data
  end

  defp durable_bytes_and_revision!(agent_id) do
    assert {:ok, value, _status, record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)

    {value.value, record.revision, :erlang.term_to_binary(record.data)}
  end

  defp strip_projection!(agent_id) do
    _ = :ets.delete(@working_memory_ets, agent_id)

    Enum.each(@projection_domains, fn domain ->
      assert :ok = Provenance.delete_domain_agent(domain, agent_id)
    end)
  end

  defp sidecar_inventory(agent_id) do
    Map.new(@projection_domains, fn domain ->
      assert {:ok, ids} = Provenance.list_item_ids(domain, agent_id)
      {domain, Enum.sort(ids)}
    end)
  end

  defp empty_sidecar_inventory do
    Map.new(@projection_domains, fn domain -> {domain, []} end)
  end

  defp recent_wm_signals(agent_id) do
    case Signals.query_recent(agent_id, types: [:working_memory_saved, :working_memory_loaded]) do
      {:ok, signals} ->
        Enum.map(signals, fn signal -> {signal.type, signal.id} end)

      _ ->
        []
    end
  end

  defp assert_admission_gate! do
    canary = unique_agent("canary")
    wm = new_wm(canary)
    assert {:ok, _fence} = MutationAdmission.drain(canary)

    assert {:error, {:working_memory_store, :store_unavailable}} =
             WorkingMemoryStore.save_working_memory(canary, wm)
  end

  defp spawn_tracked(fun) when is_function(fun, 0) do
    track_process!(spawn(fun))
  end

  defp track_process!(pid) when is_pid(pid) do
    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    pid
  end

  defp hold_agent_lock!(agent_id) do
    parent = self()

    holder =
      spawn_tracked(fn ->
        lock_id = {{WorkingMemoryStore, agent_id}, self()}
        true = :global.set_lock(lock_id, [node()])
        send(parent, {:lock_held, self()})

        receive do
          :release_lock ->
            :global.del_lock(lock_id, [node()])
            send(parent, {:lock_released, self()})
        end
      end)

    assert_receive {:lock_held, ^holder}, 2_000
    holder
  end

  defp release_agent_lock!(holder) do
    send(holder, :release_lock)
    assert_receive {:lock_released, ^holder}, 2_000
  end

  defp await_root_visible!(agent_id) do
    assert wait_until(fn ->
             match?(
               {:ok, %{active_roots: n}} when n >= 1,
               MutationAdmission.status(agent_id)
             )
           end)
  end

  defp await_draining_with_root!(agent_id) do
    assert wait_until(fn ->
             match?(
               {:ok, %{gate: :draining, active_roots: n}} when n >= 1,
               MutationAdmission.status(agent_id)
             )
           end)
  end

  defp await_mut_and_drain! do
    mut_result = receive_tagged!(:mut_done)
    drain_result = receive_tagged!(:drain_done)
    {mut_result, drain_result}
  end

  defp receive_tagged!(tag) do
    receive do
      {^tag, result} -> result
    after
      10_000 -> flunk("missing #{inspect(tag)}")
    end
  end

  defp wait_until(fun, attempts \\ 80)
  defp wait_until(fun, 0), do: fun.() || flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        25 -> wait_until(fun, attempts - 1)
      end
    end
  end

  defp ensure_default_admission! do
    case MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      _ ->
        start_parent_admission_stack!()
    end
  end

  defp start_parent_admission_stack! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    unless Process.whereis(MutationAdmission) do
      start_supervised!(
        {MutationAdmission,
         [
           target: %{
             namespace: :memory_mutation_admission,
             backend: Fake,
             opts: [agent_name: @fake_name]
           }
         ]}
      )
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  defp ensure_working_memory_ets! do
    if :ets.whereis(@working_memory_ets) == :undefined do
      :ets.new(@working_memory_ets, [:named_table, :public, :set])
    end

    :ok
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end
end
