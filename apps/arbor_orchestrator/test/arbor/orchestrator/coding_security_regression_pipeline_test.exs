defmodule Arbor.Orchestrator.CodingSecurityRegressionPipelineTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, Compiler}

  @moduletag :fast
  @moduletag :coding_change_pipeline

  @action_modules [
    Arbor.Actions.Acp.StartSession,
    Arbor.Actions.Acp.SendMessage,
    Arbor.Actions.Acp.CloseSession,
    Arbor.Actions.Coding.SecurityRegression.Validate,
    Arbor.Actions.Coding.Workspace.Acquire,
    Arbor.Actions.Coding.Workspace.Inspect,
    Arbor.Actions.Coding.Workspace.Release,
    Arbor.Actions.Coding.Workspace.CommittedChange,
    Arbor.Actions.Git.Commit,
    Arbor.Actions.Git.PR,
    Arbor.Actions.Council.ReviewChange,
    Arbor.Actions.Consensus.Decide
  ]

  defmodule FakeActionsExecutor do
    @moduledoc false

    def execute(name, args, _workdir, _opts) do
      state = Process.get(:coding_security_pipeline_state)
      args = stringify_keys(args)

      Agent.update(state, fn current ->
        %{current | calls: current.calls ++ [{name, args}]}
      end)

      scenario = Agent.get(state, & &1.scenario)

      case dispatch(name, args, scenario, state) do
        {:ok, result} when is_map(result) -> {:ok, Jason.encode!(result)}
        other -> other
      end
    end

    defp dispatch("coding_workspace_acquire", args, _scenario, _state) do
      {:ok,
       %{
         workspace_id: "ws_security_fixture",
         repo_path: args["repo_path"],
         worktree_path: "/tmp/ws_security_fixture",
         branch: "arbor/security-fixture",
         base_commit: "base-commit",
         ownership: "owned",
         active: true
       }}
    end

    defp dispatch("acp_start_session", _args, _scenario, _state) do
      {:ok,
       %{
         worker_session_id: "worker-security-fixture",
         session_id: "session-security-fixture",
         provider: "codex",
         model: "default",
         status: "ready",
         pooled: false
       }}
    end

    defp dispatch("acp_send_message", _args, _scenario, state) do
      bump(state, :implement)

      {:ok,
       %{
         text: Jason.encode!(%{status: "implemented", summary: "fixture edit"}),
         stop_reason: "end_turn",
         session_id: "session-security-fixture",
         usage: %{}
       }}
    end

    defp dispatch("coding_workspace_inspect", _args, scenario, state) do
      inspect_index = bump(state, :inspect)

      {dirty, head_commit} =
        case {scenario, inspect_index} do
          {scenario, 2}
          when scenario in [:validation_rework_self_commit, :review_rework_self_commit] ->
            {false, "commit-2"}

          {scenario, 2}
          when scenario in [:validation_rework_noop, :review_rework_noop] ->
            {false, "commit-1"}

          _other ->
            {true, if(inspect_index == 1, do: "base-commit", else: "commit-1")}
        end

      {:ok,
       %{
         workspace_id: "ws_security_fixture",
         worktree_path: "/tmp/ws_security_fixture",
         branch: "arbor/security-fixture",
         base_commit: "base-commit",
         ownership: "owned",
         active: true,
         exists: true,
         dirty: dirty,
         head_commit: head_commit,
         changed_from_base: true
       }}
    end

    defp dispatch("git_commit", _args, _scenario, state) do
      commit_index = bump(state, :commit)

      {:ok,
       %{
         path: "/tmp/ws_security_fixture",
         commit_hash: "commit-#{commit_index}",
         message: "Coding agent change",
         output: "committed"
       }}
    end

    defp dispatch("coding_workspace_committed_change", args, scenario, state) do
      material_index = bump(state, :material)

      if scenario == :post_validation_changed_head and material_index == 2 do
        {:error, "reviewed material changed"}
      else
        commit = args["commit"]

        {:ok,
         %{
           workspace_id: "ws_security_fixture",
           commit_hash: commit,
           diff: "diff for #{commit}",
           files: ["test/security_regression_test.exs", "lib/security.ex"],
           base_ref: "base-commit",
           branch: "arbor/security-fixture",
           worktree_path: "/tmp/ws_security_fixture"
         }}
      end
    end

    defp dispatch("council_review_change", _args, scenario, state) do
      review_index = bump(state, :review)

      tier =
        cond do
          scenario == :human_success ->
            "human_review"

          scenario in [:review_rework_dirty, :review_rework_self_commit, :review_rework_noop] and
              review_index == 1 ->
            "rework"

          true ->
            "auto_proceed"
        end

      result = review_payload(tier)

      if tier in ["auto_proceed", "human_review"] do
        {:ok, Map.put(result, :review_attestation_id, "attestation-#{review_index}")}
      else
        {:ok, result}
      end
    end

    defp dispatch("coding_security_regression_validate", _args, scenario, state) do
      validation_index = bump(state, :validation)

      passed =
        not (scenario in [
               :validation_rework_dirty,
               :validation_rework_self_commit,
               :validation_rework_noop
             ] and validation_index == 1)

      {:ok,
       %{
         passed: passed,
         reason: if(passed, do: "security_regression_validated", else: "candidate_tests_failed"),
         evidence_type: "reviewed_regression_evidence"
       }}
    end

    defp dispatch("acp_close_session", _args, _scenario, _state) do
      {:ok, %{worker_session_id: "worker-security-fixture", status: "closed"}}
    end

    defp dispatch("coding_workspace_release", args, _scenario, _state) do
      {:ok,
       %{
         workspace_id: "ws_security_fixture",
         status: "retained",
         mode: args["mode"],
         active: false
       }}
    end

    defp dispatch("git_pr", _args, _scenario, _state) do
      {:ok, %{url: "https://example.test/pr/1", number: 1, draft: true}}
    end

    defp dispatch(name, _args, _scenario, _state), do: {:error, "unexpected action: #{name}"}

    defp review_payload(tier) do
      feedback = %{
        "recommendation" => if(tier == "rework", do: "revise", else: "keep"),
        "tier" => %{"decision" => tier},
        "verdict" => %{"weaknesses" => []}
      }

      %{
        status: "reviewed",
        tier_decision: tier,
        recommendation: if(tier == "rework", do: "revise", else: "keep"),
        decision: "approved",
        approve_count: 1,
        reject_count: 0,
        abstain_count: 0,
        quorum_met: true,
        human_required: tier == "human_review",
        security_veto: false,
        authority_widening: false,
        blast_radius: "low",
        tier_reasons: ["fixture"],
        persistence: %{"status" => "recorded"},
        feedback: feedback,
        feedback_json: Jason.encode!(feedback)
      }
    end

    defp bump(state, key) do
      Agent.get_and_update(state, fn current ->
        next = Map.get(current.counters, key, 0) + 1
        {next, %{current | counters: Map.put(current.counters, key, next)}}
      end)
    end

    defp stringify_keys(map) do
      Map.new(map, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)
    end
  end

  setup_all do
    template_path =
      Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot")

    {:ok, action_catalog} = ActionCatalog.snapshot(modules: @action_modules)

    %{
      template_source: File.read!(template_path),
      action_catalog: action_catalog
    }
  end

  test "default plan budget reaches validator only as the opaque default-timeout call", ctx do
    assert {{:ok, result}, calls} = run_fixture(:auto_success, ctx)

    assert result.context["status"] == "change_committed",
           "pipeline stopped without success: #{inspect(current: result.context["current_node"], completed: result.completed_nodes, calls: calls)}"

    assert [{"coding_security_regression_validate", validator_args}] =
             calls_for(calls, "coding_security_regression_validate")

    assert validator_args == %{"review_attestation_id" => "attestation-1"}
    refute Map.has_key?(validator_args, "timeout")

    assert [{"council_review_change", review_args}] =
             calls_for(calls, "council_review_change")

    assert review_args["workspace_id"] == "ws_security_fixture"
    assert review_args["validation_profile"] == "security_regression"

    assert review_args["test_paths"] == [
             "apps/arbor_security/test/a_security_test.exs",
             "apps/arbor_security/test/z_security_test.exs"
           ]

    assert [first_material, final_material] =
             Enum.map(calls_for(calls, "coding_workspace_committed_change"), &elem(&1, 1))

    assert first_material["commit"] == "commit-1"
    assert final_material["commit"] == "commit-1"
    assert "post_validation_committed_change" in result.completed_nodes
  end

  test "eligible human review validates and rechecks before the human terminal", ctx do
    assert {{:ok, result}, calls} = run_fixture(:human_success, ctx, "human_required")
    assert result.context["status"] == "human_review_required"
    assert called?(calls, "coding_security_regression_validate")
    assert called?(calls, "coding_workspace_committed_change", 2)
    assert "post_validation_committed_change" in result.completed_nodes
  end

  for {scenario, source} <- [
        {:validation_rework_dirty, :validation},
        {:review_rework_dirty, :review}
      ] do
    test "#{source} rework with dirty changes creates a fresh commit, review, and token", ctx do
      assert {{:ok, result}, calls} = run_fixture(unquote(scenario), ctx)
      assert result.context["status"] == "change_committed"
      assert called?(calls, "git_commit", 2)
      assert called?(calls, "council_review_change", 2)
      assert_single_worker(calls, 2)
      assert "compare_security_rework_commit" in result.completed_nodes
      assert "check_security_rework_fresh" in result.completed_nodes

      reviews = calls_for(calls, "council_review_change")

      assert Enum.map(reviews, fn {_name, args} -> args["diff"] end) == [
               "diff for commit-1",
               "diff for commit-2"
             ]

      validator_ids =
        calls
        |> calls_for("coding_security_regression_validate")
        |> Enum.map(fn {_name, args} -> args["review_attestation_id"] end)

      if unquote(source) == :validation do
        assert validator_ids == ["attestation-1", "attestation-2"]
      else
        assert validator_ids == ["attestation-2"]
      end
    end
  end

  for scenario <- [:validation_rework_self_commit, :review_rework_self_commit] do
    test "#{scenario} accepts a clean self-committed fresh HEAD", ctx do
      assert {{:ok, result}, calls} = run_fixture(unquote(scenario), ctx)
      assert result.context["status"] == "change_committed"
      assert called?(calls, "git_commit", 1)
      assert called?(calls, "council_review_change", 2)
      assert_single_worker(calls, 2)
      assert result.context["prior_reviewed_commit"] == "commit-1"
      assert result.context["commit_hash"] == "commit-2"
      assert result.context["fresh_rework_commit"] == true
    end
  end

  for scenario <- [:validation_rework_noop, :review_rework_noop] do
    test "#{scenario} rejects the same reviewed HEAD before another Council token", ctx do
      assert {{:ok, result}, calls} = run_fixture(unquote(scenario), ctx)
      assert result.context["status"] == "validation_failed"
      assert result.context["prior_reviewed_commit"] == "commit-1"
      assert result.context["commit_hash"] == "commit-1"
      assert result.context["fresh_rework_commit"] == false
      assert called?(calls, "council_review_change", 1)
      assert_single_worker(calls, 2)
      assert "error_security_rework_not_fresh" in result.completed_nodes
    end
  end

  test "changed HEAD after validation fails closed before publication", ctx do
    assert {{:ok, result}, calls} = run_fixture(:post_validation_changed_head, ctx)
    assert result.context["status"] == "validation_failed"
    assert called?(calls, "coding_security_regression_validate", 1)
    assert called?(calls, "coding_workspace_committed_change", 2)
    assert "error_post_validation_committed_change" in result.completed_nodes
    refute "status_change_committed" in result.completed_nodes
  end

  defp run_fixture(scenario, ctx, review_profile \\ "binding") do
    {:ok, state} = Agent.start_link(fn -> %{scenario: scenario, calls: [], counters: %{}} end)
    Process.put(:coding_security_pipeline_state, state)

    on_exit(fn ->
      Process.delete(:coding_security_pipeline_state)
      if Process.alive?(state), do: Agent.stop(state)
    end)

    {:ok, plan} =
      Plan.new(%{
        "task" => "Prove a reviewed security regression",
        "repo_root" => "/tmp/security-profile-repo",
        "worker" => %{"provider" => "codex"},
        "validation_profile" => "security_regression",
        "review_profile" => review_profile,
        "requested_paths" => [
          "apps/arbor_security/test/z_security_test.exs",
          "apps/arbor_security/test/a_security_test.exs"
        ]
      })

    assert plan.budgets["wall_clock_ms"] == 900_000

    assert {:ok, compilation} =
             Compiler.compile(plan,
               template_source: ctx.template_source,
               action_catalog: ctx.action_catalog
             )

    initial_values =
      Map.merge(compilation.initial_values, %{
        "session.agent_id" => "agent-security-fixture",
        "session.task_id" => "task-security-fixture"
      })

    result =
      Arbor.Orchestrator.run(compilation.dot_source,
        authorization: false,
        actions_executor: FakeActionsExecutor,
        initial_values: initial_values,
        max_steps: 300,
        sleep_fn: fn _milliseconds -> :ok end
      )

    calls = Agent.get(state, & &1.calls)
    {result, calls}
  end

  defp calls_for(calls, action), do: Enum.filter(calls, fn {name, _args} -> name == action end)

  defp called?(calls, action, count \\ nil) do
    actual = length(calls_for(calls, action))
    if is_nil(count), do: actual > 0, else: actual == count
  end

  defp assert_single_worker(calls, send_count) do
    assert called?(calls, "acp_start_session", 1)
    assert called?(calls, "acp_send_message", send_count)

    assert Enum.all?(calls_for(calls, "acp_send_message"), fn {_name, args} ->
             args["worker_session_id"] == "worker-security-fixture"
           end)
  end
end
