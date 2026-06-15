defmodule Arbor.Orchestrator.CompileParityTest do
  @moduledoc """
  Deep parity tests between compiled and uncompiled execution paths.

  The engine has fallbacks for everything `IR.Compiler` provides:
  `Registry.resolve_with_attrs/1` when `node.handler_module == nil`,
  `Condition.eval/3` string-form when `edge.parsed_condition == nil`,
  per-execution adjacency walks when the pre-built adjacency maps are
  absent. The existing `compiled_graph_test.exs` only asserts that BOTH
  paths produce a `:success` or `:partial_success` outcome — shallow
  equivalence. That misses real divergences.

  This file extends that coverage to **deep** parity:

    - Same `completed_nodes` (and in the same order)
    - Same `final_outcome.status`
    - Same routing decisions on conditional pipelines
    - Same context shape (keys + non-timing values)
    - Same node-durations keyset (the durations themselves will differ;
      the presence/absence of each key is what matters for parity)

  Tests are pure-shell pipelines (no LLM, no shell side effects beyond
  what each node returns deterministically) so two runs of the same
  graph produce identical outputs modulo timing.

  Without these tests, a future bug in the fallback path could silently
  diverge from compiled behavior with no signal — the
  "transform → IR.Compile → Engine.run" reorder explicitly relies on the
  static analyses produced by compile being equivalent in shape to what
  the fallback path produces at runtime. If they ever drift, we want a
  CI failure here.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.IR.Compiler

  # ── Helpers ──

  defp tmp_logs do
    Path.join(System.tmp_dir!(), "compile_parity_#{System.unique_integer([:positive])}")
  end

  defp run_both(dot) do
    {:ok, parsed} = Orchestrator.parse(dot)
    assert parsed.compiled == false

    {:ok, compiled} = Compiler.compile(parsed)
    assert compiled.compiled == true

    {:ok, uncompiled_result} = Orchestrator.run(parsed, cache: false, logs_root: tmp_logs())
    {:ok, compiled_result} = Orchestrator.run(compiled, cache: false, logs_root: tmp_logs())

    {uncompiled_result, compiled_result}
  end

  defp assert_parity(uncompiled, compiled) do
    assert uncompiled.completed_nodes == compiled.completed_nodes,
           "completed_nodes diverged:\n  uncompiled: " <>
             "#{inspect(uncompiled.completed_nodes)}\n  compiled:   " <>
             "#{inspect(compiled.completed_nodes)}"

    assert uncompiled.final_outcome.status == compiled.final_outcome.status,
           "final_outcome.status diverged: " <>
             "uncompiled=#{inspect(uncompiled.final_outcome.status)} " <>
             "compiled=#{inspect(compiled.final_outcome.status)}"

    # node_durations keyset — keys present in one but not the other
    # signal a routing divergence even if `completed_nodes` happens to
    # match by coincidence.
    uncomp_dur_keys = MapSet.new(Map.keys(uncompiled.node_durations))
    comp_dur_keys = MapSet.new(Map.keys(compiled.node_durations))

    assert uncomp_dur_keys == comp_dur_keys,
           "node_durations keyset diverged:\n  only-uncompiled: " <>
             "#{inspect(MapSet.difference(uncomp_dur_keys, comp_dur_keys))}\n  " <>
             "only-compiled:   " <>
             "#{inspect(MapSet.difference(comp_dur_keys, uncomp_dur_keys))}"

    # Context parity — keys should match. Values differ in timing-sensitive
    # fields (timestamps, durations) but graph-derived fields should be
    # identical. Compare the keyset for now; deep value comparison would
    # need a known-stable-keys whitelist that we can grow as the test
    # surface matures.
    uncomp_ctx_keys = MapSet.new(Map.keys(uncompiled.context))
    comp_ctx_keys = MapSet.new(Map.keys(compiled.context))

    assert uncomp_ctx_keys == comp_ctx_keys,
           "context keyset diverged:\n  only-uncompiled: " <>
             "#{inspect(MapSet.difference(uncomp_ctx_keys, comp_ctx_keys))}\n  " <>
             "only-compiled:   " <>
             "#{inspect(MapSet.difference(comp_ctx_keys, uncomp_ctx_keys))}"
  end

  describe "linear pipelines" do
    test "minimal start → exit" do
      dot = """
      digraph Linear {
        start [shape=Mdiamond]
        exit [shape=Msquare]
        start -> exit
      }
      """

      {uncompiled, compiled} = run_both(dot)
      assert_parity(uncompiled, compiled)
    end

    test "three-step linear pipeline" do
      dot = """
      digraph Three {
        start [shape=Mdiamond]
        a [label="A", simulate="true"]
        b [label="B", simulate="true"]
        c [label="C", simulate="true"]
        exit [shape=Msquare]
        start -> a -> b -> c -> exit
      }
      """

      {uncompiled, compiled} = run_both(dot)
      assert_parity(uncompiled, compiled)
      assert compiled.completed_nodes == ["start", "a", "b", "c", "exit"]
    end
  end

  describe "conditional pipelines" do
    test "diamond with outcome=success edge" do
      dot = """
      digraph Cond {
        start [shape=Mdiamond]
        check [shape=diamond]
        yes_path [prompt="Yes", simulate="true"]
        no_path [prompt="No", simulate="true"]
        exit [shape=Msquare]
        start -> check
        check -> yes_path [condition="outcome=success"]
        check -> no_path [condition="outcome=fail"]
        yes_path -> exit
        no_path -> exit
      }
      """

      {uncompiled, compiled} = run_both(dot)
      assert_parity(uncompiled, compiled)
      # `check` should route to `yes_path` in both, NOT to `no_path`
      assert "yes_path" in compiled.completed_nodes
      refute "no_path" in compiled.completed_nodes
    end

    test "compound && condition (parsed_condition path)" do
      # This case specifically exercises the difference between
      # `edge.parsed_condition` (pre-parsed AST) and the string-eval
      # fallback. They must agree for compound conditions too.
      dot = """
      digraph Compound {
        start [shape=Mdiamond]
        gate [shape=diamond]
        approved [label="approved", simulate="true"]
        exit [shape=Msquare]
        start -> gate
        gate -> approved [condition="outcome=success && context.flag=true"]
        gate -> exit [condition="outcome=fail"]
        approved -> exit
      }
      """

      {:ok, parsed} = Orchestrator.parse(dot)
      {:ok, compiled} = Compiler.compile(parsed)

      initial = %{"context.flag" => "true"}

      {:ok, uncompiled_result} =
        Orchestrator.run(parsed, cache: false, logs_root: tmp_logs(), initial_values: initial)

      {:ok, compiled_result} =
        Orchestrator.run(compiled, cache: false, logs_root: tmp_logs(), initial_values: initial)

      assert_parity(uncompiled_result, compiled_result)
    end
  end

  describe "transforms parity" do
    test "VariableExpansion produces same context in both paths" do
      # `graph.goal` should be available as `$goal` after expansion.
      # Both paths run with the same built-in transforms (the reorder
      # only changes WHEN transforms run relative to IR.Compile, not
      # WHETHER they run).
      dot = """
      digraph Goal {
        graph [goal="Build a widget"]
        start [shape=Mdiamond]
        worker [label="$goal", simulate="true"]
        exit [shape=Msquare]
        start -> worker -> exit
      }
      """

      {uncompiled, compiled} = run_both(dot)
      assert_parity(uncompiled, compiled)
      assert uncompiled.context["graph.goal"] == "Build a widget"
      assert compiled.context["graph.goal"] == "Build a widget"
    end
  end

  describe "graph-level attribute parity" do
    test "default_max_retries attr threads identically" do
      # The attr-rename test (engine_coverage_test) already covers the
      # parsing of `default_max_retries`. Here we just confirm it
      # doesn't ROUTE differently between compiled and uncompiled.
      dot = """
      digraph Retries {
        graph [default_max_retries="2"]
        start [shape=Mdiamond]
        worker [label="W", simulate="true"]
        exit [shape=Msquare]
        start -> worker -> exit
      }
      """

      {uncompiled, compiled} = run_both(dot)
      assert_parity(uncompiled, compiled)
    end
  end
end
