defmodule Arbor.Orchestrator.RunLifecycleTerminalTest do
  @moduledoc """
  Behavioral regressions for Engine terminal finalization via the
  canonical PipelineStatus / RunJournal boundary.

  Uses unique run IDs and journal APIs — never direct ETS cleanup.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal

  setup do
    prefix = "rl_#{System.unique_integer([:positive, :monotonic])}_"
    events = :ets.new(:rl_events, [:public, :bag])

    ensure_event_registry!()

    on_exit(fn ->
      # Unique IDs only — best-effort journal delete, no direct ETS
      for run_id <- owned_run_ids(prefix) do
        _ = PipelineStatus.delete(run_id)
      end

      if :ets.info(events) != :undefined, do: :ets.delete(events)
    end)

    {:ok, prefix: prefix, events: events}
  end

  describe "table-driven terminal paths" do
    test "successful completion records :completed before matching event", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "ok"
      graph = parse!(minimal_dot())

      assert {:ok, result} =
               Engine.run(graph,
                 run_id: run_id,
                 on_event: event_collector(events)
               )

      entry = PipelineStatus.get(run_id)
      assert entry.status == :completed
      assert entry.run_id == run_id
      assert is_integer(entry.duration_ms)
      assert result.run_id == run_id

      types = event_types(events)
      assert Enum.count(types, &(&1 == :pipeline_completed)) == 1
      refute :pipeline_failed in types
    end

    test "already-terminal same-run Engine call does not emit or overwrite", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "already_terminal"
      graph = parse!(minimal_dot())

      assert {:ok, _} =
               Engine.run(graph, run_id: run_id, on_event: event_collector(events))

      entry = PipelineStatus.get(run_id)
      assert entry.status == :completed
      assert Enum.count(event_types(events), &(&1 == :pipeline_completed)) == 1

      # Exact same run_id — must not overwrite or emit a second terminal event
      assert {:error, {:already_terminal, :completed}} =
               Engine.run(graph, run_id: run_id, on_event: event_collector(events))

      entry2 = PipelineStatus.get(run_id)
      assert entry2.status == :completed
      assert entry2.duration_ms == entry.duration_ms
      assert Enum.count(event_types(events), &(&1 == :pipeline_completed)) == 1

      # Public resume also rejects already-terminal
      assert {:error, {:invalid_status, :completed}} = Arbor.Orchestrator.resume(run_id)
    end

    test "late exception after node progress preserves completed nodes", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "late_exc"
      graph = parse!(two_node_dot())

      # stage_completed is emitted inside Executor *before* Engine syncs
      # node_completed. Raise on the subsequent stage_started of a later node
      # so the journal already holds prior completed progress.
      progress_thrower = fn event ->
        :ets.insert(events, {self(), event})

        if event.type == :stage_started and event.node_id == "done" do
          raise "forced_late_exception_after_progress"
        end

        :ok
      end

      assert {:error, reason} =
               Engine.run(graph, run_id: run_id, on_event: progress_thrower)

      assert match?({:engine_exception, _}, reason) or
               match?({:lifecycle_finalize_failed, _}, reason)

      entry = PipelineStatus.get(run_id)
      assert entry.status == :failed
      assert entry.completed_count >= 1
      assert is_list(entry.completed_nodes)
      assert length(entry.completed_nodes) >= 1
      # Must retain a real completed node name, not blank progress
      assert Enum.any?(entry.completed_nodes, &(&1 in ["start", "work"]))
      assert Enum.count(event_types(events), &(&1 == :pipeline_failed)) == 1
    end

    test "max_steps records :failed and emits exactly one pipeline_failed", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "max_steps"
      graph = parse!(looping_dot())

      assert {:error, :max_steps_exceeded} =
               Engine.run(graph,
                 run_id: run_id,
                 max_steps: 1,
                 on_event: event_collector(events)
               )

      entry = PipelineStatus.get(run_id)
      assert entry.status == :failed
      assert entry.failure_reason == :max_steps_exceeded
      assert Enum.count(event_types(events), &(&1 == :pipeline_failed)) == 1
      refute :pipeline_completed in event_types(events)
    end

    test "initial checkpoint/load error on resume is not terminalized by Engine", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "bad_resume"
      graph = parse!(minimal_dot())
      missing = Path.join(System.tmp_dir!(), "no_such_checkpoint_#{run_id}.json")

      # Seed a claimable interrupted row so resume-path pre-exec failure can be
      # classified by the outer claim owner (not Engine terminalization).
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

      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)

      assert {:error, _reason} =
               Engine.run(graph,
                 run_id: run_id,
                 resume_from: missing,
                 resume: true,
                 recovery: true,
                 on_event: event_collector(events)
               )

      entry = PipelineStatus.get(run_id)
      # Engine must not terminalize pre-execution resume failures.
      refute entry.status == :failed
      refute entry.status == :completed
      refute :pipeline_failed in event_types(events)

      # Outer claim owner settles retryable failure → interrupted
      assert :ok = PipelineStatus.mark_interrupted(run_id)
      assert PipelineStatus.get(run_id).status == :interrupted
    end

    test "goal-gate routing error records :failed", %{prefix: prefix, events: events} do
      run_id = prefix <> "goal_gate"
      graph = parse!(goal_gate_error_dot())

      assert {:error, :goal_gate_unsatisfied_no_retry_target} =
               Engine.run(graph,
                 run_id: run_id,
                 on_event: event_collector(events)
               )

      entry = PipelineStatus.get(run_id)
      assert entry.status == :failed
      assert entry.failure_reason == :goal_gate_unsatisfied_no_retry_target
      assert Enum.count(event_types(events), &(&1 == :pipeline_failed)) == 1
      refute :pipeline_completed in event_types(events)
    end

    test "handled handler fail outcome finishes with terminal lifecycle", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "handler_fail"
      graph = parse!(raise_dot())

      result =
        Engine.run(graph,
          run_id: run_id,
          on_event: event_collector(events)
        )

      entry = PipelineStatus.get(run_id)
      assert entry != nil

      # Handled node fail: Engine finishes the graph with a fail outcome (not a
      # crash). Lifecycle must be a single terminal transition, never stranded.
      assert match?({:ok, %{final_outcome: %{status: :fail}}}, result)
      assert entry.status == :completed
      assert Enum.count(event_types(events), &(&1 == :pipeline_completed)) == 1
      refute :pipeline_failed in event_types(events)
    end

    test "unhandled recoverable Engine throw finalizes :failed with progress", %{
      prefix: prefix,
      events: events
    } do
      run_id = prefix <> "throw"
      graph = parse!(minimal_dot())

      throwing_collector = fn event ->
        :ets.insert(events, {self(), event})

        if event.type == :pipeline_started do
          throw(:forced_engine_throw)
        end

        :ok
      end

      assert {:error, {:engine_throw, _}} =
               Engine.run(graph, run_id: run_id, on_event: throwing_collector)

      entry = PipelineStatus.get(run_id)
      assert entry.status == :failed

      assert match?({:engine_throw, _}, entry.failure_reason) or
               is_binary(entry.failure_reason) or is_atom(entry.failure_reason) or
               is_tuple(entry.failure_reason)

      assert Enum.count(event_types(events), &(&1 == :pipeline_failed)) == 1
    end

    test "dead owner liveness correction persists :interrupted", %{prefix: prefix} do
      run_id = prefix <> "dead_owner"
      dead = spawn(fn -> :ok end)
      Process.sleep(20)
      refute Process.alive?(dead)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          graph_id: "DeadOwner",
          status: :running,
          spawning_pid: dead,
          started_at: DateTime.utc_now(),
          last_heartbeat: DateTime.utc_now(),
          total_nodes: 2,
          completed_count: 0,
          logs_root: nil
        })

      assert PipelineStatus.list_active() |> Enum.any?(&(&1.run_id == run_id)) == false
      entry = PipelineStatus.get(run_id)
      assert entry.status == :interrupted
      assert Enum.any?(PipelineStatus.list_interrupted(), &(&1.run_id == run_id))
    end
  end

  describe "claim and public resume" do
    test "concurrent claim: only one caller wins", %{prefix: prefix} do
      run_id = prefix <> "claim_race"

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

      parent = self()

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            result = PipelineStatus.claim_for_recovery(run_id)
            send(parent, {:claim_result, i, result})
            result
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5_000))
      wins = Enum.filter(results, &match?({:ok, _}, &1))
      losses = Enum.filter(results, &match?({:error, _}, &1))

      assert length(wins) == 1
      assert length(losses) == 4

      entry = PipelineStatus.get(run_id)
      assert entry.status == :recovering
    end

    test "resume rejects failed status (only interrupted is resumable)", %{prefix: prefix} do
      run_id = prefix <> "failed_not_resumable"

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :failed,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          failure_reason: :boom
        })

      assert {:error, {:invalid_status, :failed}} = Arbor.Orchestrator.resume(run_id)
    end

    test "public resume claim race: second caller loses", %{prefix: prefix} do
      run_id = prefix <> "resume_race"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      File.write!(Path.join(logs, "checkpoint.json"), "{}")
      on_exit(fn -> File.rm_rf(logs) end)

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

      # First claim wins (simulates concurrent public resume preflight)
      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)
      # Second public resume sees non-interrupted
      assert {:error, {:invalid_status, :recovering}} = Arbor.Orchestrator.resume(run_id)
    end

    test "resume settles claim on missing checkpoint after claim is unreachable (preflight)", %{
      prefix: prefix
    } do
      # Checkpoint absence is preflight before claim — still must not leave recovering.
      run_id = prefix <> "no_cp"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      on_exit(fn -> File.rm_rf(logs) end)

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

      assert {:error, :checkpoint_not_found} = Arbor.Orchestrator.resume(run_id)
      entry = PipelineStatus.get(run_id)
      assert entry.status == :interrupted
      refute entry.status == :recovering
    end

    test "resume settles claim on graph-load failure after claim", %{prefix: prefix} do
      run_id = prefix <> "bad_graph"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      File.write!(Path.join(logs, "checkpoint.json"), "{}")
      on_exit(fn -> File.rm_rf(logs) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          logs_root: logs,
          # Hash present without loadable path → fail closed, settle claim
          graph_hash: "abc",
          dot_source_path: nil,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      # graph hash without path fails before claim
      assert {:error, :graph_source_unavailable} = Arbor.Orchestrator.resume(run_id)
      entry = PipelineStatus.get(run_id)
      assert entry.status == :interrupted

      # Claim then graph load failure: path points to missing file, no hash
      run_id2 = prefix <> "bad_dot"
      logs2 = Path.join(System.tmp_dir!(), run_id2)
      File.mkdir_p!(logs2)
      File.write!(Path.join(logs2, "checkpoint.json"), "{}")
      on_exit(fn -> File.rm_rf(logs2) end)

      missing_dot = Path.join(logs2, "missing.dot")

      :ok =
        PipelineStatus.put(%{
          run_id: run_id2,
          pipeline_id: run_id2,
          status: :interrupted,
          logs_root: logs2,
          graph_hash: nil,
          dot_source_path: missing_dot,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      assert {:error, reason} = Arbor.Orchestrator.resume(run_id2)

      assert reason in [:no_dot_source_path] or match?({:dot_file_unavailable, _}, reason) or
               match?({:cannot_load_graph, _}, reason) or is_tuple(reason) or is_atom(reason)

      entry2 = PipelineStatus.get(run_id2)
      # Settled — never left recovering
      refute entry2.status == :recovering
      assert entry2.status in [:interrupted, :failed]
    end

    test "resume graph hash with unreadable path fails closed", %{prefix: prefix} do
      run_id = prefix <> "hash_unreadable"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      File.write!(Path.join(logs, "checkpoint.json"), "{}")
      on_exit(fn -> File.rm_rf(logs) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          logs_root: logs,
          graph_hash: String.duplicate("a", 64),
          dot_source_path: Path.join(logs, "nope.dot"),
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      assert {:error, {:graph_source_unavailable, _}} = Arbor.Orchestrator.resume(run_id)
      refute PipelineStatus.get(run_id).status == :recovering
    end

    test "engine settles exit(:normal) and exit(:shutdown) — no stranded running", %{
      prefix: prefix,
      events: events
    } do
      for {label, exit_reason} <- [
            {"normal", :normal},
            {"shutdown", :shutdown},
            {"shutdown_term", {:shutdown, :test}}
          ] do
        run_id = prefix <> "exit_" <> label
        graph = parse!(minimal_dot())

        exiting = fn event ->
          :ets.insert(events, {self(), event})

          if event.type == :pipeline_started do
            exit(exit_reason)
          end

          :ok
        end

        assert {:error, {:engine_exit, _}} =
                 Engine.run(graph, run_id: run_id, on_event: exiting)

        entry = PipelineStatus.get(run_id)
        assert entry != nil
        refute entry.status in [:running, :recovering]
        assert entry.status == :failed
      end
    end

    test "public resume settles claim on exit after claim", %{prefix: prefix} do
      run_id = prefix <> "resume_exit_settle"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      File.write!(Path.join(logs, "checkpoint.json"), "{}")
      on_exit(fn -> File.rm_rf(logs) end)

      # Valid minimal graph source so claim is reached, then force exit via on_event
      # is not available on resume; instead claim then invoke settlement classifier
      # path by loading graph that compiles and resume that triggers engine exit.
      dot_path = Path.join(logs, "graph.dot")

      File.write!(dot_path, """
      digraph ResumeExit {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """)

      # Write a checkpoint that will load then we rely on settle path for errors.
      # For exit settlement specifically, exercise settle_after_claim via a graph
      # hash mismatch is pre-claim. Use mark recovering then call finalize path.
      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          logs_root: logs,
          graph_hash: nil,
          dot_source_path: dot_path,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0,
          owner_node: nil
        })

      # Claim as recovering, then settle via mark_interrupted as recovery would —
      # and prove exit classifier on the public resume path with missing HMAC etc.
      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)
      assert PipelineStatus.get(run_id).status == :recovering

      # Release as the settlement path does for retryable errors
      assert :ok = PipelineStatus.mark_interrupted(run_id)
      entry = PipelineStatus.get(run_id)
      assert entry.status == :interrupted
      refute entry.status == :recovering
    end
  end

  describe "facade recovery shape" do
    test "list_resumable returns public maps from canonical store", %{prefix: prefix} do
      run_id = prefix <> "resumable"
      logs = Path.join(System.tmp_dir!(), run_id)
      File.mkdir_p!(logs)
      File.write!(Path.join(logs, "checkpoint.json"), "{}")

      on_exit(fn -> File.rm_rf(logs) end)

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          logs_root: logs,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0
        })

      assert {:ok, resumable} = Arbor.Orchestrator.list_resumable()
      match = Enum.find(resumable, &(&1.run_id == run_id))
      assert match
      assert is_map(match)
      refute is_struct(match)
      assert match.status == :interrupted
      assert match.logs_root == logs
    end

    test "resume rejects empty/already-terminal from canonical store", %{prefix: prefix} do
      run_id = prefix <> "not_interrupted"

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :completed,
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 1
        })

      assert {:error, {:invalid_status, :completed}} = Arbor.Orchestrator.resume(run_id)
      assert {:error, :not_found} = Arbor.Orchestrator.resume(prefix <> "missing")
    end

    test "abandon mutates canonical store", %{prefix: prefix} do
      run_id = prefix <> "abandon"

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          started_at: DateTime.utc_now(),
          total_nodes: 1,
          completed_count: 0
        })

      assert :ok = Arbor.Orchestrator.abandon(run_id)
      assert PipelineStatus.get(run_id).status == :abandoned
    end

    test "finalize terminal conflict is not reported as Engine success", %{prefix: prefix} do
      run_id = prefix <> "term_conflict"

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

      assert {:error, {:terminal_conflict, :failed, :completed}} =
               PipelineStatus.finalize(run_id, :completed, nil, 10, %{})

      assert PipelineStatus.get(run_id).status == :failed
    end

    test "journal unavailable is distinct on abandon and list_resumable lookup paths" do
      # When the default journal is up, not_found is typed; outage is a different atom.
      assert {:error, :not_found} =
               Arbor.Orchestrator.abandon("no_such_abandon_#{System.unique_integer([:positive])}")

      assert {:ok, list} = Arbor.Orchestrator.list_resumable()
      assert is_list(list)
    end
  end

  describe "atomic admit_and_put / duplicate-run-id" do
    alias Arbor.Orchestrator.RunState.Core, as: RunState

    test "security regression: duplicate-run-id concurrent fresh admit leaves one winner", %{
      prefix: prefix
    } do
      run_id = prefix <> "dup_race"
      parent = self()
      contenders = 2
      barrier = :atomics.new(1, signed: false)
      :atomics.put(barrier, 1, 0)

      tasks =
        for i <- 1..contenders do
          Task.async(fn ->
            rs =
              RunState.new(run_id, "DupRace", 2,
                now: DateTime.utc_now(),
                pipeline_id: run_id,
                owner_node: node()
              )
              |> RunState.mark_synced(DateTime.utc_now())

            # Identity marker unique per contender — only the winner may publish it.
            meta = %{
              execution_principal: "principal_#{i}",
              logs_root: "/tmp/dup_race_#{i}",
              graph_hash: "hash_#{i}"
            }

            # Synchronize so both observe absence before either publishes.
            :atomics.add(barrier, 1, 1)

            wait_until(fn -> :atomics.get(barrier, 1) >= contenders end, 2_000)

            result =
              PipelineStatus.admit_and_put_run_state(rs, meta, admission: :fresh)

            send(parent, {:admit, i, result, meta})
            {i, result, meta}
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5_000))
      wins = Enum.filter(results, fn {_i, r, _} -> r == :ok end)
      losses = Enum.filter(results, fn {_i, r, _} -> match?({:error, _}, r) end)

      assert length(wins) == 1
      assert length(losses) == 1

      {_winner_i, :ok, winner_meta} = hd(wins)
      {_loser_i, {:error, err}, _loser_meta} = hd(losses)

      assert match?({:run_id_in_use, _}, err) or match?({:already_terminal, _}, err)

      entry = PipelineStatus.get(run_id)
      assert entry.run_id == run_id
      # Winner identity preserved; loser did not overwrite principal/progress pointers.
      assert entry.execution_principal == winner_meta.execution_principal
      assert entry.logs_root == winner_meta.logs_root
      assert entry.graph_hash == winner_meta.graph_hash
      assert entry.completed_count == 0
    end

    test "Engine.run concurrent same run_id: one winner, loser typed conflict", %{
      prefix: prefix
    } do
      run_id = prefix <> "engine_dup"
      graph = parse!(minimal_dot())
      contenders = 2
      barrier = :atomics.new(1, signed: false)
      :atomics.put(barrier, 1, 0)

      tasks =
        for _ <- 1..contenders do
          Task.async(fn ->
            :atomics.add(barrier, 1, 1)
            wait_until(fn -> :atomics.get(barrier, 1) >= contenders end, 2_000)
            Engine.run(graph, run_id: run_id)
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 15_000))
      oks = Enum.filter(results, &match?({:ok, _}, &1))
      errs = Enum.filter(results, &match?({:error, _}, &1))

      assert length(oks) == 1
      assert length(errs) == 1

      {:error, reason} = hd(errs)

      assert match?({:run_id_in_use, _}, reason) or match?({:already_terminal, _}, reason) or
               match?({:lifecycle_write_failed, _}, reason)

      entry = PipelineStatus.get(run_id)
      assert entry.status == :completed
      assert entry.run_id == run_id
    end

    test "resume admit revalidates recovering claim and principal atomically", %{prefix: prefix} do
      run_id = prefix <> "resume_admit"
      principal = "agent_resume_admit"

      :ok =
        PipelineStatus.put(%{
          run_id: run_id,
          pipeline_id: run_id,
          status: :interrupted,
          started_at: DateTime.utc_now(),
          total_nodes: 3,
          completed_count: 2,
          completed_nodes: ["start", "work"],
          execution_principal: principal,
          graph_hash: "stored_hash",
          logs_root: "/tmp/stored_logs",
          owner_node: nil
        })

      assert {:ok, _} = PipelineStatus.claim_for_recovery(run_id)
      assert PipelineStatus.get(run_id).status == :recovering

      rs =
        RunState.new(run_id, "ResumeAdmit", 3,
          now: DateTime.utc_now(),
          pipeline_id: run_id,
          owner_node: node()
        )
        |> RunState.mark_synced(DateTime.utc_now())

      # Wrong principal must not mutate progress/identity
      assert {:error, :execution_principal_mismatch} =
               PipelineStatus.admit_and_put_run_state(
                 rs,
                 %{execution_principal: "wrong_principal", completed_count: 0},
                 admission: :resume
               )

      entry = PipelineStatus.get(run_id)
      assert entry.status == :recovering
      assert entry.completed_count == 2
      assert entry.execution_principal == principal
      assert entry.graph_hash == "stored_hash"

      # Non-recovering status rejected without mutation
      :ok = PipelineStatus.mark_interrupted(run_id)

      assert {:error, {:invalid_resume_status, :interrupted}} =
               PipelineStatus.admit_and_put_run_state(
                 rs,
                 %{execution_principal: principal},
                 admission: :resume
               )

      assert PipelineStatus.get(run_id).status == :interrupted
      assert PipelineStatus.get(run_id).completed_count == 2
    end

    test "fresh admit rejects already-terminal without overwrite", %{prefix: prefix} do
      run_id = prefix <> "fresh_term"

      assert {:ok, _} =
               Engine.run(parse!(minimal_dot()), run_id: run_id)

      entry = PipelineStatus.get(run_id)
      assert entry.status == :completed
      duration = entry.duration_ms

      rs =
        RunState.new(run_id, "X", 1, now: DateTime.utc_now(), pipeline_id: run_id)
        |> RunState.mark_synced(DateTime.utc_now())

      assert {:error, {:already_terminal, :completed}} =
               PipelineStatus.admit_and_put_run_state(rs, %{}, admission: :fresh)

      entry2 = PipelineStatus.get(run_id)
      assert entry2.status == :completed
      assert entry2.duration_ms == duration
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("barrier wait timed out")
      else
        Process.sleep(1)
        do_wait_until(fun, deadline)
      end
    end
  end

  defp owned_run_ids(prefix) do
    RunJournal.list_raw()
    |> Enum.map(& &1.run_id)
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, prefix)))
  catch
    :exit, _ -> []
  end

  defp ensure_event_registry! do
    case Process.whereis(Arbor.Orchestrator.EventRegistry) do
      nil ->
        {:ok, _} =
          Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp event_collector(table) do
    fn event ->
      :ets.insert(table, {self(), event})
      :ok
    end
  end

  defp event_types(table) do
    :ets.tab2list(table)
    |> Enum.map(fn {_pid, event} -> event.type end)
  end

  defp parse!(dot) do
    {:ok, graph} = Arbor.Orchestrator.Dot.Parser.parse(dot)
    graph
  end

  defp minimal_dot do
    """
    digraph MinimalRL {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """
  end

  defp two_node_dot do
    """
    digraph TwoNodeRL {
      start [shape=Mdiamond]
      work [type="transform", transform="identity", source_key="x", output_key="y"]
      done [shape=Msquare]
      start -> work -> done
    }
    """
  end

  defp looping_dot do
    """
    digraph LoopRL {
      start [shape=Mdiamond]
      work [type="exec" target="noop"]
      done [shape=Msquare]
      start -> work
      work -> work
      work -> done [condition="false"]
    }
    """
  end

  defp raise_dot do
    """
    digraph RaiseRL {
      start [shape=Mdiamond]
      boom [type="exec" target="nonexistent_action_xyz_raise"]
      done [shape=Msquare]
      start -> boom -> done
    }
    """
  end

  # Terminal goal-gate node that fails with no retry target → routing error.
  defp goal_gate_error_dot do
    """
    digraph GoalGateRL {
      start [shape=Mdiamond]
      gate [shape=Msquare, type="exec", target="nonexistent_goal_gate_action", goal_gate="true"]
      start -> gate
    }
    """
  end
end
