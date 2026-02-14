defmodule Arbor.Orchestrator.EngineTest do
  use ExUnit.Case, async: true

  test "runs a minimal pipeline and writes checkpoint" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [label="Task", prompt="Do task"]
      exit [shape=Msquare]
      start -> task
      task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_test_#{System.unique_integer([:positive])}"
      )

    assert {:ok, result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)
    assert "start" in result.completed_nodes
    assert "task" in result.completed_nodes
    assert "exit" in result.completed_nodes
    assert File.exists?(Path.join(logs_root, "checkpoint.json"))
    assert File.exists?(Path.join(logs_root, "manifest.json"))
    assert File.exists?(Path.join(logs_root, "task/status.json"))
    assert File.exists?(Path.join(logs_root, "task/prompt.md"))
    assert File.exists?(Path.join(logs_root, "task/response.md"))
  end

  test "returns validation errors for invalid graph" do
    dot = """
    digraph Flow {
      task [label="Task"]
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)
    assert Enum.any?(diagnostics, &(&1.rule == "start_node" and &1.severity == :error))
  end

  test "routes FAIL using retry_target before unconditional edges" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      failing [simulate="fail", retry_target="repair"]
      repair [label="Repair path"]
      bypass [label="Should not be chosen on fail"]
      exit [shape=Msquare]

      start -> failing
      failing -> bypass
      repair -> exit
      bypass -> exit
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    assert graph.nodes["failing"].attrs["simulate"] == "fail"
    assert graph.nodes["failing"].attrs["retry_target"] == "repair"

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "repair" in result.completed_nodes
    refute "bypass" in result.completed_nodes
  end

  test "enforces goal gate and retries via retry_target until gate succeeds" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [goal_gate=true, retry_target="repair", simulate="fail_once"]
      repair [label="Repair work"]
      exit [shape=Msquare]

      start -> gate
      gate -> exit [condition="outcome=fail"]
      gate -> exit [condition="outcome=success"]
      repair -> gate
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, max_steps: 20)

    gate_runs = Enum.count(result.completed_nodes, &(&1 == "gate"))
    assert gate_runs >= 2
    assert "repair" in result.completed_nodes
    assert List.last(result.completed_nodes) == "exit"
  end

  test "emits lifecycle and checkpoint events via callback" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [label="Task"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    parent = self()

    on_event = fn event ->
      send(parent, {:event, event})
    end

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    assert_receive {:event, %{type: :pipeline_started}}
    assert_receive {:event, %{type: :stage_started, node_id: "start"}}
    assert_receive {:event, %{type: :checkpoint_saved}}
    assert_receive {:event, %{type: :pipeline_completed}}
  end

  test "retries on RETRY outcomes with backoff and emits retry events" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=2, retry_initial_delay_ms=1]
      exit [shape=Msquare]
      start -> flaky -> exit
    }
    """

    parent = self()

    on_event = fn event ->
      send(parent, {:event, event})
    end

    sleep_fn = fn _ms -> :ok end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: sleep_fn)
    assert "flaky" in result.completed_nodes

    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1}}
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 2}}
    assert_receive {:event, %{type: :stage_failed, node_id: "flaky", will_retry: false}}
  end

  test "retries on FAIL outcomes before routing failure path" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="fail", max_retries=2, retry_initial_delay_ms=1]
      recovery [label="Recovery"]
      exit [shape=Msquare]
      start -> flaky
      flaky -> recovery [condition="outcome=fail"]
      recovery -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert "recovery" in result.completed_nodes
    assert result.final_outcome.status == :success

    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1}}
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 2}}
    assert_receive {:event, %{type: :stage_failed, node_id: "flaky", will_retry: false}}
  end

  test "retry policy preset defines attempts when max_retries is omitted" do
    dot = """
    digraph Flow {
      retry_policy="patient"
      start [shape=Mdiamond]
      flaky [simulate="retry", retry_jitter=false]
      exit [shape=Msquare]
      start -> flaky -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               on_event: on_event,
               sleep_fn: fn _ -> :ok end
             )

    assert "flaky" in result.completed_nodes
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1}}
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 2}}
    assert_receive {:event, %{type: :stage_failed, node_id: "flaky", will_retry: false}}
  end

  test "applies retry jitter when enabled" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=1, retry_initial_delay_ms=10, retry_backoff_factor=1.0, retry_max_delay_ms=10, retry_jitter=true]
      exit [shape=Msquare]
      start -> flaky -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, _result} =
             Arbor.Orchestrator.run(dot,
               on_event: on_event,
               sleep_fn: fn _ -> :ok end,
               rand_fn: fn -> 0.0 end
             )

    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1, delay_ms: 5}}
  end

  test "retries on retryable exceptions and then fails when exhausted" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="raise_retryable", max_retries=1, retry_initial_delay_ms=1]
      exit [shape=Msquare]
      start -> flaky -> exit
    }
    """

    sleep_fn = fn _ms -> :ok end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, sleep_fn: sleep_fn)
    assert "flaky" in result.completed_nodes
    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason =~ "network timeout"
  end

  test "resume continues from saved checkpoint" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      b [label="B"]
      exit [shape=Msquare]
      start -> a -> b -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_resume_#{System.unique_integer([:positive])}"
      )

    assert {:error, :max_steps_exceeded} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, max_steps: 2)

    assert File.exists?(Path.join(logs_root, "checkpoint.json"))

    assert {:ok, resumed} = Arbor.Orchestrator.run(dot, logs_root: logs_root, resume: true)

    assert "start" in resumed.completed_nodes
    assert "a" in resumed.completed_nodes
    assert "b" in resumed.completed_nodes
    assert "exit" in resumed.completed_nodes
  end

  test "wait.human routes by interviewer choice" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Proceed?", fan_out="false"]
      yes_path [label="Yes path"]
      no_path [label="No path"]
      exit [shape=Msquare]
      start -> gate
      gate -> yes_path [label="[Y] Yes"]
      gate -> no_path [label="[N] No"]
      yes_path -> exit
      no_path -> exit
    }
    """

    interviewer = fn _question -> %{value: "N", selected_option: nil, text: nil} end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, interviewer: interviewer)
    assert "no_path" in result.completed_nodes
    refute "yes_path" in result.completed_nodes
    assert result.context["human.gate.selected"] == "N"
  end

  test "wait.human timeout uses default choice when configured" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Proceed?", human.default_choice="no_path", human.timeout_seconds=2.5, fan_out="false"]
      yes_path [label="Yes path"]
      no_path [label="No path"]
      exit [shape=Msquare]
      start -> gate
      gate -> yes_path [label="[Y] Yes"]
      gate -> no_path [label="[N] No"]
      yes_path -> exit
      no_path -> exit
    }
    """

    interviewer = fn question ->
      assert question.timeout_seconds == 2.5
      assert question.default == "no_path"
      :timeout
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, interviewer: interviewer)
    assert "no_path" in result.completed_nodes
  end

  test "wait.human timeout without default returns retry then fail on exhaustion" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Proceed?", max_retries=1, fan_out="false"]
      exit [shape=Msquare]
      start -> gate
      gate -> exit [label="[Y] Yes"]
    }
    """

    interviewer = fn _question -> :timeout end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, interviewer: interviewer, sleep_fn: fn _ -> :ok end)

    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason == "max retries exceeded"
  end

  test "tuple interviewer module routes by queued answer" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Pick one", fan_out="false"]
      yes_path [label="Yes path"]
      no_path [label="No path"]
      exit [shape=Msquare]
      start -> gate
      gate -> yes_path [label="[Y] Yes"]
      gate -> no_path [label="[N] No"]
      yes_path -> exit
      no_path -> exit
    }
    """

    interviewer = {Arbor.Orchestrator.Human.QueueInterviewer, [answers: ["N"]]}

    assert {:ok, result} = Arbor.Orchestrator.run(dot, interviewer: interviewer)
    assert "no_path" in result.completed_nodes
  end

  test "applies model stylesheet with specificity and explicit override" do
    dot = """
    digraph Flow {
      model_stylesheet="* { llm_provider: anthropic } .code { llm_model: claude-opus } #critical { llm_model: gpt-5 } #critical { reasoning_effort: high }"
      start [shape=Mdiamond]
      critical [class="code"]
      explicit [class="code", llm_model="explicit-model"]
      exit [shape=Msquare]
      start -> critical -> explicit -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_style_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    {:ok, critical_status_json} = File.read(Path.join([logs_root, "critical", "status.json"]))
    {:ok, critical_status} = Jason.decode(critical_status_json)
    critical_updates = critical_status["context_updates"]

    assert critical_updates["llm.provider"] == "anthropic"
    assert critical_updates["llm.model"] == "gpt-5"
    assert critical_updates["llm.reasoning_effort"] == "high"

    {:ok, explicit_status_json} = File.read(Path.join([logs_root, "explicit", "status.json"]))
    {:ok, explicit_status} = Jason.decode(explicit_status_json)
    explicit_updates = explicit_status["context_updates"]

    assert explicit_updates["llm.provider"] == "anthropic"
    assert explicit_updates["llm.model"] == "explicit-model"
  end

  test "resolves fidelity precedence from edge then node then graph default" do
    dot = """
    digraph Flow {
      default_fidelity="summary:low"
      start [shape=Mdiamond]
      task [fidelity="compact", thread_id="node-thread"]
      another [thread_id="another-node-thread"]
      exit [shape=Msquare]
      start -> task [fidelity="full", thread_id="edge-thread"]
      task -> another
      another -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    assert_receive {:event,
                    %{
                      type: :fidelity_resolved,
                      node_id: "task",
                      mode: "full",
                      thread_id: "node-thread"
                    }}

    assert_receive {:event, %{type: :fidelity_resolved, node_id: "another", mode: "summary:low"}}
  end

  test "parallel handler executes branches and routes to fan-in" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", fan_out="false"]
      branch_a [label="A"]
      branch_b [label="B"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]

      start -> parallel
      parallel -> branch_a
      parallel -> branch_b
      branch_a -> join
      branch_b -> join
      join -> exit
    }
    """

    branch_executor = fn branch_node_id, _context, _graph, _opts ->
      case branch_node_id do
        "branch_a" -> %{"id" => "branch_a", "status" => "success", "score" => 0.2}
        "branch_b" -> %{"id" => "branch_b", "status" => "success", "score" => 0.9}
      end
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, parallel_branch_executor: branch_executor)

    assert "parallel" in result.completed_nodes
    assert "join" in result.completed_nodes
    assert result.context["parallel.success_count"] == 2
    assert result.context["parallel.fan_in.best_id"] == "branch_b"
    assert result.context["parallel.fan_in.best_outcome"] == "success"
    refute "branch_a" in result.completed_nodes
    refute "branch_b" in result.completed_nodes
  end

  test "fan-in fails when all parallel candidates fail" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", fan_out="false"]
      branch_a [label="A"]
      branch_b [label="B"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]

      start -> parallel
      parallel -> branch_a
      parallel -> branch_b
      branch_a -> join
      branch_b -> join
      join -> exit [condition="outcome=success"]
    }
    """

    branch_executor = fn branch_node_id, _context, _graph, _opts ->
      %{"id" => branch_node_id, "status" => "fail", "score" => 0.0}
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, parallel_branch_executor: branch_executor)

    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason == "All parallel candidates failed"
  end

  test "manager loop exits successfully when child completes" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, manager.poll_interval="1ms", manager.max_cycles=5]
      exit [shape=Msquare]
      start -> manager -> exit
    }
    """

    observer = fn local, _node, _opts ->
      cycle = Map.get(local, "manager.cycle", 0)

      if cycle >= 2 do
        %{
          "context.stack.child.status" => "completed",
          "context.stack.child.outcome" => "success"
        }
      else
        %{"context.stack.child.status" => "running"}
      end
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               manager_observe: observer,
               sleep_fn: fn _ -> :ok end
             )

    assert "manager" in result.completed_nodes
    assert result.context["context.stack.child.status"] == "completed"
    assert result.context["manager.cycle"] >= 2
  end

  test "manager loop fails when max cycles exceeded" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, manager.poll_interval="1ms", manager.max_cycles=2]
      exit [shape=Msquare]
      start -> manager -> exit [condition="outcome=success"]
    }
    """

    observer = fn _local, _node, _opts ->
      %{"context.stack.child.status" => "running"}
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               manager_observe: observer,
               sleep_fn: fn _ -> :ok end
             )

    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason == "Max cycles exceeded"
  end

  test "writes stage status.json with appendix C contract keys" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [label="Task"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_status_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    {:ok, status_json} = File.read(Path.join([logs_root, "task", "status.json"]))
    {:ok, status} = Jason.decode(status_json)

    assert status["outcome"] == "success"
    assert Map.has_key?(status, "preferred_next_label")
    assert is_list(status["suggested_next_ids"])
    assert is_map(status["context_updates"])
    assert Map.has_key?(status, "notes")
  end

  test "parallel executes branch subgraphs to inferred fan-in target" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", fan_out="false"]
      a1 [label="A1"]
      a2 [label="A2", score=0.2]
      b1 [label="B1"]
      b2 [label="B2", score=0.9]
      join [shape=tripleoctagon]
      exit [shape=Msquare]

      start -> parallel
      parallel -> a1
      parallel -> b1
      a1 -> a2
      b1 -> b2
      a2 -> join
      b2 -> join
      join -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "parallel" in result.completed_nodes
    assert "join" in result.completed_nodes
    assert result.context["parallel.success_count"] == 2
    assert result.context["parallel.fan_in.best_id"] == "b2"
    assert result.context["parallel.fan_in.best_score"] == 0.9
  end

  test "unconditional edges fan out by default" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      b [label="B"]
      done [label="Done"]
      exit [shape=Msquare]

      start -> a
      start -> b
      a -> done
      b -> done
      done -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    # Both branches should execute
    assert "a" in result.completed_nodes
    assert "b" in result.completed_nodes
    assert "done" in result.completed_nodes
    assert "exit" in result.completed_nodes

    # Fan-out event should be emitted
    assert_receive {:event, %{type: :fan_out_detected, node_id: "start", branch_count: 2}}
  end

  test "fan_out=false forces single path selection" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond, fan_out="false"]
      a [label="A"]
      b [label="B"]
      done [label="Done"]
      exit [shape=Msquare]

      start -> a
      start -> b
      a -> done
      b -> done
      done -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    # Only one of a or b should execute (select_next_edge picks the first/preferred)
    a_ran = "a" in result.completed_nodes
    b_ran = "b" in result.completed_nodes
    assert a_ran or b_ran, "At least one branch should execute"
    refute a_ran and b_ran, "Only one branch should execute when fan_out=false"

    assert "done" in result.completed_nodes
    assert "exit" in result.completed_nodes

    # No fan-out event should be emitted
    refute_receive {:event, %{type: :fan_out_detected}}
  end

  test "fan-in gate waits for all branches before proceeding" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      fast [label="Fast"]
      slow [label="Slow"]
      join [label="Join"]
      exit [shape=Msquare]

      start -> fast
      start -> slow
      fast -> join
      slow -> join
      join -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    # Both branches must complete before join
    assert "fast" in result.completed_nodes
    assert "slow" in result.completed_nodes
    assert "join" in result.completed_nodes

    # Join must come after both branches in execution order
    fast_idx = Enum.find_index(result.completed_nodes, &(&1 == "fast"))
    slow_idx = Enum.find_index(result.completed_nodes, &(&1 == "slow"))
    join_idx = Enum.find_index(result.completed_nodes, &(&1 == "join"))

    assert join_idx > fast_idx, "join should execute after fast"
    assert join_idx > slow_idx, "join should execute after slow"

    # Fan-in deferred event should fire for the second branch's target
    assert_receive {:event, %{type: :fan_in_deferred, node_id: "join"}}
  end

  test "three-way fan-out executes all branches" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      b [label="B"]
      c [label="C"]
      merge [label="Merge"]
      exit [shape=Msquare]

      start -> a
      start -> b
      start -> c
      a -> merge
      b -> merge
      c -> merge
      merge -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    assert "a" in result.completed_nodes
    assert "b" in result.completed_nodes
    assert "c" in result.completed_nodes
    assert "merge" in result.completed_nodes
    assert "exit" in result.completed_nodes

    # Fan-out detected with 3 branches
    assert_receive {:event, %{type: :fan_out_detected, node_id: "start", branch_count: 3}}
  end

  test "fan-out with conditional edges does not fan out conditional branches" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      b [label="B"]
      fail_path [label="Fail path"]
      exit [shape=Msquare]

      start -> a
      start -> b
      start -> fail_path [condition="outcome=fail"]
      a -> exit
      b -> exit
      fail_path -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, on_event: on_event)

    # Both unconditional branches should execute
    assert "a" in result.completed_nodes
    assert "b" in result.completed_nodes
    # Conditional branch should NOT execute (start succeeds, so outcome=fail doesn't match)
    refute "fail_path" in result.completed_nodes
  end

  test "tool handler respects pre-hook skip and emits hook events" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      tool [shape=parallelogram, tool_command="echo run"]
      exit [shape=Msquare]
      start -> tool -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               tool_hooks: %{pre: fn _payload -> :skip end},
               on_event: on_event
             )

    assert result.final_outcome.status == :success
    assert result.context["outcome"] == "success"
    assert_receive {:event, %{type: :tool_hook_pre, node_id: "tool"}}
  end
end
