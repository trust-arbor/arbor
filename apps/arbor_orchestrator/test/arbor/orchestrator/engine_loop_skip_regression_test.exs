defmodule Arbor.Orchestrator.EngineLoopSkipRegressionTest do
  @moduledoc """
  Regression test for the content-hash-skip + loop-clobber bug.

  Before the fix, an idempotent node revisited inside a loop would get
  skipped (content hash matched the stored hash from its first
  execution), but the engine did NOT re-apply the cached outcome's
  `context_updates` on skip. If another node between the two visits
  had clobbered the skipped node's `output_key`, the slot retained the
  clobbered value rather than being restored to the skipped node's
  "would-have-produced" output.

  Surfaced by the TDD-cycle example DOT: a `transform=identity`
  renaming `impl_file_path` → `path` got skipped on iteration 2;
  meanwhile `prep_test_run_path` had clobbered `path` with the workdir
  between visits; so `write_impl` on iteration 2 saw `path=workdir`,
  tried to write to a directory, and the action failed with `:eisdir`.

  Fix: on the skip branch in `Engine.handle_normal_node/1`, apply
  `outcome.context_updates` exactly as the normal-execution branch
  does. Same effect, no recomputation.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator

  test "skipped idempotent node re-applies its cached context_updates on loop revisit" do
    # Pipeline:
    #
    #   start → init → prep → check
    #   check (done=true)  → exit
    #   check (done=false) → clobber → mark_done → prep (loop back)
    #
    # Iteration 1: prep sets shared="from_src", clobber sets shared="from_other",
    #              mark_done sets done=true, loop back to prep.
    # Iteration 2: prep is content-hash-skipped (same inputs as iter 1).
    #              The cached outcome's context_updates include shared="from_src".
    #              With the fix, skip re-applies that update → shared="from_src".
    #              Without the fix, the iter-1 clobber's "from_other" persists.
    # check evaluates done=true → exit.

    dot = """
    digraph LoopClobberRestore {
      graph [goal="exercise content-hash skip + clobber on loop revisit"]

      start [shape=Mdiamond]

      init [type="transform", transform="identity", source_key="false_val", output_key="done"]
      prep [type="transform", transform="identity", source_key="src", output_key="shared"]
      clobber [type="transform", transform="identity", source_key="other", output_key="shared"]
      mark_done [type="transform", transform="identity", source_key="true_val", output_key="done"]
      check [type="gate", shape=diamond, predicate="expression", expression="done"]

      exit [shape=Msquare]

      start -> init -> prep -> check
      check -> exit [condition="context.done=true"]
      check -> clobber [condition="context.done!=true"]
      clobber -> mark_done -> prep
    }
    """

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_loop_skip_regression_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(logs_root) end)

    initial_values = %{
      "src" => "from_src",
      "other" => "from_other",
      "false_val" => false,
      "true_val" => true
    }

    assert {:ok, _result} =
             Orchestrator.run(dot, logs_root: logs_root, initial_values: initial_values)

    final_context =
      logs_root
      |> Path.join("checkpoint.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("context_values")

    # prep was the last node to write `shared` on the path to exit (revisited
    # on iter 2 between clobber and check). With the fix, prep's skipped
    # re-execution re-applies its cached context_updates, restoring shared
    # to "from_src". Without the fix, shared stays "from_other" from iter 1's
    # clobber because the skip path doesn't re-apply updates.
    assert final_context["shared"] == "from_src",
           "Expected shared='from_src' (prep last wrote it on iteration 2). " <>
             "Got #{inspect(final_context["shared"])} — likely the skip path " <>
             "didn't re-apply prep's cached context_updates."
  end
end
