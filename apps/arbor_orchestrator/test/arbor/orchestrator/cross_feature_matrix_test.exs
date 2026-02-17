defmodule Arbor.Orchestrator.CrossFeatureMatrixTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry

  test "matrix: parse simple linear pipeline" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      b [label="B"]
      exit [shape=Msquare]
      start -> a -> b -> exit
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    assert map_size(graph.nodes) == 4
    assert length(graph.edges) == 3
  end

  test "matrix: parse graph-level attributes and multiline attrs" do
    dot = """
    digraph Flow {
      goal="Ship feature"
      label="pipeline"
      start [shape=Mdiamond]
      task [
        label="Task",
        prompt="Use $goal"
      ]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    assert graph.attrs["goal"] == "Ship feature"
    assert graph.attrs["label"] == "pipeline"
    assert graph.nodes["task"].attrs["prompt"] == "Use $goal"
  end

  test "matrix: validate missing start and missing exit errors" do
    no_start = """
    digraph Flow {
      task [label="Task"]
      exit [shape=Msquare]
    }
    """

    no_exit = """
    digraph Flow {
      start [shape=Mdiamond]
      task [label="Task"]
    }
    """

    assert Enum.any?(
             Arbor.Orchestrator.validate(no_start),
             &(&1.rule == "start_node" and &1.severity == :error)
           )

    assert Enum.any?(
             Arbor.Orchestrator.validate(no_exit),
             &(&1.rule == "terminal_node" and &1.severity == :error)
           )
  end

  test "matrix: validate orphan node produces reachability diagnostic" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      orphan [label="Orphan"]
      exit [shape=Msquare]
      start -> a -> exit
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)

    assert Enum.any?(
             diagnostics,
             &(&1.rule == "reachability" and &1.node_id == "orphan" and
                 &1.severity in [:warning, :error])
           )
  end

  test "matrix: execute linear pipeline end-to-end" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A"]
      b [label="B"]
      exit [shape=Msquare]
      start -> a -> b -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert List.last(result.completed_nodes) == "exit"
  end

  test "matrix: execute conditional branching success/fail paths" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      decision [shape=box, simulate="fail"]
      ok [label="ok"]
      bad [label="bad"]
      exit [shape=Msquare]
      start -> decision
      decision -> ok [condition="outcome=success"]
      decision -> bad [condition="outcome=fail"]
      ok -> exit
      bad -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "bad" in result.completed_nodes
    refute "ok" in result.completed_nodes
  end

  test "matrix: goal gate blocks exit until satisfied" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [goal_gate=true, retry_target="repair", simulate="fail_once"]
      repair [label="repair"]
      exit [shape=Msquare]
      start -> gate
      gate -> exit
      repair -> gate
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, max_steps: 20)
    assert Enum.count(result.completed_nodes, &(&1 == "gate")) >= 2
    assert "repair" in result.completed_nodes
  end

  test "matrix: goal gate allows exit when satisfied" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [goal_gate=true]
      exit [shape=Msquare]
      start -> gate -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert List.last(result.completed_nodes) == "exit"
    assert result.final_outcome.status == :success
  end

  test "matrix: execute retry on failure with max_retries=2" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=2, retry_initial_delay_ms=1]
      exit [shape=Msquare]
      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, sleep_fn: fn _ -> :ok end)
    assert "flaky" in result.completed_nodes
    assert result.final_outcome.status == :success
  end

  test "matrix: edge selection priority condition > weight > lexical" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      n [simulate="fail"]
      a [label="A"]
      b [label="B"]
      c [label="C"]
      exit [shape=Msquare]
      start -> n
      n -> c [weight=50]
      n -> b [weight=10]
      n -> a [condition="outcome=fail", weight=1]
      a -> exit
      b -> exit
      c -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "a" in result.completed_nodes
    refute "c" in result.completed_nodes
  end

  test "matrix: edge selection weight breaks ties for unconditional edges" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      choose [label="choose", fan_out="false"]
      high [label="High"]
      low [label="Low"]
      exit [shape=Msquare]
      start -> choose
      choose -> low [weight=1]
      choose -> high [weight=10]
      high -> exit
      low -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "high" in result.completed_nodes
    refute "low" in result.completed_nodes
  end

  test "matrix: edge selection lexical tiebreak is final fallback" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      choose [label="choose", fan_out="false"]
      alpha [label="Alpha"]
      zeta [label="Zeta"]
      exit [shape=Msquare]
      start -> choose
      choose -> zeta [weight=0]
      choose -> alpha [weight=0]
      alpha -> exit
      zeta -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "alpha" in result.completed_nodes
    refute "zeta" in result.completed_nodes
  end

  test "matrix: wait.human presents choices and routes on selection" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Choose path", fan_out="false"]
      left [label="Left"]
      right [label="Right"]
      exit [shape=Msquare]
      start -> gate
      gate -> left [label="[L] Left"]
      gate -> right [label="[R] Right"]
      left -> exit
      right -> exit
    }
    """

    interviewer = fn _question -> %{value: "R"} end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, interviewer: interviewer)
    assert "right" in result.completed_nodes
    refute "left" in result.completed_nodes
  end

  test "matrix: context updates flow across nodes" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      a [label="A", prompt="set"]
      b [shape=diamond, fan_out="false"]
      yes [label="yes"]
      no [label="no"]
      exit [shape=Msquare]
      start -> a
      a -> b
      b -> yes [condition="context.last_stage=a"]
      b -> no
      yes -> exit
      no -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "yes" in result.completed_nodes
    refute "no" in result.completed_nodes
  end

  test "matrix: checkpoint resume reaches same terminal node" do
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
        "arbor_orchestrator_matrix_resume_#{System.unique_integer([:positive])}"
      )

    assert {:error, :max_steps_exceeded} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, max_steps: 2)

    assert {:ok, resumed} = Arbor.Orchestrator.run(dot, logs_root: logs_root, resume: true)
    assert List.last(resumed.completed_nodes) == "exit"
  end

  test "matrix: stylesheet shape selector and prompt variable expansion" do
    dot = """
    digraph Flow {
      goal="Build API"
      model_stylesheet="box { llm_model: gpt-5 }"
      start [shape=Mdiamond]
      task [shape=box, prompt="Do $goal"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_matrix_style_#{System.unique_integer([:positive])}"
      )

    assert {:ok, result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)
    assert result.context["last_prompt"] == "Do Build API"

    {:ok, status_json} = File.read(Path.join([logs_root, "task", "status.json"]))
    {:ok, status} = Jason.decode(status_json)
    assert status["context_updates"]["llm.model"] == "gpt-5"
  end

  test "matrix: parallel fan-out/fan-in complete" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      p [shape=component, fan_out="false"]
      a [label="A", score=0.3]
      b [label="B", score=0.8]
      j [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> p
      p -> a
      p -> b
      a -> j
      b -> j
      j -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "j" in result.completed_nodes
    assert result.context["parallel.fan_in.best_id"] == "b"
  end

  defmodule MatrixCustomHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler
    @impl true
    def execute(_node, _context, _graph, _opts),
      do: %Outcome{status: :success, context_updates: %{"matrix.custom" => true}}
  end

  test "matrix: custom handler registration and execution works" do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok = Registry.register("matrix.custom", MatrixCustomHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="matrix.custom"]
      exit [shape=Msquare]
      start -> custom -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["matrix.custom"] == true
  end

  test "matrix: pipeline with 10+ nodes completes without errors" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      n1 [label="n1"]
      n2 [label="n2"]
      n3 [label="n3"]
      n4 [label="n4"]
      n5 [label="n5"]
      n6 [label="n6"]
      n7 [label="n7"]
      n8 [label="n8"]
      n9 [label="n9"]
      n10 [label="n10"]
      exit [shape=Msquare]
      start -> n1 -> n2 -> n3 -> n4 -> n5 -> n6 -> n7 -> n8 -> n9 -> n10 -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert length(result.completed_nodes) == 12
    assert List.last(result.completed_nodes) == "exit"
  end
end
