defmodule Arbor.Orchestrator.RunJournalRuntimeRefreshL4Test.AppRestartStore do
  @moduledoc false
  use GenServer

  def durability_class(_opts), do: :application_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})

  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)

    case GenServer.call(name, :mode) do
      :throw_get -> throw(:injected_get_throw)
      _ -> GenServer.call(name, {:get, key})
    end
  end

  def list(opts) do
    name = Keyword.fetch!(opts, :name)

    case GenServer.call(name, :mode) do
      :throw_list -> throw(:injected_list_throw)
      _ -> GenServer.call(name, :list)
    end
  end

  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})

  def set_fail(name, fail?), do: GenServer.call(name, {:set_fail, fail?})
  def set_mode(name, mode), do: GenServer.call(name, {:set_mode, mode})

  @impl true
  def init(_opts), do: {:ok, %{data: %{}, fail?: false, mode: :normal}}

  @impl true
  def handle_call({:set_fail, fail?}, _from, state), do: {:reply, :ok, %{state | fail?: fail?}}

  def handle_call({:set_mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}

  def handle_call({:put, _key, _value}, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_write_failure}, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  def handle_call({:get, _key}, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_get_failure}, state}
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

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
  end
end

defmodule Arbor.Orchestrator.RunJournalRuntimeRefreshL4Test do
  @moduledoc """
  L4B2 durable runtime refresh + recurring interrupted-run discovery proofs.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RecoveryCoordinator
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunJournalRuntimeRefreshL4Test.AppRestartStore

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, suffix: suffix}
  end

  describe "runtime refresh from durable authority" do
    test "survivor journal discovers remote row written after it started", %{suffix: suffix} do
      store_name = :"l4b2_shared_store_#{suffix}"
      survivor = :"l4b2_survivor_#{suffix}"
      owner = :"l4b2_owner_#{suffix}"
      local_node = :survivor@test
      owner_node = :owner@test
      run_id = "remote_later_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {AppRestartStore, :start_link, [[name: store_name]]}
        })

      # Survivor boots first against empty durable backend.
      {:ok, _} =
        start_supervised(%{
          id: survivor,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: survivor,
                 ets_table: :"l4b2_hot_surv_#{suffix}",
                 backend: AppRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local_node
               ]
             ]}
        })

      assert {:ok, []} = RunJournal.list_records(server: survivor)

      {:ok, _} =
        start_supervised(%{
          id: owner,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: owner,
                 ets_table: :"l4b2_hot_own_#{suffix}",
                 backend: AppRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: owner_node
               ]
             ]}
        })

      now = DateTime.utc_now()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: owner_node,
                   source_node: owner_node,
                   spawning_pid: self(),
                   execution_principal: "agent_remote_#{suffix}"
                 },
                 server: owner
               )

      # Owner-local row is not yet in survivor hot table.
      assert {:error, :not_found} = RunJournal.get_record(run_id, server: survivor)

      assert {:ok, %{upserted: 1}} = PipelineStatus.refresh_from_durable(server: survivor)

      assert {:ok, %Record{status: :running, owner_node: ^owner_node, spawning_pid: nil}} =
               RunJournal.get_record(run_id, server: survivor)
    end

    test "preserves live local spawning_pid and does not boot-normalize running", %{
      suffix: suffix
    } do
      {journal, _store, local_node} = start_journal(suffix, "preserve")
      run_id = "local_running_#{suffix}"
      now = DateTime.utc_now()
      pid = self()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   source_node: local_node,
                   spawning_pid: pid,
                   execution_principal: "agent_local_#{suffix}"
                 },
                 server: journal
               )

      assert {:ok, %{upserted: 1}} = RunJournal.refresh_from_durable(server: journal)

      assert {:ok,
              %Record{
                status: :running,
                owner_node: ^local_node,
                spawning_pid: ^pid
              }} = RunJournal.get_record(run_id, server: journal)
    end

    test "remote or ownership-changed rows do not inherit local spawning_pid", %{suffix: suffix} do
      {journal, _store, local_node} = start_journal(suffix, "no_inherit")
      remote = :remote@other
      run_id = "remote_own_#{suffix}"
      now = DateTime.utc_now()
      local_pid = self()

      # Plant a local hot-only view with a local PID.
      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   source_node: local_node,
                   spawning_pid: local_pid,
                   execution_principal: "agent_flip_#{suffix}"
                 },
                 server: journal
               )

      # Durable authority now shows remote ownership (simulate peer takeover write).
      durable = %{
        "run_id" => run_id,
        "pipeline_id" => run_id,
        "status" => "running",
        "started_at" => DateTime.to_iso8601(now),
        "last_heartbeat" => DateTime.to_iso8601(now),
        "owner_node" => to_string(remote),
        "source_node" => to_string(remote),
        "execution_principal" => "agent_flip_#{suffix}"
      }

      assert :ok =
               AppRestartStore.put(
                 run_id,
                 Arbor.Contracts.Persistence.Record.new(run_id, durable),
                 name: store_name_for(suffix, "no_inherit")
               )

      assert {:ok, %{upserted: 1}} = RunJournal.refresh_from_durable(server: journal)

      assert {:ok, %Record{status: :running, owner_node: owner, spawning_pid: nil}} =
               RunJournal.get_record(run_id, server: journal)

      assert to_string(owner) == to_string(remote)
    end

    test "missing durable rows do not delete hot entries; durable failures fail closed", %{
      suffix: suffix
    } do
      store_name = store_name_for(suffix, "absent")
      journal = :"l4b2_j_absent_#{suffix}"
      local_node = :absent@test
      hot_only = "hot_only_#{suffix}"
      now = DateTime.utc_now()

      {:ok, store} =
        start_supervised(%{
          id: store_name,
          start: {AppRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal,
                 ets_table: :"l4b2_hot_absent_#{suffix}",
                 backend: AppRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local_node
               ]
             ]}
        })

      # Hot-only row never written through durable path after artificial delete.
      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: hot_only,
                   pipeline_id: hot_only,
                   status: :interrupted,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   execution_principal: "agent_hot_#{suffix}"
                 },
                 server: journal
               )

      # Remove durable key while leaving hot intact.
      assert :ok = AppRestartStore.delete(hot_only, name: store_name)

      assert {:ok, %{upserted: 0}} = RunJournal.refresh_from_durable(server: journal)

      assert {:ok, %Record{status: :interrupted, run_id: ^hot_only}} =
               RunJournal.get_record(hot_only, server: journal)

      # Fail closed on durable list outage: bounded error + degraded health.
      assert :ok = AppRestartStore.set_fail(store, true)

      assert {:error, reason} = RunJournal.refresh_from_durable(server: journal)
      assert match?({:durable_refresh_list_failed, _}, reason)

      st = RunJournal.durability_status(server: journal)
      assert st.durable == false
      assert st.mode == :degraded
      assert st.last_error != nil

      # Hot row still present after failed refresh.
      assert {:ok, %Record{run_id: ^hot_only}} = RunJournal.get_record(hot_only, server: journal)
    end
  end

  describe "recurring discovery and queue semantics" do
    test "configured delay controls the initial discovery tick", %{suffix: suffix} do
      {journal, _store, local_node} = start_journal(suffix, "initial_delay")
      run_id = "initial_delay_#{suffix}"
      now = DateTime.utc_now()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :interrupted,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   source_node: local_node,
                   execution_principal: "agent_initial_delay_#{suffix}"
                 },
                 server: journal
               )

      recovery_root = Path.join(System.tmp_dir!(), "l4b2_initial_delay_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      coord = :"l4b2_coord_initial_delay_#{suffix}"

      {:ok, _coord_pid} =
        start_supervised(%{
          id: coord,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord,
                 enabled: true,
                 journal_opts: [server: journal],
                 recovery_root: recovery_root,
                 delay_ms: 25,
                 max_concurrent: 0
               ]
             ]}
        })

      assert_eventually(fn -> RecoveryCoordinator.status(coord).pending == 1 end)
    end

    test "repeated discovery neither duplicates nor clobbers pending work", %{suffix: suffix} do
      {journal, _store, local_node} = start_journal(suffix, "dedupe")
      run_a = "pending_a_#{suffix}"
      run_b = "pending_b_#{suffix}"
      now = DateTime.utc_now()

      for run_id <- [run_a, run_b] do
        assert :ok =
                 RunJournal.put(
                   %Record{
                     run_id: run_id,
                     pipeline_id: run_id,
                     status: :interrupted,
                     started_at: now,
                     last_heartbeat: now,
                     owner_node: local_node,
                     source_node: local_node,
                     execution_principal: "agent_dedupe_#{suffix}"
                   },
                   server: journal
                 )
      end

      recovery_root = Path.join(System.tmp_dir!(), "l4b2_dedupe_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      coord = :"l4b2_coord_dedupe_#{suffix}"

      {:ok, coord_pid} =
        start_supervised(%{
          id: coord,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord,
                 enabled: true,
                 journal_opts: [server: journal],
                 recovery_root: recovery_root,
                 delay_ms: 60_000,
                 max_concurrent: 0
               ]
             ]}
        })

      send(coord_pid, :discover_interrupted)
      assert_eventually(fn -> RecoveryCoordinator.status(coord).pending == 2 end)

      send(coord_pid, :discover_interrupted)
      Process.sleep(50)
      st = RecoveryCoordinator.status(coord)
      assert st.pending == 2
      assert st.recovering == 0
    end

    test "repeated synchronous failures retain one bounded entry per run", %{suffix: suffix} do
      {journal, _store, local_node} = start_journal(suffix, "failure_dedupe")
      run_id = "failure_dedupe_#{suffix}"
      now = DateTime.utc_now()
      test_pid = self()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :interrupted,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   source_node: local_node,
                   execution_principal: "agent_failure_dedupe_#{suffix}"
                 },
                 server: journal
               )

      recovery_root = Path.join(System.tmp_dir!(), "l4b2_failure_dedupe_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      coord = :"l4b2_coord_failure_dedupe_#{suffix}"

      resolver = fn _record ->
        send(test_pid, :resolver_called)
        {:error, :authentication_unavailable}
      end

      {:ok, coord_pid} =
        start_supervised(%{
          id: coord,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord,
                 enabled: true,
                 journal_opts: [server: journal],
                 recovery_root: recovery_root,
                 resume_options_resolver: resolver,
                 delay_ms: 60_000
               ]
             ]}
        })

      for _ <- 1..3 do
        send(coord_pid, :discover_interrupted)
        assert_receive :resolver_called, 1_000
        assert_eventually(fn -> RecoveryCoordinator.status(coord).pending == 0 end)
      end

      assert RecoveryCoordinator.status(coord).failed == 1
    end

    test "killed engine after empty scan is discovered by later liveness-aware discovery", %{
      suffix: suffix
    } do
      {journal, _store, local_node} = start_journal(suffix, "killed")
      run_id = "killed_engine_#{suffix}"
      now = DateTime.utc_now()

      recovery_root = Path.join(System.tmp_dir!(), "l4b2_killed_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      coord = :"l4b2_coord_killed_#{suffix}"

      {:ok, coord_pid} =
        start_supervised(%{
          id: coord,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord,
                 enabled: true,
                 journal_opts: [server: journal],
                 recovery_root: recovery_root,
                 delay_ms: 60_000,
                 max_concurrent: 0
               ]
             ]}
        })

      # Initial empty discovery.
      send(coord_pid, :discover_interrupted)
      Process.sleep(30)
      assert RecoveryCoordinator.status(coord).pending == 0

      {:ok, engine_pid} =
        Task.start(fn ->
          Process.sleep(60_000)
        end)

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   source_node: local_node,
                   spawning_pid: engine_pid,
                   execution_principal: "agent_killed_#{suffix}"
                 },
                 server: journal
               )

      Process.exit(engine_pid, :kill)
      assert_eventually(fn -> not Process.alive?(engine_pid) end)

      send(coord_pid, :discover_interrupted)

      assert_eventually(fn ->
        RecoveryCoordinator.status(coord).pending >= 1
      end)

      assert {:ok, %Record{status: :interrupted, run_id: ^run_id}} =
               RunJournal.get_record(run_id, server: journal)
    end

    test "initially unhealthy durable backend becomes healthy and re-enables automatic recovery",
         %{suffix: suffix} do
      store_name = store_name_for(suffix, "health")
      journal = :"l4b2_j_health_#{suffix}"
      local_node = :health@test

      {:ok, store} =
        start_supervised(%{
          id: store_name,
          start: {AppRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal,
                 ets_table: :"l4b2_hot_health_#{suffix}",
                 backend: AppRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local_node
               ]
             ]}
        })

      recovery_root = Path.join(System.tmp_dir!(), "l4b2_health_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      coord = :"l4b2_coord_health_#{suffix}"

      {:ok, coord_pid} =
        start_supervised(%{
          id: coord,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord,
                 enabled: true,
                 journal_opts: [server: journal],
                 recovery_root: recovery_root,
                 delay_ms: 60_000,
                 max_concurrent: 0
               ]
             ]}
        })

      assert RecoveryCoordinator.status(coord).automatic_recovery == true

      # Inject durable outage after healthy start.
      assert :ok = AppRestartStore.set_fail(store, true)
      send(coord_pid, :discover_interrupted)
      Process.sleep(50)

      st = RecoveryCoordinator.status(coord)
      assert st.automatic_recovery == false

      assert match?(
               {:automatic_recovery_disabled, :durability_unhealthy, _},
               st.automatic_recovery_disabled_reason
             )

      # Heal backend; recurring discovery re-evaluates eligibility.
      assert :ok = AppRestartStore.set_fail(store, false)
      send(coord_pid, :discover_interrupted)
      Process.sleep(50)

      st2 = RecoveryCoordinator.status(coord)
      assert st2.automatic_recovery == true
      assert st2.automatic_recovery_disabled_reason == nil
      assert st2.durable == true
    end
  end

  describe "durable identity binding and owner provenance (r2)" do
    test "envelope key mismatch fails closed with no hot partial upsert", %{suffix: suffix} do
      {journal, store, local_node} = start_journal(suffix, "env_key")
      store_name = store_name_for(suffix, "env_key")
      hot_only = "hot_only_env_#{suffix}"
      listed = "listed_env_#{suffix}"
      now = DateTime.utc_now()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: hot_only,
                   pipeline_id: hot_only,
                   status: :interrupted,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   execution_principal: "agent_env_#{suffix}"
                 },
                 server: journal
               )

      # Durable row under listed key but envelope key disagrees.
      payload = %{
        "run_id" => listed,
        "pipeline_id" => listed,
        "status" => "interrupted",
        "started_at" => DateTime.to_iso8601(now),
        "owner_node" => to_string(local_node)
      }

      pr =
        Arbor.Contracts.Persistence.Record.new("attacker_envelope_key", payload,
          generation: 1,
          revision: 1
        )

      assert :ok = AppRestartStore.put(listed, pr, name: store_name)

      assert {:error, reason} = RunJournal.refresh_from_durable(server: journal)

      assert match?(
               {:durable_refresh_identity_mismatch, ^listed, :envelope_key_mismatch},
               reason
             )

      # Hot-only survivor intact; miskeyed durable never entered hot under either id.
      assert {:ok, %Record{run_id: ^hot_only, status: :interrupted}} =
               RunJournal.get_record(hot_only, server: journal)

      assert {:error, :not_found} = RunJournal.get_record(listed, server: journal)

      assert {:error, :not_found} =
               RunJournal.get_record("attacker_envelope_key", server: journal)

      st = RunJournal.durability_status(server: journal)
      assert st.mode == :degraded
      assert Process.alive?(Process.whereis(journal))
      _ = store
    end

    test "payload run_id mismatch fails closed with no hot partial upsert", %{suffix: suffix} do
      {journal, _store, local_node} = start_journal(suffix, "run_id_mm")
      store_name = store_name_for(suffix, "run_id_mm")
      listed = "listed_run_#{suffix}"
      foreign = "foreign_run_#{suffix}"
      hot_only = "hot_only_run_#{suffix}"
      now = DateTime.utc_now()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: hot_only,
                   pipeline_id: hot_only,
                   status: :interrupted,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   execution_principal: "agent_run_#{suffix}"
                 },
                 server: journal
               )

      payload = %{
        "run_id" => foreign,
        "pipeline_id" => foreign,
        "status" => "interrupted",
        "started_at" => DateTime.to_iso8601(now),
        "owner_node" => to_string(local_node)
      }

      pr =
        Arbor.Contracts.Persistence.Record.new(listed, payload, generation: 1, revision: 1)

      assert :ok = AppRestartStore.put(listed, pr, name: store_name)

      assert {:error, reason} = RunJournal.refresh_from_durable(server: journal)

      assert match?(
               {:durable_refresh_identity_mismatch, ^listed, :run_id_key_mismatch},
               reason
             )

      assert {:ok, %Record{run_id: ^hot_only}} = RunJournal.get_record(hot_only, server: journal)
      assert {:error, :not_found} = RunJournal.get_record(listed, server: journal)
      assert {:error, :not_found} = RunJournal.get_record(foreign, server: journal)
    end

    test "preserves local spawning_pid when owner is local after takeover with remote source",
         %{suffix: suffix} do
      {journal, _store, local_node} = start_journal(suffix, "takeover")
      remote = :origin@remote
      run_id = "takeover_#{suffix}"
      now = DateTime.utc_now()
      pid = self()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: local_node,
                   source_node: local_node,
                   spawning_pid: pid,
                   execution_principal: "agent_takeover_#{suffix}"
                 },
                 server: journal
               )

      # Durable authority still has local owner (after fenced takeover) but retains
      # remote source provenance from the original remote journal.
      durable = %{
        "run_id" => run_id,
        "pipeline_id" => run_id,
        "status" => "running",
        "started_at" => DateTime.to_iso8601(now),
        "last_heartbeat" => DateTime.to_iso8601(now),
        "owner_node" => to_string(local_node),
        "source_node" => to_string(remote),
        "execution_principal" => "agent_takeover_#{suffix}"
      }

      assert :ok =
               AppRestartStore.put(
                 run_id,
                 Arbor.Contracts.Persistence.Record.new(run_id, durable,
                   generation: 1,
                   revision: 1
                 ),
                 name: store_name_for(suffix, "takeover")
               )

      assert {:ok, %{upserted: 1}} = RunJournal.refresh_from_durable(server: journal)

      assert {:ok,
              %Record{
                status: :running,
                owner_node: ^local_node,
                spawning_pid: ^pid
              }} = RunJournal.get_record(run_id, server: journal)
    end

    test "backend throw during refresh fails closed and leaves GenServer alive", %{
      suffix: suffix
    } do
      {journal, store, _local} = start_journal(suffix, "throw")
      jpid = Process.whereis(journal)
      assert is_pid(jpid)

      assert :ok = AppRestartStore.set_mode(store, :throw_list)

      assert {:error, reason} = RunJournal.refresh_from_durable(server: journal)
      assert match?({:durable_refresh_list_failed, _}, reason)

      assert Process.alive?(jpid)
      st = RunJournal.durability_status(server: journal)
      assert st.mode == :degraded
      assert st.last_error != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp store_name_for(suffix, label), do: :"l4b2_store_#{label}_#{suffix}"

  defp start_journal(suffix, label) do
    store_name = store_name_for(suffix, label)
    journal = :"l4b2_j_#{label}_#{suffix}"
    local_node = :"l4b2_#{label}@test"

    {:ok, store} =
      start_supervised(%{
        id: store_name,
        start: {AppRestartStore, :start_link, [[name: store_name]]}
      })

    {:ok, _} =
      start_supervised(%{
        id: journal,
        start:
          {RunJournal, :start_link,
           [
             [
               name: journal,
               ets_table: :"l4b2_hot_#{label}_#{suffix}",
               backend: AppRestartStore,
               store_name: store_name,
               start_store: false,
               local_node: local_node
             ]
           ]}
      })

    {journal, store, local_node}
  end

  defp assert_eventually(fun, attempts \\ 40) do
    if fun.() do
      true
    else
      if attempts <= 1 do
        flunk("condition not met in time")
      else
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
      end
    end
  end
end
