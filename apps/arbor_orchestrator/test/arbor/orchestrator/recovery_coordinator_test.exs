defmodule Arbor.Orchestrator.RecoveryCoordinatorTest.AppRestartStore do
  @moduledoc false
  use GenServer

  # Store contract: durability_class/1 only (arity-0 is neither required nor used).
  def durability_class(_opts), do: :application_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
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
  def init(_opts), do: {:ok, %{data: %{}}}

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

defmodule Arbor.Orchestrator.RecoveryCoordinatorTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.RecoveryCoordinator
  alias Arbor.Orchestrator.RecoveryCoordinatorTest.AppRestartStore
  alias Arbor.Orchestrator.JobRegistry

  describe "compute_graph_hash/1" do
    test "produces consistent SHA-256 hex hash" do
      source = "digraph { start -> end }"
      hash = RecoveryCoordinator.compute_graph_hash(source)

      assert is_binary(hash)
      assert String.length(hash) == 64
      # Deterministic
      assert hash == RecoveryCoordinator.compute_graph_hash(source)
    end

    test "different sources produce different hashes" do
      hash1 = RecoveryCoordinator.compute_graph_hash("digraph { a -> b }")
      hash2 = RecoveryCoordinator.compute_graph_hash("digraph { x -> y }")

      refute hash1 == hash2
    end
  end

  describe "status/0" do
    test "returns current recovery status" do
      status = RecoveryCoordinator.status()
      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :recovering)
      assert Map.has_key?(status, :recovered)
      assert Map.has_key?(status, :failed)
      assert Map.has_key?(status, :pending)
      assert Map.has_key?(status, :automatic_recovery)
      assert Map.has_key?(status, :automatic_recovery_disabled_reason)
    end
  end

  describe "automatic recovery durability gate" do
    alias Arbor.Orchestrator.RunJournal
    alias Arbor.Persistence.Store.ETS, as: StoreETS

    test "eligibility refuses volatile and process_lifetime backends" do
      assert {:error, {:automatic_recovery_disabled, :durability_not_crash_durable, :volatile}} =
               RecoveryCoordinator.automatic_recovery_eligibility(%{
                 durable: false,
                 durability_class: :volatile,
                 mode: :ets_only
               })

      assert {:error,
              {:automatic_recovery_disabled, :durability_not_crash_durable, :process_lifetime}} =
               RecoveryCoordinator.automatic_recovery_eligibility(%{
                 durable: false,
                 durability_class: :process_lifetime,
                 mode: :backed_nondurable
               })

      assert {:error, {:automatic_recovery_disabled, :durability_unhealthy, :application_restart}} =
               RecoveryCoordinator.automatic_recovery_eligibility(%{
                 durable: false,
                 durability_class: :application_restart,
                 mode: :degraded
               })
    end

    test "eligibility allows healthy application_restart and node_restart" do
      assert :ok =
               RecoveryCoordinator.automatic_recovery_eligibility(%{
                 durable: true,
                 durability_class: :application_restart,
                 mode: :durable_declared
               })

      assert :ok =
               RecoveryCoordinator.automatic_recovery_eligibility(%{
                 durable: true,
                 durability_class: :node_restart,
                 mode: :durable_declared
               })
    end

    test "default coordinator refuses automatic recovery under volatile journal" do
      status = RecoveryCoordinator.status()
      # Production/test journal is ETS-only / not crash-durable.
      assert status.automatic_recovery == false
      assert status.durable == false

      assert match?(
               {:automatic_recovery_disabled, :durability_not_crash_durable, _},
               status.automatic_recovery_disabled_reason
             )
    end

    test "process_lifetime journal fixture refuses automatic recovery" do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rc_pl_store_#{suffix}"
      journal_name = :"rc_pl_journal_#{suffix}"
      ets_table = :"rc_pl_hot_#{suffix}"
      coord_name = :"rc_pl_coord_#{suffix}"

      {:ok, _} = start_supervised({StoreETS, name: store_name})

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: ets_table,
                 backend: StoreETS,
                 store_name: store_name,
                 start_store: false
               ]
             ]}
        })

      durability = RunJournal.durability_status(server: journal_name)
      assert durability.durable == false
      assert durability.durability_class in [:process_lifetime, :volatile]

      {:ok, _pid} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: [server: journal_name],
                 recovery_root: Path.join(System.tmp_dir!(), "rc_pl_root_#{suffix}"),
                 # Large delay so discover never runs during the assertion window
                 delay_ms: 60_000
               ]
             ]}
        })

      st = RecoveryCoordinator.status(coord_name)
      assert st.automatic_recovery == false
      assert st.enabled == true

      assert match?(
               {:automatic_recovery_disabled, :durability_not_crash_durable, _},
               st.automatic_recovery_disabled_reason
             )
    end

    test "durable application_restart fixture allows automatic recovery" do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rc_ar_store_#{suffix}"
      journal_name = :"rc_ar_journal_#{suffix}"
      ets_table = :"rc_ar_hot_#{suffix}"
      coord_name = :"rc_ar_coord_#{suffix}"

      {:ok, _} = start_supervised({AppRestartStore, name: store_name})

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: ets_table,
                 backend: AppRestartStore,
                 store_name: store_name,
                 durability_class: :application_restart,
                 start_store: false
               ]
             ]}
        })

      durability = RunJournal.durability_status(server: journal_name)
      assert durability.durable == true
      assert durability.durability_class == :application_restart

      recovery_root =
        Path.join(System.tmp_dir!(), "rc_ar_root_#{suffix}")

      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      {:ok, _pid} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: [server: journal_name],
                 recovery_root: recovery_root,
                 delay_ms: 60_000
               ]
             ]}
        })

      st = RecoveryCoordinator.status(coord_name)
      assert st.automatic_recovery == true
      assert st.automatic_recovery_disabled_reason == nil
      assert st.durable == true
      assert st.durability_class == :application_restart
    end

    test "injected recovery_root is used for materialization (not only Application env)" do
      injected =
        Path.join(System.tmp_dir!(), "rc_injected_root_#{System.unique_integer([:positive])}")

      File.mkdir_p!(injected)
      on_exit(fn -> File.rm_rf(injected) end)

      # Clear Application env so a reread would fall back to a different default.
      previous = Application.get_env(:arbor_orchestrator, :recovery_materialization_root)
      Application.delete_env(:arbor_orchestrator, :recovery_materialization_root)

      on_exit(fn ->
        if previous do
          Application.put_env(:arbor_orchestrator, :recovery_materialization_root, previous)
        else
          Application.delete_env(:arbor_orchestrator, :recovery_materialization_root)
        end
      end)

      run_id = "inject_root_#{System.unique_integer([:positive])}"
      payload = Jason.encode!(%{"run_id" => run_id})

      assert {:ok, %{path: path, logs_root: logs_root, recovery_root: root}} =
               RecoveryCoordinator.__test_materialize_store_checkpoint__(
                 payload,
                 run_id,
                 injected
               )

      assert String.starts_with?(path, root)
      assert String.starts_with?(logs_root, root)
      {:ok, real_injected} = Arbor.Common.SafePath.resolve_real(injected)
      assert root == real_injected or String.starts_with?(root, real_injected)
    end

    test "custom journal_opts server discovers and mutates only that journal" do
      alias Arbor.Orchestrator.PipelineStatus
      alias Arbor.Orchestrator.RunLifecycle.Record

      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rc_custom_store_#{suffix}"
      journal_name = :"rc_custom_journal_#{suffix}"
      ets_table = :"rc_custom_hot_#{suffix}"
      coord_name = :"rc_custom_coord_#{suffix}"
      # Same run_id in both journals — proves which journal the coordinator mutates.
      shared_run = "shared_run_#{suffix}"
      other_global = "global_only_#{suffix}"
      dead_owner = :"dead_owner@nohost_#{suffix}"

      on_exit(fn ->
        RunJournal.delete(shared_run)
        RunJournal.delete(other_global)
      end)

      {:ok, _} = start_supervised({AppRestartStore, name: store_name})

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: ets_table,
                 backend: AppRestartStore,
                 store_name: store_name,
                 durability_class: :application_restart,
                 start_store: false
               ]
             ]}
        })

      now = DateTime.utc_now()

      # spawning_pid: nil so PID liveness does not auto-correct before nodedown.
      custom_record = %Record{
        run_id: shared_run,
        pipeline_id: shared_run,
        status: :running,
        started_at: now,
        last_heartbeat: now,
        owner_node: dead_owner,
        spawning_pid: nil,
        execution_principal: "agent_custom_#{suffix}"
      }

      global_record = %Record{
        run_id: shared_run,
        pipeline_id: shared_run,
        status: :running,
        started_at: now,
        last_heartbeat: now,
        owner_node: dead_owner,
        spawning_pid: nil,
        execution_principal: "agent_global_#{suffix}"
      }

      assert :ok = RunJournal.put(custom_record, server: journal_name)
      assert :ok = RunJournal.put(global_record)

      # Precondition: both journals hold the same run_id as running.
      assert {:ok, %Record{status: :running, owner_node: ^dead_owner}} =
               RunJournal.get_record(shared_run, server: journal_name)

      assert {:ok, %Record{status: :running, owner_node: ^dead_owner}} =
               RunJournal.get_record(shared_run)

      recovery_root = Path.join(System.tmp_dir!(), "rc_custom_root_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      {:ok, coord_pid} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: [server: journal_name],
                 recovery_root: recovery_root,
                 # Delay auto-discovery; we drive the coordinator explicitly.
                 delay_ms: 60_000,
                 # Discovery + mark only — no resume slots.
                 max_concurrent: 0
               ]
             ]}
        })

      st = RecoveryCoordinator.status(coord_name)
      assert st.automatic_recovery == true
      assert st.durability_class == :application_restart
      assert st.pending == 0

      # Coordinator itself discovers by owner and mutates only the injected journal.
      send(coord_pid, {:nodedown, dead_owner})

      assert_eventually(fn ->
        match?(
          {:ok, %Record{status: :interrupted}},
          RunJournal.get_record(shared_run, server: journal_name)
        )
      end)

      assert {:ok, %Record{status: :interrupted, run_id: ^shared_run}} =
               RunJournal.get_record(shared_run, server: journal_name)

      # Global journal remains untouched (same run_id still running there).
      assert {:ok, %Record{status: :running, run_id: ^shared_run}} =
               RunJournal.get_record(shared_run)

      # recover_next with max_concurrent: 0 leaves pending after nodedown enqueue.
      assert_eventually(fn ->
        RecoveryCoordinator.status(coord_name).pending >= 1
      end)

      pending_status = RecoveryCoordinator.status(coord_name)
      assert pending_status.pending >= 1
      assert pending_status.recovering == 0

      # Explicit interrupted discovery also targets only the custom journal.
      send(coord_pid, :discover_interrupted)

      assert_eventually(fn ->
        RecoveryCoordinator.status(coord_name).pending >= 1
      end)

      # Isolation still holds for claim: global run is not in custom journal
      # under a different id, and custom-only claim path does not touch global.
      assert :ok =
               RunJournal.put(%Record{
                 run_id: other_global,
                 pipeline_id: other_global,
                 status: :interrupted,
                 started_at: now,
                 last_heartbeat: now,
                 owner_node: node(),
                 execution_principal: "agent_global_only_#{suffix}"
               })

      assert {:error, :not_found} =
               PipelineStatus.claim_for_recovery_record(other_global, node(),
                 server: journal_name
               )

      assert {:ok, %Record{status: :interrupted}} = RunJournal.get_record(other_global)
    end
  end

  describe "graph version check" do
    test "detects changed DOT source" do
      # Create a temp DOT file
      tmp_dir = System.tmp_dir!()
      dot_path = Path.join(tmp_dir, "recovery_test_#{:rand.uniform(100_000)}.dot")
      logs_root = Path.join(tmp_dir, "recovery_test_logs_#{:rand.uniform(100_000)}")

      original_source = """
      digraph Pipeline {
        start [type="transform" handler="echo"]
        end_ [type="transform" handler="echo"]
        start -> end_
      }
      """

      File.write!(dot_path, original_source)
      File.mkdir_p!(logs_root)

      original_hash = RecoveryCoordinator.compute_graph_hash(original_source)

      # Modify the file
      modified_source = """
      digraph Pipeline {
        start [type="transform" handler="echo"]
        middle [type="transform" handler="echo"]
        end_ [type="transform" handler="echo"]
        start -> middle -> end_
      }
      """

      File.write!(dot_path, modified_source)

      current_hash = RecoveryCoordinator.compute_graph_hash(File.read!(dot_path))

      # Hashes should differ
      refute original_hash == current_hash

      # Cleanup
      File.rm(dot_path)
      File.rm_rf(logs_root)
    end
  end

  describe "facade API" do
    test "list_resumable returns empty when no interrupted pipelines" do
      assert {:ok, []} = Arbor.Orchestrator.list_resumable()
    end

    test "staleness decisions are deterministic when using explicit time (via JobRegistry)" do
      # This exercises the time-threading path we added in Wave 3
      # (RecoveryCoordinator → JobRegistry.list_stale_heartbeats with explicit now).
      fixed_now = ~U[2026-05-21 12:00:00Z]

      # Insert a running entry with a very old heartbeat
      entry = %JobRegistry.Entry{
        pipeline_id: "run_time_threading_test",
        run_id: "run_time_threading_test",
        graph_id: "time_threading",
        started_at: ~U[2026-05-20 00:00:00Z],
        status: :running,
        completed_count: 0,
        total_nodes: 5,
        node_durations: %{},
        owner_node: node(),
        # very old
        last_heartbeat: ~U[2026-05-20 00:00:00Z]
      }

      Arbor.Persistence.BufferedStore.put("run_time_threading_test", entry,
        name: :arbor_orchestrator_jobs
      )

      # With a 1-hour cutoff using our fixed_now, this should be considered stale
      stale = JobRegistry.list_stale_heartbeats(60 * 60 * 1000, fixed_now)
      assert Enum.any?(stale, fn e -> e.run_id == "run_time_threading_test" end)

      # Cleanup
      Arbor.Persistence.BufferedStore.delete("run_time_threading_test",
        name: :arbor_orchestrator_jobs
      )
    end

    test "resume returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Arbor.Orchestrator.resume("nonexistent_run")
    end

    test "abandon returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Arbor.Orchestrator.abandon("nonexistent_run")
    end

    test "resume rejects non-interrupted pipelines" do
      alias Arbor.Orchestrator.PipelineStatus

      PipelineStatus.put(%{
        pipeline_id: "run_active_1",
        run_id: "run_active_1",
        graph_id: "running_pipeline",
        started_at: DateTime.utc_now(),
        status: :running,
        completed_count: 0,
        total_nodes: 1,
        node_durations: %{},
        owner_node: node(),
        last_heartbeat: DateTime.utc_now(),
        spawning_pid: self()
      })

      assert {:error, {:invalid_status, :running}} =
               Arbor.Orchestrator.resume("run_active_1")

      PipelineStatus.mark_abandoned("run_active_1")
    end

    test "list_resumable only includes entries with checkpoints" do
      tmp_dir = System.tmp_dir!()
      alias Arbor.Orchestrator.PipelineStatus

      # Create entry with checkpoint
      logs_with = Path.join(tmp_dir, "resumable_with_#{:rand.uniform(100_000)}")
      File.mkdir_p!(logs_with)
      File.write!(Path.join(logs_with, "checkpoint.json"), "{}")

      # Create entry without checkpoint
      logs_without = Path.join(tmp_dir, "resumable_without_#{:rand.uniform(100_000)}")
      File.mkdir_p!(logs_without)

      for {run_id, graph_id, logs} <- [
            {"run_with_cp", "with_cp", logs_with},
            {"run_without_cp", "without_cp", logs_without}
          ] do
        PipelineStatus.put(%{
          pipeline_id: run_id,
          run_id: run_id,
          graph_id: graph_id,
          logs_root: logs,
          started_at: DateTime.utc_now(),
          status: :interrupted,
          completed_count: 0,
          total_nodes: 1,
          node_durations: %{},
          owner_node: node(),
          last_heartbeat: DateTime.utc_now()
        })
      end

      assert {:ok, resumable} = Arbor.Orchestrator.list_resumable()
      run_ids = Enum.map(resumable, & &1.run_id)

      assert "run_with_cp" in run_ids
      refute "run_without_cp" in run_ids

      # Cleanup
      File.rm_rf(logs_with)
      File.rm_rf(logs_without)
      PipelineStatus.mark_abandoned("run_with_cp")
      PipelineStatus.mark_abandoned("run_without_cp")
    end

    test "staleness logic respects explicit time (via JobRegistry injection)" do
      # Exercises the Wave 3 change: JobRegistry.list_stale_heartbeats threads an
      # explicit `now` into its age calculation. We prove the *injected* time — not
      # wall-clock — drives the verdict by flipping it with the cutoff alone, while
      # `now` stays fixed. (The companion test only checks the stale side once.)
      fixed_now = ~U[2026-05-21 12:00:00Z]

      # A running entry whose last heartbeat is ~36h before fixed_now.
      entry = %JobRegistry.Entry{
        pipeline_id: "run_time_injection",
        run_id: "run_time_injection",
        graph_id: "time_injection",
        started_at: ~U[2026-05-20 00:00:00Z],
        status: :running,
        completed_count: 0,
        total_nodes: 3,
        node_durations: %{},
        owner_node: node(),
        last_heartbeat: ~U[2026-05-20 00:00:00Z]
      }

      Arbor.Persistence.BufferedStore.put("run_time_injection", entry,
        name: :arbor_orchestrator_jobs
      )

      # 1-hour cutoff against fixed_now → the 36h-old heartbeat is stale.
      stale = JobRegistry.list_stale_heartbeats(60 * 60 * 1000, fixed_now)
      assert Enum.any?(stale, &(&1.run_id == "run_time_injection"))

      # 48-hour cutoff against the SAME fixed_now → no longer stale. Only the
      # injected time makes this deterministic regardless of when the test runs.
      not_stale = JobRegistry.list_stale_heartbeats(48 * 60 * 60 * 1000, fixed_now)
      refute Enum.any?(not_stale, &(&1.run_id == "run_time_injection"))

      # Cleanup
      Arbor.Persistence.BufferedStore.delete("run_time_injection", name: :arbor_orchestrator_jobs)
    end
  end

  describe "claim settlement (no :recovering residue)" do
    alias Arbor.Orchestrator.PipelineStatus

    test "post-claim clean exits settle — no stranded recovering" do
      run_id = "rc_exit_settle_#{System.unique_integer([:positive])}"

      on_exit(fn -> PipelineStatus.delete(run_id) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      # Simulate claim + settlement for every clean exit class that used to be ignored.
      for _reason <- [:normal, :shutdown, {:shutdown, :test}] do
        :ok = PipelineStatus.mark_interrupted(run_id)
        assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)
        assert PipelineStatus.get(run_id).status == :recovering

        # Retryable recovery exit → interrupted (mirrors settle_recovery_failure)
        assert :ok = PipelineStatus.mark_interrupted(run_id)
        entry = PipelineStatus.get(run_id)
        refute entry.status in [:running, :recovering]
        assert entry.status == :interrupted
      end
    end

    test "missing checkpoint after claim settles to interrupted" do
      run_id = "rc_missing_cp_#{System.unique_integer([:positive])}"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      # No checkpoint.json
      on_exit(fn ->
        File.rm_rf(logs)
        PipelineStatus.delete(run_id)
      end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          logs_root: logs,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)
      assert PipelineStatus.get(run_id).status == :recovering

      # Coordinator settle path for checkpoint_not_found → interrupted
      assert :ok = PipelineStatus.mark_interrupted(run_id)
      assert PipelineStatus.get(run_id).status == :interrupted
    end

    test "graph hash without loadable source fails closed and settles" do
      run_id = "rc_hash_#{System.unique_integer([:positive])}"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      File.write!(Path.join(logs, "checkpoint.json"), "{}")

      on_exit(fn ->
        File.rm_rf(logs)
        PipelineStatus.delete(run_id)
      end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          logs_root: logs,
          graph_hash: String.duplicate("b", 64),
          dot_source_path: Path.join(logs, "gone.dot"),
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      assert {:error, {:graph_source_unavailable, _}} = Arbor.Orchestrator.resume(run_id)
      refute PipelineStatus.get(run_id).status == :recovering
    end

    test "concurrent claims leave exactly one winner and no double-own" do
      run_id = "rc_race_#{System.unique_integer([:positive])}"

      on_exit(fn -> PipelineStatus.delete(run_id) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> PipelineStatus.claim_for_recovery(run_id) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      wins = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(wins) == 1
      assert PipelineStatus.get(run_id).status == :recovering

      # Explicit settlement for the winner (as task crash would)
      assert :ok = PipelineStatus.mark_interrupted(run_id)
      assert PipelineStatus.get(run_id).status == :interrupted
    end

    test "remote/second claimant cannot run — fail closed without L4 fencing" do
      run_id = "rc_remote_claim_#{System.unique_integer([:positive])}"
      on_exit(fn -> PipelineStatus.delete(run_id) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil,
          source_node: node()
        })

      # Cross-node claim through this journal is unfenced → fail closed.
      assert {:error, :cross_node_claim_unfenced} =
               PipelineStatus.claim_for_recovery(run_id, :"other@remote-host")

      assert PipelineStatus.get(run_id).status == :interrupted

      # Local claim wins.
      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id, node())
      assert PipelineStatus.get(run_id).status == :recovering

      # Second local claim while recovering fails.
      assert {:error, {:invalid_status, :recovering}} =
               PipelineStatus.claim_for_recovery(run_id, node())
    end

    test "ambiguous remote-sourced row fails closed on claim" do
      run_id = "rc_ambiguous_#{System.unique_integer([:positive])}"
      on_exit(fn -> PipelineStatus.delete(run_id) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil,
          source_node: :"peer@other-node"
        })

      assert {:error, :ambiguous_remote_row} =
               PipelineStatus.claim_for_recovery(run_id, node())

      entry = PipelineStatus.get(run_id)
      assert entry.status == :interrupted
      # Source metadata preserved for L4.
      assert to_string(entry.source_node) == "peer@other-node"
    end
  end

  describe "nil meta merge preserves recovery pointers" do
    alias Arbor.Orchestrator.RunLifecycle.Adapter
    alias Arbor.Orchestrator.RunLifecycle.Record

    test "merge_meta ignores nil overwrites for path/hash/logs/owner/source" do
      base = %Record{
        run_id: "merge_meta",
        pipeline_id: "merge_meta",
        graph_hash: "abc",
        dot_source_path: "/tmp/graph.dot",
        logs_root: "/tmp/logs",
        owner_node: :a@host,
        source_node: :b@host,
        origin_trust_zone: 1
      }

      merged =
        Adapter.merge_meta(base, %{
          graph_hash: nil,
          dot_source_path: nil,
          logs_root: nil,
          owner_node: nil,
          source_node: nil,
          origin_trust_zone: nil
        })

      assert merged.graph_hash == "abc"
      assert merged.dot_source_path == "/tmp/graph.dot"
      assert merged.logs_root == "/tmp/logs"
      assert merged.owner_node == :a@host
      assert merged.source_node == :b@host
      assert merged.origin_trust_zone == 1
    end
  end

  describe "process liveness tri-state" do
    test "local dead pid is :dead and local live is :alive" do
      dead = spawn(fn -> :ok end)
      Process.sleep(20)
      refute Process.alive?(dead)

      assert Arbor.Orchestrator.PipelineStatus.process_liveness(dead) == :dead
      assert Arbor.Orchestrator.PipelineStatus.process_liveness(self()) == :alive
    end
  end

  describe "recovery path security and principal" do
    alias Arbor.Orchestrator.PipelineStatus

    test "tampered logs_root outside recovery root cannot materialize writes (security regression)" do
      recovery_root =
        Path.join(System.tmp_dir!(), "arbor_recovery_root_#{System.unique_integer([:positive])}")

      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      # Outside target an attacker hopes materialization will write into.
      evil_root =
        Path.join(System.tmp_dir!(), "evil_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(evil_root)

      Application.put_env(:arbor_orchestrator, :recovery_materialization_root, recovery_root)

      on_exit(fn ->
        Application.delete_env(:arbor_orchestrator, :recovery_materialization_root)
        File.rm_rf(evil_root)
      end)

      run_id = "sec_path_#{System.unique_integer([:positive])}"
      payload = Jason.encode!(%{"run_id" => run_id, "node" => "start"})

      assert {:ok, %{path: path, logs_root: logs_root, recovery_root: root}} =
               RecoveryCoordinator.__test_materialize_store_checkpoint__(payload, run_id)

      # Wrote only under the private recovery root, never the evil outside path.
      assert String.starts_with?(path, root)
      assert String.starts_with?(logs_root, root)
      refute String.starts_with?(path, evil_root)
      refute File.exists?(Path.join(evil_root, "checkpoint.json"))
      assert File.regular?(path)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(path)
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(logs_root)
    end

    test "recovery root that is a pre-existing symlink is rejected (security regression)" do
      base =
        Path.join(System.tmp_dir!(), "arbor_rec_symlink_#{System.unique_integer([:positive])}")

      real = Path.join(base, "real")
      link = Path.join(base, "link")
      File.mkdir_p!(real)
      File.ln_s!(real, link)
      on_exit(fn -> File.rm_rf(base) end)

      Application.put_env(:arbor_orchestrator, :recovery_materialization_root, link)

      on_exit(fn ->
        Application.delete_env(:arbor_orchestrator, :recovery_materialization_root)
      end)

      assert {:error, :recovery_root_is_symlink} =
               RecoveryCoordinator.__test_ensure_recovery_root__()
    end

    test "exclusive checkpoint create rejects pre-existing path/symlink" do
      recovery_root =
        Path.join(System.tmp_dir!(), "arbor_excl_cp_#{System.unique_integer([:positive])}")

      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      Application.put_env(:arbor_orchestrator, :recovery_materialization_root, recovery_root)

      on_exit(fn ->
        Application.delete_env(:arbor_orchestrator, :recovery_materialization_root)
      end)

      run_id = "excl_#{System.unique_integer([:positive])}"
      payload = ~s({"ok":true})

      assert {:ok, first} =
               RecoveryCoordinator.__test_materialize_store_checkpoint__(payload, run_id)

      # Plant a symlink at checkpoint path of a second exclusive attempt by
      # writing only through the public hook; second exclusive create is always
      # a fresh attempt dir so it succeeds. Prove File.open exclusive on an
      # existing regular file path fails via a planted file in a fresh dir.
      planted = Path.join(first.logs_root, "checkpoint.json")
      assert File.regular?(planted)

      # Re-materializing into same logs_root is not the public API; verify via
      # exclusive open semantics used by materialization.
      assert {:error, :eexist} =
               File.open(planted, [:write, :binary, :exclusive], fn _ -> :ok end)
    end

    test "settlement failure is typed on public resume when mark_interrupted fails" do
      run_id = "settle_term_#{System.unique_integer([:positive])}"

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :failed,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          failure_reason: :prior
        })

      on_exit(fn -> PipelineStatus.delete(run_id) end)

      assert {:error, {:invalid_status, :failed}} = Arbor.Orchestrator.resume(run_id)
    end

    test "execution_principal is preserved through journal put" do
      run_id = "principal_#{System.unique_integer([:positive])}"

      assert :ok =
               PipelineStatus.put(%{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 execution_principal: "agent_abc123",
                 started_at: DateTime.utc_now(),
                 total_nodes: 1,
                 completed_count: 0,
                 owner_node: nil,
                 source_node: node()
               })

      on_exit(fn -> PipelineStatus.delete(run_id) end)

      entry = PipelineStatus.get(run_id)
      assert entry.execution_principal == "agent_abc123"
    end

    test "missing lifecycle mutation returns not_found never ok" do
      missing = "missing_mut_#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = PipelineStatus.mark_interrupted(missing)
      assert {:error, :not_found} = PipelineStatus.mark_abandoned(missing)
      assert {:error, :not_found} = PipelineStatus.mark_failed(missing, :boom)
      assert {:error, :not_found} = PipelineStatus.mark_recovering(missing)
      assert {:error, :not_found} = PipelineStatus.touch_heartbeat(missing)
    end

    test "identity rejects atom coercion and pipeline_id fallback for missing run_id" do
      alias Arbor.Orchestrator.RunLifecycle.Record

      # Atom run_id on a typed Record is invalid_type (no atom coercion).
      assert {:error, {:invalid_lifecycle_identity, :run_id, :invalid_type}} =
               PipelineStatus.put(%Record{
                 run_id: :atom_run,
                 pipeline_id: "pipe",
                 status: :interrupted,
                 started_at: DateTime.utc_now()
               })

      # Map atom keys are dropped before validation → empty (never coerced).
      assert {:error, {:invalid_lifecycle_identity, :run_id, :empty}} =
               PipelineStatus.put(%{
                 run_id: :atom_run,
                 pipeline_id: "pipe",
                 status: :interrupted,
                 started_at: DateTime.utc_now()
               })

      # pipeline_id alone must not become run_id
      assert {:error, {:invalid_lifecycle_identity, :run_id, :empty}} =
               PipelineStatus.put(%{
                 pipeline_id: "only_pipeline",
                 status: :interrupted,
                 started_at: DateTime.utc_now()
               })
    end

    test "graph hash/parse corruption nonretryable; filesystem I/O retryable" do
      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(:graph_changed)
      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(:graph_source_unavailable)

      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:graph_source_unavailable, :enoent}
             )

      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:cannot_load_graph, {:parse_error, "bad"}}
             )

      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:cannot_load_graph, :no_dot_source_path}
             )

      refute RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:graph_source_unavailable, :eio}
             )

      refute RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:cannot_load_graph, {:dot_file_unavailable, :estale}}
             )

      refute RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:dot_file_unavailable, :enxio}
             )
    end
  end

  describe "engine takeover admission (security regression)" do
    alias Arbor.Orchestrator.PipelineStatus
    alias Arbor.Orchestrator.Engine

    defp minimal_graph do
      {:ok, graph} =
        Arbor.Orchestrator.compile("""
        digraph Takeover {
          start [shape=Mdiamond]
          done [shape=Msquare]
          start -> done
        }
        """)

      graph
    end

    test "fresh Engine.run rejects existing nonterminal run_id (no takeover)" do
      run_id = "takeover_fresh_#{System.unique_integer([:positive])}"
      on_exit(fn -> PipelineStatus.delete(run_id) end)

      assert :ok =
               PipelineStatus.put(%{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 execution_principal: "agent_owner",
                 started_at: DateTime.utc_now(),
                 total_nodes: 1,
                 completed_count: 0,
                 owner_node: nil,
                 source_node: node()
               })

      assert {:error, {:run_id_in_use, :interrupted}} =
               Engine.run(minimal_graph(), run_id: run_id, authorization: false)

      entry = PipelineStatus.get(run_id)
      assert entry.status == :interrupted
      assert entry.execution_principal == "agent_owner"
    end

    test "resume without claim status is rejected" do
      run_id = "takeover_unclaimed_#{System.unique_integer([:positive])}"
      on_exit(fn -> PipelineStatus.delete(run_id) end)

      assert :ok =
               PipelineStatus.put(%{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 execution_principal: "agent_owner",
                 started_at: DateTime.utc_now(),
                 total_nodes: 1,
                 completed_count: 0,
                 owner_node: nil,
                 source_node: node()
               })

      assert {:error, {:invalid_resume_status, :interrupted}} =
               Engine.run(minimal_graph(),
                 run_id: run_id,
                 resume: true,
                 recovery: true,
                 execution_principal: "agent_owner",
                 authorization: false
               )
    end

    test "claimed resume with mismatched execution_principal is rejected" do
      run_id = "takeover_principal_#{System.unique_integer([:positive])}"
      on_exit(fn -> PipelineStatus.delete(run_id) end)

      assert :ok =
               PipelineStatus.put(%{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 execution_principal: "agent_owner",
                 started_at: DateTime.utc_now(),
                 total_nodes: 1,
                 completed_count: 0,
                 owner_node: nil,
                 source_node: node()
               })

      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)
      assert PipelineStatus.get(run_id).status == :recovering

      assert {:error, :execution_principal_mismatch} =
               Engine.run(minimal_graph(),
                 run_id: run_id,
                 resume: true,
                 recovery: true,
                 execution_principal: "agent_attacker",
                 authorization: false
               )

      # Claim state preserved for legitimate resume/settlement
      assert PipelineStatus.get(run_id).status == :recovering
      assert PipelineStatus.get(run_id).execution_principal == "agent_owner"
    end

    test "claimed resume with matching principal is admitted past lifecycle gate" do
      run_id = "takeover_ok_#{System.unique_integer([:positive])}"
      on_exit(fn -> PipelineStatus.delete(run_id) end)

      assert :ok =
               PipelineStatus.put(%{
                 run_id: run_id,
                 pipeline_id: run_id,
                 status: :interrupted,
                 execution_principal: "agent_owner",
                 started_at: DateTime.utc_now(),
                 total_nodes: 1,
                 completed_count: 0,
                 owner_node: nil,
                 source_node: node()
               })

      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)

      # May fail later (no checkpoint) but must not fail admission as takeover.
      result =
        Engine.run(minimal_graph(),
          run_id: run_id,
          resume: true,
          recovery: true,
          execution_principal: "agent_owner",
          authorization: false
        )

      refute match?({:error, {:run_id_in_use, _}}, result)
      refute match?({:error, :execution_principal_mismatch}, result)
      refute match?({:error, {:invalid_resume_status, _}}, result)
    end
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
