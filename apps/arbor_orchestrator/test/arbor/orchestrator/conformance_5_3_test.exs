defmodule Arbor.Orchestrator.Conformance53Test do
  use ExUnit.Case, async: true

  test "5.3 checkpoint captures node progress, context, retry counters, and outcomes" do
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
        "arbor_orchestrator_5_3_checkpoint_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, sleep_fn: fn _ -> :ok end)

    checkpoint_path = Path.join(logs_root, "checkpoint.json")
    assert File.exists?(checkpoint_path)

    {:ok, checkpoint_json} = File.read(checkpoint_path)
    {:ok, checkpoint} = Jason.decode(checkpoint_json)

    assert checkpoint["current_node"] == "exit"
    assert checkpoint["completed_nodes"] == ["start", "flaky", "exit"]
    assert is_map(checkpoint["context_values"])
    assert get_in(checkpoint, ["node_retries", "flaky"]) == 1
    assert get_in(checkpoint, ["node_outcomes", "flaky", "status"]) == "fail"
  end

  test "5.3 resume_from checkpoint continues execution from persisted position" do
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
        "arbor_orchestrator_5_3_resume_#{System.unique_integer([:positive])}"
      )

    assert {:error, :max_steps_exceeded} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, max_steps: 2)

    checkpoint_path = Path.join(logs_root, "checkpoint.json")
    assert File.exists?(checkpoint_path)

    assert {:ok, resumed} =
             Arbor.Orchestrator.run(dot, logs_root: logs_root, resume_from: checkpoint_path)

    assert "b" in resumed.completed_nodes
    assert "exit" in resumed.completed_nodes
  end
end
