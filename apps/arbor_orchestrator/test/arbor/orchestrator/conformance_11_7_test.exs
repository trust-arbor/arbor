defmodule Arbor.Orchestrator.Conformance117Test do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Handlers.Registry

  defmodule ContextWriterHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{
        status: :success,
        context_updates: %{"context.shared" => "alpha"}
      }
    end
  end

  defmodule ContextReaderHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, context, _graph, opts) do
      value = Context.get(context, "context.shared")

      if parent = opts[:parent] do
        send(parent, {:context_read, value})
      end

      %Outcome{
        status: :success,
        context_updates: %{"context.readback" => value}
      }
    end
  end

  setup do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok
  end

  test "11.7 context is shared across handlers and merges context_updates after each node" do
    :ok = Registry.register("context.writer", ContextWriterHandler)
    :ok = Registry.register("context.reader", ContextReaderHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      writer [type="context.writer"]
      reader [type="context.reader"]
      exit [shape=Msquare]

      start -> writer -> reader -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, parent: self())
    assert_receive {:context_read, "alpha"}
    assert result.context["context.shared"] == "alpha"
    assert result.context["context.readback"] == "alpha"
  end

  test "11.7 checkpoint captures current node, completed nodes, context values, and retry counters" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=1, retry_initial_delay_ms=1]
      exit [shape=Msquare]

      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_11_7_checkpoint_#{System.unique_integer([:positive])}"
      )

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, sleep_fn: fn _ -> :ok end)

    assert "exit" in result.completed_nodes

    checkpoint_path = Path.join(logs_root, "checkpoint.json")
    assert File.exists?(checkpoint_path)

    {:ok, checkpoint_json} = File.read(checkpoint_path)
    {:ok, checkpoint} = Jason.decode(checkpoint_json)

    assert checkpoint["current_node"] == "exit"
    assert checkpoint["completed_nodes"] == ["start", "flaky", "exit"]
    assert is_map(checkpoint["context_values"])
    assert get_in(checkpoint, ["node_retries", "flaky"]) == 1
  end

  test "11.7 resume restores checkpointed state and continues from the checkpoint position" do
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
        "arbor_orchestrator_11_7_resume_#{System.unique_integer([:positive])}"
      )

    assert {:error, :max_steps_exceeded} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, max_steps: 2)

    assert {:ok, resumed} = Arbor.Orchestrator.run(dot, logs_root: logs_root, resume: true)
    assert "b" in resumed.completed_nodes
    assert "exit" in resumed.completed_nodes
  end

  test "11.7 stage artifacts are written to {logs_root}/{node_id}/" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [shape=box, prompt="Do thing"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_11_7_artifacts_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    assert File.exists?(Path.join([logs_root, "task", "prompt.md"]))
    assert File.exists?(Path.join([logs_root, "task", "response.md"]))
    assert File.exists?(Path.join([logs_root, "task", "status.json"]))
  end
end
