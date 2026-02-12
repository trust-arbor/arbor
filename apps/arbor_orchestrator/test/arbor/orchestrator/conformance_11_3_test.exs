defmodule Arbor.Orchestrator.Conformance113Test do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry

  defmodule PriorityHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{
        status: :success,
        preferred_label: "Preferred",
        suggested_next_ids: ["suggested"],
        context_updates: %{"priority.handler" => true}
      }
    end
  end

  defmodule ProbeHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(node, context, graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:probe_execute, node.id, is_map(context.values), map_size(graph.nodes)})
      end

      %Outcome{
        status: :success,
        context_updates: %{"probe.node" => node.id}
      }
    end
  end

  setup do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok
  end

  test "11.3 engine resolves start node, executes handlers, writes status files, and stops at terminal" do
    :ok = Registry.register("probe", ProbeHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="probe"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_11_3_#{System.unique_integer([:positive])}"
      )

    assert {:ok, result} = Arbor.Orchestrator.run(dot, logs_root: logs_root, parent: self())

    assert result.completed_nodes == ["start", "task", "exit"]
    assert_receive {:probe_execute, "task", true, 3}
    assert File.exists?(Path.join([logs_root, "start", "status.json"]))
    assert File.exists?(Path.join([logs_root, "task", "status.json"]))
    assert File.exists?(Path.join([logs_root, "exit", "status.json"]))
  end

  test "11.3 edge selection priority applies condition before preferred/suggested/weight/lexical" do
    :ok = Registry.register("priority.custom", PriorityHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      chooser [type="priority.custom", simulate="fail"]
      condition_wins [label="Condition wins"]
      preferred [label="Preferred"]
      suggested [label="Suggested"]
      weighted [label="Weighted"]
      lexical [label="Lexical"]
      exit [shape=Msquare]

      start -> chooser
      chooser -> condition_wins [condition="outcome=success", weight=1]
      chooser -> preferred [label="Preferred", weight=999]
      chooser -> suggested [weight=500]
      chooser -> weighted [weight=100]
      chooser -> lexical [weight=100]

      condition_wins -> exit
      preferred -> exit
      suggested -> exit
      weighted -> exit
      lexical -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "condition_wins" in result.completed_nodes
    refute "preferred" in result.completed_nodes
    refute "suggested" in result.completed_nodes
  end

  test "11.3 preferred label beats suggested ids and weight when no condition matches" do
    :ok = Registry.register("priority.custom", PriorityHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      chooser [type="priority.custom"]
      preferred [label="Preferred", weight=1]
      suggested [label="Suggested", weight=999]
      weighted [label="Weighted", weight=50]
      exit [shape=Msquare]

      start -> chooser
      chooser -> preferred [label="Preferred", weight=1]
      chooser -> suggested [weight=999]
      chooser -> weighted [weight=50]

      preferred -> exit
      suggested -> exit
      weighted -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "preferred" in result.completed_nodes
    refute "suggested" in result.completed_nodes
  end
end
