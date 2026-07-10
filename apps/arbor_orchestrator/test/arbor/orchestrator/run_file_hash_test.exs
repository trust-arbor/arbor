defmodule Arbor.Orchestrator.RunFileHashTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "security regression: expected graph hash binds run_file to exact DOT bytes" do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_run_file_hash_#{System.unique_integer([:positive, :monotonic])}.dot"
      )

    source = """
    digraph HashBoundRun {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    actual_hash = sha256(source)
    wrong_hash = String.duplicate("0", 64)

    assert {:error, {:graph_hash_mismatch, ^wrong_hash, ^actual_hash}} =
             Arbor.Orchestrator.run_file(path, graph_hash: wrong_hash)

    assert {:ok, result} = Arbor.Orchestrator.run_file(path, graph_hash: actual_hash)
    assert "done" in result.completed_nodes
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
