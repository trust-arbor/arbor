defmodule Arbor.Actions.CouncilTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Council
  alias Arbor.Actions.Coding.ReviewTree
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :fast

  describe "Consult" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Council.Consult.validate_params(%{})

      # Test that schema accepts valid params with just question
      assert {:ok, _} =
               Council.Consult.validate_params(%{
                 question: "Should we use Redis or ETS for caching?"
               })

      # Test with all optional params
      assert {:ok, _} =
               Council.Consult.validate_params(%{
                 question: "Should we use Redis or ETS for caching?",
                 context: %{constraints: "must survive restarts"},
                 timeout: 120_000,
                 evaluator: Arbor.Consensus.Evaluators.AdvisoryLLM
               })
    end

    test "validates action metadata" do
      assert Council.Consult.name() == "council_consult"
      assert Council.Consult.category() == "council"
      assert "council" in Council.Consult.tags()
      assert "advisory" in Council.Consult.tags()
      assert "consult" in Council.Consult.tags()
    end

    test "generates tool schema" do
      tool = Council.Consult.to_tool()
      assert is_map(tool)
      assert tool[:name] == "council_consult"
      assert tool[:description] =~ "Query all advisory council perspectives"
    end

    test "declares taint roles" do
      roles = Council.Consult.taint_roles()
      assert roles[:question] == :control
      assert roles[:context] == :data
      assert roles[:timeout] == :data
      assert roles[:evaluator] == :control
    end
  end

  describe "ConsultOne" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Council.ConsultOne.validate_params(%{})
      assert {:error, _} = Council.ConsultOne.validate_params(%{question: "Test"})

      # Test that schema accepts valid params
      assert {:ok, _} =
               Council.ConsultOne.validate_params(%{
                 question: "Is this design secure?",
                 perspective: :security
               })

      # Test with all optional params
      assert {:ok, _} =
               Council.ConsultOne.validate_params(%{
                 question: "Is this design secure?",
                 perspective: :security,
                 context: %{code: "def foo, do: :bar"},
                 timeout: 60_000,
                 evaluator: Arbor.Consensus.Evaluators.AdvisoryLLM
               })
    end

    test "validates action metadata" do
      assert Council.ConsultOne.name() == "council_consult_one"
      assert Council.ConsultOne.category() == "council"
      assert "council" in Council.ConsultOne.tags()
      assert "single" in Council.ConsultOne.tags()
    end

    test "generates tool schema" do
      tool = Council.ConsultOne.to_tool()
      assert is_map(tool)
      assert tool[:name] == "council_consult_one"
      assert tool[:description] =~ "Query a single advisory council perspective"
    end

    test "declares taint roles" do
      roles = Council.ConsultOne.taint_roles()
      assert roles[:question] == :control
      assert roles[:perspective] == :control
      assert roles[:context] == :data
      assert roles[:timeout] == :data
      assert roles[:evaluator] == :control
    end
  end

  describe "ReviewChange" do
    @valid_review_params %{
      diff: "diff --git a/lib/a.ex b/lib/a.ex\n+def ok, do: :ok",
      files: ["lib/a.ex", "test/a_test.exs"],
      branch: "agent/review-loop",
      base_ref: "main",
      intent: "Add the review loop",
      agent_id: "agent_123"
    }

    test "schema accepts field params and request map params" do
      assert {:ok, _} = Council.ReviewChange.validate_params(@valid_review_params)

      assert {:ok, _} =
               Council.ReviewChange.validate_params(%{
                 request: @valid_review_params,
                 timeout: 30_000,
                 quorum: "majority",
                 tier_decision: "pending"
               })
    end

    test "validates action metadata and egress classification" do
      assert Council.ReviewChange.name() == "council_review_change"
      assert Council.ReviewChange.category() == "council"
      assert "code_review" in Council.ReviewChange.tags()
      assert Council.ReviewChange.effect_class() == :network_egress
      assert Council.ReviewChange.egress_tier(%{}, %{}) == :external_provider
    end

    test "runtime validation rejects an incomplete request" do
      assert {:error, {:missing_required_field, :diff}} =
               Council.ReviewChange.run(%{}, %{review_runner: fn _, _, _ -> flunk("unused") end})
    end

    test "approved council decision becomes a keep verdict and is persisted" do
      parent = self()

      review_runner = fn request, _params, _context ->
        assert request.branch == "agent/review-loop"
        assert request.files == ["lib/a.ex", "test/a_test.exs"]

        {:ok,
         %{
           decision: "approved",
           approve_count: 7,
           reject_count: 2,
           abstain_count: 1,
           quorum_met: true,
           average_confidence: 0.82,
           primary_concerns: []
         }}
      end

      persist_verdict = fn verdict, request, decision ->
        send(parent, {:persisted, verdict, request, decision})
        {:ok, "run_123"}
      end

      assert {:ok, result} =
               Council.ReviewChange.run(@valid_review_params, %{
                 review_runner: review_runner,
                 persist_verdict: persist_verdict
               })

      assert result.status == "reviewed"
      assert result.recommendation == "keep"
      assert result.verdict.recommendation == "keep"
      assert result.verdict.overall_score == 0.7
      assert result.blast_radius == "low"
      assert result.tier_decision == "auto_proceed"
      refute result.human_required
      assert result.persistence == %{"status" => "recorded", "run_id" => "run_123"}

      assert_receive {:persisted, verdict, request, decision}
      assert verdict.meta.branch == "agent/review-loop"
      assert request.agent_id == "agent_123"
      assert decision.decision == "approved"
    end

    test "negative regression: rejecting panel yields reject verdict, not keep" do
      review_runner = fn _request, _params, _context ->
        {:ok,
         %{
           "decision" => "rejected",
           "approve_count" => 2,
           "reject_count" => 6,
           "abstain_count" => 2,
           "quorum_met" => true,
           "average_confidence" => 0.9,
           "primary_concerns" => ["security regression"]
         }}
      end

      assert {:ok, result} =
               Council.ReviewChange.run(@valid_review_params, %{
                 review_runner: review_runner,
                 persist_verdict: false
               })

      assert result.decision == "rejected"
      assert result.recommendation == "reject"
      assert result.verdict.recommendation == "reject"
      assert result.verdict.weaknesses == ["security regression"]
      assert result.tier_decision == "stop"
      refute result.human_required
    end

    test "deadlock maps to revise so the agent reworks instead of proceeding" do
      review_runner = fn _request, _params, _context ->
        {:ok,
         %{
           decision: "deadlock",
           approve_count: 4,
           reject_count: 4,
           abstain_count: 2,
           quorum_met: false,
           average_confidence: 0.61
         }}
      end

      assert {:ok, result} =
               Council.ReviewChange.run(@valid_review_params, %{
                 review_runner: review_runner,
                 persist_verdict: false
               })

      assert result.recommendation == "revise"
      assert result.verdict.recommendation == "revise"
      assert result.verdict.overall_score == 0.4
      assert result.tier_decision == "rework"
      refute result.human_required
    end

    test "high-risk keep verdict routes to human review" do
      review_runner = fn _request, _params, _context ->
        {:ok,
         %{
           decision: "approved",
           approve_count: 8,
           reject_count: 1,
           abstain_count: 1,
           quorum_met: true,
           average_confidence: 0.88
         }}
      end

      params = %{@valid_review_params | files: ["apps/arbor_security/lib/arbor/security.ex"]}

      assert {:ok, result} =
               Council.ReviewChange.run(params, %{
                 review_runner: review_runner,
                 persist_verdict: false
               })

      assert result.recommendation == "keep"
      assert result.blast_radius == "high"
      assert result.tier_decision == "human_review"
      assert result.human_required
      assert "security_app" in result.tier_reasons
    end

    test "security veto routes to human review even for docs-only keep verdicts" do
      review_runner = fn _request, _params, _context ->
        {:ok,
         %{
           decision: "approved",
           approve_count: 9,
           reject_count: 1,
           abstain_count: 0,
           quorum_met: true,
           average_confidence: 0.91,
           security_veto: true
         }}
      end

      params = %{@valid_review_params | files: ["docs/review-loop.md"]}

      assert {:ok, result} =
               Council.ReviewChange.run(params, %{
                 review_runner: review_runner,
                 persist_verdict: false
               })

      assert result.recommendation == "keep"
      assert result.blast_radius == "low"
      assert result.tier_decision == "human_review"
      assert result.human_required
      assert result.security_veto
      assert "security_veto" in result.tier_reasons
    end

    test "security perspective reject vote routes to human review even when majority approves" do
      review_runner = fn _request, _params, _context ->
        {:ok,
         %{
           decision: "approved",
           approve_count: 2,
           reject_count: 1,
           abstain_count: 0,
           quorum_met: true,
           average_confidence: 0.86,
           perspective_votes: %{
             "security" => "reject",
             "correctness" => "approve",
             "tests" => "approve"
           }
         }}
      end

      params = %{@valid_review_params | files: ["docs/review-loop.md"]}

      assert {:ok, result} =
               Council.ReviewChange.run(params, %{
                 review_runner: review_runner,
                 persist_verdict: false
               })

      assert result.recommendation == "keep"
      assert result.blast_radius == "low"
      assert result.tier_decision == "human_review"
      assert result.human_required
      assert result.security_veto
      assert "security_veto" in result.tier_reasons
    end

    test "default runner uses the decide graph path and preserves security veto" do
      graph_path = write_review_decide_fixture!()

      on_exit(fn -> File.rm(graph_path) end)

      params =
        @valid_review_params
        |> Map.put(:files, ["docs/review-loop.md"])
        |> Map.put(:graph, graph_path)

      assert {:ok, result} =
               Council.ReviewChange.run(params, %{
                 persist_verdict: false,
                 review_context: %{
                   "council.decision" => "approved",
                   "council.approve_count" => 2,
                   "council.reject_count" => 1,
                   "council.abstain_count" => 0,
                   "council.quorum_met" => true,
                   "council.average_confidence" => 0.86,
                   "council.primary_concerns" => [],
                   "council.security_veto" => true
                 }
               })

      assert result.decision == "approved"
      assert result.recommendation == "keep"
      assert result.blast_radius == "low"
      assert result.tier_decision == "human_review"
      assert result.security_veto
      assert result.human_required
    end

    test "security regression: bound default runner uses trusted graph and runtime opts" do
      Code.ensure_loaded!(Arbor.Consensus)
      :erlang.trace_pattern({Arbor.Consensus, :decide, 2}, true, [])

      on_exit(fn ->
        :erlang.trace_pattern({Arbor.Consensus, :decide, 2}, false, [])
      end)

      parent = self()
      signer = fn _resource -> {:ok, :signed} end
      authorizer = fn _agent_id, _handler_type -> :ok end
      authority = :malformed_parent_authorization
      candidate_commit = String.duplicate("a", 40)

      snapshot_opener = fn _workspace_id, ^candidate_commit, _caller ->
        {:ok,
         %{
           review_snapshot_id: "review_snap_bound_test",
           candidate_commit: candidate_commit,
           base_commit: "main"
         }}
      end

      snapshot_closer = fn "review_snap_bound_test", _caller ->
        send(parent, :bound_snapshot_closed)
        {:ok, %{active: false}}
      end

      params =
        @valid_review_params
        |> Map.put(:workspace_id, "ws_bound_test")
        |> Map.put(:commit_hash, candidate_commit)

      result =
        Task.async(fn ->
          :erlang.trace(self(), true, [:call, {:tracer, parent}])

          Council.ReviewChange.run(params, %{
            persist_verdict: false,
            run_authorization: authority,
            review_snapshot_opener: snapshot_opener,
            review_snapshot_closer: snapshot_closer,
            nested_engine_opts: [signer: signer, authorizer: authorizer],
            review_context: %{
              "council.decision" => "approved",
              "council.quorum_met" => true
            }
          })
        end)
        |> Task.await()

      assert {:error, :invalid_run_authorization} = result
      assert_receive :bound_snapshot_closed

      assert_receive {:trace, _pid, :call, {Arbor.Consensus, :decide, [question, consensus_opts]}}

      assert question == consensus_opts[:context]["council.question"]
      assert consensus_opts[:context]["branch"] == "agent/review-loop"
      assert consensus_opts[:context]["review.snapshot_id"] == "review_snap_bound_test"
      assert consensus_opts[:run_authorization] == authority
      assert consensus_opts[:nested_engine_opts][:signer] == signer
      assert consensus_opts[:nested_engine_opts][:authorizer] == authorizer

      assert {:ok, reviewed_pipeline} =
               Arbor.Actions.reviewed_pipeline("code_review_council")

      assert Path.expand(consensus_opts[:graph]) == Path.expand(reviewed_pipeline.path)

      refute Keyword.has_key?(consensus_opts, :mode)
      refute Keyword.has_key?(consensus_opts, :quorum)
      refute Map.has_key?(consensus_opts[:context], :nested_engine_opts)
      refute Map.has_key?(consensus_opts[:context], "nested_engine_opts")
    end

    test "rejects graph and quorum overrides for bound reviews" do
      context = %{
        persist_verdict: false,
        run_authorization: :opaque_parent_authorization,
        nested_engine_opts: [
          signer: fn _resource -> {:ok, :signed} end,
          authorizer: fn _agent_id, _handler_type -> :ok end
        ]
      }

      for {key, value} <- [graph: "/tmp/not-allowlisted.dot", quorum: "unanimous"] do
        params = Map.put(@valid_review_params, key, value)

        assert {:error, {:bound_council_override, ^key}} =
                 Council.ReviewChange.run(params, context)
      end
    end

    test "security regression: bound reviews fail closed without workspace and commit scope" do
      assert {:error, :missing_bound_review_snapshot} =
               Council.ReviewChange.run(@valid_review_params, %{
                 run_authorization: :opaque_parent_authorization,
                 review_runner: fn _, _, _ -> flunk("must not run without snapshot scope") end,
                 persist_verdict: false
               })
    end

    test "security regression: binding review reads exact commit evidence and closes its snapshot",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "binding_review_repo"))
      File.mkdir_p!(Path.join(repo, "lib"))
      File.write!(Path.join(repo, "lib/a.ex"), "defmodule A do\n  def value, do: :base\nend\n")
      git!(repo, ["add", "lib/a.ex"])
      git!(repo, ["commit", "-m", "base module"])
      base_commit = git!(repo, ["rev-parse", "HEAD"])

      task_id = "task_binding_review_#{System.unique_integer([:positive])}"
      principal_id = "agent_binding_review_#{System.unique_integer([:positive])}"
      authority_context = %{task_id: task_id, agent_id: principal_id}

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/binding-review",
                   worktree_base_dir: Path.join(tmp_dir, "binding_review_worktrees"),
                   base_ref: base_commit
                 },
                 authority_context
               )

      on_exit(fn ->
        _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, authority_context)
      end)

      File.write!(
        Path.join(lease.worktree_path, "lib/a.ex"),
        "defmodule A do\n  def value, do: :candidate\nend\n"
      )

      git!(lease.worktree_path, ["add", "lib/a.ex"])
      git!(lease.worktree_path, ["commit", "-m", "candidate module"])
      candidate_commit = git!(lease.worktree_path, ["rev-parse", "HEAD"])
      diff = git!(lease.worktree_path, ["diff", "#{base_commit}..#{candidate_commit}"])
      parent = self()

      review_runner = fn request, _params, context ->
        assert request.candidate_commit == candidate_commit
        assert request.base_ref == base_commit
        assert is_binary(request.review_snapshot_id)

        assert {:ok, read} =
                 ReviewTree.Read.run(
                   %{
                     review_snapshot_id: request.review_snapshot_id,
                     revision: "base",
                     path: "lib/a.ex"
                   },
                   context
                 )

        assert read.content =~ ":base"
        send(parent, {:binding_snapshot, request.review_snapshot_id})

        {:ok,
         %{
           decision: "approved",
           approve_count: 2,
           reject_count: 0,
           abstain_count: 0,
           quorum_met: true,
           average_confidence: 0.9,
           primary_concerns: []
         }}
      end

      params = %{
        diff: diff,
        files: ["lib/a.ex"],
        branch: lease.branch,
        base_ref: base_commit,
        intent: "Change A.value/0",
        agent_id: principal_id,
        workspace_id: lease.workspace_id,
        commit_hash: candidate_commit
      }

      assert {:ok, result} =
               Council.ReviewChange.run(params, %{
                 review_runner: review_runner,
                 persist_verdict: false,
                 task_id: task_id,
                 agent_id: principal_id
               })

      assert result.recommendation == "keep"
      assert_receive {:binding_snapshot, snapshot_id}

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(snapshot_id, authority_context)
    end

    test "security regression: top-level params override request maps without accepting snapshot ids" do
      params = %{
        request: Map.put(@valid_review_params, :review_snapshot_id, "review_snap_forged"),
        branch: "agent/override"
      }

      assert {:ok, request} = Council.build_code_review_request(params)
      assert request.branch == "agent/override"
      assert request.review_snapshot_id == nil
    end

    test "successful outputs are JSON-clean on keep, revise, reject, and human routes" do
      routes = [
        {"keep", @valid_review_params,
         %{decision: "approved", approve_count: 3, reject_count: 0, abstain_count: 0}},
        {"revise", @valid_review_params,
         %{decision: "deadlock", approve_count: 1, reject_count: 1, abstain_count: 1}},
        {"reject", @valid_review_params,
         %{decision: "rejected", approve_count: 0, reject_count: 3, abstain_count: 0}},
        {"human", %{@valid_review_params | files: ["apps/arbor_security/lib/arbor/security.ex"]},
         %{decision: "approved", approve_count: 3, reject_count: 0, abstain_count: 0}}
      ]

      for {_route, params, decision} <- routes do
        assert {:ok, result} =
                 Council.ReviewChange.run(params, %{
                   review_runner: fn _, _, _ -> {:ok, decision} end,
                   persist_verdict: false
                 })

        assert {:ok, json} = Jason.encode(result)
        assert Jason.decode!(json)["feedback"] == Jason.decode!(result.feedback_json)
        assert is_binary(result.recommendation)
        assert is_binary(result.tier_decision)
        assert is_map(result.verdict)
        assert is_map(result.persistence)
      end
    end

    test "feedback bounds text and list fields" do
      concerns = List.duplicate(String.duplicate("w", 1_500), 25)

      assert {:ok, result} =
               Council.ReviewChange.run(@valid_review_params, %{
                 review_runner: fn _, _, _ ->
                   {:ok,
                    %{
                      decision: "rejected",
                      reject_count: 1,
                      primary_concerns: concerns
                    }}
                 end,
                 persist_verdict: false
               })

      assert length(result.feedback["verdict"]["weaknesses"]) == 20
      assert Enum.all?(result.feedback["verdict"]["weaknesses"], &(String.length(&1) <= 1_000))
    end
  end

  describe "normalize_perspective/1" do
    test "passes through atoms unchanged" do
      assert Council.normalize_perspective(:security) == :security
      assert Council.normalize_perspective(:brainstorming) == :brainstorming
    end

    test "converts valid string perspectives to atoms" do
      assert Council.normalize_perspective("security") == :security
      assert Council.normalize_perspective("stability") == :stability
    end

    test "rejects invalid string perspectives" do
      assert {:error, {:invalid_perspective, "invalid", _allowed}} =
               Council.normalize_perspective("invalid")
    end

    test "rejects non-string/non-atom input" do
      assert {:error, {:invalid_perspective_type, 123}} =
               Council.normalize_perspective(123)
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      assert Code.ensure_loaded?(Council.Consult)
      assert Code.ensure_loaded?(Council.ConsultOne)
      assert Code.ensure_loaded?(Council.ReviewChange)

      assert function_exported?(Council.Consult, :run, 2)
      assert function_exported?(Council.ConsultOne, :run, 2)
      assert function_exported?(Council.ReviewChange, :run, 2)
      assert function_exported?(Council.Consult, :taint_roles, 0)
      assert function_exported?(Council.ConsultOne, :taint_roles, 0)
      assert function_exported?(Council.ReviewChange, :taint_roles, 0)
    end
  end

  describe "action registration" do
    test "actions are registered in list_actions/0" do
      actions = Arbor.Actions.list_actions()
      assert :council in Map.keys(actions)
      assert Council.Consult in actions[:council]
      assert Council.ConsultOne in actions[:council]
      assert Council.ReviewChange in actions[:council]
    end

    test "actions appear in all_actions/0" do
      all = Arbor.Actions.all_actions()
      assert Council.Consult in all
      assert Council.ConsultOne in all
      assert Council.ReviewChange in all
    end
  end

  # Integration tests with mocked Consult API
  # These would make real LLM calls - skip by default
  describe "Consult integration" do
    @describetag :llm

    @tag :skip
    test "consults all perspectives with real provider" do
      # This would make real API calls across multiple providers
      assert {:ok, result} =
               Council.Consult.run(
                 %{
                   question: "Should we use Redis or ETS?",
                   context: %{constraints: "must survive restarts"}
                 },
                 %{}
               )

      assert is_list(result.responses)
      assert result.perspective_count == 12
      assert result.response_count > 0
      assert is_integer(result.duration_ms)
    end
  end

  defp write_review_decide_fixture! do
    path =
      Path.join(
        System.tmp_dir!(),
        "review-decide-fixture-#{System.unique_integer([:positive])}.dot"
      )

    File.write!(path, """
    digraph review_decide_fixture {
      start [type="start"]

      done [type="exit"]

      start -> done
    }
    """)

    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  describe "ConsultOne integration" do
    @describetag :llm

    @tag :skip
    test "consults single perspective with real provider" do
      # This would make a real API call
      assert {:ok, result} =
               Council.ConsultOne.run(
                 %{
                   question: "Is this caching approach secure?",
                   perspective: :security,
                   context: %{code: "defmodule Cache do ... end"}
                 },
                 %{}
               )

      assert result.perspective == :security
      assert is_map(result.evaluation)
      assert is_binary(result.reasoning)
      assert is_integer(result.duration_ms)
    end
  end
end
