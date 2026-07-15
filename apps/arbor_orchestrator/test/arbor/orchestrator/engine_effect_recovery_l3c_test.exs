defmodule Arbor.Orchestrator.EngineEffectRecoveryL3CTest do
  @moduledoc """
  L3C Engine resume regressions for conservative canonical effect recovery.

  Uses isolated RunJournal processes and public facades only.
  Proves handlers are never invoked for pending / completed-unapplied effects,
  including force_replay and DOT on_resume=\"retry\" overrides.
  Public Arbor.Orchestrator.resume/2 owner settlement is covered end-to-end.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  # ---------------------------------------------------------------------------
  # Controllable store (one-shot fail on named effect transition)
  # ---------------------------------------------------------------------------

  defmodule OneShotFailStore do
    @moduledoc false
    use GenServer

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      fail_on = Keyword.fetch!(opts, :fail_on)
      GenServer.start_link(__MODULE__, %{fail_on: fail_on, fired?: false, data: %{}}, name: name)
    end

    def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def fired?(name), do: GenServer.call(name, :fired?)

    def rearm(name, fail_on) do
      GenServer.call(name, {:rearm, fail_on})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, key, value}, _from, state) do
      if not state.fired? and matches_transition?(state.fail_on, value) do
        {:reply, {:error, {:oneshot_fail, state.fail_on}}, %{state | fired?: true}}
      else
        {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
      end
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

    def handle_call(:fired?, _from, state), do: {:reply, state.fired?, state}

    def handle_call({:rearm, fail_on}, _from, state) do
      {:reply, :ok, %{state | fail_on: fail_on, fired?: false}}
    end

    defp matches_transition?(fail_on, value) do
      data = lifecycle_data(value)
      effect = data["current_effect"]
      completed = List.wrap(data["completed_nodes"])
      status = data["status"] || data[:status]

      case fail_on do
        :receipt ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == "task" and
            "task" not in completed

        :completed_progress ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == "task" and
            "task" in completed

        :settle ->
          is_map(effect) and effect["status"] == "settled" and effect["node_id"] == "task"

        :progress_sync_once ->
          # Fail the first progress publish that includes task after a completed effect
          # (used to prove resume progress-sync fails closed before settle).
          is_map(effect) and effect["status"] == "completed" and "task" in completed and
            to_string(status) in ["running", "recovering"]

        _ ->
          false
      end
    end

    defp lifecycle_data(%PersistenceRecord{data: data}) when is_map(data), do: data
    defp lifecycle_data(%{data: data}) when is_map(data), do: data
    defp lifecycle_data(data) when is_map(data), do: data
    defp lifecycle_data(_), do: %{}
  end

  defmodule SideEffectProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:l3c_probe, node.id, opts[:execution_id]})
      end

      %Outcome{status: :success, context_updates: %{"probe.side" => node.id}}
    end
  end

  defmodule CheckpointBreakProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      logs_root = opts[:logs_root]

      if is_binary(logs_root) and logs_root != "" do
        _ = File.rm_rf(logs_root)
        :ok = File.write(logs_root, "not-a-directory")
      end

      if parent = opts[:parent] do
        send(parent, {:l3c_probe, node.id, opts[:execution_id]})
      end

      %Outcome{status: :success, context_updates: %{"probe.ckpt" => node.id}}
    end
  end

  setup do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    :ok = Registry.register("l3c_side", SideEffectProbe)
    :ok = Registry.register("l3c_ckpt", CheckpointBreakProbe)
    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Pending — no handler, force_replay / on_resume ignored
  # ---------------------------------------------------------------------------

  describe "pending current_effect on resume" do
    test "halts as indeterminate and never invokes handler, even with force_replay" do
      ctx = start_backed_journal("l3c_pend", :receipt)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_pend")

      assert {:error, {:effect_receipt_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "pending"
      assert rec.current_effect["execution_id"] == exec_id

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true,
                 force_replay: true
               )

      refute_receive {:l3c_probe, _, _}, 150

      rec2 = PipelineStatus.get_record(ctx.run_id, jopts)
      refute rec2.status == :failed
      refute rec2.status == :completed
      assert rec2.current_effect["status"] == "pending"
    end

    test "DOT on_resume=retry does not bypass pending canonical effect" do
      ctx = start_backed_journal("l3c_retry", :receipt)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_retry")

      assert {:error, {:effect_receipt_failed, _}} =
               Engine.run(parse!(side_retry_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()
      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Engine.run(parse!(side_retry_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, _, _}, 150
    end
  end

  # ---------------------------------------------------------------------------
  # Completed-but-unapplied
  # ---------------------------------------------------------------------------

  describe "completed-but-unapplied current_effect on resume" do
    test "halts without handler invocation (force_replay cannot bypass)" do
      # Checkpoint.persist fails after handler: receipt recorded, no applied checkpoint node.
      ctx = start_isolated_journal("l3c_unapp")
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_unapp")

      assert {:error, {:effect_checkpoint_failed, _}} =
               Engine.run(parse!(ckpt_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id

      # Restore a usable logs_root and seed a pre-task checkpoint (start only)
      # so resume can authenticate without replaying the broken path.
      _ = File.rm_rf(logs_root)
      :ok = File.mkdir_p(logs_root)
      seed_start_checkpoint!(logs_root, ctx.run_id, identity)

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:error, {:completed_effect_unapplied, "task", ^exec_id}} =
               Engine.run(parse!(ckpt_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true,
                 force_replay: true
               )

      refute_receive {:l3c_probe, _, _}, 150
      rec2 = PipelineStatus.get_record(ctx.run_id, jopts)
      refute rec2.status == :failed
      assert rec2.current_effect["status"] == "completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Exact reconciliation success + settle-only path
  # ---------------------------------------------------------------------------

  describe "exact reconciliation" do
    test "syncs behind progress, settles, and continues without re-invoking the handler" do
      # completed_progress fails after authenticated checkpoint write for task.
      ctx = start_backed_journal("l3c_recon", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_recon")

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id
      refute "exit" in (rec.completed_nodes || [])

      assert File.exists?(Path.join(logs_root, "checkpoint.json"))

      # Checkpoint must carry the current-visit execution marker.
      assert {:ok, checkpoint} =
               Arbor.Orchestrator.Engine.Checkpoint.load(
                 Path.join(logs_root, "checkpoint.json"),
                 run_id: ctx.run_id,
                 hmac_secret: Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
               )

      assert checkpoint.execution_digests["task"].execution_id == exec_id
      assert is_binary(checkpoint.execution_digests["task"].input_hash)
      assert checkpoint.execution_digests["task"].outcome_status == :success
      assert is_binary(checkpoint.execution_digests["task"].completed_at)

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:ok, result} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, "task", _}, 150
      assert "exit" in result.completed_nodes

      final = PipelineStatus.get_record(ctx.run_id, jopts)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
      assert "task" in (final.completed_nodes || [])
    end

    test "settle-only when durable progress already agrees" do
      ctx = start_backed_journal("l3c_settle", :settle)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_settle")

      assert {:error, {:effect_settle_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert "task" in (rec.completed_nodes || [])

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:ok, result} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, "task", _}, 150
      assert "exit" in result.completed_nodes

      final = PipelineStatus.get_record(ctx.run_id, jopts)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
    end

    test "progress-sync failure on resume fails closed before settle" do
      # First run: leave completed effect with an authenticated checkpoint that
      # includes task. Hot journal may already show task in completed_nodes even
      # when the durable put failed — force ordered progress strictly behind the
      # checkpoint so resume must take the sync path.
      ctx = start_backed_journal("l3c_syncfail", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_syncfail")

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id
      assert File.exists?(Path.join(logs_root, "checkpoint.json"))

      # Durable ordered progress is a strict prefix of checkpoint completed_nodes.
      behind = %Record{
        rec
        | status: :interrupted,
          failure_reason: nil,
          finished_at: nil,
          duration_ms: nil,
          owner_node: nil,
          logs_root: logs_root,
          completed_nodes: ["start"],
          completed_count: 1
      }

      assert :ok = PipelineStatus.put(behind, jopts)

      # Rearm store to fail the resume progress-sync write, not settle.
      assert :ok = OneShotFailStore.rearm(ctx.store_name, :progress_sync_once)
      assert {:ok, _} = PipelineStatus.claim_for_recovery_record(ctx.run_id, node(), jopts)

      assert {:error, {:effect_recovery_progress_sync_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, "task", _}, 150

      rec2 = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec2.current_effect["status"] == "completed"
      assert rec2.current_effect["execution_id"] == exec_id
      refute rec2.current_effect["status"] == "settled"
      refute rec2.status == :completed
    end

    test "settle failure on resume fails closed without re-invoking the handler" do
      ctx = start_backed_journal("l3c_settlefail", :settle)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_settlefail")

      assert {:error, {:effect_settle_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert "task" in (rec.completed_nodes || [])

      # Rearm so resume settle fails again.
      assert :ok = OneShotFailStore.rearm(ctx.store_name, :settle)
      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:error, {:effect_recovery_settle_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, "task", _}, 150

      rec2 = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec2.current_effect["status"] == "completed"
      assert rec2.current_effect["execution_id"] == exec_id
      refute rec2.status == :completed
    end

    test "result digest mismatch fails closed without handler invocation" do
      ctx = start_backed_journal("l3c_dgfail", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_dgfail")

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)
      corrupt_effect_digest!(ctx.run_id, jopts)

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, "task", _}, 150
      rec2 = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec2.current_effect["status"] == "completed"
      assert rec2.current_effect["execution_id"] == exec_id
      refute rec2.status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # Public Arbor.Orchestrator.resume/2 owner settlement
  # ---------------------------------------------------------------------------

  describe "public Arbor.Orchestrator.resume/2 owner settlement" do
    test "pending effect ends interrupted with zero handler calls" do
      ctx = start_backed_journal("l3c_own_pend", :receipt)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      {logs_root, dot_path, graph_hash} = prepare_resumable_graph!("l3c_own_pend", side_dot())

      assert {:error, {:effect_receipt_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true,
                 graph_hash: graph_hash,
                 dot_source_path: dot_path
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      prepare_interrupted_for_public_resume!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Orchestrator.resume(ctx.run_id,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, _, _}, 150
      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :interrupted
      assert rec.current_effect["status"] == "pending"
    end

    test "completed-unapplied ends interrupted with zero handler calls" do
      ctx = start_isolated_journal("l3c_own_unapp")
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      {logs_root, dot_path, graph_hash} = prepare_resumable_graph!("l3c_own_unapp", ckpt_dot())

      assert {:error, {:effect_checkpoint_failed, _}} =
               Engine.run(parse!(ckpt_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true,
                 graph_hash: graph_hash,
                 dot_source_path: dot_path
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      _ = File.rm_rf(logs_root)
      :ok = File.mkdir_p(logs_root)
      seed_start_checkpoint!(logs_root, ctx.run_id, identity)

      prepare_interrupted_for_public_resume!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:error, {:completed_effect_unapplied, "task", ^exec_id}} =
               Orchestrator.resume(ctx.run_id,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, _, _}, 150
      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :interrupted
      assert rec.current_effect["status"] == "completed"
    end

    test "structural mismatch ends failed" do
      ctx = start_backed_journal("l3c_own_struct", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      {logs_root, dot_path, graph_hash} = prepare_resumable_graph!("l3c_own_struct", side_dot())

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true,
                 graph_hash: graph_hash,
                 dot_source_path: dot_path
               )

      assert_receive {:l3c_probe, "task", _exec_id}, 1_000
      flush_probes()

      prepare_interrupted_for_public_resume!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      corrupt_effect_digest!(ctx.run_id, jopts)

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               Orchestrator.resume(ctx.run_id,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, "task", _}, 150
      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
    end

    test "exact reconciliation succeeds without handler re-invocation" do
      ctx = start_backed_journal("l3c_own_recon", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      {logs_root, dot_path, graph_hash} = prepare_resumable_graph!("l3c_own_recon", side_dot())

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true,
                 graph_hash: graph_hash,
                 dot_source_path: dot_path
               )

      assert_receive {:l3c_probe, "task", exec_id}, 1_000
      flush_probes()

      prepare_interrupted_for_public_resume!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:ok, result} =
               Orchestrator.resume(ctx.run_id,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, "task", _}, 150
      assert "exit" in result.completed_nodes

      final = PipelineStatus.get_record(ctx.run_id, jopts)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_isolated_journal(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    run_id = "#{label}_run_#{suffix}"

    {:ok, journal} =
      start_supervised({RunJournal, name: journal_name, ets_table: ets_table})

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id, server: journal_name)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{journal_name: journal_name, ets_table: ets_table, run_id: run_id, journal: journal}
  end

  defp start_backed_journal(label, fail_on) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    store_name = :"#{label}_store_#{suffix}"
    run_id = "#{label}_run_#{suffix}"

    {:ok, _store} =
      start_supervised({OneShotFailStore, name: store_name, fail_on: fail_on})

    {:ok, journal} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: OneShotFailStore,
         store_name: store_name,
         start_store: false}
      )

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id, server: journal_name)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      journal_name: journal_name,
      ets_table: ets_table,
      store_name: store_name,
      run_id: run_id,
      journal: journal
    }
  end

  defp reopen_as_recovering!(run_id, jopts, logs_root) do
    rec = PipelineStatus.get_record(run_id, jopts)
    assert %Record{} = rec

    reopened = %Record{
      rec
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: logs_root || rec.logs_root
    }

    assert :ok = PipelineStatus.put(reopened, jopts)
    assert {:ok, _} = PipelineStatus.claim_for_recovery_record(run_id, node(), jopts)
  end

  defp prepare_interrupted_for_public_resume!(run_id, jopts, logs_root, dot_path, graph_hash) do
    rec = PipelineStatus.get_record(run_id, jopts)
    assert %Record{} = rec

    reopened = %Record{
      rec
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: logs_root,
        dot_source_path: dot_path,
        graph_hash: graph_hash
    }

    assert :ok = PipelineStatus.put(reopened, jopts)
  end

  defp prepare_resumable_graph!(label, dot) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_l3c_dot_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    :ok = File.mkdir_p(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "pipeline.dot")
    :ok = File.write(path, dot)
    hash = :crypto.hash(:sha256, dot) |> Base.encode16(case: :lower)
    logs_root = tmp_logs(label)
    {logs_root, path, hash}
  end

  defp corrupt_effect_digest!(run_id, jopts) do
    rec = PipelineStatus.get_record(run_id, jopts)
    effect = rec.current_effect
    assert is_map(effect)
    digest = effect["result_digest"]
    flipped = flip_hex_nibble(digest)
    corrupted = %{effect | "result_digest" => flipped}
    assert :ok = PipelineStatus.put(%Record{rec | current_effect: corrupted}, jopts)
  end

  defp flip_hex_nibble(<<c, rest::binary>>) do
    flipped =
      case <<c>> do
        "a" -> "b"
        "b" -> "a"
        "0" -> "1"
        _ -> "0"
      end

    flipped <> rest
  end

  defp seed_start_checkpoint!(logs_root, run_id, identity) do
    alias Arbor.Orchestrator.Engine.Checkpoint
    alias Arbor.Orchestrator.Engine.Context
    alias Arbor.Orchestrator.Engine.Outcome

    context = Context.new(%{"outcome" => "success"})
    outcomes = %{"start" => %Outcome{status: :success}}

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    checkpoint =
      Checkpoint.from_state("start", ["start"], %{}, context, outcomes,
        run_id: run_id,
        pipeline_started_at: DateTime.utc_now(),
        execution_digests: %{}
      )

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, hmac_secret: hmac)
  end

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_l3c_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp flush_probes do
    receive do
      {:l3c_probe, _, _} -> flush_probes()
    after
      0 -> :ok
    end
  end

  defp side_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3c_side"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp side_retry_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3c_side", on_resume="retry"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp ckpt_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3c_ckpt"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp parse!(dot) do
    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    graph
  end
end
