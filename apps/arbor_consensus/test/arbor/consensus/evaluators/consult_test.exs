defmodule Arbor.Consensus.Evaluators.ConsultTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Evaluators.Consult
  alias Arbor.Consensus.TestHelpers.{FailingAdvisoryEvaluator, TestAdvisoryEvaluator}

  # Mirrors production Engine.Context: get/3 only, no fetch/2. Values live in an
  # internal map so Map.has_key?/2 on the struct itself cannot detect presence.
  defmodule GetOnlyContext do
    defstruct values: %{}

    def new(values) when is_map(values), do: %__MODULE__{values: values}

    def get(%__MODULE__{values: values}, key, default \\ nil) do
      Map.get(values, key, default)
    end
  end

  # Duck-typed stand-in for Engine.Outcome fields Consult inspects. Lives only
  # in this test so consensus stays free of orchestrator compile-time deps.
  defmodule FakeOutcome do
    defstruct status: nil, failure_reason: nil
  end

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

    test "security regression: Consult.decide forwards signing_authority nested engine opt" do
      # Fails on a3928b18: @nested_engine_opt_allowlist omitted :signing_authority,
      # so parent authority mode was silently dropped into nested Engine runs.
      # This exercises production Consult.decide/3 → nested_engine_opts/2, not a
      # locally recreated Keyword.take allowlist.
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      authority = {:opaque_parent_authorization, make_ref()}
      signing_authority = {:opaque_signing_authority, make_ref()}

      engine_runner = fn _graph, engine_opts ->
        send(parent, {:signing_authority_nested_opts, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Authority nested propagation",
                 graph: graph_path,
                 run_authorization: authority,
                 nested_engine_opts: [
                   signing_authority: signing_authority,
                   signer: fn _ -> {:ok, :signed} end,
                   max_depth: 4,
                   # Must not pass through the allowlist:
                   actions_executor: :must_not_cross,
                   middleware: [:must_not_cross]
                 ],
                 engine_runner: engine_runner
               )

      assert_receive {:signing_authority_nested_opts, engine_opts}
      assert Keyword.fetch!(engine_opts, :signing_authority) == signing_authority
      assert engine_opts[:max_depth] == 4
      assert engine_opts[:run_authorization] == authority
      assert engine_opts[:authorization] == true
      refute Keyword.has_key?(engine_opts, :actions_executor)
      refute Keyword.has_key?(engine_opts, :middleware)
      # Authority stays process-local engine opts, not initial context.
      refute Map.has_key?(engine_opts[:initial_values], "signing_authority")
      refute Map.has_key?(engine_opts[:initial_values], :signing_authority)
    end

    test "security regression: Consult.decide present nil signing_authority stays present (fail-closed)" do
      # Presence of the key (even nil) must be preserved so nested Engine fails
      # closed rather than treating absence as legacy authorizer/signer mode.
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      authority = {:opaque_parent_authorization, make_ref()}

      engine_runner = fn _graph, engine_opts ->
        send(parent, {:nil_signing_authority_nested_opts, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Nil authority presence",
                 graph: graph_path,
                 run_authorization: authority,
                 nested_engine_opts: [
                   signing_authority: nil,
                   max_depth: 2
                 ],
                 engine_runner: engine_runner
               )

      assert_receive {:nil_signing_authority_nested_opts, engine_opts}
      assert Keyword.has_key?(engine_opts, :signing_authority)
      assert Keyword.fetch!(engine_opts, :signing_authority) == nil
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

  describe "decide/3 review decision projection" do
    @review_fields [
      :review_cycle,
      :finding_ledger,
      :findings,
      :out_of_scope,
      :review_disposition,
      :blocking_ids,
      :blocking_reasons,
      :human_required
    ]

    test "projects closed review metadata from exec.decide.* Engine context" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      finding_ledger = %{
        "review_cycle" => 1,
        "findings" => %{},
        "cycles" => %{},
        "out_of_scope" => []
      }

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{
             "exec.decide.decision" => "approved",
             "exec.decide.approve_count" => 3,
             "exec.decide.reject_count" => 0,
             "exec.decide.abstain_count" => 0,
             "exec.decide.quorum_met" => true,
             "exec.decide.review_cycle" => 1,
             "exec.decide.finding_ledger" => finding_ledger,
             "exec.decide.findings" => [],
             "exec.decide.out_of_scope" => [],
             "exec.decide.review_disposition" => "accept",
             "exec.decide.blocking_ids" => [],
             "exec.decide.blocking_reasons" => [],
             "exec.decide.human_required" => false,
             # Must not forward arbitrary nested context outside the allowlist.
             "exec.decide.secret_internal" => "must-not-project",
             "exec.decide.arbitrary_payload" => %{"x" => 1}
           }
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "Project exec.decide review fields",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "approved"
      assert decision.approve_count == 3
      assert decision.quorum_met == true
      assert decision.review_cycle == 1
      assert decision.finding_ledger == finding_ledger
      assert decision.findings == []
      assert decision.out_of_scope == []
      assert decision.review_disposition == "accept"
      assert decision.blocking_ids == []
      assert decision.blocking_reasons == []
      # Legitimate false must survive; absence is what omits the key.
      assert decision.human_required == false
      assert Map.has_key?(decision, :human_required)

      refute Map.has_key?(decision, :secret_internal)
      refute Map.has_key?(decision, "secret_internal")
      refute Map.has_key?(decision, :arbitrary_payload)
      refute Map.has_key?(decision, "arbitrary_payload")
    end

    test "falls back to council.* review fields for legacy prefix compatibility" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{
             "council.decision" => "rejected",
             "council.approve_count" => 1,
             "council.reject_count" => 2,
             "council.abstain_count" => 0,
             "council.quorum_met" => true,
             "council.review_cycle" => 2,
             "council.finding_ledger" => %{"review_cycle" => 2, "findings" => %{}},
             "council.review_disposition" => "human_review",
             "council.blocking_ids" => ["finding-1"],
             "council.blocking_reasons" => [%{"id" => "finding-1", "reason" => "open"}],
             "council.human_required" => true,
             "council.findings" => [%{"id" => "finding-1"}],
             "council.out_of_scope" => [%{"id" => "oos-1"}]
           }
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "Project council.* review fields",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "rejected"
      assert decision.review_cycle == 2
      assert decision.finding_ledger == %{"review_cycle" => 2, "findings" => %{}}
      assert decision.review_disposition == "human_review"
      assert decision.blocking_ids == ["finding-1"]
      assert decision.blocking_reasons == [%{"id" => "finding-1", "reason" => "open"}]
      assert decision.human_required == true
      assert decision.findings == [%{"id" => "finding-1"}]
      assert decision.out_of_scope == [%{"id" => "oos-1"}]
    end

    test "prefers exec.decide.* over council.* when both prefixes are present" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{
             "exec.decide.decision" => "approved",
             "council.decision" => "rejected",
             "exec.decide.review_cycle" => 3,
             "council.review_cycle" => 1,
             "exec.decide.human_required" => false,
             "council.human_required" => true,
             "exec.decide.review_disposition" => "accept",
             "council.review_disposition" => "human_review"
           }
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "Prefer exec.decide prefix",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "approved"
      assert decision.review_cycle == 3
      assert decision.human_required == false
      assert decision.review_disposition == "accept"
    end

    test "ordinary generic council decisions have no review-specific keys" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{
             "exec.decide.decision" => "approved",
             "exec.decide.approve_count" => 4,
             "exec.decide.reject_count" => 0,
             "exec.decide.abstain_count" => 0,
             "exec.decide.quorum_met" => true,
             "exec.decide.status" => "decided"
           }
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "Generic council only",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "approved"
      assert decision.approve_count == 4
      assert decision.quorum_met == true

      for field <- @review_fields do
        refute Map.has_key?(decision, field),
               "generic decision must not invent review key #{inspect(field)}"
      end

      # Explicit non-review keys that must also stay absent (never defaulted).
      refute Map.has_key?(decision, :human_required)
      refute Map.has_key?(decision, "human_required")
    end

    test "projects review metadata through get/3-only context structs (Engine.Context shape)" do
      # Production Arbor.Orchestrator.Engine.Context exports get/3, not fetch/2.
      # Presence detection must use an unforgeable sentinel via get/3 so live
      # nested Engine results keep review fields (including false/empty/nil).
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      finding_ledger = %{"review_cycle" => 1, "findings" => %{}}

      values = %{
        "exec.decide.decision" => "approved",
        "exec.decide.approve_count" => 2,
        "exec.decide.reject_count" => 0,
        "exec.decide.abstain_count" => 0,
        "exec.decide.quorum_met" => true,
        "exec.decide.review_cycle" => 1,
        "exec.decide.finding_ledger" => finding_ledger,
        # Present nil must survive presence detection (distinct from absence).
        "exec.decide.findings" => nil,
        "exec.decide.out_of_scope" => [],
        "exec.decide.review_disposition" => "accept",
        "exec.decide.blocking_ids" => [],
        "exec.decide.blocking_reasons" => [],
        # Legitimate false must survive presence detection.
        "exec.decide.human_required" => false,
        "exec.decide.secret_internal" => "must-not-project"
      }

      engine_runner = fn _graph, _engine_opts ->
        {:ok, %{context: GetOnlyContext.new(values)}}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "get/3-only context projection",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "approved"
      assert decision.review_cycle == 1
      assert decision.finding_ledger == finding_ledger
      assert decision.findings == nil
      assert decision.out_of_scope == []
      assert decision.review_disposition == "accept"
      assert decision.blocking_ids == []
      assert decision.blocking_reasons == []
      assert decision.human_required == false
      assert Map.has_key?(decision, :human_required)
      assert Map.has_key?(decision, :findings)

      refute Map.has_key?(decision, :secret_internal)
      refute Map.has_key?(decision, "secret_internal")
    end

    test "get/3-only generic decisions still omit every review-specific key" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context:
             GetOnlyContext.new(%{
               "exec.decide.decision" => "approved",
               "exec.decide.approve_count" => 3,
               "exec.decide.reject_count" => 0,
               "exec.decide.abstain_count" => 0,
               "exec.decide.quorum_met" => true,
               "exec.decide.status" => "decided"
             })
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "get/3-only generic decision",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "approved"
      assert decision.approve_count == 3

      for field <- @review_fields do
        refute Map.has_key?(decision, field),
               "get/3-only generic decision must not invent #{inspect(field)}"
      end
    end
  end

  describe "decide/3 terminal Engine outcome causality" do
    # Arbor Engine returns {:ok, run_result} even when final_outcome.status is
    # :fail (e.g. parallel.fan_in "All parallel candidates failed"). Consult
    # must fail closed on that terminal failure rather than inventing
    # :no_decision_in_result or accepting stale decision keys from context.

    test "failed terminal outcome without decision returns council_pipeline_failed" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{},
           final_outcome: %{
             status: :fail,
             failure_reason: "All parallel candidates failed"
           }
         }}
      end

      assert {:error, {:council_pipeline_failed, "All parallel candidates failed"}} =
               Consult.decide(TestAdvisoryEvaluator, "Failed fan-in with no decision",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
    end

    test "failed terminal outcome rejects stale decision keys from context" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{
             "exec.decide.decision" => "approved",
             "exec.decide.approve_count" => 5,
             "exec.decide.quorum_met" => true,
             "council.decision" => "approved"
           },
           final_outcome: %{
             "status" => "fail",
             "failure_reason" => "All parallel candidates failed"
           }
         }}
      end

      assert {:error, {:council_pipeline_failed, "All parallel candidates failed"}} =
               Consult.decide(TestAdvisoryEvaluator, "Failed fan-in with stale decision keys",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
    end

    test "successful terminal outcome still extracts decision" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{
             "exec.decide.decision" => "approved",
             "exec.decide.approve_count" => 3,
             "exec.decide.reject_count" => 0,
             "exec.decide.abstain_count" => 0,
             "exec.decide.quorum_met" => true
           },
           final_outcome: %{status: :success, failure_reason: nil}
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "Successful terminal outcome",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "approved"
      assert decision.approve_count == 3
    end

    test "partial_success terminal outcome still extracts decision" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{"council.decision" => "rejected", "council.quorum_met" => true},
           final_outcome: %{status: :partial_success}
         }}
      end

      assert {:ok, decision} =
               Consult.decide(TestAdvisoryEvaluator, "Partial-success terminal outcome",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert decision.decision == "rejected"
    end

    test "omitted final_outcome keeps simple injected-engine compatibility" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "No final_outcome field",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
    end

    test "struct-shaped final_outcome with fail status is causal" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      # Mimic Engine.Outcome without importing orchestrator internals.
      outcome = %FakeOutcome{status: :fail, failure_reason: "handler exploded"}

      engine_runner = fn _graph, _engine_opts ->
        {:ok, %{context: %{"exec.decide.decision" => "approved"}, final_outcome: outcome}}
      end

      assert {:error, {:council_pipeline_failed, "handler exploded"}} =
               Consult.decide(TestAdvisoryEvaluator, "Struct final_outcome fail",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
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
