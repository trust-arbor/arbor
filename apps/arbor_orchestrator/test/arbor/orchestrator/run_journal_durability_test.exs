defmodule Arbor.Orchestrator.RunJournalDurabilityTest.ControllableStore do
  @moduledoc false
  use GenServer

  # Store contract: durability_class/1 only. Arity-0 is neither required nor used.
  def durability_class(_opts), do: :process_lifetime

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:put, key, value})
  end

  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:get, key})
  end

  def list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, :list)
  end

  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  def set_fail(name, fail?), do: GenServer.call(name, {:set_fail, fail?})

  @impl true
  def init(_opts), do: {:ok, %{data: %{}, fail?: false}}

  @impl true
  def handle_call({:set_fail, fail?}, _from, state), do: {:reply, :ok, %{state | fail?: fail?}}

  def handle_call({:put, _key, _value}, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_write_failure}, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.data, key) do
      {:ok, v} -> {:reply, {:ok, v}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_list_failure}, state}
  end

  def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

  def handle_call({:delete, _key}, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_delete_failure}, state}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
  end
end

defmodule Arbor.Orchestrator.RunJournalDurabilityTest do
  @moduledoc """
  Durability diagnostics + real restart proof for current-run lifecycle.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Adapter
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunJournalDurabilityTest.ControllableStore
  alias Arbor.Persistence.Store.ETS, as: StoreETS

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"rj_durable_store_#{suffix}"
    journal_name = :"rj_durable_journal_#{suffix}"
    ets_table = :"rj_durable_hot_#{suffix}"
    run_id = "durable_restart_#{suffix}"

    {:ok, _store} = start_supervised({StoreETS, name: store_name})

    {:ok, journal} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: StoreETS,
         store_name: store_name,
         start_store: false}
      )

    on_exit(fn ->
      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok,
     store_name: store_name,
     journal_name: journal_name,
     ets_table: ets_table,
     run_id: run_id,
     journal: journal}
  end

  test "durability_status reports non-durable for default ETS-only journal" do
    status = PipelineStatus.durability_status()
    assert status.durable == false
    assert status.mode in [:ets_only, :unavailable, :degraded]
  end

  test "isolated journal with ETS backend is honest about non-application durability", %{
    journal_name: j
  } do
    status = RunJournal.durability_status(server: j)
    # StoreETS is process-lifetime — never claim application-restart durability.
    assert status.durable == false
    assert status.durability_class in [:process_lifetime, :volatile]
    assert status.fenced_claim == false
    assert status.cross_node_atomic_recovery == false
    assert status.mode in [:backed_nondurable, :ets_only, :degraded]
  end

  test "private hot table rejects non-owner access", %{journal: journal, ets_table: ets_table} do
    assert :ets.info(ets_table, :owner) == journal
    assert :ets.info(ets_table, :protection) == :private

    parent = self()

    spawn(fn ->
      result =
        try do
          :ets.lookup(ets_table, "anything")
        rescue
          e -> {:error, e.__struct__}
        catch
          class, reason -> {class, reason}
        end

      send(parent, {:non_owner, result})
    end)

    assert_receive {:non_owner, result}, 1_000
    refute match?([_ | _], result)
    refute match?([], result)
  end

  test "durable payloads are JSON-clean, omit PIDs, and encode adversarial metadata" do
    record = %Record{
      run_id: "adv_meta",
      pipeline_id: "adv_meta",
      graph_id: "DurableGraph",
      status: :running,
      total_nodes: 3,
      completed_count: 1,
      current_node: "work",
      node_durations: %{
        "work" => 12,
        :atom_key => self(),
        "nested" => %{pid: self(), ref: make_ref(), fun: fn -> :ok end}
      },
      started_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now(),
      logs_root: "/tmp/durable_logs",
      graph_hash: "abc123",
      dot_source_path: "/tmp/graph.dot",
      spawning_pid: self(),
      origin_trust_zone: %{zone: :edge, tags: [:a, :b], nested: %{pid: self()}},
      failure_reason: {:engine_exception, "boom with atom and " <> inspect(self())}
    }

    assert {:ok, durable} = Adapter.to_durable_map(record)
    assert durable["run_id"] == "adv_meta"
    refute Map.has_key?(durable, "spawning_pid")

    assert is_map(durable["node_durations"])
    assert durable["node_durations"]["work"] == 12
    refute durable["node_durations"] |> inspect() =~ ~r/#PID<\d+\.\d+\.\d+>/

    assert {:ok, unknown} = Adapter.to_durable_map(%Record{record | status: :not_a_real_status})
    assert unknown["status"] == "unknown"

    assert {:ok, encoded} = Jason.encode(durable)
    refute encoded =~ ~r/#PID<\d+\.\d+\.\d+>/

    reloaded = Adapter.from_durable_map(durable)
    assert reloaded.spawning_pid == nil
    assert reloaded.status == :running
  end

  test "real restart reloads running record as interrupted without PID", ctx do
    %{
      journal_name: journal_name,
      store_name: store_name,
      ets_table: ets_table,
      run_id: run_id,
      journal: journal
    } = ctx

    now = DateTime.utc_now()

    record = %Record{
      run_id: run_id,
      pipeline_id: run_id,
      graph_id: "RestartGraph",
      status: :running,
      total_nodes: 4,
      completed_count: 2,
      current_node: "work",
      started_at: now,
      last_heartbeat: now,
      logs_root: "/tmp/restart_logs_#{run_id}",
      graph_hash: "hash_restart",
      dot_source_path: "/tmp/graph_restart.dot",
      spawning_pid: self(),
      owner_node: node()
    }

    assert :ok = RunJournal.put(record, server: journal_name)
    assert {:ok, hot} = RunJournal.get_record(run_id, server: journal_name)
    assert hot.status == :running
    assert is_pid(hot.spawning_pid)
    assert :ets.info(ets_table, :owner) == journal

    :ok = stop_supervised(journal_name)
    assert :ets.info(ets_table) == :undefined

    {:ok, _journal2} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: StoreETS,
         store_name: store_name,
         start_store: false}
      )

    assert {:ok, reloaded} = RunJournal.get_record(run_id, server: journal_name)
    assert reloaded.status == :interrupted
    assert reloaded.spawning_pid == nil
    assert reloaded.completed_count == 2
    assert reloaded.owner_node == nil
    # Path / hash / logs must survive restart rehydrate.
    assert reloaded.dot_source_path == "/tmp/graph_restart.dot"
    assert reloaded.graph_hash == "hash_restart"
    assert reloaded.logs_root == "/tmp/restart_logs_#{run_id}"
    # ETS backend is not application-restart durable by class.
    assert RunJournal.durability_status(server: journal_name).durable == false
  end

  test "backend write failure leaves prior hot record unchanged" do
    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"rj_fail_store_#{suffix}"
    journal_name = :"rj_fail_journal_#{suffix}"
    ets_table = :"rj_fail_hot_#{suffix}"
    run_id = "durable_fail_#{suffix}"

    {:ok, _} = start_supervised({ControllableStore, name: store_name})

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: ControllableStore,
         store_name: store_name,
         start_store: false}
      )

    seed = %Record{
      run_id: run_id,
      pipeline_id: run_id,
      status: :interrupted,
      total_nodes: 2,
      completed_count: 1,
      completed_nodes: ["start"],
      started_at: DateTime.utc_now(),
      owner_node: nil,
      source_node: node()
    }

    assert :ok = RunJournal.put(seed, server: journal_name)
    assert {:ok, before} = RunJournal.get_record(run_id, server: journal_name)
    assert before.status == :interrupted

    :ok = ControllableStore.set_fail(store_name, true)

    running = %Record{seed | status: :running, completed_count: 99, completed_nodes: ["x", "y"]}

    assert {:error, {:durable_write_failed, :injected_write_failure}} =
             RunJournal.put(running, server: journal_name)

    assert {:ok, after_fail} = RunJournal.get_record(run_id, server: journal_name)
    assert after_fail.status == :interrupted
    assert after_fail.completed_count == 1
    assert after_fail.completed_nodes == ["start"]

    status = RunJournal.durability_status(server: journal_name)
    assert status.mode == :degraded
    assert status.last_error == :injected_write_failure
  end

  test "claim_for_recovery fails closed on durable write failure and retries after recovery" do
    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"rj_claim_store_#{suffix}"
    journal_name = :"rj_claim_journal_#{suffix}"
    ets_table = :"rj_claim_hot_#{suffix}"
    run_id = "claim_fail_#{suffix}"

    {:ok, _} = start_supervised({ControllableStore, name: store_name})

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: ControllableStore,
         store_name: store_name,
         start_store: false}
      )

    seed = %Record{
      run_id: run_id,
      pipeline_id: run_id,
      status: :interrupted,
      total_nodes: 1,
      completed_count: 0,
      started_at: DateTime.utc_now(),
      owner_node: nil,
      source_node: node()
    }

    assert :ok = RunJournal.put(seed, server: journal_name)
    :ok = ControllableStore.set_fail(store_name, true)

    assert {:error, {:durable_write_failed, :injected_write_failure}} =
             RunJournal.claim_for_recovery(run_id, node(), server: journal_name)

    assert {:ok, still} = RunJournal.get_record(run_id, server: journal_name)
    assert still.status == :interrupted
    assert still.owner_node == nil

    :ok = ControllableStore.set_fail(store_name, false)

    assert {:ok, claimed} =
             RunJournal.claim_for_recovery(run_id, node(), server: journal_name)

    assert claimed.status == :recovering
    assert claimed.owner_node == node()
  end

  test "finalize is idempotent for same status and conflicts on different terminal", %{
    journal_name: j,
    run_id: run_id
  } do
    run_id = run_id <> "_fin"

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :running,
                 total_nodes: 3,
                 completed_count: 2,
                 completed_nodes: ["a", "b"],
                 node_durations: %{"a" => 1, "b" => 2},
                 started_at: DateTime.utc_now()
               },
               server: j
             )

    assert {:ok, :transitioned, rec1} =
             RunJournal.finalize(run_id, :failed, :boom, 50, %{}, server: j)

    assert rec1.status == :failed
    assert rec1.completed_count == 2
    assert rec1.completed_nodes == ["a", "b"]

    # Same terminal status → idempotent
    assert {:ok, :already_terminal, rec_same} =
             RunJournal.finalize(run_id, :failed, :boom, 50, %{}, server: j)

    assert rec_same.status == :failed

    # Different terminal status → typed conflict, no mutation
    assert {:error, {:terminal_conflict, :failed, :completed}} =
             RunJournal.finalize(run_id, :completed, nil, 99, %{}, server: j)

    assert {:ok, still} = RunJournal.get_record(run_id, server: j)
    assert still.status == :failed
    assert still.duration_ms == 50
  end

  test "journal-only restart does not invent interrupted rows without durable backend" do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"rj_ets_only_#{suffix}"
    ets_table = :"rj_ets_only_hot_#{suffix}"
    run_id = "ets_only_#{suffix}"

    {:ok, _j} =
      start_supervised({RunJournal, name: journal_name, ets_table: ets_table, backend: nil})

    :ok =
      RunJournal.put(
        %Record{
          run_id: run_id,
          pipeline_id: run_id,
          status: :running,
          total_nodes: 1,
          completed_count: 0,
          started_at: DateTime.utc_now(),
          spawning_pid: self()
        },
        server: journal_name
      )

    :ok = stop_supervised(journal_name)
    assert :ets.info(ets_table) == :undefined

    {:ok, _} =
      start_supervised({RunJournal, name: journal_name, ets_table: ets_table, backend: nil})

    assert {:error, :not_found} = RunJournal.get_record(run_id, server: journal_name)
    assert RunJournal.durability_status(server: journal_name).mode == :ets_only
  end

  test "get_record distinguishes not_found from journal unavailable", %{journal_name: j} do
    assert {:error, :not_found} =
             RunJournal.get_record("no_such_run_#{System.unique_integer([:positive])}",
               server: j
             )

    assert {:error, :journal_unavailable} =
             RunJournal.get_record("x", server: :definitely_missing_run_journal_process)
  end

  test "configured backend that cannot be observed fails journal startup closed" do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"rj_missing_backend_#{suffix}"
    ets_table = :"rj_missing_backend_hot_#{suffix}"
    store_name = :"rj_missing_backend_store_#{suffix}"

    result =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: StoreETS,
         store_name: store_name,
         start_store: false}
      )

    # start_supervised wraps the GenServer {:stop, reason} as {:error, {reason, child_spec}}
    assert match?(
             {:error, {{:durable_backend_not_ready, StoreETS, ^store_name, _}, _}},
             result
           ) or
             match?(
               {:error, {:durable_backend_not_ready, StoreETS, ^store_name, _}},
               result
             )
  end

  test "restart rehydrates recovering/running/suspended as claimable interrupted", ctx do
    %{
      journal_name: journal_name,
      store_name: store_name,
      ets_table: ets_table
    } = ctx

    now = DateTime.utc_now()

    for {run_id, status} <- [
          {"rehydrate_recovering_#{System.unique_integer([:positive])}", :recovering},
          {"rehydrate_running_#{System.unique_integer([:positive])}", :running},
          {"rehydrate_suspended_#{System.unique_integer([:positive])}", :suspended},
          {"rehydrate_degraded_#{System.unique_integer([:positive])}", :degraded},
          {"rehydrate_delegated_#{System.unique_integer([:positive])}", :delegated}
        ] do
      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: status,
                   total_nodes: 2,
                   completed_count: 1,
                   completed_nodes: ["start"],
                   current_node: "work",
                   started_at: now,
                   owner_node: node(),
                   spawning_pid: self()
                 },
                 server: journal_name
               )
    end

    :ok = stop_supervised(journal_name)
    assert :ets.info(ets_table) == :undefined

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: StoreETS,
         store_name: store_name,
         start_store: false}
      )

    {:ok, records} = RunJournal.list_records(server: journal_name)

    for record <- records do
      if String.starts_with?(record.run_id, "rehydrate_") do
        assert record.status == :interrupted,
               "expected interrupted, got #{record.status} for #{record.run_id}"

        assert record.spawning_pid == nil
        assert record.owner_node == nil
        assert record.current_node == nil

        assert {:ok, claimed} =
                 RunJournal.claim_for_recovery(record.run_id, node(), server: journal_name)

        assert claimed.status == :recovering
      end
    end
  end

  test "equal completed_count merges richer nodes and durations", %{journal_name: j} do
    run_id = "progress_merge_#{System.unique_integer([:positive])}"

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :running,
                 total_nodes: 4,
                 completed_count: 2,
                 completed_nodes: ["a"],
                 node_durations: %{"a" => 10, "b" => 5},
                 started_at: DateTime.utc_now()
               },
               server: j
             )

    # Same count, richer nodes + overlapping duration that should max-merge
    rs = %Arbor.Orchestrator.RunState.Core{
      run_id: run_id,
      pipeline_id: run_id,
      graph_id: "g",
      status: :running,
      total_nodes: 4,
      completed_count: 2,
      completed_nodes: ["b", "a"],
      node_durations: %{"a" => 3, "c" => 7},
      current_node: "c",
      started_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now(),
      last_ets_sync: DateTime.utc_now(),
      owner_node: node(),
      source_node: node()
    }

    assert :ok = RunJournal.put_run_state(rs, %{}, server: j)
    assert {:ok, merged} = RunJournal.get_record(run_id, server: j)
    assert merged.completed_count >= 2
    assert "a" in merged.completed_nodes
    assert "b" in merged.completed_nodes
    assert merged.node_durations["a"] == 10
    assert merged.node_durations["b"] == 5
    assert merged.node_durations["c"] == 7
  end

  test "adversarial metadata is bounded Jason-encodable durable output" do
    huge = String.duplicate("x", 50_000)
    deep = Enum.reduce(1..20, huge, fn _, acc -> %{"n" => acc, "p" => self()} end)

    record = %Record{
      run_id: "bound_#{System.unique_integer([:positive])}",
      pipeline_id: "bound",
      status: :failed,
      total_nodes: 1,
      completed_count: 0,
      completed_nodes: Enum.map(1..500, &"node_#{&1}"),
      node_durations:
        Map.new(1..500, fn i -> {"n_#{i}", i} end)
        |> Map.put("deep", deep),
      failure_reason: {:engine_exception, huge <> inspect(self()) <> inspect(make_ref())},
      origin_trust_zone: deep,
      started_at: DateTime.utc_now()
    }

    assert {:ok, durable} = Adapter.to_durable_map(record)
    assert {:ok, encoded} = Jason.encode(durable)
    assert byte_size(encoded) <= 8_192
    refute encoded =~ ~r/#PID<\d+\.\d+\.\d+>/
    refute encoded =~ ~r/#Reference</

    public = Adapter.to_public_map(record)
    fr = public.failure_reason

    assert fr == nil or is_atom(fr) or is_binary(fr) or is_tuple(fr)

    if is_binary(fr) do
      assert byte_size(fr) <= 512
    end
  end

  test "durable delete failure leaves hot record and returns explicit error" do
    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"rj_del_store_#{suffix}"
    journal_name = :"rj_del_journal_#{suffix}"
    ets_table = :"rj_del_hot_#{suffix}"
    run_id = "del_fail_#{suffix}"

    {:ok, _} = start_supervised({ControllableStore, name: store_name})

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: ControllableStore,
         store_name: store_name,
         start_store: false}
      )

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 total_nodes: 1,
                 completed_count: 0,
                 started_at: DateTime.utc_now(),
                 source_node: node()
               },
               server: journal_name
             )

    :ok = ControllableStore.set_fail(store_name, true)

    assert {:error, {:durable_delete_failed, :injected_delete_failure}} =
             RunJournal.delete(run_id, server: journal_name)

    assert {:ok, still} = RunJournal.get_record(run_id, server: journal_name)
    assert still.status == :interrupted

    :ok = ControllableStore.set_fail(store_name, false)
    assert :ok = RunJournal.delete(run_id, server: journal_name)
    assert {:error, :not_found} = RunJournal.get_record(run_id, server: journal_name)
  end

  test "list_records surfaces journal unavailability distinctly from empty" do
    assert {:error, :journal_unavailable} =
             RunJournal.list_records(server: :no_such_run_journal_for_list)
  end

  test "nil put_run_state meta does not erase retained path/hash/logs", %{journal_name: j} do
    run_id = "meta_preserve_#{System.unique_integer([:positive])}"

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :running,
                 total_nodes: 2,
                 completed_count: 1,
                 completed_nodes: ["start"],
                 started_at: DateTime.utc_now(),
                 graph_hash: "keep_hash",
                 dot_source_path: "/tmp/keep.dot",
                 logs_root: "/tmp/keep_logs",
                 owner_node: node(),
                 source_node: node()
               },
               server: j
             )

    rs = %Arbor.Orchestrator.RunState.Core{
      run_id: run_id,
      pipeline_id: run_id,
      graph_id: "g",
      status: :running,
      total_nodes: 2,
      completed_count: 1,
      completed_nodes: ["start"],
      node_durations: %{},
      current_node: "work",
      started_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now(),
      last_ets_sync: DateTime.utc_now(),
      owner_node: node(),
      source_node: node()
    }

    # Explicit nil meta values must not wipe recovery pointers.
    assert :ok =
             RunJournal.put_run_state(
               rs,
               %{
                 graph_hash: nil,
                 dot_source_path: nil,
                 logs_root: nil
               },
               server: j
             )

    assert {:ok, kept} = RunJournal.get_record(run_id, server: j)
    assert kept.graph_hash == "keep_hash"
    assert kept.dot_source_path == "/tmp/keep.dot"
    assert kept.logs_root == "/tmp/keep_logs"
  end

  test "boot does not rewrite remote-owned in-flight rows", ctx do
    %{
      journal_name: journal_name,
      store_name: store_name,
      ets_table: ets_table
    } = ctx

    run_id = "remote_owned_#{System.unique_integer([:positive])}"

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :running,
                 total_nodes: 2,
                 completed_count: 1,
                 completed_nodes: ["start"],
                 started_at: DateTime.utc_now(),
                 owner_node: :peer@remote,
                 source_node: :peer@remote,
                 spawning_pid: self()
               },
               server: journal_name
             )

    :ok = stop_supervised(journal_name)

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: StoreETS,
         store_name: store_name,
         start_store: false}
      )

    assert {:ok, remote} = RunJournal.get_record(run_id, server: journal_name)
    # Still running — not rewritten to interrupted for remote ownership.
    assert remote.status == :running
    assert to_string(remote.owner_node) == "peer@remote"
    assert to_string(remote.source_node) == "peer@remote"
    assert remote.spawning_pid == nil

    # Claim fails closed until L4 fencing.
    assert {:error, reason} =
             RunJournal.claim_for_recovery(run_id, node(), server: journal_name)

    assert reason in [
             :remote_or_foreign_claim,
             {:invalid_status, :running},
             :ambiguous_remote_row
           ]
  end

  test "direct put(%Record{}) normalizes and bounds payload", %{journal_name: j} do
    huge = String.duplicate("x", 20_000)

    run_id = "direct_put_#{System.unique_integer([:positive])}"

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :failed,
                 total_nodes: 1,
                 completed_count: 0,
                 completed_nodes: Enum.map(1..400, &"n#{&1}"),
                 failure_reason: huge,
                 graph_hash: "abc123",
                 started_at: DateTime.utc_now()
               },
               server: j
             )

    assert {:ok, stored} = RunJournal.get_record(run_id, server: j)
    assert length(stored.completed_nodes) <= 256
    assert stored.graph_hash == "abc123"

    if is_binary(stored.failure_reason) do
      assert byte_size(stored.failure_reason) <= 512
    end

    assert {:ok, durable} = Adapter.to_durable_map(stored)
    assert {:ok, encoded} = Jason.encode(durable)
    assert byte_size(encoded) <= 8_192
    assert durable["graph_hash"] == "abc123"
  end

  test "direct put rejects invalid identity and recovery pointers", %{journal_name: j} do
    run_id = "id_reject_#{System.unique_integer([:positive])}"

    assert {:error, {:invalid_lifecycle_identity, :run_id, :empty}} =
             RunJournal.put(
               %Record{
                 run_id: "",
                 pipeline_id: "x",
                 status: :running,
                 started_at: DateTime.utc_now()
               },
               server: j
             )

    assert {:error, {:invalid_recovery_pointer, :graph_hash, :invalid_utf8}} =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :running,
                 graph_hash: <<0xFF, 0xFE>>,
                 started_at: DateTime.utc_now()
               },
               server: j
             )

    assert {:error, {:invalid_recovery_pointer, :logs_root, :oversized}} =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :running,
                 logs_root: String.duplicate("p", 2_000),
                 started_at: DateTime.utc_now()
               },
               server: j
             )

    assert {:error, :not_found} = RunJournal.get_record(run_id, server: j)
  end

  test "backed store rejects claim on owner/source-ambiguous rows", %{journal_name: j} do
    run_id = "ambig_claim_#{System.unique_integer([:positive])}"

    assert :ok =
             RunJournal.put(
               %Record{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 started_at: DateTime.utc_now(),
                 owner_node: nil,
                 source_node: nil
               },
               server: j
             )

    assert {:error, :ambiguous_remote_row} =
             RunJournal.claim_for_recovery(run_id, node(), server: j)
  end

  test "adversarial bounds: huge lists, tuples, bignums, improper lists, invalid utf8" do
    huge_list = Enum.to_list(1..100_000)
    improper = [1, 2 | :tail]
    huge_tuple = List.to_tuple(Enum.to_list(1..10_000))
    bignum = 2 ** 200
    invalid = <<0xFF, 0xFE, 0xFD>>

    record = %Record{
      run_id: "adv_bounds",
      pipeline_id: "adv_bounds",
      status: :failed,
      total_nodes: bignum,
      completed_count: 1,
      completed_nodes: Enum.map(huge_list, &"n_#{&1}"),
      node_durations: Map.new(1..1_000, fn i -> {"k#{i}", bignum} end),
      failure_reason: {huge_tuple, improper, bignum, invalid, huge_list},
      origin_trust_zone: %{deep: %{a: %{b: %{c: %{d: huge_list}}}}},
      started_at: DateTime.utc_now()
    }

    assert {:ok, durable} = Adapter.to_durable_map(record)
    assert {:ok, encoded} = Jason.encode(durable)
    assert byte_size(encoded) <= 8_192
    assert durable["run_id"] == "adv_bounds"
    assert is_integer(durable["total_nodes"])
    assert durable["total_nodes"] <= 9_223_372_036_854_775_807
    assert length(durable["completed_nodes"]) <= 256
  end

  test "durability_status never claims durable for default ETS-only or ControllableStore" do
    status = PipelineStatus.durability_status()
    assert status.durable == false

    assert status.durability_class in [:volatile, :process_lifetime, nil] or
             is_atom(status.durability_class)

    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"rj_class_store_#{suffix}"
    journal_name = :"rj_class_journal_#{suffix}"
    ets_table = :"rj_class_hot_#{suffix}"

    {:ok, _} = start_supervised({ControllableStore, name: store_name})

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: ControllableStore,
         store_name: store_name,
         start_store: false}
      )

    st = RunJournal.durability_status(server: journal_name)
    assert st.durable == false
    assert st.durability_class == :process_lifetime
    assert st.fenced_claim == false
  end

  describe "durability_class ceiling/intersection table" do
    # Code-owned capability via durability_class/1; configured :durability_class
    # is a ceiling only — never elevation. Order:
    # volatile < process_lifetime < application_restart < node_restart

    defmodule CapabilityStore do
      @moduledoc false
      use GenServer

      def start_link(opts) do
        name = Keyword.fetch!(opts, :name)
        class = Keyword.get(opts, :class, :process_lifetime)
        GenServer.start_link(__MODULE__, class, name: name)
      end

      def durability_class(opts) do
        name = Keyword.fetch!(opts, :name)
        GenServer.call(name, :durability_class)
      end

      def put(key, value, opts) do
        GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
      end

      def get(key, opts) do
        GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
      end

      def list(opts) do
        GenServer.call(Keyword.fetch!(opts, :name), :list)
      end

      def delete(key, opts) do
        GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
      end

      @impl true
      def init(class), do: {:ok, %{class: class, data: %{}}}

      @impl true
      def handle_call(:durability_class, _from, state), do: {:reply, state.class, state}

      def handle_call({:put, key, value}, _from, state) do
        {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
      end

      def handle_call({:get, key}, _from, state) do
        case Map.fetch(state.data, key) do
          {:ok, v} -> {:reply, {:ok, v}, state}
          :error -> {:reply, {:error, :not_found}, state}
        end
      end

      def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

      def handle_call({:delete, key}, _from, state) do
        {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
      end
    end

    defmodule ArityZeroOnlyStore do
      @moduledoc false
      # Proves arity-0 durability_class is neither required nor used.
      use GenServer

      def durability_class, do: :node_restart

      def start_link(opts) do
        name = Keyword.fetch!(opts, :name)
        GenServer.start_link(__MODULE__, %{}, name: name)
      end

      def put(key, value, opts) do
        GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
      end

      def get(key, opts) do
        GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
      end

      def list(opts) do
        GenServer.call(Keyword.fetch!(opts, :name), :list)
      end

      def delete(key, opts) do
        GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
      end

      @impl true
      def init(_), do: {:ok, %{data: %{}}}

      @impl true
      def handle_call({:put, key, value}, _from, state) do
        {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
      end

      def handle_call({:get, key}, _from, state) do
        case Map.fetch(state.data, key) do
          {:ok, v} -> {:reply, {:ok, v}, state}
          :error -> {:reply, {:error, :not_found}, state}
        end
      end

      def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

      def handle_call({:delete, key}, _from, state) do
        {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
      end
    end

    defp start_class_journal(backend, store_opts, journal_opts) do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rj_cap_store_#{suffix}"
      journal_name = :"rj_cap_journal_#{suffix}"
      ets_table = :"rj_cap_hot_#{suffix}"

      # Unique child ids — module-default id collides when starting multiple
      # CapabilityStore fixtures in one test.
      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {backend, :start_link, [Keyword.put(store_opts, :name, store_name)]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: ets_table,
                 backend: backend,
                 store_name: store_name,
                 start_store: false
               ] ++ journal_opts
             ]}
        })

      {journal_name, store_name}
    end

    test "no configured ceiling uses backend capability" do
      {j, _} = start_class_journal(CapabilityStore, [class: :node_restart], [])
      assert RunJournal.durability_status(server: j).durability_class == :node_restart

      {j2, _} = start_class_journal(CapabilityStore, [class: :application_restart], [])
      assert RunJournal.durability_status(server: j2).durability_class == :application_restart
    end

    test "lower ceiling lowers effective class" do
      {j, _} =
        start_class_journal(CapabilityStore, [class: :node_restart],
          durability_class: :application_restart
        )

      assert RunJournal.durability_status(server: j).durability_class == :application_restart

      {j2, _} =
        start_class_journal(CapabilityStore, [class: :node_restart],
          durability_class: :process_lifetime
        )

      st = RunJournal.durability_status(server: j2)
      assert st.durability_class == :process_lifetime
      assert st.durable == false
    end

    test "higher ceiling cannot elevate backend capability" do
      {j, _} =
        start_class_journal(CapabilityStore, [class: :process_lifetime],
          durability_class: :node_restart
        )

      st = RunJournal.durability_status(server: j)
      assert st.durability_class == :process_lifetime
      assert st.durable == false

      {j2, _} =
        start_class_journal(CapabilityStore, [class: :application_restart],
          durability_class: :node_restart
        )

      assert RunJournal.durability_status(server: j2).durability_class == :application_restart
    end

    test "unsupported or invalid capability fails closed to process_lifetime" do
      # ControllableStore has durability_class/1 → process_lifetime; ceiling
      # cannot raise it.
      {j, _} =
        start_class_journal(ControllableStore, [], durability_class: :node_restart)

      assert RunJournal.durability_status(server: j).durability_class == :process_lifetime

      # Arity-0 only → Persistence.supports_durability_class? is false → process_lifetime
      {j2, _} =
        start_class_journal(ArityZeroOnlyStore, [], durability_class: :node_restart)

      st = RunJournal.durability_status(server: j2)
      assert st.durability_class == :process_lifetime
      assert st.durable == false
      refute function_exported?(ArityZeroOnlyStore, :durability_class, 1)
      assert function_exported?(ArityZeroOnlyStore, :durability_class, 0)

      # Invalid declared capability value
      {j3, _} = start_class_journal(CapabilityStore, [class: :not_a_class], [])
      assert RunJournal.durability_status(server: j3).durability_class == :process_lifetime
    end

    test "explicit :volatile capability is preserved; ceiling may only lower" do
      # No ceiling — preserve code-owned :volatile exactly.
      {j, _} = start_class_journal(CapabilityStore, [class: :volatile], [])
      st = RunJournal.durability_status(server: j)
      assert st.durability_class == :volatile
      assert st.durable == false

      # Equal ceiling leaves capability unchanged.
      {j_eq, _} =
        start_class_journal(CapabilityStore, [class: :volatile], durability_class: :volatile)

      assert RunJournal.durability_status(server: j_eq).durability_class == :volatile

      # Higher ceiling cannot elevate :volatile.
      {j_hi, _} =
        start_class_journal(CapabilityStore, [class: :volatile], durability_class: :node_restart)

      st_hi = RunJournal.durability_status(server: j_hi)
      assert st_hi.durability_class == :volatile
      assert st_hi.durable == false

      # Lower/equal relative to a higher capability still works with volatile
      # as the lower bound of the ordering.
      {j_pl, _} =
        start_class_journal(CapabilityStore, [class: :process_lifetime],
          durability_class: :volatile
        )

      assert RunJournal.durability_status(server: j_pl).durability_class == :volatile
    end

    test "nil backend is volatile; ETS-only journal is not crash-durable" do
      suffix = System.unique_integer([:positive, :monotonic])
      journal_name = :"rj_vol_journal_#{suffix}"
      ets_table = :"rj_vol_hot_#{suffix}"

      {:ok, _} =
        start_supervised({RunJournal, name: journal_name, ets_table: ets_table, backend: nil})

      st = RunJournal.durability_status(server: journal_name)
      assert st.durability_class == :volatile
      assert st.durable == false
    end
  end

  describe "backend_opts reach every Persistence facade op" do
    defmodule SentinelOptsStore do
      @moduledoc false
      use GenServer

      @sentinel_key :opts_sentinel
      @sentinel_value :backend_opts_required

      def durability_class(opts) do
        require_sentinel!(opts)
        :process_lifetime
      end

      def start_link(opts) do
        name = Keyword.fetch!(opts, :name)
        GenServer.start_link(__MODULE__, %{}, name: name)
      end

      def put(key, value, opts) do
        require_sentinel!(opts)
        GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
      end

      def get(key, opts) do
        require_sentinel!(opts)
        GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
      end

      def list(opts) do
        require_sentinel!(opts)
        GenServer.call(Keyword.fetch!(opts, :name), :list)
      end

      def delete(key, opts) do
        require_sentinel!(opts)
        GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
      end

      @impl true
      def init(_), do: {:ok, %{data: %{}}}

      @impl true
      def handle_call({:put, key, value}, _from, state) do
        {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
      end

      def handle_call({:get, key}, _from, state) do
        case Map.fetch(state.data, key) do
          {:ok, v} -> {:reply, {:ok, v}, state}
          :error -> {:reply, {:error, :not_found}, state}
        end
      end

      def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

      def handle_call({:delete, key}, _from, state) do
        {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
      end

      defp require_sentinel!(opts) do
        unless Keyword.get(opts, @sentinel_key) == @sentinel_value do
          raise ArgumentError,
                "backend_opts sentinel missing or wrong: got #{inspect(Keyword.get(opts, @sentinel_key))}"
        end

        :ok
      end
    end

    test "sentinel backend_opts are required on class/list/get/put/delete and restart" do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rj_sent_store_#{suffix}"
      journal_name = :"rj_sent_journal_#{suffix}"
      ets_table = :"rj_sent_hot_#{suffix}"
      run_id = "sentinel_run_#{suffix}"
      backend_opts = [opts_sentinel: :backend_opts_required]

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {SentinelOptsStore, :start_link, [[name: store_name]]}
        })

      # Missing sentinel fails closed during init (durability_class and/or list probe).
      assert {:error, _reason} =
               start_supervised(%{
                 id: :"#{journal_name}_bad",
                 start:
                   {RunJournal, :start_link,
                    [
                      [
                        name: :"#{journal_name}_bad",
                        ets_table: :"#{ets_table}_bad",
                        backend: SentinelOptsStore,
                        store_name: store_name,
                        start_store: false
                      ]
                    ]}
               })

      {:ok, journal} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: ets_table,
                 backend: SentinelOptsStore,
                 store_name: store_name,
                 start_store: false,
                 backend_opts: backend_opts
               ]
             ]}
        })

      # durability_class/1 already ran with sentinel during init.
      st = RunJournal.durability_status(server: journal_name)
      assert st.durability_class == :process_lifetime
      assert st.durable == false

      now = DateTime.utc_now()

      record = %Record{
        run_id: run_id,
        pipeline_id: run_id,
        status: :running,
        started_at: now,
        last_heartbeat: now,
        owner_node: node(),
        execution_principal: "agent_sentinel_#{suffix}"
      }

      # put through Persistence facade with backend_opts
      assert :ok = RunJournal.put(record, server: journal_name)

      assert {:ok, %Record{status: :running}} =
               RunJournal.get_record(run_id, server: journal_name)

      # delete uses Persistence.delete with backend_opts
      assert :ok = RunJournal.delete(run_id, server: journal_name)
      assert {:error, :not_found} = RunJournal.get_record(run_id, server: journal_name)

      # Re-put for rehydrate proof
      assert :ok = RunJournal.put(record, server: journal_name)

      :ok = stop_supervised(journal_name)
      assert :ets.info(ets_table) == :undefined

      # Restart rehydrates via list + get with the same backend_opts.
      {:ok, _journal2} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: ets_table,
                 backend: SentinelOptsStore,
                 store_name: store_name,
                 start_store: false,
                 backend_opts: backend_opts
               ]
             ]}
        })

      assert {:ok, %Record{run_id: ^run_id, status: :interrupted}} =
               RunJournal.get_record(run_id, server: journal_name)

      # Keep dialyzer/unused quiet if stop was partial
      _ = journal
    end
  end
end
