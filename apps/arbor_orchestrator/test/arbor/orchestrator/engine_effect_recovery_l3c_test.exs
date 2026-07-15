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
      fail_node = Keyword.get(opts, :fail_node, "task")

      GenServer.start_link(
        __MODULE__,
        %{fail_on: fail_on, fail_node: fail_node, fired?: false, data: %{}},
        name: name
      )
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
      if not state.fired? and matches_transition?(state.fail_on, state.fail_node, value) do
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

    defp matches_transition?(fail_on, fail_node, value) do
      data = lifecycle_data(value)
      effect = data["current_effect"]
      completed = List.wrap(data["completed_nodes"])
      status = data["status"] || data[:status]

      case fail_on do
        :receipt ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == fail_node and
            fail_node not in completed

        :completed_progress ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == fail_node and
            fail_node in completed

        :settle ->
          is_map(effect) and effect["status"] == "settled" and effect["node_id"] == fail_node

        :progress_sync_once ->
          # Fail the first progress publish that includes the effect node after a
          # completed effect (used to prove resume progress-sync fails closed before settle).
          is_map(effect) and effect["status"] == "completed" and fail_node in completed and
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
      # Public result and durable record must both be chronological.
      assert result.completed_nodes == ["start", "task", "exit"]

      final = PipelineStatus.get_record(ctx.run_id, jopts)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
      assert final.completed_nodes == ["start", "task", "exit"]
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
  # Legacy intent visit binding (security regression)
  # ---------------------------------------------------------------------------

  describe "legacy pending_intent visit binding (security regression)" do
    test "different execution marker cannot bypass indeterminate side-effect gate or invoke handler" do
      # A later/different L3C visit marker for the same node_id must not resolve
      # a legacy pending_intent. force_replay remains the deliberate override;
      # without it, resume must halt before any handler call.
      ctx = start_isolated_journal("l3c_legacy_mask")
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_legacy_mask")

      input_hash = String.duplicate("a", 64)
      legacy_exec = "exec_legacy_old"
      later_exec = "exec_later_visit"

      seed_legacy_intent_checkpoint!(
        logs_root,
        ctx.run_id,
        identity,
        intent_execution_id: legacy_exec,
        intent_input_hash: input_hash,
        digest_execution_id: later_exec,
        digest_input_hash: input_hash
      )

      # No current_effect — L3C continues; legacy intent gate must still fire.
      put_minimal_interrupted!(ctx.run_id, jopts, logs_root, completed_nodes: ["start"])

      assert {:error, {:indeterminate_side_effect, "task", ^legacy_exec}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, _, _}, 150

      # force_replay remains the deliberate legacy override (not a security hole).
      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:ok, _result} =
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

      # Handler may run under force_replay; that is intentional legacy override.
      assert_receive {:l3c_probe, "task", _}, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # Settled checkpoint-ahead progress
  # ---------------------------------------------------------------------------

  describe "settled checkpoint-ahead progress" do
    test "syncs journal progress from authenticated terminal checkpoint without re-settling or replaying" do
      # Valid settled fixture: journal settled with ["start","task"]; authenticated
      # terminal checkpoint advanced to chronological ["start","task","exit"] with
      # current_node "exit". Resume must recover, sync the non-journaled suffix,
      # and finalize without re-invoking task or re-settling.
      ctx = start_backed_journal("l3c_settled_ahead", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_settled_ahead")

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
      assert File.exists?(Path.join(logs_root, "checkpoint.json"))

      # Build a coherent settled record that includes the effect node.
      settled = settle_effect_in_record!(rec)

      coherent = %Record{
        settled
        | status: :interrupted,
          failure_reason: nil,
          finished_at: nil,
          duration_ms: nil,
          owner_node: nil,
          logs_root: logs_root,
          completed_nodes: ["start", "task"],
          completed_count: 2
      }

      assert :ok = PipelineStatus.put(coherent, jopts)

      # Structurally consistent terminal checkpoint (current_node exit, full
      # chronological completed_nodes). Relies on fixed terminal recovery path.
      write_terminal_checkpoint_ahead!(logs_root, ctx.run_id, identity, coherent)

      assert {:ok, _} = PipelineStatus.claim_for_recovery_record(ctx.run_id, node(), jopts)

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
      assert result.completed_nodes == ["start", "task", "exit"]

      final = PipelineStatus.get_record(ctx.run_id, jopts)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
      assert final.completed_nodes == ["start", "task", "exit"]
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal checkpoint recovery (next_node_id nil)
  # ---------------------------------------------------------------------------

  describe "terminal checkpoint recovery" do
    test "side-effecting terminal node recovers exact evidence, settles, never re-invokes" do
      # Terminal exec node id "end" is Router.terminal?/1 true. First run records
      # receipt + authenticated terminal checkpoint then fails before progress/settle.
      # Resume (next_node_id nil) must recover, sync, settle, and complete without
      # re-invoking the handler.
      ctx =
        start_backed_journal("l3c_term_recon", :completed_progress, fail_node: "end")

      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_term_recon")
      graph = parse!(terminal_side_dot())

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(graph,
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "end", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id
      assert rec.current_effect["node_id"] == "end"
      assert File.exists?(Path.join(logs_root, "checkpoint.json"))

      assert {:ok, checkpoint} =
               Arbor.Orchestrator.Engine.Checkpoint.load(
                 Path.join(logs_root, "checkpoint.json"),
                 run_id: ctx.run_id,
                 hmac_secret: Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
               )

      assert checkpoint.current_node == "end"
      assert checkpoint.completed_nodes == ["start", "end"]
      assert checkpoint.execution_digests["end"].execution_id == exec_id

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:ok, result} =
               Engine.run(graph,
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, "end", _}, 150
      assert result.completed_nodes == ["start", "end"]
      assert result.final_outcome.status == :success

      final = PipelineStatus.get_record(ctx.run_id, jopts)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
      assert final.completed_nodes == ["start", "end"]
    end

    test "pending effect on terminal checkpoint halts before completion or handler dispatch" do
      ctx = start_backed_journal("l3c_term_pend", :receipt, fail_node: "end")
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_term_pend")
      graph = parse!(terminal_side_dot())

      assert {:error, {:effect_receipt_failed, _}} =
               Engine.run(graph,
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "end", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "pending"
      assert rec.current_effect["execution_id"] == exec_id

      # Seed a terminal checkpoint so resume takes next_node_id: nil; recovery
      # must still halt on pending before finalize/handler.
      seed_terminal_checkpoint!(logs_root, ctx.run_id, identity,
        completed_nodes: ["start", "end"]
      )

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:error, {:indeterminate_effect, "end", ^exec_id}} =
               Engine.run(graph,
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
      refute rec2.status == :completed
      refute rec2.status == :failed
      assert rec2.current_effect["status"] == "pending"
    end

    test "completed-unapplied effect on terminal checkpoint halts before completion" do
      # Receipt recorded for terminal "end", but checkpoint never applied this
      # visit (pre-task seed). Terminal next_node_id nil must still halt.
      ctx = start_isolated_journal("l3c_term_unapp")
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_term_unapp")
      graph = parse!(terminal_ckpt_dot())

      assert {:error, {:effect_checkpoint_failed, _}} =
               Engine.run(graph,
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resumable: true
               )

      assert_receive {:l3c_probe, "end", exec_id}, 1_000
      flush_probes()

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id
      assert rec.current_effect["node_id"] == "end"

      _ = File.rm_rf(logs_root)
      :ok = File.mkdir_p(logs_root)
      # Structurally coherent terminal progress without this visit's exact
      # execution marker is still completed-but-unapplied.
      seed_terminal_checkpoint!(logs_root, ctx.run_id, identity,
        completed_nodes: ["start", "end"]
      )

      reopen_as_recovering!(ctx.run_id, jopts, logs_root)

      assert {:error, {:completed_effect_unapplied, "end", ^exec_id}} =
               Engine.run(graph,
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
      refute rec2.status == :completed
      assert rec2.current_effect["status"] == "completed"
    end
  end

  describe "nil current_effect ordered progress (security regression)" do
    test "divergent canonical progress halts before handlers and does not overwrite record" do
      ctx = start_isolated_journal("l3c_nil_div")
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l3c_nil_div")

      # Authenticated checkpoint says ["start","other"]; journal has ["start","task"].
      seed_divergent_progress_checkpoint!(logs_root, ctx.run_id, identity)

      put_minimal_interrupted!(ctx.run_id, jopts, logs_root, completed_nodes: ["start", "task"])

      before = PipelineStatus.get_record(ctx.run_id, jopts)
      assert before.completed_nodes == ["start", "task"]
      assert before.current_effect == nil

      assert {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}} =
               Engine.run(parse!(side_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true
               )

      refute_receive {:l3c_probe, _, _}, 150

      after_rec = PipelineStatus.get_record(ctx.run_id, jopts)
      # Must not overwrite durable progress with divergent checkpoint content.
      assert after_rec.completed_nodes == ["start", "task"]
      refute after_rec.status == :completed
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

      publish_to_default_journal!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Orchestrator.resume(ctx.run_id,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, _, _}, 150
      rec = PipelineStatus.get_record(ctx.run_id)
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

      publish_to_default_journal!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:error, {:completed_effect_unapplied, "task", ^exec_id}} =
               Orchestrator.resume(ctx.run_id,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, _, _}, 150
      rec = PipelineStatus.get_record(ctx.run_id)
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

      corrupt_effect_digest!(ctx.run_id, jopts)

      publish_to_default_journal!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
               Orchestrator.resume(ctx.run_id,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, "task", _}, 150
      rec = PipelineStatus.get_record(ctx.run_id)
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

      publish_to_default_journal!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      assert {:ok, result} =
               Orchestrator.resume(ctx.run_id,
                 parent: parent,
                 identity_private_key: identity
               )

      refute_receive {:l3c_probe, "task", _}, 150
      assert "exit" in result.completed_nodes

      final = PipelineStatus.get_record(ctx.run_id)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
    end

    test "caller journal_opts cannot redirect Engine after default journal claim (security regression)" do
      # Claim/lookup always use the canonical default journal. A caller-supplied
      # journal_opts (or bare :server) must not let Engine mutate an alternate
      # journal after the default record was claimed.
      ctx = start_backed_journal("l3c_own_jopts", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      identity = :crypto.strong_rand_bytes(32)
      {logs_root, dot_path, graph_hash} = prepare_resumable_graph!("l3c_own_jopts", side_dot())

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

      publish_to_default_journal!(
        ctx.run_id,
        jopts,
        logs_root,
        dot_path,
        graph_hash
      )

      # Alternate journal with a decoy recovering row for the same run_id.
      alt = start_isolated_journal("l3c_alt_jopts")
      alt_opts = [server: alt.journal_name]

      # Distinct decoy identity: generation 0 + nil effect is the only valid
      # "no current effect" shape; completed_nodes empty marks it as unused.
      decoy = %Record{
        run_id: ctx.run_id,
        pipeline_id: ctx.run_id,
        status: :recovering,
        total_nodes: 3,
        completed_count: 0,
        completed_nodes: [],
        effect_generation: 0,
        current_effect: nil,
        logs_root: logs_root,
        started_at: DateTime.utc_now(),
        owner_node: node()
      }

      assert :ok = PipelineStatus.put(decoy, alt_opts)
      alt_before = PipelineStatus.get_record(ctx.run_id, alt_opts)
      assert alt_before.effect_generation == 0
      assert alt_before.completed_nodes == []

      assert {:ok, result} =
               Orchestrator.resume(ctx.run_id,
                 parent: parent,
                 identity_private_key: identity,
                 journal_opts: alt_opts,
                 server: alt.journal_name
               )

      refute_receive {:l3c_probe, "task", _}, 150
      assert "exit" in result.completed_nodes

      # Default journal is the one resumed and settled.
      final = PipelineStatus.get_record(ctx.run_id)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
      assert "task" in (final.completed_nodes || [])

      # Alternate target must remain the untouched decoy — not the resumed run.
      alt_after = PipelineStatus.get_record(ctx.run_id, alt_opts)
      assert alt_after.status == :recovering
      assert alt_after.effect_generation == 0
      assert alt_after.completed_nodes == []
      assert alt_after.current_effect == nil
      refute alt_after.status == :completed
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

  defp start_backed_journal(label, fail_on, opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    store_name = :"#{label}_store_#{suffix}"
    run_id = "#{label}_run_#{suffix}"
    fail_node = Keyword.get(opts, :fail_node, "task")

    {:ok, _store} =
      start_supervised(
        {OneShotFailStore, name: store_name, fail_on: fail_on, fail_node: fail_node}
      )

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
      journal: journal,
      fail_node: fail_node
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

  # Publish the prepared unique record into the canonical default journal so
  # public Orchestrator.resume/2 (no journal target) observes the same state
  # as list/status/abandon. Clean up the default entry after the test.
  defp publish_to_default_journal!(run_id, jopts, logs_root, dot_path, graph_hash) do
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

    assert :ok = PipelineStatus.put(reopened)

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id)
      catch
        :exit, _ -> :ok
      end
    end)

    reopened
  end

  defp put_minimal_interrupted!(run_id, jopts, logs_root, opts) do
    completed = Keyword.get(opts, :completed_nodes, ["start"])

    # Nil current_effect is valid only with effect_generation 0 (legacy absence).
    rec = %Record{
      run_id: run_id,
      pipeline_id: run_id,
      status: :interrupted,
      total_nodes: 3,
      completed_count: length(completed),
      completed_nodes: completed,
      effect_generation: 0,
      current_effect: nil,
      logs_root: logs_root,
      started_at: DateTime.utc_now()
    }

    assert :ok = PipelineStatus.put(rec, jopts)
    assert {:ok, _} = PipelineStatus.claim_for_recovery_record(run_id, node(), jopts)
  end

  defp settle_effect_in_record!(%Record{} = rec) do
    alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope

    effect = rec.current_effect
    assert is_map(effect)
    assert effect["status"] == "completed"
    assert {:ok, settled} = EffectEnvelope.settle(effect)
    %Record{rec | current_effect: settled}
  end

  defp seed_legacy_intent_checkpoint!(logs_root, run_id, identity, opts) do
    alias Arbor.Orchestrator.Engine.Checkpoint
    alias Arbor.Orchestrator.Engine.Context
    alias Arbor.Orchestrator.Engine.Outcome

    intent_exec = Keyword.fetch!(opts, :intent_execution_id)
    intent_hash = Keyword.fetch!(opts, :intent_input_hash)
    digest_exec = Keyword.fetch!(opts, :digest_execution_id)
    digest_hash = Keyword.fetch!(opts, :digest_input_hash)

    context = Context.new(%{"outcome" => "success"})
    outcomes = %{"start" => %Outcome{status: :success}}

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    pending_intent = %{
      handler: "Arbor.Orchestrator.Handlers.ExecHandler",
      input_hash: intent_hash,
      started_at: "2026-07-15T12:00:00.000000Z",
      execution_id: intent_exec
    }

    # Later/different visit marker for the same node_id — must NOT resolve intent.
    later_digest = %{
      input_hash: digest_hash,
      outcome_status: :success,
      completed_at: "2026-07-15T12:00:01.000000Z",
      execution_id: digest_exec
    }

    checkpoint =
      Checkpoint.from_state("start", ["start"], %{}, context, outcomes,
        run_id: run_id,
        pipeline_started_at: DateTime.utc_now(),
        pending_intents: %{"task" => pending_intent},
        execution_digests: %{"task" => later_digest}
      )

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, hmac_secret: hmac)
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

  # Structurally consistent terminal checkpoint: current_node "exit", chronological
  # completed_nodes ["start", effect_node, "exit"], retaining effect markers so L3C
  # settled recovery can sync the non-journaled suffix then finalize.
  defp write_terminal_checkpoint_ahead!(logs_root, run_id, identity, %Record{} = rec) do
    alias Arbor.Orchestrator.Engine.Checkpoint
    alias Arbor.Orchestrator.Engine.Context
    alias Arbor.Orchestrator.Engine.Outcome

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    path = Path.join(logs_root, "checkpoint.json")

    assert {:ok, checkpoint} =
             Checkpoint.load(path, run_id: run_id, hmac_secret: hmac)

    effect = rec.current_effect
    assert is_map(effect)
    node_id = effect["node_id"]
    assert is_binary(node_id)

    task_outcome =
      Map.get(checkpoint.node_outcomes || %{}, node_id) ||
        %Outcome{status: :success, context_updates: %{"probe.side" => node_id}}

    outcomes =
      (checkpoint.node_outcomes || %{})
      |> Map.put(node_id, task_outcome)
      |> Map.put("exit", %Outcome{status: :success})

    digests = checkpoint.execution_digests || %{}
    assert Map.has_key?(digests, node_id)

    context =
      Context.new(
        Map.merge(checkpoint.context_values || %{}, %{
          "outcome" => "success",
          "probe.side" => node_id
        })
      )

    advanced =
      Checkpoint.from_state(
        "exit",
        ["start", node_id, "exit"],
        checkpoint.node_retries || %{},
        context,
        outcomes,
        run_id: run_id,
        pipeline_started_at: checkpoint.pipeline_started_at || DateTime.utc_now(),
        execution_digests: digests,
        content_hashes: checkpoint.content_hashes || %{},
        pending_intents: checkpoint.pending_intents || %{},
        run_authorization: checkpoint.run_authorization
      )

    assert {:ok, _} = Checkpoint.persist(advanced, logs_root, hmac_secret: hmac)
  end

  defp seed_terminal_checkpoint!(logs_root, run_id, identity, opts) do
    alias Arbor.Orchestrator.Engine.Checkpoint
    alias Arbor.Orchestrator.Engine.Context
    alias Arbor.Orchestrator.Engine.Outcome

    completed = Keyword.get(opts, :completed_nodes, ["start", "end"])
    current = Keyword.get(opts, :current_node, "end")

    context = Context.new(%{"outcome" => "success"})

    outcomes =
      completed
      |> Enum.map(fn id -> {id, %Outcome{status: :success}} end)
      |> Map.new()

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    checkpoint =
      Checkpoint.from_state(current, completed, %{}, context, outcomes,
        run_id: run_id,
        pipeline_started_at: DateTime.utc_now(),
        execution_digests: Keyword.get(opts, :execution_digests, %{})
      )

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, hmac_secret: hmac)
  end

  defp seed_divergent_progress_checkpoint!(logs_root, run_id, identity) do
    alias Arbor.Orchestrator.Engine.Checkpoint
    alias Arbor.Orchestrator.Engine.Context
    alias Arbor.Orchestrator.Engine.Outcome

    context = Context.new(%{"outcome" => "success"})
    outcomes = %{"start" => %Outcome{status: :success}}

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    # current_node must exist in the graph; completed_nodes deliberately diverge
    # from the journal record (["start","task"]) with same length.
    checkpoint =
      Checkpoint.from_state("start", ["start", "other"], %{}, context, outcomes,
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

  # Terminal side-effecting node: id "end" is Router.terminal?/1 true.
  defp terminal_side_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      end [type="l3c_side"]
      start -> end
    }
    """
  end

  defp terminal_ckpt_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      end [type="l3c_ckpt"]
      start -> end
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
