defmodule Arbor.Orchestrator.Conformance56Test do
  use ExUnit.Case, async: true

  test "5.6 run directory has manifest, checkpoint, node stage files, and artifacts dir" do
    dot = """
    digraph Flow {
      goal="Verify directory tree"
      start [shape=Mdiamond]
      task [shape=box, prompt="Do $goal"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_5_6_#{System.unique_integer([:positive])}"
      )

    assert {:ok, result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)
    assert "exit" in result.completed_nodes

    assert File.exists?(Path.join(logs_root, "manifest.json"))
    assert File.exists?(Path.join(logs_root, "checkpoint.json"))
    assert File.dir?(Path.join(logs_root, "artifacts"))

    assert File.exists?(Path.join([logs_root, "task", "prompt.md"]))
    assert File.exists?(Path.join([logs_root, "task", "response.md"]))
    assert File.exists?(Path.join([logs_root, "task", "status.json"]))
  end

  test "5.6 manifest includes graph metadata and checkpoint references terminal node" do
    dot = """
    digraph Flow {
      goal="Ship"
      label="Directory Test"
      start [shape=Mdiamond]
      task [shape=box]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_5_6_meta_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    {:ok, manifest_json} = File.read(Path.join(logs_root, "manifest.json"))
    {:ok, manifest} = Jason.decode(manifest_json)
    assert manifest["goal"] == "Ship"
    assert is_binary(manifest["graph_id"])
    assert is_binary(manifest["started_at"])

    {:ok, checkpoint_json} = File.read(Path.join(logs_root, "checkpoint.json"))
    {:ok, checkpoint} = Jason.decode(checkpoint_json)
    assert checkpoint["current_node"] == "exit"
  end
end
