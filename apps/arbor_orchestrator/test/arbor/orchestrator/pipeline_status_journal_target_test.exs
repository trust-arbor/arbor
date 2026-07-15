defmodule Arbor.Orchestrator.PipelineStatusJournalTargetTest do
  @moduledoc """
  L3B prerequisite: PipelineStatus effect owner wrappers + Engine
  `:journal_opts` targeting a uniquely named isolated RunJournal.

  Uses public facades and unique journal fixtures; never clears global ETS.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  @hash_a String.duplicate("a", 64)
  @hash_b String.duplicate("b", 64)
  @started_at "2026-07-15T12:00:00.000000Z"
  @completed_at "2026-07-15T12:00:01.000000Z"

  defmodule ProbeHandler do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:probe_execute, node.id})
      end

      %Arbor.Orchestrator.Engine.Outcome{
        status: :success,
        context_updates: %{"probe.node" => node.id}
      }
    end
  end

  # ---------------------------------------------------------------------------
  # PipelineStatus effect owner wrappers on an isolated journal
  # ---------------------------------------------------------------------------

  describe "PipelineStatus effect owner wrappers" do
    setup do
      ctx = start_isolated_journal("ps_effect")

      seed = %Record{
        run_id: ctx.run_id,
        pipeline_id: ctx.run_id,
        status: :running,
        total_nodes: 2,
        completed_count: 0,
        started_at: DateTime.utc_now(),
        owner_node: node(),
        source_node: node()
      }

      assert :ok = PipelineStatus.put(seed, server: ctx.journal_name)
      # Default journal must not hold this run_id.
      assert PipelineStatus.get(ctx.run_id) == nil

      ctx
    end

    test "prepare, record, and settle preserve generation/execution_id checks", ctx do
      jopts = [server: ctx.journal_name]
      run_id = ctx.run_id
      attrs = prepare_attrs(run_id)

      assert {:ok, :prepared, effect1} = PipelineStatus.prepare_effect(run_id, attrs, jopts)
      assert effect1["status"] == "pending"
      assert effect1["generation"] == 1
      assert effect1["execution_id"] == "exec_1"
      assert effect1["run_id"] == run_id

      # Exact retry: no write, same envelope
      assert {:ok, :already_prepared, effect1b} =
               PipelineStatus.prepare_effect(run_id, attrs, jopts)

      assert effect1b == effect1

      # Different pending attrs conflict without mutation
      bad_attrs = Map.put(attrs, "execution_id", "exec_other")

      assert {:error, {:effect_conflict, :pending}} =
               PipelineStatus.prepare_effect(run_id, bad_attrs, jopts)

      assert %Record{current_effect: ^effect1, effect_generation: 1} =
               PipelineStatus.get_record(run_id, jopts)

      # Default journal untouched
      assert PipelineStatus.get(run_id) == nil

      receipt = receipt_attrs()

      assert {:ok, :recorded, completed} =
               PipelineStatus.record_effect_receipt(run_id, 1, "exec_1", receipt, jopts)

      assert completed["status"] == "completed"
      assert completed["result_digest"] == @hash_b

      assert {:ok, :already_recorded, completed2} =
               PipelineStatus.record_effect_receipt(run_id, 1, "exec_1", receipt, jopts)

      assert completed2 == completed

      # Wrong generation / wrong execution_id fail closed
      assert {:error, {:effect_conflict, :completed}} =
               PipelineStatus.record_effect_receipt(run_id, 9, "exec_1", receipt, jopts)

      assert {:error, {:effect_conflict, :completed}} =
               PipelineStatus.record_effect_receipt(run_id, 1, "exec_wrong", receipt, jopts)

      still = PipelineStatus.get_record(run_id, jopts)
      assert still.current_effect == completed
      assert still.effect_generation == 1

      assert {:ok, :settled, settled} =
               PipelineStatus.settle_effect(run_id, 1, "exec_1", jopts)

      assert settled["status"] == "settled"
      assert settled["execution_id"] == "exec_1"
      assert settled["generation"] == 1

      assert {:ok, :already_settled, settled2} =
               PipelineStatus.settle_effect(run_id, 1, "exec_1", jopts)

      assert settled2 == settled

      # Wrong execution_id / generation fails closed without mutating settled state
      assert {:error, {:effect_conflict, :stale_or_mismatch}} =
               PipelineStatus.settle_effect(run_id, 1, "exec_wrong", jopts)

      final = PipelineStatus.get_record(run_id, jopts)
      assert final.current_effect == settled
      assert final.effect_generation == 1
      assert PipelineStatus.get(run_id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Engine :journal_opts isolation
  # ---------------------------------------------------------------------------

  describe "Engine journal_opts isolation" do
    setup do
      start_isolated_journal("eng_jopts")
    end

    test "run admits/syncs/finalizes only against the isolated journal", ctx do
      jopts = [server: ctx.journal_name]
      run_id = ctx.run_id

      logs_root =
        Path.join(
          System.tmp_dir!(),
          "arbor_jopts_#{System.unique_integer([:positive, :monotonic])}"
        )

      on_exit(fn -> File.rm_rf(logs_root) end)

      graph = parse!(minimal_dot())

      assert {:ok, result} =
               Engine.run(graph,
                 run_id: run_id,
                 logs_root: logs_root,
                 journal_opts: jopts
               )

      assert result.run_id == run_id

      # Isolated journal holds the completed run.
      entry = PipelineStatus.get(run_id, jopts)
      assert entry != nil
      assert entry.status == :completed
      assert entry.run_id == run_id
      assert is_integer(entry.duration_ms)

      record = PipelineStatus.get_record(run_id, jopts)
      assert match?(%Record{status: :completed, run_id: ^run_id}, record)
      assert record.completed_count >= 1

      # Default (process-global) journal never received this run_id.
      assert PipelineStatus.get(run_id) == nil
      assert PipelineStatus.get_record(run_id) == nil
    end

    test "in-call heartbeat updates only the isolated journal", ctx do
      jopts = [server: ctx.journal_name]

      seed = %Record{
        run_id: ctx.run_id,
        pipeline_id: ctx.run_id,
        status: :running,
        total_nodes: 1,
        completed_count: 0,
        started_at: DateTime.utc_now(),
        owner_node: node(),
        source_node: node()
      }

      assert :ok = PipelineStatus.put(seed, jopts)
      assert :ok = Engine.touch_in_call_heartbeat_for_test(ctx.run_id, jopts)

      assert %Record{last_heartbeat: %DateTime{}} =
               PipelineStatus.get_record(ctx.run_id, jopts)

      assert PipelineStatus.get_record(ctx.run_id) == nil
    end

    test "invalid journal_opts fails before a probe handler executes", ctx do
      saved = Registry.snapshot_custom_handlers()
      Registry.reset_custom_handlers()
      on_exit(fn -> Registry.restore_custom_handlers(saved) end)

      :ok = Registry.register("l3b_probe", ProbeHandler)

      run_id = ctx.run_id <> "_invalid"
      parent = self()

      logs_root =
        Path.join(
          System.tmp_dir!(),
          "arbor_jopts_bad_#{System.unique_integer([:positive, :monotonic])}"
        )

      on_exit(fn ->
        File.rm_rf(logs_root)
        _ = PipelineStatus.delete(run_id)
      end)

      graph = parse!(probe_dot())

      # Non-keyword list
      assert {:error, :invalid_journal_opts} =
               Engine.run(graph,
                 run_id: run_id,
                 logs_root: logs_root,
                 journal_opts: [{:server, ctx.journal_name}, "not_a_pair"],
                 parent: parent
               )

      refute_receive {:probe_execute, _}, 50
      assert PipelineStatus.get(run_id) == nil
      assert PipelineStatus.get(run_id, server: ctx.journal_name) == nil

      # Non-list
      assert {:error, :invalid_journal_opts} =
               Engine.run(graph,
                 run_id: run_id <> "_map",
                 logs_root: logs_root,
                 journal_opts: %{server: ctx.journal_name},
                 parent: parent
               )

      refute_receive {:probe_execute, _}, 50

      # nil
      assert {:error, :invalid_journal_opts} =
               Engine.run(graph,
                 run_id: run_id <> "_nil",
                 logs_root: logs_root,
                 journal_opts: nil,
                 parent: parent
               )

      refute_receive {:probe_execute, _}, 50
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

  defp prepare_attrs(run_id) do
    %{
      "node_id" => "node_a",
      "execution_id" => "exec_1",
      "handler" => "Arbor.Orchestrator.Handlers.ExecHandler",
      "input_hash" => @hash_a,
      "idempotency_class" => "idempotent",
      "started_at" => @started_at,
      "run_id" => run_id
    }
  end

  defp receipt_attrs do
    %{
      "completed_at" => @completed_at,
      "outcome_status" => "success",
      "result_digest" => @hash_b
    }
  end

  defp minimal_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      work [label="Work", simulate="true"]
      exit [shape=Msquare]
      start -> work -> exit
    }
    """
  end

  defp probe_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l3b_probe"]
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
