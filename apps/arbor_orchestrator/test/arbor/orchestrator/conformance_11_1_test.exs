defmodule Arbor.Orchestrator.Conformance111Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Parser

  test "11.1 parser accepts digraph subset with graph/node/edge attribute blocks" do
    dot = """
    digraph Flow {
      graph [goal="Ship", label="Pipeline", model_stylesheet="* { llm_provider: openai; }"]
      node [shape=box, max_retries=2]
      edge [weight=7]
      start [shape=Mdiamond]
      task [label="Task"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert graph.attrs["goal"] == "Ship"
    assert graph.attrs["label"] == "Pipeline"
    assert graph.attrs["model_stylesheet"] =~ "llm_provider"
    assert graph.nodes["task"].attrs["max_retries"] == 2
    assert Enum.all?(graph.edges, &(&1.attrs["weight"] == 7))
  end

  test "11.1 parses multi-line node attributes and edge attributes" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [
        label="Task node",
        prompt="Build $goal",
        max_retries=2
      ]
      exit [shape=Msquare]
      start -> task [label="next", condition="outcome=success", weight=10]
      task -> exit
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert graph.nodes["task"].attrs["label"] == "Task node"
    assert graph.nodes["task"].attrs["prompt"] == "Build $goal"
    assert graph.nodes["task"].attrs["max_retries"] == 2

    edge = Enum.find(graph.edges, &(&1.from == "start" and &1.to == "task"))
    assert edge.attrs["label"] == "next"
    assert edge.attrs["condition"] == "outcome=success"
    assert edge.attrs["weight"] == 10
  end

  test "11.1 chained edges produce pairwise edges and subgraph contents are flattened" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      subgraph cluster_build {
        plan [label="Plan"]; implement [label="Implement"]; plan -> implement [label="flow"];
      }
      implement -> verify -> exit
      verify [label="Verify"]
      exit [shape=Msquare]
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert Map.has_key?(graph.nodes, "plan")
    assert Map.has_key?(graph.nodes, "implement")
    assert Enum.any?(graph.edges, &(&1.from == "plan" and &1.to == "implement"))
    assert Enum.any?(graph.edges, &(&1.from == "implement" and &1.to == "verify"))
    assert Enum.any?(graph.edges, &(&1.from == "verify" and &1.to == "exit"))
  end

  test "11.1 quoted and unquoted values both parse and comments are stripped" do
    dot = """
    digraph Flow {
      // line comment
      /* block
         comment */
      start [shape=Mdiamond]
      task [label=Task, max_retries=3, allow_partial=true, timeout="900s"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert graph.nodes["task"].attrs["label"] == "Task"
    assert graph.nodes["task"].attrs["max_retries"] == 3
    assert graph.nodes["task"].attrs["allow_partial"] == true
    assert graph.nodes["task"].attrs["timeout"] == "900s"
  end

  test "11.1 class attribute is parsed and merges via stylesheet transform" do
    dot = """
    digraph Flow {
      model_stylesheet=".code { llm_model: class-model; llm_provider: anthropic; }"
      start [shape=Mdiamond]
      task [shape=box, class="code", prompt="Do work"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_11_1_class_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)
    {:ok, status_json} = File.read(Path.join([logs_root, "task", "status.json"]))
    {:ok, status} = Jason.decode(status_json)
    assert status["context_updates"]["llm.model"] == "class-model"
    assert status["context_updates"]["llm.provider"] == "anthropic"
  end
end
