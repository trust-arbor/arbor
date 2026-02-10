defmodule Arbor.Orchestrator.Conformance411Test do
  use ExUnit.Case, async: false

  test "4.11 manager succeeds when child reports completed success" do
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
             Arbor.Orchestrator.run(dot, manager_observe: observer, sleep_fn: fn _ -> :ok end)

    assert "manager" in result.completed_nodes
    assert result.context["context.stack.child.status"] == "completed"
  end

  test "4.11 manager fails when child reports failed status" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, manager.poll_interval="1ms", manager.max_cycles=5]
      exit [shape=Msquare]
      start -> manager -> exit [condition="outcome=success"]
    }
    """

    observer = fn _local, _node, _opts ->
      %{
        "context.stack.child.status" => "failed",
        "context.stack.child.outcome" => "fail"
      }
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, manager_observe: observer, sleep_fn: fn _ -> :ok end)

    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason == "Child failed"
  end

  test "4.11 manager honors stop_condition with observe action" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, manager.actions="observe", manager.stop_condition="context.guard=ready", manager.max_cycles=3]
      exit [shape=Msquare]
      start -> manager -> exit
    }
    """

    observer = fn _local, _node, _opts ->
      %{"context.guard" => "ready", "context.stack.child.status" => "running"}
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, manager_observe: observer)
    assert "exit" in result.completed_nodes
    assert result.context["context.guard"] == "ready"
  end

  test "4.11 manager steer action is invoked when configured" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, manager.actions="steer", manager.max_cycles=2]
      exit [shape=Msquare]
      start -> manager -> exit [condition="outcome=success"]
    }
    """

    parent = self()

    steerer = fn local, _node, _opts ->
      send(parent, {:steer, Map.get(local, "manager.cycle", 0)})
      %{"context.steer.applied" => true}
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               manager_steer: steerer
             )

    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason == "Max cycles exceeded"
    assert_receive {:steer, _}
  end

  test "4.11 manager wait action sleeps when wait is enabled" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, manager.poll_interval="1ms", manager.max_cycles=2]
      exit [shape=Msquare]
      start -> manager -> exit [condition="outcome=success"]
    }
    """

    parent = self()

    observer = fn _local, _node, _opts ->
      %{"context.stack.child.status" => "running"}
    end

    sleep_fn = fn ms ->
      send(parent, {:wait, ms})
      :ok
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               manager_observe: observer,
               sleep_fn: sleep_fn
             )

    assert result.final_outcome.status == :fail
    assert_receive {:wait, 1}
  end

  test "4.11 manager autostart hook is called when configured" do
    dot = """
    digraph Flow {
      stack.child_dotfile="child.dot"
      start [shape=Mdiamond]
      manager [shape=house, stack.child_autostart=true, manager.actions="observe", manager.max_cycles=1]
      exit [shape=Msquare]
      start -> manager -> exit [condition="outcome=success"]
    }
    """

    parent = self()

    starter = fn child_dotfile, _local, _node, _graph, _opts ->
      send(parent, {:started_child, child_dotfile})
      %{"context.stack.child.status" => "running"}
    end

    observer = fn _local, _node, _opts ->
      %{"context.stack.child.status" => "running"}
    end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               manager_start_child: starter,
               manager_observe: observer
             )

    assert result.final_outcome.status == :fail
    assert_receive {:started_child, "child.dot"}
  end
end
