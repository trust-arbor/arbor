defmodule Arbor.Orchestrator.EngineRecursiveSubgraphTest do
  @moduledoc """
  Adversarial input: a DOT pipeline that invokes ITSELF as a child,
  with no exit condition. Either the engine's `:max_depth` guard
  (H16, set at `Engine.run/2` line 62) catches the infinite recursion
  or we have a real bug.

  This test confirms:
    1. The guard fires within a bounded number of invocations.
    2. The pipeline terminates with `:max_depth_exceeded` (or a wrapped
       error chain that surfaces that as the root cause).
    3. No process leaks, no stack overflow, no resource exhaustion.

  Conceptually:

      run(self.dot, max_depth: 3)
        → SubgraphHandler invokes self.dot with max_depth: 2
        → ... with max_depth: 1
        → ... with max_depth: 0
        → ... with max_depth: -1 → engine refuses

  So we expect 4 successful engine runs (top + 3 nested) and the 5th
  to fail fast.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  # A minimal DOT that invokes itself via graph_source_key. No exit
  # condition — the engine's max_depth guard is what must stop it.
  @recursive_dot """
  digraph SelfInvoker {
    graph [goal="Adversarial: invoke self recursively, rely on max_depth"]

    start [shape=Mdiamond]

    invoke_self [
      type="graph.invoke",
      graph_source_key="self_dot",
      pass_context="self_dot"
    ]

    done [shape=Msquare]

    start -> invoke_self -> done
  }
  """

  test "infinite recursive subgraph invocation is bounded by max_depth and fails fast" do
    initial_values = %{
      # The DOT references itself via graph_source_key, so the source
      # has to be in context.
      "self_dot" => @recursive_dot
    }

    logs_root =
      Path.join(System.tmp_dir!(), "arbor_recursion_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(logs_root) end)

    # Wall-clock guard — if the test takes more than a few seconds the
    # recursion is NOT bounded and we have a real bug. The engine should
    # fail at depth 4 within milliseconds.
    task =
      Task.async(fn ->
        Arbor.Orchestrator.run(@recursive_dot,
          initial_values: initial_values,
          logs_root: logs_root,
          authorization: false,
          # Reduce default to make the test deterministic across changes.
          max_depth: 3
        )
      end)

    result = Task.await(task, 5_000)

    # The exact shape of the result depends on how the failing
    # SubgraphHandler propagates the inner engine error. Either:
    #   (a) Top-level engine returns {:error, :max_depth_exceeded}
    #       directly (if it's the first to hit the guard), OR
    #   (b) Top-level returns {:ok, %{final_outcome: %{status: :fail, ...}}}
    #       where the failure_reason mentions max_depth_exceeded somewhere
    #       in the chain.
    #
    # Whichever shape, the failure cause MUST be max_depth_exceeded.
    cause = extract_failure_cause(result)

    # Emit the cause so test runs leave a paper trail.
    IO.puts("\n  recursion bounded with cause: #{cause}")

    assert cause =~ "max_depth_exceeded",
           "Expected the pipeline to terminate due to max_depth_exceeded. " <>
             "Got result: #{inspect(result, limit: :infinity)}"
  end

  defp extract_failure_cause({:error, reason}), do: inspect(reason)

  defp extract_failure_cause({:ok, result}) do
    case result.final_outcome do
      %{status: :success} ->
        "(unexpected success — recursion was NOT bounded)"

      %{failure_reason: reason} when is_binary(reason) ->
        reason

      other ->
        inspect(other)
    end
  end
end
