defmodule Arbor.Orchestrator.Conformance116Test do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry

  defmodule CustomConformanceHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{
        status: :success,
        context_updates: %{"custom.11_6.executed" => true}
      }
    end
  end

  setup do
    Registry.reset_custom_handlers()
    on_exit(fn -> Registry.reset_custom_handlers() end)
    :ok
  end

  test "11.6 start and exit handlers are no-op success handlers" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      start -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.completed_nodes == ["start", "exit"]
    assert result.final_outcome.status == :success
  end

  test "11.6 codergen expands $goal and writes prompt/response artifacts" do
    dot = """
    digraph Flow {
      goal="Ship API"
      start [shape=Mdiamond]
      task [shape=box, prompt="Do $goal"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_11_6_codegen_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    assert File.read!(Path.join([logs_root, "task", "prompt.md"])) == "Do Ship API"
    assert File.read!(Path.join([logs_root, "task", "response.md"])) =~ "[Simulated] Response"
  end

  test "11.6 wait.human routes via interviewer choice and records preferred label" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Approve?"]
      yes_path [label="Yes"]
      no_path [label="No"]
      exit [shape=Msquare]

      start -> gate
      gate -> yes_path [label="[Y] Yes"]
      gate -> no_path [label="[N] No"]
      yes_path -> exit
      no_path -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_11_6_human_#{System.unique_integer([:positive])}"
      )

    interviewer = fn _question -> %{value: "N"} end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, interviewer: interviewer)

    assert "no_path" in result.completed_nodes
    refute "yes_path" in result.completed_nodes

    {:ok, gate_status_json} = File.read(Path.join([logs_root, "gate", "status.json"]))
    {:ok, gate_status} = Jason.decode(gate_status_json)
    assert gate_status["preferred_next_label"] == "[N] No"
  end

  test "11.6 conditional handler is pass-through and engine evaluates edge conditions" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      seed [shape=box]
      cond [shape=diamond]
      yes [label="Yes"]
      no [label="No"]
      exit [shape=Msquare]

      start -> seed -> cond
      cond -> yes [condition="context.last_stage=seed"]
      cond -> no
      yes -> exit
      no -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "yes" in result.completed_nodes
    refute "no" in result.completed_nodes
  end

  test "11.6 parallel and fan-in handlers execute all branches and consolidate result" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      p [shape=component]
      a [label="A"]
      b [label="B"]
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

    parent = self()

    branch_executor = fn branch_node_id, _context, _graph, _opts ->
      send(parent, {:branch_start, branch_node_id})

      case branch_node_id do
        "a" -> Process.sleep(25)
        _ -> Process.sleep(5)
      end

      send(parent, {:branch_done, branch_node_id})

      %{
        "id" => branch_node_id,
        "status" => "success",
        "score" => if(branch_node_id == "a", do: 0.3, else: 0.9)
      }
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, parallel_branch_executor: branch_executor)
    assert "p" in result.completed_nodes
    assert "j" in result.completed_nodes
    assert result.context["parallel.total_count"] == 2
    assert result.context["parallel.success_count"] == 2
    assert result.context["parallel.fan_in.best_id"] == "b"
    assert_receive {:branch_start, "a"}
    assert_receive {:branch_start, "b"}
    assert_receive {:branch_done, "a"}
    assert_receive {:branch_done, "b"}
  end

  test "11.6 tool handler runs configured command and records output" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      tool [shape=parallelogram, tool_command="echo run"]
      exit [shape=Msquare]
      start -> tool -> exit
    }
    """

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, tool_command_runner: fn "echo run" -> "run" end)

    assert result.context["tool.output"] == "run"
  end

  test "11.6 custom handlers are registerable by type string" do
    :ok = Registry.register("custom.11_6", CustomConformanceHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="custom.11_6"]
      exit [shape=Msquare]
      start -> custom -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["custom.11_6.executed"] == true
  end
end
