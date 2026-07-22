defmodule Arbor.Orchestrator.CodingPlan.CandidateVerifierTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.CodingPlan.CandidateVerifierTest.{ExplodingExecutor, FakeExecutor}
  alias Arbor.Orchestrator.CodingPlan.{Profiles, ValidationProgram}
  alias Arbor.Orchestrator.Config

  @moduletag :fast

  @agent_id "agent_candidate_verifier"
  @caller_id "human_candidate_reviewer"
  @task_id "task-candidate-verification"
  @workspace_id "workspace-candidate-verification"
  @attestation_id "review-attestation-001"
  @worktree "/tmp/arbor-candidate-worktree"
  @observed_at "2026-07-22T14:30:00Z"
  @sha1 String.duplicate("a", 40)
  @sha256 String.duplicate("b", 64)
  @head String.duplicate("c", 40)
  @digest String.duplicate("d", 64)
  @other_digest String.duplicate("e", 64)

  setup do
    previous = Application.get_env(:arbor_orchestrator, :coding_candidate_actions_executor)
    Application.put_env(:arbor_orchestrator, :coding_candidate_actions_executor, FakeExecutor)
    Process.put(:candidate_verifier_calls, [])
    Process.put(:candidate_verifier_responses, [])

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_orchestrator, :coding_candidate_actions_executor)
      else
        Application.put_env(
          :arbor_orchestrator,
          :coding_candidate_actions_executor,
          previous
        )
      end
    end)

    :ok
  end

  test "executes exact closed inspection and validation calls for every profile" do
    authority = authority!()

    assert Config.coding_candidate_actions_executor() == FakeExecutor
    assert Code.ensure_loaded?(FakeExecutor)
    assert function_exported?(FakeExecutor, :execute_structured, 4)

    for profile_id <- ~w[default cross_app security_regression] do
      Process.put(:candidate_verifier_calls, [])
      program = program!(profile_id)
      set_responses([{:ok, inspection()}, {:ok, %{"raw_secret" => "must-not-return"}}])

      assert {:ok, report} =
               Arbor.Orchestrator.verify_coding_candidate(
                 candidate(program),
                 valid_opts(authority)
               )

      assert report["status"] == "blocked"
      assert report["profile"] == profile_id
      assert report["candidate_ref"] == "git-tree:" <> @sha1
      refute Map.has_key?(report, "raw_secret")

      approval_timeout_ms =
        Config.coding_approval_timeout_ms(program["static_parameters"]["timeout"])

      expected_auth_opts = [
        agent_id: @agent_id,
        caller_id: @caller_id,
        task_id: @task_id,
        signing_authority: authority,
        approval_timeout_ms: approval_timeout_ms
      ]

      assert calls() == [
               {
                 "coding_workspace_inspect",
                 %{
                   "workspace_id" => @workspace_id,
                   "include_committable_tree" => true
                 },
                 Path.expand(System.tmp_dir!()),
                 expected_auth_opts
               },
               {
                 program["action"],
                 expected_validator_params(program),
                 @worktree,
                 expected_auth_opts
               }
             ]
    end
  end

  test "owner-observed pre-validation tree reaches the core and drift blocks the report" do
    set_responses([{:ok, inspection()}, {:ok, default_result(@sha256)}])

    assert {:ok, report} =
             Arbor.Orchestrator.verify_coding_candidate(
               candidate(program!("default")),
               valid_opts(authority!())
             )

    assert report["status"] == "blocked"
    assert report["candidate_ref"] == "git-tree:" <> @sha1

    assert Enum.all?(
             report["diagnostics"],
             &(&1["code"] == "candidate_state_drifted" and &1["decision"] == "blocked")
           )
  end

  test "security attestation is required only for the security regression profile" do
    security = candidate(program!("security_regression"))
    default = candidate(program!("default"))
    cross_app = candidate(program!("cross_app"))

    assert {:error, :review_attestation_required} =
             Arbor.Orchestrator.verify_coding_candidate(
               Map.delete(security, "review_attestation_id"),
               valid_opts(authority!())
             )

    for non_security <- [default, cross_app] do
      assert {:error, :review_attestation_forbidden} =
               Arbor.Orchestrator.verify_coding_candidate(
                 Map.put(non_security, "review_attestation_id", @attestation_id),
                 valid_opts(authority!())
               )
    end

    assert calls() == []
  end

  test "malformed candidates, options, authorities, and principal mismatches fail before execution" do
    program = program!("default")
    valid_candidate = candidate(program)
    authority = authority!()

    cases = [
      {nil, valid_opts(authority), :invalid_candidate},
      {%{"workspace_id" => @workspace_id, validation_program: program}, valid_opts(authority),
       :invalid_candidate},
      {Map.put(valid_candidate, "workspace_id", ""), valid_opts(authority),
       :invalid_workspace_id},
      {Map.put(valid_candidate, "workspace_id", String.duplicate("x", 257)),
       valid_opts(authority), :invalid_workspace_id},
      {valid_candidate, [], :invalid_agent_id},
      {valid_candidate, [:malformed], :invalid_options},
      {valid_candidate, [{:agent_id, @agent_id}, :malformed], :invalid_options},
      {valid_candidate, [{:agent_id, @agent_id} | :improper_tail], :invalid_options},
      {valid_candidate, [agent_id: @agent_id, agent_id: @agent_id], :invalid_options},
      {valid_candidate, valid_opts(authority) ++ [unknown: true], :invalid_options},
      {valid_candidate, Keyword.put(valid_opts(authority), :agent_id, ""), :invalid_agent_id},
      {valid_candidate, Keyword.put(valid_opts(authority), :task_id, " "), :invalid_task_id},
      {valid_candidate, Keyword.put(valid_opts(authority), :caller_id, <<0>>),
       :invalid_caller_id},
      {valid_candidate, Keyword.put(valid_opts(authority), :signing_authority, nil),
       :invalid_signing_authority},
      {valid_candidate, Keyword.put(valid_opts(authority), :observed_at, "not-a-timestamp"),
       :invalid_observed_at},
      {valid_candidate, valid_opts(authority!("agent_someone_else")),
       :signing_authority_principal_mismatch}
    ]

    for {candidate, opts, expected_error} <- cases do
      assert Arbor.Orchestrator.verify_coding_candidate(candidate, opts) ==
               {:error, expected_error}
    end

    assert calls() == []
  end

  test "inspection errors, stale workspaces, and malformed owner evidence fail closed" do
    malformed_inspections = [
      {:error, "credential=must-not-leak"},
      {:ok, Map.delete(inspection(), :committable_tree_oid)},
      {:ok, %{inspection() | exists: false}},
      {:ok, %{inspection() | workspace_id: "workspace-other"}},
      {:ok, Map.delete(inspection(), :workspace_id)},
      {:ok, Map.put(inspection(), "exists", true)},
      :unexpected_executor_result,
      fn _action, _params, _workdir, _opts -> raise "authority secret must not leak" end
    ]

    for response <- malformed_inspections do
      Process.put(:candidate_verifier_calls, [])
      set_responses([response])

      result =
        Arbor.Orchestrator.verify_coding_candidate(
          candidate(program!("default")),
          valid_opts(authority!())
        )

      assert result == {:error, :workspace_inspection_failed}
      refute inspect(result) =~ "must-not-leak"
    end
  end

  test "validator action failures are stable and successful malformed output is only a blocked report" do
    failures = [
      {:error, "validator credential must-not-leak"},
      :unexpected_executor_result,
      fn _action, _params, _workdir, _opts -> raise "validator authority must-not-leak" end
    ]

    for failure <- failures do
      Process.put(:candidate_verifier_calls, [])
      set_responses([{:ok, inspection()}, failure])

      assert Arbor.Orchestrator.verify_coding_candidate(
               candidate(program!("default")),
               valid_opts(authority!())
             ) == {:error, :validator_execution_failed}
    end

    set_responses([{:ok, inspection()}, {:ok, %{"raw_secret" => "must-not-return"}}])

    assert {:ok, report} =
             Arbor.Orchestrator.verify_coding_candidate(
               candidate(program!("default")),
               valid_opts(authority!())
             )

    assert report["status"] == "blocked"
    assert Enum.all?(report["diagnostics"], &(&1["code"] == "validation_evidence_invalid"))
    refute inspect(report) =~ "must-not-return"
  end

  test "security regression: caller path, tree, action, parameters, and executor overrides are impossible" do
    program = program!("default")
    valid_candidate = candidate(program)
    authority = authority!()

    candidate_overrides = [
      Map.put(valid_candidate, "path", "/caller/path"),
      Map.put(valid_candidate, "committable_tree_oid", @sha256),
      Map.put(valid_candidate, "action", "shell_execute"),
      Map.put(valid_candidate, "static_parameters", %{"timeout" => 999_999}),
      Map.put(valid_candidate, "executor_module", ExplodingExecutor),
      put_in(valid_candidate, ["validation_program", "action"], "shell_execute"),
      put_in(valid_candidate, ["validation_program", "static_parameters", "path"], "/caller/path")
    ]

    for override <- candidate_overrides do
      assert {:error, :invalid_candidate} =
               Arbor.Orchestrator.verify_coding_candidate(override, valid_opts(authority))
    end

    for key <- [:path, :tree_oid, :action, :static_parameters, :actions_executor] do
      assert {:error, :invalid_options} =
               Arbor.Orchestrator.verify_coding_candidate(
                 valid_candidate,
                 valid_opts(authority) ++ [{key, ExplodingExecutor}]
               )
    end

    assert calls() == []
  end

  test "configured executor seam validates the code-owned module and cannot be input-selected" do
    Application.put_env(:arbor_orchestrator, :coding_candidate_actions_executor, String)

    assert {:error, :candidate_verification_unavailable} =
             Arbor.Orchestrator.verify_coding_candidate(
               candidate(program!("default")),
               valid_opts(authority!())
             )

    assert {:error, :invalid_options} =
             Arbor.Orchestrator.verify_coding_candidate(
               candidate(program!("default")),
               valid_opts(authority!()) ++ [coding_candidate_actions_executor: FakeExecutor]
             )

    assert calls() == []
  end

  defp candidate(program) do
    %{
      "validation_program" => program,
      "workspace_id" => @workspace_id
    }
    |> maybe_put_attestation(program["profile_id"])
  end

  defp maybe_put_attestation(candidate, "security_regression"),
    do: Map.put(candidate, "review_attestation_id", @attestation_id)

  defp maybe_put_attestation(candidate, _profile_id), do: candidate

  defp valid_opts(authority) do
    [
      agent_id: @agent_id,
      caller_id: @caller_id,
      task_id: @task_id,
      signing_authority: authority,
      observed_at: @observed_at
    ]
  end

  defp authority!(principal_id \\ @agent_id) do
    {:ok, authority} =
      SigningAuthority.new(
        token: String.duplicate("authority-token", 2),
        principal_id: principal_id,
        purpose: :candidate_verification_test
      )

    authority
  end

  defp program!(profile_id) do
    {:ok, profile} = Profiles.fetch_executable(profile_id)

    {:ok, program} =
      ValidationProgram.build(profile["validation_strategy"], %{"wall_clock_ms" => 120_000})

    program
  end

  defp inspection do
    %{
      exists: true,
      workspace_id: @workspace_id,
      committable_tree_oid: @sha1,
      worktree_path: @worktree
    }
  end

  defp expected_validator_params(program) do
    bound =
      case program["profile_id"] do
        "default" -> %{"path" => @worktree, "workspace_id" => @workspace_id}
        "cross_app" -> %{"workspace_id" => @workspace_id}
        "security_regression" -> %{"review_attestation_id" => @attestation_id}
      end

    Map.merge(bound, program["static_parameters"])
  end

  defp default_result(validated_tree_oid) do
    %{
      path: @worktree,
      exit_code: 0,
      passed: true,
      stdout: "compile output",
      stderr: "",
      feedback: %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => "compile output",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => @digest,
        "stderr_sha256" => @other_digest
      },
      feedback_json: "ignored feedback json",
      validated_tree_oid: validated_tree_oid,
      validated_head: @head
    }
  end

  defp set_responses(responses), do: Process.put(:candidate_verifier_responses, responses)
  defp calls, do: Process.get(:candidate_verifier_calls, [])

  defmodule FakeExecutor do
    def execute_structured(action, params, workdir, opts) do
      call = {action, params, workdir, opts}
      calls = Process.get(:candidate_verifier_calls, [])
      Process.put(:candidate_verifier_calls, calls ++ [call])

      case Process.get(:candidate_verifier_responses, []) do
        [response | rest] ->
          Process.put(:candidate_verifier_responses, rest)

          if is_function(response, 4),
            do: response.(action, params, workdir, opts),
            else: response

        [] ->
          {:error, "unexpected fake executor call"}
      end
    end
  end

  defmodule ExplodingExecutor do
    def execute_structured(_action, _params, _workdir, _opts) do
      raise "caller-selected executor ran"
    end
  end
end
