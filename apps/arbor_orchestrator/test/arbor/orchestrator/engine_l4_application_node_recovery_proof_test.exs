defmodule Arbor.Orchestrator.EngineL4ApplicationNodeRecoveryProofTest do
  @moduledoc """
  Final Engine L4 crash-consistency proofs using real LocalCluster BEAM nodes.

  Proof A — Orchestrator application restart against a shared controller store
  (`:application_restart`), public list_resumable/resume, zero handler replay.

  Proof B — Real owner-node loss with a survivor sharing the same controller
  store (`:node_restart` + CAS). Survivor RecoveryCoordinator nodedown path
  claims, resumes from durable checkpoint, settles without replay.

  ## Explicit non-claims

  These tests prove owner BEAM termination / application restart with a shared
  controller GenServer store on **one physical Mac**. They do **not** prove
  network partitions, old-owner fencing, storage failover, shared-filesystem
  loss, or physical-host durability. Postgres is intentionally unused.

  Run: `./bin/mix test path/to/this_file.exs --include distributed`
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 180_000

  alias Arbor.Orchestrator.L4ClusterRecoverySupport, as: Support
  alias Arbor.Orchestrator.L4ClusterRecoverySupport.CentralStore
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RecoveryCoordinator

  @support_file Path.expand("../../../support/l4_cluster_recovery_support.ex", __DIR__)

  setup_all do
    started_distribution? = not Node.alive?()

    if started_distribution? do
      assert :ok = LocalCluster.start()

      on_exit(fn ->
        assert :ok = LocalCluster.stop()
      end)
    end

    :ok
  end

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    controller_name = :"l4_central_#{suffix}"
    journal_store = :"l4_journal_#{suffix}"
    checkpoint_store = :"l4_checkpoint_#{suffix}"
    parent = self()

    _central_pid =
      start_supervised!(
        {CentralStore,
         [
           name: controller_name,
           parent: parent,
           hold_store: journal_store,
           hold_on: :completed_progress,
           hold_node: "task"
         ]}
      )

    on_exit(fn ->
      try do
        _ = CentralStore.release_hold(controller_name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      suffix: suffix,
      controller_name: controller_name,
      controller_node: Node.self(),
      journal_store: journal_store,
      checkpoint_store: checkpoint_store,
      parent: parent
    }
  end

  # ---------------------------------------------------------------------------
  # Proof A: application restart + public resume
  # ---------------------------------------------------------------------------

  describe "Proof A: Orchestrator application restart" do
    test "public durable resume after app restart with zero handler replay", ctx do
      {:ok, cluster} = start_cluster(1, "l4a_#{ctx.suffix}")
      on_exit(fn -> safe_stop_cluster(cluster) end)

      {:ok, [owner]} = LocalCluster.nodes(cluster)
      identity = :crypto.strong_rand_bytes(32)
      run_id = "l4a_run_#{ctx.suffix}"

      tmp = tmp_root("l4a", ctx.suffix)
      logs_root = Path.join(tmp, "logs")
      File.mkdir_p!(logs_root)
      recovery_root = Path.join(tmp, "recovery")
      File.mkdir_p!(recovery_root)
      dot_path = Support.write_dot_file!(Path.join(tmp, "dot"), Support.side_dot())

      peer_opts =
        peer_opts(ctx,
          durability: :application_restart,
          recovery_enabled: false,
          recovery_root: recovery_root
        )

      assert :ok = :erpc.call(owner, Support, :prepare_peer!, [peer_opts], 60_000)
      assert_resume_authorized!(owner)

      :ok =
        CentralStore.set_resume_material(ctx.controller_name, %{
          identity: identity,
          execution_principal: "agent_system",
          parent: ctx.parent
        })

      run_opts = run_opts(ctx, run_id, logs_root, identity)

      assert {:ok, engine_pid} =
               :erpc.call(
                 owner,
                 Support,
                 :start_run_file_async,
                 [dot_path, run_opts, ctx.parent],
                 10_000
               )

      assert_receive {:l4_engine_started, ^owner, ^engine_pid}, 10_000
      assert_receive {:l4_cluster_probe, %{node_id: "task", run_id: ^run_id}}, 30_000
      assert CentralStore.invocation_count(ctx.controller_name) == 1

      assert_receive {:l4_store_held, :completed_progress, held}, 30_000
      assert held.effect["status"] == "completed"
      assert held.effect["node_id"] == "task"
      assert "task" in held.completed_nodes

      assert CentralStore.has_key?(
               ctx.controller_name,
               ctx.checkpoint_store,
               Support.checkpoint_key(run_id)
             )

      # Durable-only recovery path: remove local compatibility file only.
      checkpoint_path = Path.join(logs_root, "checkpoint.json")
      assert File.exists?(checkpoint_path)
      File.rm!(checkpoint_path)
      refute File.exists?(checkpoint_path)
      assert File.exists?(dot_path)

      # Kill the real Engine owner while blocked on the held journal reply.
      engine_ref = Process.monitor(engine_pid)
      true = :erpc.call(owner, Process, :exit, [engine_pid, :kill], 5_000)
      assert_receive {:DOWN, ^engine_ref, :process, ^engine_pid, :killed}, 10_000

      # Stop the application while the completed-progress journal reply remains
      # withheld. The controller store has persisted the write, but no local
      # liveness correction can normalize the in-flight record before restart.
      assert :ok = :erpc.call(owner, Support, :stop_orchestrator_app!, [], 30_000)
      assert :ok = CentralStore.release_hold(ctx.controller_name)
      assert :ok = :erpc.call(owner, Support, :restart_orchestrator_only!, [peer_opts], 60_000)
      assert_resume_authorized!(owner)

      assert {:ok, rec} =
               Support.await_until(30_000, fn ->
                 case :erpc.call(owner, PipelineStatus, :get_record, [run_id], 5_000) do
                   %{status: :interrupted} = r -> {:ok, r}
                   other -> {:error, other}
                 end
               end)

      assert is_map(rec.current_effect)
      assert rec.current_effect["status"] == "completed"
      assert "task" in (rec.completed_nodes || [])

      assert {:ok, resumable} = :erpc.call(owner, Arbor.Orchestrator, :list_resumable, [], 10_000)
      assert Enum.any?(resumable, &(&1.run_id == run_id))

      resume_opts = [
        identity_private_key: identity,
        execution_principal: "agent_system",
        agent_id: "agent_system",
        parent: ctx.parent,
        l4_controller: {ctx.controller_name, ctx.controller_node}
      ]

      assert {:ok, result} =
               :erpc.call(owner, Arbor.Orchestrator, :resume, [run_id, resume_opts], 60_000)

      assert "start" in result.completed_nodes
      assert "task" in result.completed_nodes
      assert "exit" in result.completed_nodes
      assert CentralStore.invocation_count(ctx.controller_name) == 1
      assert [%{node: ^owner, run_id: ^run_id}] = CentralStore.invocations(ctx.controller_name)
      refute_receive {:l4_cluster_probe, _}, 100

      final = :erpc.call(owner, PipelineStatus, :get_record, [run_id], 5_000)
      assert final.status == :completed
      assert is_map(final.current_effect)
      assert final.current_effect["status"] == "settled"

      assert {:ok, after_done} =
               :erpc.call(owner, Arbor.Orchestrator, :list_resumable, [], 10_000)

      refute Enum.any?(after_done, &(&1.run_id == run_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Proof B: real owner-node loss + survivor automatic recovery
  # ---------------------------------------------------------------------------

  describe "Proof B: real owner-node loss" do
    test "survivor nodedown recovery claims durable checkpoint without replay", ctx do
      # Does not prove partitions, old-owner fencing, storage failover, or host loss.
      {:ok, cluster} = start_cluster(2, "l4b_#{ctx.suffix}")
      on_exit(fn -> safe_stop_cluster(cluster) end)

      {:ok, [owner, survivor]} = LocalCluster.nodes(cluster)
      identity = :crypto.strong_rand_bytes(32)
      run_id = "l4b_run_#{ctx.suffix}"

      tmp = tmp_root("l4b", ctx.suffix)
      logs_root = Path.join(tmp, "logs")
      File.mkdir_p!(logs_root)
      recovery_root_owner = Path.join(tmp, "recovery_owner")
      recovery_root_survivor = Path.join(tmp, "recovery_survivor")
      File.mkdir_p!(recovery_root_owner)
      File.mkdir_p!(recovery_root_survivor)
      dot_path = Support.write_dot_file!(Path.join(tmp, "dot"), Support.side_dot())

      # Start survivor first, then owner. Automatic recovery on both with node_restart.
      survivor_opts =
        peer_opts(ctx,
          durability: :node_restart,
          recovery_enabled: true,
          recovery_root: recovery_root_survivor,
          recovery_delay_ms: 50
        )

      owner_opts =
        peer_opts(ctx,
          durability: :node_restart,
          recovery_enabled: true,
          recovery_root: recovery_root_owner,
          recovery_delay_ms: 50
        )

      assert :ok = :erpc.call(survivor, Support, :prepare_peer!, [survivor_opts], 60_000)
      assert :ok = :erpc.call(owner, Support, :prepare_peer!, [owner_opts], 60_000)
      assert_resume_authorized!(survivor)
      assert_resume_authorized!(owner)

      # Explicit connect + prove membership both ways.
      assert true == :erpc.call(survivor, Node, :connect, [owner], 5_000)
      assert true == :erpc.call(owner, Node, :connect, [survivor], 5_000)

      assert :ok =
               Support.await_until(10_000, fn ->
                 list = :erpc.call(survivor, Node, :list, [], 2_000)

                 if owner in list do
                   :ok
                 else
                   {:error, {:not_connected, list}}
                 end
               end)

      :ok =
        CentralStore.set_resume_material(ctx.controller_name, %{
          identity: identity,
          execution_principal: "agent_system",
          parent: ctx.parent
        })

      run_opts = run_opts(ctx, run_id, logs_root, identity)

      assert {:ok, engine_pid} =
               :erpc.call(
                 owner,
                 Support,
                 :start_run_file_async,
                 [dot_path, run_opts, ctx.parent],
                 10_000
               )

      assert_receive {:l4_engine_started, ^owner, ^engine_pid}, 10_000
      assert_receive {:l4_cluster_probe, %{node_id: "task", run_id: ^run_id}}, 30_000
      assert CentralStore.invocation_count(ctx.controller_name) == 1

      assert_receive {:l4_store_held, :completed_progress, held}, 30_000
      assert held.effect["status"] == "completed"
      assert "task" in held.completed_nodes

      assert CentralStore.has_key?(
               ctx.controller_name,
               ctx.checkpoint_store,
               Support.checkpoint_key(run_id)
             )

      File.rm!(Path.join(logs_root, "checkpoint.json"))
      refute File.exists?(Path.join(logs_root, "checkpoint.json"))
      assert File.exists?(dot_path)

      # Kill the entire owner LocalCluster member (not graceful Application.stop).
      owner_ref = Process.monitor(engine_pid)
      :ok = LocalCluster.stop(cluster, owner)

      assert_receive {:DOWN, ^owner_ref, :process, ^engine_pid, _}, 10_000

      assert :ok =
               Support.await_until(10_000, fn ->
                 list = Node.list()

                 if owner in list do
                   {:error, {:still_visible, list}}
                 else
                   :ok
                 end
               end)

      assert :ok = CentralStore.release_hold(ctx.controller_name)

      # Survivor public/canonical state reaches completed without a second invoke.
      assert {:ok, final} =
               Support.await_until(90_000, fn ->
                 case :erpc.call(survivor, PipelineStatus, :get_record, [run_id], 5_000) do
                   %{status: :completed} = r -> {:ok, r}
                   other -> {:error, other}
                 end
               end)

      assert is_map(final.current_effect)
      assert final.current_effect["status"] == "settled"
      assert "task" in (final.completed_nodes || [])
      assert "exit" in (final.completed_nodes || [])

      assert :ok =
               Support.await_until(30_000, fn ->
                 status = :erpc.call(survivor, RecoveryCoordinator, :status, [], 5_000)

                 if status.pending == 0 and status.recovering == 0 do
                   :ok
                 else
                   {:error, status}
                 end
               end)

      assert CentralStore.invocation_count(ctx.controller_name) == 1
      assert [%{node: ^owner, run_id: ^run_id}] = CentralStore.invocations(ctx.controller_name)

      assert {:ok, resumable} =
               :erpc.call(survivor, Arbor.Orchestrator, :list_resumable, [], 10_000)

      refute Enum.any?(resumable, &(&1.run_id == run_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_cluster(count, prefix) do
    LocalCluster.start_link(count,
      prefix: prefix,
      applications: [],
      files: [@support_file]
    )
  end

  defp safe_stop_cluster(cluster) do
    try do
      LocalCluster.stop(cluster)
    catch
      :exit, _ -> :ok
    end
  end

  defp peer_opts(ctx, opts) do
    [
      controller_name: ctx.controller_name,
      controller_node: ctx.controller_node,
      journal_store: ctx.journal_store,
      checkpoint_store: ctx.checkpoint_store,
      durability_class: Keyword.fetch!(opts, :durability),
      recovery_enabled: Keyword.get(opts, :recovery_enabled, false),
      recovery_delay_ms: Keyword.get(opts, :recovery_delay_ms, 100),
      recovery_root: Keyword.get(opts, :recovery_root)
    ]
  end

  defp run_opts(ctx, run_id, logs_root, identity) do
    [
      run_id: run_id,
      logs_root: logs_root,
      resumable: true,
      identity_private_key: identity,
      execution_principal: "agent_system",
      agent_id: "agent_system",
      parent: ctx.parent,
      l4_controller: {ctx.controller_name, ctx.controller_node}
    ]
  end

  defp assert_resume_authorized!(peer) do
    assert false ==
             :erpc.call(
               peer,
               Arbor.Security.Config,
               :capability_signing_required?,
               [],
               5_000
             )

    assert {:ok, capabilities} =
             :erpc.call(peer, Arbor.Security, :list_capabilities, ["agent_system"], 5_000)

    assert Enum.any?(capabilities, fn capability ->
             :erpc.call(
               peer,
               Arbor.Security,
               :capability_authorizes?,
               [capability, "arbor://orchestrator/execute", []],
               5_000
             )
           end)

    assert {:ok, :authorized} =
             :erpc.call(
               peer,
               Arbor.Security,
               :authorize,
               ["agent_system", "arbor://orchestrator/execute", :resume, []],
               5_000
             )
  end

  defp tmp_root(label, suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_l4_proof_#{label}_#{suffix}"
      )

    File.rm_rf(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
