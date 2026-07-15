defmodule Arbor.Orchestrator.EngineEffectOwnerOrderingTest do
  @moduledoc """
  L3B core: Engine effect-owner ordering via PipelineStatus on an isolated journal.

  Uses uniquely named RunJournal processes and public facades only.
  Never clears or mutates the process-global RunJournal ETS table.
  Failure tests exercise real owner boundaries — no production inject hooks.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Orchestrator.Engine.EffectOwner
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  # ---------------------------------------------------------------------------
  # Test-only one-shot persistence store (fails exactly one matching transition)
  # ---------------------------------------------------------------------------

  defmodule OneShotFailStore do
    @moduledoc false
    use GenServer

    # Store contract used by RunJournal via Arbor.Persistence facade.
    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      fail_on = Keyword.fetch!(opts, :fail_on)
      GenServer.start_link(__MODULE__, %{fail_on: fail_on, fired?: false, data: %{}}, name: name)
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

    def fired?(name), do: GenServer.call(name, :fired?)

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

    # Inspect the persisted RunLifecycle durable payload and match exactly one
    # owner transition. Terminal finalization and later writes succeed after fire.
    defp matches_transition?(fail_on, value) do
      data = lifecycle_data(value)
      effect = data["current_effect"]
      completed = List.wrap(data["completed_nodes"])
      current_node = data["current_node"]

      case fail_on do
        :node_started ->
          current_node == "task" and is_nil(effect) and data["status"] == "running"

        :prepare ->
          is_map(effect) and effect["status"] == "pending" and effect["node_id"] == "task"

        :receipt ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == "task" and
            "task" not in completed

        :completed_progress ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == "task" and
            "task" in completed

        :settle ->
          is_map(effect) and effect["status"] == "settled" and effect["node_id"] == "task"

        _ ->
          false
      end
    end

    defp lifecycle_data(%PersistenceRecord{data: data}) when is_map(data), do: data
    defp lifecycle_data(%{data: data}) when is_map(data), do: data
    defp lifecycle_data(data) when is_map(data), do: data
    defp lifecycle_data(_), do: %{}
  end

  # ---------------------------------------------------------------------------
  # Probe handlers (focused test support — not production handlers)
  # ---------------------------------------------------------------------------

  defmodule SideEffectingProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        jopts = Keyword.get(opts, :journal_opts, [])
        run_id = opts[:run_id]
        record = PipelineStatus.get_record(run_id, jopts)
        effect = record && record.current_effect

        send(
          parent,
          {:probe_execute,
           %{
             node_id: node.id,
             execution_id: opts[:execution_id],
             effect_status: effect && effect["status"],
             effect_execution_id: effect && effect["execution_id"],
             generation: effect && effect["generation"]
           }}
        )
      end

      %Outcome{status: :success, context_updates: %{"probe.side" => node.id}}
    end
  end

  defmodule IdempotentWithKeyProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :idempotent_with_key

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:probe_execute, %{node_id: node.id, execution_id: opts[:execution_id]}})
      end

      %Outcome{status: :success, context_updates: %{"probe.key" => node.id}}
    end
  end

  defmodule ReadOnlyProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :read_only

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:probe_execute, %{node_id: node.id, execution_id: opts[:execution_id]}})
      end

      %Outcome{status: :success, context_updates: %{"probe.read" => node.id}}
    end
  end

  defmodule IdempotentProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :idempotent

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:probe_execute, %{node_id: node.id, execution_id: opts[:execution_id]}})
      end

      %Outcome{status: :success, context_updates: %{"probe.idem" => node.id}}
    end
  end

  defmodule RetryOnceProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      key = {__MODULE__, opts[:run_id], node.id}
      count = Process.get(key, 0)
      Process.put(key, count + 1)

      if parent = opts[:parent] do
        send(
          parent,
          {:probe_retry_exec,
           %{
             attempt: count + 1,
             execution_id: opts[:execution_id]
           }}
        )
      end

      if count == 0 do
        %Outcome{status: :retry, failure_reason: "force_retry"}
      else
        %Outcome{status: :success, context_updates: %{"probe.retry" => "ok"}}
      end
    end
  end

  defmodule LoopSideEffectProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(_node, context, _graph, opts) do
      visits =
        case Arbor.Orchestrator.Engine.Context.get(context, "loop_visits") do
          n when is_integer(n) -> n
          _ -> 0
        end

      next = visits + 1

      if parent = opts[:parent] do
        send(
          parent,
          {:probe_loop_visit,
           %{
             visit: next,
             execution_id: opts[:execution_id]
           }}
        )
      end

      %Outcome{
        status: :success,
        context_updates: %{"loop_visits" => next, "loop_done" => next >= 2}
      }
    end
  end

  defmodule PrepareNeverRunsProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:probe_should_not_run, node.id})
      end

      %Outcome{status: :success}
    end
  end

  defmodule CheckpointFailProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      # Replace only this run's temporary logs_root directory with a file so the
      # real Checkpoint.persist/3 file path fails — no Engine test hooks.
      logs_root = opts[:logs_root]

      if is_binary(logs_root) and logs_root != "" do
        _ = File.rm_rf(logs_root)
        :ok = File.write(logs_root, "not-a-directory")
      end

      if parent = opts[:parent] do
        jopts = Keyword.get(opts, :journal_opts, [])
        run_id = opts[:run_id]
        record = PipelineStatus.get_record(run_id, jopts)
        effect = record && record.current_effect

        send(
          parent,
          {:probe_execute,
           %{
             node_id: node.id,
             execution_id: opts[:execution_id],
             effect_status: effect && effect["status"]
           }}
        )
      end

      %Outcome{status: :success, context_updates: %{"probe.ckpt" => node.id}}
    end
  end

  setup do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()

    :ok = Registry.register("l3b_side", SideEffectingProbe)
    :ok = Registry.register("l3b_key", IdempotentWithKeyProbe)
    :ok = Registry.register("l3b_read", ReadOnlyProbe)
    :ok = Registry.register("l3b_idem", IdempotentProbe)
    :ok = Registry.register("l3b_retry", RetryOnceProbe)
    :ok = Registry.register("l3b_loop", LoopSideEffectProbe)
    :ok = Registry.register("l3b_never", PrepareNeverRunsProbe)
    :ok = Registry.register("l3b_ckpt", CheckpointFailProbe)

    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # EffectOwner pure helpers
  # ---------------------------------------------------------------------------

  describe "EffectOwner helpers" do
    test "journaled?/1 selects protocol classes only" do
      assert EffectOwner.journaled?(:side_effecting)
      assert EffectOwner.journaled?(:idempotent_with_key)
      refute EffectOwner.journaled?(:idempotent)
      refute EffectOwner.journaled?(:read_only)
    end

    test "fresh_execution_id/1 is bounded hex from supplied bytes" do
      a = EffectOwner.fresh_execution_id(:crypto.strong_rand_bytes(16))
      b = EffectOwner.fresh_execution_id(:crypto.strong_rand_bytes(16))
      assert is_binary(a)
      assert byte_size(a) == byte_size("exec_") + 32
      assert String.starts_with?(a, "exec_")
      assert a == String.downcase(a)
      assert a != b

      fixed =
        EffectOwner.fresh_execution_id(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>)

      assert fixed ==
               "exec_" <>
                 Base.encode16(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>,
                   case: :lower
                 )
    end

    test "outcome_result_digest/1 is deterministic, map-order independent, type-distinct" do
      o1 = %Outcome{status: :success, context_updates: %{"a" => 1, "b" => 2}, notes: "n"}
      o2 = %Outcome{status: :success, context_updates: Map.new([{"b", 2}, {"a", 1}]), notes: "n"}
      o3 = %Outcome{status: :fail, context_updates: %{"a" => 1, "b" => 2}, notes: "n"}
      # Type-distinct: integer 1 vs string "1" must not alias
      o4 = %Outcome{status: :success, context_updates: %{"a" => "1", "b" => 2}, notes: "n"}

      d1 = EffectOwner.outcome_result_digest(o1)
      d2 = EffectOwner.outcome_result_digest(o2)
      d3 = EffectOwner.outcome_result_digest(o3)
      d4 = EffectOwner.outcome_result_digest(o4)

      assert d1 == d2
      assert d1 != d3
      assert d1 != d4
      assert byte_size(d1) == 64
      assert d1 == String.downcase(d1)
    end

    test "receipt_attrs/2 fails closed on invalid outcome status" do
      ok = %Outcome{status: :success}
      bad = %Outcome{status: :not_a_real_status}

      assert {:ok, attrs} =
               EffectOwner.receipt_attrs(ok, "2026-07-15T12:00:00.000000Z")

      assert attrs["outcome_status"] == "success"
      assert is_binary(attrs["result_digest"])
      assert attrs["completed_at"] == "2026-07-15T12:00:00.000000Z"

      assert {:error, :invalid_outcome_status} =
               EffectOwner.receipt_attrs(bad, "2026-07-15T12:00:00.000000Z")
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path: pending during execute, settled after
  # ---------------------------------------------------------------------------

  describe "effect owner ordering happy path" do
    setup do
      start_isolated_journal("eo_happy")
    end

    test "probe sees pending envelope during execute; final effect is settled", ctx do
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_happy")

      graph = parse!(side_effect_dot())

      assert {:ok, result} =
               Engine.run(graph,
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: true
               )

      assert_receive {:probe_execute, probe}, 1_000
      assert probe.node_id == "task"
      assert is_binary(probe.execution_id)
      assert probe.effect_status == "pending"
      assert probe.effect_execution_id == probe.execution_id
      assert probe.generation == 1

      record = PipelineStatus.get_record(ctx.run_id, jopts)
      assert %Record{status: :completed} = record
      assert record.current_effect["status"] == "settled"
      assert record.current_effect["execution_id"] == probe.execution_id
      assert record.current_effect["node_id"] == "task"
      assert record.current_node == nil or is_binary(record.current_node)
      assert record.completed_count >= 1
      assert "task" in (record.completed_nodes || [])

      # Isolated: global journal untouched
      assert PipelineStatus.get(ctx.run_id) == nil
      assert result.run_id == ctx.run_id
    end

    test "idempotent_with_key and side_effecting create effects; read_only and idempotent do not",
         ctx do
      jopts = [server: ctx.journal_name]
      parent = self()

      # side_effecting
      run_side = ctx.run_id <> "_side"
      logs_side = tmp_logs("eo_side")

      assert {:ok, _} =
               Engine.run(parse!(side_effect_dot()),
                 run_id: run_side,
                 logs_root: logs_side,
                 journal_opts: jopts,
                 parent: parent
               )

      assert_receive {:probe_execute, %{execution_id: side_id}}, 1_000
      assert is_binary(side_id)

      rec_side = PipelineStatus.get_record(run_side, jopts)
      assert rec_side.current_effect["status"] == "settled"
      assert rec_side.current_effect["idempotency_class"] == "side_effecting"

      # idempotent_with_key
      run_key = ctx.run_id <> "_key"
      logs_key = tmp_logs("eo_key")

      assert {:ok, _} =
               Engine.run(parse!(key_dot()),
                 run_id: run_key,
                 logs_root: logs_key,
                 journal_opts: jopts,
                 parent: parent
               )

      assert_receive {:probe_execute, %{execution_id: key_id}}, 1_000
      assert is_binary(key_id)

      rec_key = PipelineStatus.get_record(run_key, jopts)
      assert rec_key.current_effect["status"] == "settled"
      assert rec_key.current_effect["idempotency_class"] == "idempotent_with_key"

      # read_only
      run_read = ctx.run_id <> "_read"
      logs_read = tmp_logs("eo_read")

      assert {:ok, _} =
               Engine.run(parse!(read_dot()),
                 run_id: run_read,
                 logs_root: logs_read,
                 journal_opts: jopts,
                 parent: parent
               )

      assert_receive {:probe_execute, %{execution_id: nil}}, 1_000
      rec_read = PipelineStatus.get_record(run_read, jopts)
      assert rec_read.current_effect == nil
      assert rec_read.effect_generation in [0, nil]

      # idempotent
      run_idem = ctx.run_id <> "_idem"
      logs_idem = tmp_logs("eo_idem")

      assert {:ok, _} =
               Engine.run(parse!(idem_dot()),
                 run_id: run_idem,
                 logs_root: logs_idem,
                 journal_opts: jopts,
                 parent: parent
               )

      assert_receive {:probe_execute, %{execution_id: nil}}, 1_000
      rec_idem = PipelineStatus.get_record(run_idem, jopts)
      assert rec_idem.current_effect == nil

      assert PipelineStatus.get(run_side) == nil
      assert PipelineStatus.get(run_key) == nil
      assert PipelineStatus.get(run_read) == nil
      assert PipelineStatus.get(run_idem) == nil
    end

    test "execution_id is stable across Executor retries and distinct across loop visits", ctx do
      jopts = [server: ctx.journal_name]
      parent = self()

      # Retries within one visit
      run_retry = ctx.run_id <> "_retry"
      logs_retry = tmp_logs("eo_retry")

      assert {:ok, _} =
               Engine.run(parse!(retry_dot()),
                 run_id: run_retry,
                 logs_root: logs_retry,
                 journal_opts: jopts,
                 parent: parent
               )

      assert_receive {:probe_retry_exec, %{attempt: 1, execution_id: id1}}, 1_000
      assert_receive {:probe_retry_exec, %{attempt: 2, execution_id: id2}}, 1_000
      assert is_binary(id1)
      assert id1 == id2

      rec = PipelineStatus.get_record(run_retry, jopts)
      assert rec.current_effect["execution_id"] == id1
      assert rec.current_effect["status"] == "settled"

      # Distinct visits in a loop
      run_loop = ctx.run_id <> "_loop"
      logs_loop = tmp_logs("eo_loop")

      assert {:ok, _} =
               Engine.run(parse!(loop_dot()),
                 run_id: run_loop,
                 logs_root: logs_loop,
                 journal_opts: jopts,
                 parent: parent,
                 max_steps: 20
               )

      assert_receive {:probe_loop_visit, %{visit: 1, execution_id: v1}}, 1_000
      assert_receive {:probe_loop_visit, %{visit: 2, execution_id: v2}}, 1_000
      assert is_binary(v1)
      assert is_binary(v2)
      assert v1 != v2

      loop_rec = PipelineStatus.get_record(run_loop, jopts)
      assert loop_rec.current_effect["status"] == "settled"
      assert loop_rec.current_effect["execution_id"] == v2
      assert loop_rec.effect_generation >= 2
    end

    test "successful journaled execution does not write new legacy pending_intents/execution_digests",
         ctx do
      jopts = [server: ctx.journal_name]
      logs_root = tmp_logs("eo_legacy")

      assert {:ok, _} =
               Engine.run(parse!(side_effect_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: self(),
                 resumable: true
               )

      assert {:ok, checkpoint} =
               Checkpoint.load(Path.join(logs_root, "checkpoint.json"), run_id: ctx.run_id)

      assert checkpoint.pending_intents == %{}
      assert checkpoint.execution_digests == %{}

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.current_effect["status"] == "settled"
    end

    test "resumable:false still journals receipt, progress, and settle before completion", ctx do
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_noresume")

      assert {:ok, _} =
               Engine.run(parse!(side_effect_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: false
               )

      assert_receive {:probe_execute, %{effect_status: "pending"}}, 1_000

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :completed
      assert rec.current_effect["status"] == "settled"
      assert "task" in (rec.completed_nodes || [])

      refute File.exists?(Path.join(logs_root, "checkpoint.json"))
    end
  end

  # ---------------------------------------------------------------------------
  # Failure boundaries via real persistence / checkpoint paths
  # ---------------------------------------------------------------------------

  describe "effect owner failure boundaries" do
    test "node_started progress failure prevents prepare and handler invocation" do
      ctx = start_backed_journal("eo_ns", :node_started)
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_ns_fail")

      assert {:error, {:effect_node_start_sync_failed, _}} =
               Engine.run(parse!(never_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: false
               )

      refute_receive {:probe_should_not_run, _}, 100
      assert OneShotFailStore.fired?(ctx.store_name)

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
      assert rec.current_effect == nil
      assert PipelineStatus.get(ctx.run_id) == nil
    end

    test "prepare failure prevents probe handler from running" do
      ctx = start_backed_journal("eo_prep", :prepare)
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_prep_fail")

      assert {:error, {:effect_prepare_failed, _}} =
               Engine.run(parse!(never_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: false
               )

      refute_receive {:probe_should_not_run, _}, 100
      assert OneShotFailStore.fired?(ctx.store_name)

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
      # Backend-first prepare failure leaves hot effect evidence unchanged (nil).
      assert rec.current_effect == nil
      assert PipelineStatus.get(ctx.run_id) == nil
    end

    test "receipt failure stops advancement and leaves pending effect evidence" do
      ctx = start_backed_journal("eo_rcpt", :receipt)
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_receipt_fail")

      assert {:error, {:effect_receipt_failed, _}} =
               Engine.run(parse!(side_effect_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: false
               )

      assert_receive {:probe_execute, %{effect_status: "pending", execution_id: exec_id}}, 1_000
      assert OneShotFailStore.fired?(ctx.store_name)

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
      assert rec.current_effect["status"] == "pending"
      assert rec.current_effect["execution_id"] == exec_id
      refute rec.current_effect["status"] == "settled"
      # Graph must not advance past the journaled node via settle/exit
      refute "exit" in (rec.completed_nodes || [])
    end

    test "checkpoint failure stops advancement and leaves completed receipt evidence" do
      # Real Checkpoint.persist fails after handler replaces logs_root with a file.
      # No Engine inject, no Application env, no journal backend required.
      ctx = start_isolated_journal("eo_ckpt")
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_ckpt_fail")

      assert {:error, {:effect_checkpoint_failed, _}} =
               Engine.run(parse!(ckpt_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: true
               )

      assert_receive {:probe_execute, %{effect_status: "pending"}}, 1_000

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
      assert rec.current_effect["status"] == "completed"
      assert is_binary(rec.current_effect["result_digest"])
      refute rec.current_effect["status"] == "settled"
      refute "exit" in (rec.completed_nodes || [])
    end

    test "completed-progress failure stops advancement and leaves completed receipt" do
      ctx = start_backed_journal("eo_prog", :completed_progress)
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_progress_fail")

      assert {:error, {:effect_completed_progress_failed, _}} =
               Engine.run(parse!(side_effect_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: false
               )

      assert_receive {:probe_execute, _}, 1_000
      assert OneShotFailStore.fired?(ctx.store_name)

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
      assert rec.current_effect["status"] == "completed"
      # Progress write failed: hot may not yet list task under completed_nodes,
      # but receipt evidence remains completed and unsettleable path is closed.
      refute rec.current_effect["status"] == "settled"
      refute "exit" in (rec.completed_nodes || [])
    end

    test "settle failure stops advancement and leaves completed receipt evidence" do
      ctx = start_backed_journal("eo_settle", :settle)
      jopts = [server: ctx.journal_name]
      parent = self()
      logs_root = tmp_logs("eo_settle_fail")

      assert {:error, {:effect_settle_failed, _}} =
               Engine.run(parse!(side_effect_dot()),
                 run_id: ctx.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 resumable: false
               )

      assert_receive {:probe_execute, _}, 1_000
      assert OneShotFailStore.fired?(ctx.store_name)

      rec = PipelineStatus.get_record(ctx.run_id, jopts)
      assert rec.status == :failed
      assert rec.current_effect["status"] == "completed"
      assert "task" in (rec.completed_nodes || [])
      refute "exit" in (rec.completed_nodes || [])
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

    %{
      journal_name: journal_name,
      ets_table: ets_table,
      run_id: run_id,
      journal: journal
    }
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

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_eo_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp side_effect_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_side"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp key_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_key"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp read_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_read"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp idem_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_idem"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp retry_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_retry", max_retries="2"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp loop_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_loop"]
      gate [shape=diamond]
      exit [shape=Msquare]
      start -> task -> gate
      gate -> task [condition="context.loop_done=false"]
      gate -> exit [condition="context.loop_done=true"]
    }
    """
  end

  defp never_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_never"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp ckpt_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_ckpt"]
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
