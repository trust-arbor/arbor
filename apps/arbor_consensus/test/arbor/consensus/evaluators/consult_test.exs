defmodule Arbor.Consensus.Evaluators.ConsultTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Evaluators.Consult
  alias Arbor.Consensus.TestHelpers.{FailingAdvisoryEvaluator, TestAdvisoryEvaluator}

  @moduletag :fast

  describe "ask/3" do
    test "consults all perspectives and returns sorted results" do
      {:ok, results} = Consult.ask(TestAdvisoryEvaluator, "How should we design the router?")

      assert length(results) == 2

      # Sorted by perspective
      [{p1, eval1}, {p2, eval2}] = results
      assert p1 == :brainstorming
      assert p2 == :design_review

      assert eval1.perspective == :brainstorming
      assert eval1.reasoning =~ "brainstorming"
      assert eval1.reasoning =~ "How should we design the router?"

      assert eval2.perspective == :design_review
      assert eval2.reasoning =~ "design_review"
    end

    test "passes context to the proposal" do
      {:ok, results} =
        Consult.ask(TestAdvisoryEvaluator, "ETS or Redis?",
          context: %{requirement: "persistence"}
        )

      assert length(results) == 2
      # All evaluations succeed (test evaluator ignores context but proposal has it)
      Enum.each(results, fn {_perspective, eval} ->
        assert eval.sealed == true
      end)
    end

    test "handles evaluator errors in results" do
      {:ok, results} = Consult.ask(FailingAdvisoryEvaluator, "This will fail")

      assert [{:brainstorming, {:error, :intentional_failure}}] = results
    end
  end

  describe "ask_one/4" do
    test "consults a single perspective" do
      {:ok, eval} =
        Consult.ask_one(TestAdvisoryEvaluator, "What about the API design?", :design_review)

      assert eval.perspective == :design_review
      assert eval.reasoning =~ "design_review"
      assert eval.reasoning =~ "What about the API design?"
      assert eval.sealed == true
    end

    test "passes context through" do
      {:ok, eval} =
        Consult.ask_one(
          TestAdvisoryEvaluator,
          "Should we cache?",
          :brainstorming,
          context: %{current: "no caching"}
        )

      assert eval.perspective == :brainstorming
    end

    test "returns error from failing evaluator" do
      assert {:error, :intentional_failure} =
               Consult.ask_one(FailingAdvisoryEvaluator, "Will fail", :brainstorming)
    end
  end

  describe "decide/3 run authorization" do
    test "bound execution forwards the nested recursion budget" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      authority = {:opaque_parent_authorization, make_ref()}

      engine_runner = fn _graph, engine_opts ->
        send(parent, {:nested_engine_opts, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Runtime review question",
                 graph: graph_path,
                 run_authorization: authority,
                 nested_engine_opts: [max_depth: 6],
                 engine_runner: engine_runner
               )

      assert_receive {:nested_engine_opts, engine_opts}
      assert engine_opts[:max_depth] == 6
      assert engine_opts[:authorization] == true
      assert engine_opts[:run_authorization] == authority
    end

    test "bound execution filters unrelated and executable nested engine overrides" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      authority = {:opaque_parent_authorization, make_ref()}

      engine_runner = fn _graph, engine_opts ->
        send(parent, {:filtered_nested_engine_opts, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Runtime review question",
                 graph: graph_path,
                 run_authorization: authority,
                 nested_engine_opts: [
                   unrelated: :not_an_engine_control,
                   actions_executor: fn _, _, _ -> :executed_override end,
                   middleware: [fn token -> token end],
                   tool_executor: fn _, _ -> :executed_override end
                 ],
                 engine_runner: engine_runner
               )

      assert_receive {:filtered_nested_engine_opts, engine_opts}
      refute Keyword.has_key?(engine_opts, :unrelated)
      refute Keyword.has_key?(engine_opts, :actions_executor)
      refute Keyword.has_key?(engine_opts, :middleware)
      refute Keyword.has_key?(engine_opts, :tool_executor)
    end

    test "security regression: bound execution preserves graph and trusted runtime opts" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      authority = {:opaque_parent_authorization, make_ref()}
      signer = fn _resource -> {:ok, :signed} end
      authorizer = fn _agent_id, _handler_type -> :ok end
      context = %{"review.prompt" => "Review the exact branch diff"}
      expected_graph = compile_graph!(graph_path)

      engine_runner = fn graph, engine_opts ->
        send(parent, {:nested_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Runtime review question",
                 graph: graph_path,
                 context: context,
                 run_authorization: authority,
                 nested_engine_opts: [
                   signer: signer,
                   authorizer: authorizer,
                   max_depth: 5,
                   authorization: false,
                   run_authorization: :wrong_authority,
                   initial_values: %{"poisoned" => true},
                   graph: "/tmp/not-reviewed.dot",
                   mode: "advisory",
                   quorum: "unanimous"
                 ],
                 engine_runner: engine_runner
               )

      assert_receive {:nested_engine_run, actual_graph, engine_opts}
      assert actual_graph == expected_graph
      assert actual_graph.compiled
      assert canonical_graph_hash(actual_graph) == canonical_graph_hash(expected_graph)
      assert compiled_graph_hash(actual_graph) == compiled_graph_hash(expected_graph)

      assert actual_graph.attrs["council.question"] == "Reviewed graph question"
      assert actual_graph.attrs["mode"] == "decision"
      assert actual_graph.attrs["quorum"] == "supermajority"

      assert engine_opts[:initial_values] ==
               Map.put(context, "council.question", "Runtime review question")

      assert engine_opts[:signer] == signer
      assert engine_opts[:authorizer] == authorizer
      assert engine_opts[:max_depth] == 5
      assert engine_opts[:run_authorization] == authority
      assert engine_opts[:authorization] == true
      refute Map.has_key?(engine_opts[:initial_values], "run_authorization")
      refute Map.has_key?(engine_opts[:initial_values], "signer")
      refute Keyword.has_key?(engine_opts, :graph)
      refute Keyword.has_key?(engine_opts, :mode)
      refute Keyword.has_key?(engine_opts, :quorum)
    end

    test "preserves legacy graph overrides and omits authorization when unbound" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()

      engine_runner = fn graph, engine_opts ->
        send(parent, {:nested_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Review this change",
                 graph: graph_path,
                 mode: "advisory",
                 quorum: "unanimous",
                 engine_runner: engine_runner
               )

      assert_receive {:nested_engine_run, graph, engine_opts}
      assert graph.attrs["council.question"] == "Review this change"
      assert graph.attrs["mode"] == "advisory"
      assert graph.attrs["quorum"] == "unanimous"
      refute Keyword.has_key?(engine_opts, :run_authorization)
      refute Keyword.has_key?(engine_opts, :authorization)
    end

    test "rejects mode and quorum overrides when bound" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts -> flunk("engine runner must not be called") end
      authority = {:opaque_parent_authorization, make_ref()}

      for {key, value} <- [mode: "advisory", quorum: "unanimous"] do
        opts =
          [
            graph: graph_path,
            run_authorization: authority,
            engine_runner: engine_runner
          ]
          |> Keyword.put(key, value)

        assert {:error, {:bound_council_override, ^key}} =
                 Consult.decide(TestAdvisoryEvaluator, "Review this change", opts)
      end
    end
  end

  defp write_decision_graph! do
    path =
      Path.join(
        System.tmp_dir!(),
        "consult-decision-#{System.unique_integer([:positive])}.dot"
      )

    File.write!(path, """
    digraph consult_decision {
      council.question="Reviewed graph question"
      mode="decision"
      quorum="supermajority"

      start [type="start"]
      done [type="exit"]
      start -> done
    }
    """)

    path
  end

  defp compile_graph!(path) do
    orchestrator = Module.concat(["Arbor", "Orchestrator"])
    {:ok, graph} = apply(orchestrator, :compile, [File.read!(path)])
    graph
  end

  defp canonical_graph_hash(graph) do
    run_authorization =
      Module.concat(["Arbor", "Orchestrator", "Engine", "RunAuthorization"])

    apply(run_authorization, :graph_hash, [graph])
  end

  defp compiled_graph_hash(graph) do
    execution_manifest =
      Module.concat(["Arbor", "Orchestrator", "CodingPlan", "ExecutionManifest"])

    {:ok, hash} = apply(execution_manifest, :compiled_graph_hash, [graph])
    hash
  end
end
