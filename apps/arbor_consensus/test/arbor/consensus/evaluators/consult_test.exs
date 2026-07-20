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

    test "security regression: authorization true without run_authorization forwards principal lineage" do
      # Root authorized launch for the legacy coding council path: no inherited
      # RunAuthorization. Requires a canonical %SigningAuthority{} top-level
      # (never opaque doubles / nested discovery); principal never defaults to
      # "system".
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      principal = "agent_root_auth_#{System.unique_integer([:positive])}"
      task_id = "task_root_auth_#{System.unique_integer([:positive])}"
      workdir = File.cwd!()
      expected_graph = compile_graph!(graph_path)

      {:ok, signing_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      engine_runner = fn graph, engine_opts ->
        send(parent, {:root_authorized_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "Root authorized council",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 execution_principal: principal,
                 caller_id: principal,
                 author_id: principal,
                 task_id: task_id,
                 workdir: workdir,
                 signing_authority: signing_authority,
                 nested_engine_opts: [
                   max_depth: 3,
                   actions_executor: :must_not_cross
                 ],
                 engine_runner: engine_runner
               )

      assert_receive {:root_authorized_engine_run, actual_graph, engine_opts}
      assert actual_graph.compiled
      assert actual_graph == expected_graph
      assert engine_opts[:authorization] == true
      assert engine_opts[:agent_id] == principal
      assert engine_opts[:execution_principal] == principal
      assert engine_opts[:caller_id] == principal
      assert engine_opts[:author_id] == principal
      assert engine_opts[:task_id] == task_id
      assert engine_opts[:workdir] == workdir
      refute Keyword.has_key?(engine_opts, :run_authorization)
      assert Keyword.fetch!(engine_opts, :signing_authority) == signing_authority
      assert engine_opts[:max_depth] == 3
      refute Keyword.has_key?(engine_opts, :actions_executor)
      refute Map.has_key?(engine_opts[:initial_values], :signing_authority)
      refute Map.has_key?(engine_opts[:initial_values], "signing_authority")
      refute Map.has_key?(engine_opts[:initial_values], :agent_id)
      refute Map.has_key?(engine_opts[:initial_values], :workdir)
      refute engine_opts[:agent_id] in ["system", "agent_system"]
    end

    test "security regression: root path rejects overrides, mixed credentials, and non-canonical authority" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      principal = "agent_bound_root_#{System.unique_integer([:positive])}"

      {:ok, signing_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      engine_runner = fn _graph, _engine_opts -> flunk("engine runner must not be called") end

      assert {:error, {:bound_council_override, :mode}} =
               Consult.decide(TestAdvisoryEvaluator, "Bound root auth",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signing_authority: signing_authority,
                 mode: "advisory",
                 engine_runner: engine_runner
               )

      assert {:error, {:mixed_signing_credentials, forbidden}} =
               Consult.decide(TestAdvisoryEvaluator, "mixed credentials",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signing_authority: signing_authority,
                 nested_engine_opts: [
                   signer: fn _ -> {:ok, :signed} end
                 ],
                 engine_runner: engine_runner
               )

      assert :signer in forbidden

      # Nested signing_authority is forbidden on the root path (top-level only).
      assert {:error, {:mixed_signing_credentials, nested_sa_forbidden}} =
               Consult.decide(TestAdvisoryEvaluator, "nested authority discovery",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signing_authority: signing_authority,
                 nested_engine_opts: [signing_authority: signing_authority],
                 engine_runner: engine_runner
               )

      assert :signing_authority in nested_sa_forbidden

      assert {:error, :missing_signing_authority} =
               Consult.decide(TestAdvisoryEvaluator, "missing authority",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 engine_runner: engine_runner
               )

      # Present nil/malformed signing_authority binds and fails closed (never unbound).
      assert {:error, :invalid_signing_authority} =
               Consult.decide(TestAdvisoryEvaluator, "nil authority",
                 graph: graph_path,
                 signing_authority: nil,
                 engine_runner: engine_runner
               )

      assert {:error, :invalid_signing_authority} =
               Consult.decide(TestAdvisoryEvaluator, "opaque double",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signing_authority: {:opaque, make_ref()},
                 engine_runner: engine_runner
               )

      assert {:error, {:identity_mismatch, :agent_id}} =
               Consult.decide(TestAdvisoryEvaluator, "mismatched agent_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: "agent_other_#{System.unique_integer([:positive])}",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert {:error, {:identity_mismatch, :execution_principal}} =
               Consult.decide(TestAdvisoryEvaluator, "mismatched execution_principal",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 execution_principal: "agent_other_#{System.unique_integer([:positive])}",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert {:error, {:identity_mismatch, :principal_id}} =
               Consult.decide(TestAdvisoryEvaluator, "mismatched principal_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 principal_id: "agent_other_#{System.unique_integer([:positive])}",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      # Flat Engine key "session.agent_id" is the identity claim; nested session maps are not.
      assert {:error, {:identity_mismatch, :session_agent_id}} =
               Consult.decide(TestAdvisoryEvaluator, "mismatched flat session.agent_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 "session.agent_id": "agent_other_#{System.unique_integer([:positive])}",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert {:error, {:identity_mismatch, :auth_context}} =
               Consult.decide(TestAdvisoryEvaluator, "mismatched auth_context",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 auth_context: %{
                   principal_id: "agent_other_#{System.unique_integer([:positive])}"
                 },
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert {:error, {:identity_mismatch, :signed_request}} =
               Consult.decide(TestAdvisoryEvaluator, "mismatched signed_request",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signed_request: %{agent_id: "agent_other_#{System.unique_integer([:positive])}"},
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      # Well-formed map/list authority is rejected (struct required; no rehydrate).
      well_formed_map = %{
        token: :crypto.strong_rand_bytes(32),
        principal_id: principal,
        purpose: :legacy_coding_task_executor
      }

      assert {:error, :invalid_signing_authority} =
               Consult.decide(TestAdvisoryEvaluator, "well-formed map authority",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signing_authority: well_formed_map,
                 engine_runner: engine_runner
               )

      assert {:error, :invalid_signing_authority} =
               Consult.decide(TestAdvisoryEvaluator, "well-formed list authority",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 signing_authority: [
                   token: well_formed_map.token,
                   principal_id: principal,
                   purpose: :legacy_coding_task_executor
                 ],
                 engine_runner: engine_runner
               )

      assert {:error, :system_principal_forbidden} =
               Consult.decide(TestAdvisoryEvaluator, "system agent_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: "system",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )
    end

    test "security regression: flat session.agent_id accepted; nested session maps ignored; opaque whitespace preserved" do
      # Engine identity lives at flat "session.agent_id". Nested %{session: %{agent_id: ...}}
      # must not authorize or mismatch. Whitespace-bearing identities are opaque.
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      principal = "agent_flat_session_#{System.unique_integer([:positive])}"
      other = "agent_other_#{System.unique_integer([:positive])}"
      spaced_principal = principal <> " "
      workdir = File.cwd!()

      {:ok, signing_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      {:ok, spaced_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: spaced_principal,
          purpose: :legacy_coding_task_executor
        })

      engine_runner = fn graph, engine_opts ->
        send(parent, {:flat_session_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      # Matching flat atom key is accepted.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "flat atom session.agent_id match",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 "session.agent_id": principal,
                 workdir: workdir,
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert_receive {:flat_session_engine_run, _graph, engine_opts}
      assert engine_opts[:agent_id] == principal

      # Matching flat string key is accepted (List.keyfind path; Keyword string keys raise).
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "flat string session.agent_id match",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {"session.agent_id", principal},
                   {:workdir, workdir},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:flat_session_engine_run, _graph2, _}

      # Mismatched string-key claim also uses List.keyfind and fails closed.
      assert {:error, {:identity_mismatch, :session_agent_id}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "flat string session.agent_id mismatch",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {"session.agent_id", other},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Nested session map alone is ignored (not an identity claim).
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "nested session ignored",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 session: %{agent_id: other},
                 workdir: workdir,
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert_receive {:flat_session_engine_run, _graph3, _}

      # Nested session map must not mask a real flat mismatch either.
      assert {:error, {:identity_mismatch, :session_agent_id}} =
               Consult.decide(TestAdvisoryEvaluator, "nested does not mask flat mismatch",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 session: %{agent_id: principal},
                 "session.agent_id": other,
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      # All-whitespace is blank and rejects (trim only as predicate).
      assert {:error, :invalid_principal_id} =
               Consult.decide(TestAdvisoryEvaluator, "whitespace-only agent_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: "   ",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      assert {:error, :invalid_principal_id} =
               Consult.decide(TestAdvisoryEvaluator, "whitespace-only session.agent_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: principal,
                 "session.agent_id": "\t  \n",
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      # Opaque whitespace: "agent_x " must not match authority principal "agent_x".
      assert {:error, {:identity_mismatch, :agent_id}} =
               Consult.decide(TestAdvisoryEvaluator, "opaque whitespace agent_id",
                 graph: graph_path,
                 authorization: true,
                 agent_id: spaced_principal,
                 signing_authority: signing_authority,
                 engine_runner: engine_runner
               )

      # Matching spaced principal through flat session.agent_id and agent_id is accepted.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(TestAdvisoryEvaluator, "opaque spaced match",
                 graph: graph_path,
                 authorization: true,
                 agent_id: spaced_principal,
                 "session.agent_id": spaced_principal,
                 workdir: workdir,
                 signing_authority: spaced_authority,
                 engine_runner: engine_runner
               )

      assert_receive {:flat_session_engine_run, _graph4, spaced_opts}
      assert spaced_opts[:agent_id] == spaced_principal

      # Trimmed claim must not authorize a whitespace-bearing principal.
      assert {:error, {:identity_mismatch, :agent_id}} =
               Consult.decide(TestAdvisoryEvaluator, "trimmed does not match spaced",
                 graph: graph_path,
                 authorization: true,
                 agent_id: String.trim(spaced_principal),
                 signing_authority: spaced_authority,
                 engine_runner: engine_runner
               )
    end

    test "security regression: signing_authority and launch selectors are all-occurrences never first-wins" do
      # Keyword.fetch!/get first-wins hid a later hostile signing_authority,
      # run_authorization, authorization, or nested_engine_opts occurrence.
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      principal = "agent_sa_list_#{System.unique_integer([:positive])}"
      workdir = File.cwd!()

      {:ok, signing_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      {:ok, other_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      engine_runner = fn graph, engine_opts ->
        send(parent, {:sa_list_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      # Conflicting duplicate atom signing_authority fails closed.
      assert {:error, :conflicting_signing_authority} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "duplicate atom signing_authority conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:signing_authority, other_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Mixed atom/string signing_authority conflict fails closed.
      assert {:error, :conflicting_signing_authority} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "mixed signing_authority conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {"signing_authority", other_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Present-nil duplicate next to a valid claim fails closed.
      assert {:error, :invalid_signing_authority} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "present-nil signing_authority alias",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {"signing_authority", nil},
                   {:engine_runner, engine_runner}
                 ]
               )

      # String-only signing_authority is not ignored by Keyword.has_key?.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "string-only signing_authority",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {"signing_authority", signing_authority},
                   {:workdir, workdir},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:sa_list_engine_run, _g1, opts1}
      assert Keyword.fetch!(opts1, :signing_authority) == signing_authority

      # Equal atom/string signing_authority duplicates may pass.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "equal signing_authority duplicates",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {"signing_authority", signing_authority},
                   {:workdir, workdir},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:sa_list_engine_run, _g2, _}

      # Conflicting run_authorization fails closed.
      assert {:error, :conflicting_run_authorization} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "run_authorization conflict",
                 [
                   {:graph, graph_path},
                   {:run_authorization, {:opaque_a, make_ref()}},
                   {"run_authorization", {:opaque_b, make_ref()}},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Conflicting authorization true/false fails closed.
      assert {:error, :conflicting_authorization} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "authorization conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {"authorization", false},
                   {:signing_authority, signing_authority},
                   {:agent_id, principal},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Conflicting nested_engine_opts max_depth projections fail closed on root.
      assert {:error, :conflicting_nested_engine_opts} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "nested_engine_opts conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:nested_engine_opts, [max_depth: 1]},
                   {"nested_engine_opts", [max_depth: 2]},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Equal nested max_depth projections may pass; extra non-credential keys on
      # one envelope are stripped and cannot alter the sanitized root boundary.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "equal nested projections",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, workdir},
                   {:nested_engine_opts, [max_depth: 4, ignored_noise: true]},
                   {"nested_engine_opts", [max_depth: 4]},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:sa_list_engine_run, _g3, opts3}
      assert opts3[:max_depth] == 4
      refute Keyword.has_key?(opts3, :ignored_noise)
    end

    test "security regression: all-occurrences list identity claims never first-wins" do
      # Keyword.get is first-wins and Keyword APIs reject string keys. Hostile
      # duplicate atom keys or mixed atom/string tuples must all be validated.
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      principal = "agent_list_all_values_#{System.unique_integer([:positive])}"
      other = "agent_other_#{System.unique_integer([:positive])}"
      workdir = File.cwd!()

      {:ok, signing_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      engine_runner = fn graph, engine_opts ->
        send(parent, {:list_all_values_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      # Conflicting duplicate atom agent_id keys fail closed.
      assert {:error, {:identity_mismatch, :agent_id}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "duplicate atom agent_id conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:agent_id, other},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Mixed atom/string agent_id conflict fails closed.
      assert {:error, {:identity_mismatch, :agent_id}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "mixed agent_id conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {"agent_id", other},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # String-only hostile agent_id is not ignored (was invisible to Keyword.get).
      assert {:error, {:identity_mismatch, :agent_id}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "string-only hostile agent_id",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {"agent_id", other},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Equal duplicate atom agent_id keys may pass.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "equal duplicate agent_id",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:agent_id, principal},
                   {:workdir, workdir},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:list_all_values_engine_run, _graph, engine_opts}
      assert engine_opts[:agent_id] == principal

      # Equal atom/string agent_id spellings may pass.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "equal mixed agent_id",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {"agent_id", principal},
                   {:workdir, workdir},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:list_all_values_engine_run, _graph2, _}

      # Present-nil direct claim fails closed.
      assert {:error, :invalid_principal_id} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "present-nil agent_id",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, nil},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Conflicting flat session.agent_id atom/string claims fail closed.
      assert {:error, {:identity_mismatch, :session_agent_id}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "session.agent_id conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:"session.agent_id", principal},
                   {"session.agent_id", other},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Nested auth_context principal_id atom/string conflict fails closed.
      assert {:error, {:identity_mismatch, :auth_context}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "nested auth_context conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:auth_context,
                    %{
                      "principal_id" => other,
                      principal_id: principal
                    }},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Conflicting caller_id lineage claims fail closed.
      assert {:error, {:identity_mismatch, :caller_id}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "caller_id lineage conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:caller_id, principal},
                   {"caller_id", other},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Invalid UTF-8 / NUL claims fail closed.
      assert {:error, :invalid_principal_id} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "invalid utf8 agent_id",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, "agent_ok" <> <<0xFF>>},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert {:error, :invalid_principal_id} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "nul principal_id",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:principal_id, "agent_ok" <> <<0>>},
                   {:signing_authority, signing_authority},
                   {:engine_runner, engine_runner}
                 ]
               )
    end

    test "security regression: within-envelope keyword duplicates and workdir claims never first-wins" do
      # Gaps left by outer-envelope-only reconciliation: duplicate max_depth /
      # credential keys inside one nested list, and present-nil/conflict workdir.
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      parent = self()
      principal = "agent_within_kw_#{System.unique_integer([:positive])}"
      workdir = File.cwd!()
      other_workdir = Path.join(System.tmp_dir!(), "hostile-workdir")

      {:ok, signing_authority} =
        Arbor.Contracts.Security.SigningAuthority.new(%{
          token: :crypto.strong_rand_bytes(32),
          principal_id: principal,
          purpose: :legacy_coding_task_executor
        })

      engine_runner = fn graph, engine_opts ->
        send(parent, {:within_kw_engine_run, graph, engine_opts})
        {:ok, %{context: %{"council.decision" => "approved"}}}
      end

      signer_a = fn _req -> {:ok, :signed_a} end
      signer_b = fn _req -> {:ok, :signed_b} end

      # Within one nested_engine_opts list: conflicting max_depth fails closed.
      assert {:error, :conflicting_nested_engine_opts} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "within-envelope max_depth conflict",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:nested_engine_opts, [max_depth: 1, max_depth: 2]},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Equal within-envelope max_depth may pass.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "within-envelope equal max_depth",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, workdir},
                   {:nested_engine_opts, [max_depth: 5, max_depth: 5]},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:within_kw_engine_run, _g1, opts1}
      assert opts1[:max_depth] == 5

      # Inherited path: conflicting credential allowlist entries inside one list.
      parent_ra = {:opaque_parent_ra, make_ref()}

      assert {:error, :conflicting_nested_engine_opts} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "within-envelope signer conflict",
                 [
                   {:graph, graph_path},
                   {:run_authorization, parent_ra},
                   {:nested_engine_opts, [signer: signer_a, signer: signer_b, max_depth: 2]},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Equal credential allowlist entries within one list may pass.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "within-envelope equal signer",
                 [
                   {:graph, graph_path},
                   {:run_authorization, parent_ra},
                   {:nested_engine_opts,
                    [signer: signer_a, signer: signer_a, max_depth: 2, max_depth: 2]},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:within_kw_engine_run, _g2, opts2}
      assert opts2[:signer] == signer_a
      assert opts2[:max_depth] == 2

      # workdir: present nil fails closed (never discarded before reconciliation).
      assert {:error, :invalid_workdir} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "present-nil workdir",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, nil},
                   {:engine_runner, engine_runner}
                 ]
               )

      # workdir: nil next to a valid claim fails closed (not first-wins valid).
      assert {:error, :invalid_workdir} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "nil then valid workdir",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, nil},
                   {:workdir, workdir},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert {:error, :invalid_workdir} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "valid then nil workdir",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, workdir},
                   {"workdir", nil},
                   {:engine_runner, engine_runner}
                 ]
               )

      # workdir: conflicting path values fail closed.
      assert {:error, {:identity_mismatch, :workdir}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "conflicting workdir",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, workdir},
                   {"workdir", other_workdir},
                   {:engine_runner, engine_runner}
                 ]
               )

      # workdir: blank / malformed fail closed.
      assert {:error, :invalid_workdir} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "blank workdir",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, "   "},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert {:error, :invalid_workdir} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "nul workdir",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, "/tmp/ok" <> <<0>>},
                   {:engine_runner, engine_runner}
                 ]
               )

      # Equal workdir duplicates (atom/string) may pass.
      assert {:ok, %{decision: "approved"}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "equal workdir duplicates",
                 [
                   {:graph, graph_path},
                   {:authorization, true},
                   {:agent_id, principal},
                   {:signing_authority, signing_authority},
                   {:workdir, workdir},
                   {"workdir", workdir},
                   {:engine_runner, engine_runner}
                 ]
               )

      assert_receive {:within_kw_engine_run, _g3, opts3}
      assert opts3[:workdir] == workdir

      # Bound override after a first-wins nil still fails closed.
      assert {:error, {:bound_council_override, :mode}} =
               Consult.decide(
                 TestAdvisoryEvaluator,
                 "bound mode override after nil",
                 [
                   {:graph, graph_path},
                   {:run_authorization, parent_ra},
                   {:mode, nil},
                   {:mode, "advisory"},
                   {:engine_runner, engine_runner}
                 ]
               )
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

    test "failure_reason over byte limit truncates on a UTF-8 codepoint boundary" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      # 511 ASCII bytes + 2-byte "é" = 513; a raw 512-byte cut would split "é".
      prefix = String.duplicate("a", 511)
      reason = prefix <> "é" <> "tail"
      assert byte_size(reason) > 512
      assert String.valid?(reason)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{},
           final_outcome: %{status: :fail, failure_reason: reason}
         }}
      end

      assert {:error, {:council_pipeline_failed, bounded}} =
               Consult.decide(TestAdvisoryEvaluator, "UTF-8 safe failure_reason bound",
                 graph: graph_path,
                 engine_runner: engine_runner
               )

      assert String.valid?(bounded)
      assert byte_size(bounded) <= 512
      assert bounded == prefix
      refute String.contains?(bounded, "é")
    end

    test "invalid UTF-8 failure_reason fails closed to a known-good default" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      invalid = <<0xFF, 0xFE, "not-utf8">>
      refute String.valid?(invalid)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{"council.decision" => "approved"},
           final_outcome: %{status: :fail, failure_reason: invalid}
         }}
      end

      assert {:error, {:council_pipeline_failed, "pipeline failed"}} =
               Consult.decide(TestAdvisoryEvaluator, "Invalid UTF-8 failure_reason",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
    end

    test "retry terminal outcome fails closed and rejects stale decision keys" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{"exec.decide.decision" => "approved", "council.decision" => "approved"},
           final_outcome: %{status: :retry, failure_reason: nil}
         }}
      end

      assert {:error, {:council_pipeline_failed, "terminal outcome status: retry"}} =
               Consult.decide(TestAdvisoryEvaluator, "Retry is not decision-admissible",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
    end

    test "skipped terminal outcome fails closed" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      engine_runner = fn _graph, _engine_opts ->
        {:ok,
         %{
           context: %{"council.decision" => "approved"},
           final_outcome: %{"status" => "skipped"}
         }}
      end

      assert {:error, {:council_pipeline_failed, "terminal outcome status: skipped"}} =
               Consult.decide(TestAdvisoryEvaluator, "Skipped is not decision-admissible",
                 graph: graph_path,
                 engine_runner: engine_runner
               )
    end

    test "unknown or malformed present final_outcome fails closed" do
      graph_path = write_decision_graph!()
      on_exit(fn -> File.rm(graph_path) end)

      for final_outcome <- [
            %{status: :unknown},
            %{},
            "not-an-outcome",
            42
          ] do
        engine_runner = fn _graph, _engine_opts ->
          {:ok,
           %{
             context: %{"exec.decide.decision" => "approved"},
             final_outcome: final_outcome
           }}
        end

        assert {:error, {:council_pipeline_failed, reason}} =
                 Consult.decide(TestAdvisoryEvaluator, "Malformed/unknown final_outcome",
                   graph: graph_path,
                   engine_runner: engine_runner
                 )

        assert is_binary(reason)
        assert String.valid?(reason)
        assert reason != ""
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
