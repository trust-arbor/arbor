defmodule Arbor.Commands.CodingTaskOutcomeTerminalCanaryTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Contracts.Coding.{TaskOutcome, TaskTerminalEnvelope}
  alias Arbor.Orchestrator.CodingPlan.ArtifactStore
  alias Arbor.Orchestrator.CodingTaskExecutor

  @agent_id "agent_outcome_canary"
  @caller_id "operator_outcome_canary"

  defmodule CanaryExecutor do
    @moduledoc false

    def run(agent_id, task, context) do
      task_id = Map.fetch!(context, "task_id")
      notify({:canary_runner_started, task_id, self(), agent_id, task, context})

      case canary_result(task_id) do
        :block ->
          receive do
            {:finish, result} -> result
          after
            10_000 -> {:error, :canary_runner_timeout}
          end

        result ->
          result
      end
    end

    def finalize_task(agent_id, result, controls, context) do
      reply = CodingTaskExecutor.finalize_task(agent_id, result, controls, context)
      notify({:canary_finalize_task_reply, context["task_id"], reply})
      reply
    end

    def finalize_terminal_task(agent_id, terminal_envelope, controls, context) do
      reply =
        CodingTaskExecutor.finalize_terminal_task(
          agent_id,
          terminal_envelope,
          controls,
          context
        )

      notify({:canary_finalize_terminal_reply, context["task_id"], reply})
      reply
    end

    def adopt_task(agent_id, result, request, context) do
      reply = CodingTaskExecutor.adopt_task(agent_id, result, request, context)
      notify({:canary_adopt_task_reply, context["task_id"], self(), reply})
      reply
    end

    defp canary_result(task_id) do
      :arbor_orchestrator
      |> Application.fetch_env!(:coding_outcome_canary_results)
      |> Map.fetch!(task_id)
    end

    defp notify(message) do
      case Application.get_env(:arbor_orchestrator, :coding_outcome_canary_observer) do
        observer when is_pid(observer) -> send(observer, message)
        _ -> :ok
      end
    end
  end

  defmodule CleanupProbe do
    @moduledoc false

    def cleanup(task_id, opts) do
      root = Application.fetch_env!(:arbor_orchestrator, :coding_pipeline_logs_root)
      path = Path.join(task_root(root, task_id), "coding-task-terminal.json")

      case Application.get_env(:arbor_orchestrator, :coding_outcome_canary_observer) do
        observer when is_pid(observer) ->
          send(observer, {:canary_cleanup, task_id, opts[:cleanup_reason], File.regular?(path)})

        _ ->
          :ok
      end

      :ok
    end

    defp task_root(root, task_id) do
      digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
      Path.join(root, "task-" <> digest)
    end
  end

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    supervisor = Module.concat(__MODULE__, :"TaskSupervisor#{unique}")
    store = Module.concat(__MODULE__, :"TaskStore#{unique}")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "coding-outcome-terminal-canary-#{unique}"
      )

    File.mkdir_p!(tmp_dir)
    {:ok, tmp_dir} = Arbor.Common.SafePath.resolve_real(tmp_dir)
    logs_root = Path.join(tmp_dir, "artifacts")
    File.mkdir_p!(logs_root)

    originals = %{
      agent_executors: Application.get_env(:arbor_agent, :task_executors),
      artifact_store: Application.get_env(:arbor_orchestrator, :coding_plan_artifact_store),
      logs_root: Application.get_env(:arbor_orchestrator, :coding_pipeline_logs_root),
      observer: Application.get_env(:arbor_orchestrator, :coding_outcome_canary_observer),
      results: Application.get_env(:arbor_orchestrator, :coding_outcome_canary_results)
    }

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => CanaryExecutor
    })

    Application.put_env(:arbor_orchestrator, :coding_plan_artifact_store, ArtifactStore)
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, logs_root)
    Application.put_env(:arbor_orchestrator, :coding_outcome_canary_observer, self())
    Application.put_env(:arbor_orchestrator, :coding_outcome_canary_results, %{})

    start_supervised!({Task.Supervisor, name: supervisor})

    start_supervised!(
      {TaskStore,
       [
         name: store,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         approval_cleanup_mfa: {CleanupProbe, :cleanup, 2},
         cancel_turn: fn _agent_id, _task_id -> :ok end,
         executor_callback_timeout_ms: 1_000
       ]},
      id: store
    )

    on_exit(fn ->
      restore_env(:arbor_agent, :task_executors, originals.agent_executors)

      restore_env(
        :arbor_orchestrator,
        :coding_plan_artifact_store,
        originals.artifact_store
      )

      restore_env(:arbor_orchestrator, :coding_pipeline_logs_root, originals.logs_root)
      restore_env(:arbor_orchestrator, :coding_outcome_canary_observer, originals.observer)
      restore_env(:arbor_orchestrator, :coding_outcome_canary_results, originals.results)
      File.rm_rf(tmp_dir)
    end)

    {:ok, store: store, logs_root: logs_root, tmp_dir: tmp_dir}
  end

  test "terminal canary preserves every retry class across status, result, and archive", %{
    store: store,
    logs_root: logs_root
  } do
    cases = [
      %{
        task_id: "task_canary_review_rejected",
        code: "review_rejected",
        runner_result: :terminal,
        disposition: "rejected",
        phase: "review",
        origin: "reviewer",
        retry: "none",
        state: :done
      },
      %{
        task_id: "task_canary_validation_failed",
        code: "validation_failed",
        runner_result: :terminal,
        disposition: "failed",
        phase: "validation",
        origin: "validator",
        retry: "same_session",
        state: :done
      },
      %{
        task_id: "task_canary_provider_exhausted",
        code: "worker_provider_account_exhausted",
        runner_result: :pipeline_failure,
        disposition: "failed",
        phase: "worker_turn",
        origin: "provider",
        retry: "new_session",
        state: :failed
      },
      %{
        task_id: "task_canary_transport_failure",
        code: "worker_recovery_send_failed",
        runner_result: :pipeline_failure,
        disposition: "failed",
        phase: "worker_turn",
        origin: "acp_transport",
        retry: "new_session",
        state: :failed
      },
      %{
        task_id: "task_canary_workspace_missing",
        code: "workspace_missing",
        runner_result: :pipeline_failure,
        disposition: "failed",
        phase: "workspace",
        origin: "arbor",
        retry: "after_external_change",
        state: :failed
      },
      %{
        task_id: "task_canary_cleanup_uncertain",
        code: "worker_stale_close_failed",
        runner_result: :pipeline_failure,
        disposition: "failed",
        phase: "cleanup",
        origin: "acp_transport",
        retry: "new_session",
        state: :failed
      }
    ]

    for canary <- cases do
      outcome = registered_outcome(canary.code)
      prepare_compilation_artifacts(logs_root, canary.task_id)

      runner_result =
        case canary.runner_result do
          :terminal ->
            {:ok, terminal_result(logs_root, canary.task_id, canary.code)}

          :pipeline_failure ->
            {:error,
             {:pipeline_error,
              %{
                "status" => "pipeline_error",
                "error" => canary.code,
                "outcome" => outcome
              }}}
        end

      dispatch_canary(store, canary.task_id, runner_result)

      assert_receive {:canary_runner_started, task_id, _pid, @agent_id, _task, context},
                     1_000

      assert task_id == canary.task_id
      assert context["task_id"] == canary.task_id

      status = await_terminal_status(store, canary.task_id)

      if canary.runner_result == :terminal do
        assert_receive {:canary_finalize_task_reply, ^task_id, {:ok, _finalized}}, 1_000
      end

      assert_receive {:canary_finalize_terminal_reply, ^task_id, :ok}, 1_000
      assert status.state == canary.state
      assert_outcome_identity(status.outcome, canary)
      assert status.outcome == outcome

      assert {:ok, result} = Orchestration.task_result(canary.task_id, facade_opts(store))
      assert result_outcome(result) == status.outcome
      assert_outcome_identity(result_outcome(result), canary)

      archive = read_task_terminal_archive(logs_root, canary.task_id)
      assert archive["task_id"] == canary.task_id
      assert archive["terminal_envelope"]["outcome"] == status.outcome
      assert archive["terminal_envelope"]["terminal_state"] == Atom.to_string(canary.state)
      assert_public_result_matches_archive(result, archive)

      assert_non_adoptable(store, canary.task_id, canary.state)

      assert {:ok, unchanged_result} =
               Orchestration.task_result(canary.task_id, facade_opts(store))

      assert result_outcome(unchanged_result) == status.outcome
      assert read_task_terminal_archive(logs_root, canary.task_id) == archive

      assert Path.wildcard(
               Path.join(task_root(logs_root, canary.task_id), "coding-adoption-evidence-*.json")
             ) == []
    end

    assert Enum.map(cases, & &1.retry) |> MapSet.new() ==
             MapSet.new(~w(none same_session new_session after_external_change))
  end

  test "successful adoption preserves outcome identity and task-bound evidence", %{
    store: store,
    logs_root: logs_root,
    tmp_dir: tmp_dir
  } do
    task_id = "task_canary_success_adoption"
    adoption = prepare_git_adoption_fixture(tmp_dir, task_id)

    prepare_compilation_artifacts(logs_root, task_id)

    result =
      terminal_result(logs_root, task_id, "change_committed")
      |> Map.merge(%{
        "branch" => adoption.branch,
        "branch_provenance" => "created",
        "base_commit" => adoption.base_commit,
        "commit" => adoption.candidate_commit,
        "commit_hash" => adoption.candidate_commit,
        "repo_path" => adoption.repo,
        "workspace_id" => adoption.workspace_id,
        "evidence_ref" => adoption.evidence_ref,
        "published_commit" => adoption.candidate_commit,
        "workspace_release_status" => "removed"
      })

    dispatch_canary(store, task_id, {:ok, result})
    assert_receive {:canary_runner_started, ^task_id, _pid, @agent_id, _task, _context}, 1_000

    status = await_terminal_status(store, task_id)
    assert_receive {:canary_finalize_task_reply, ^task_id, {:ok, _finalized}}, 1_000
    assert_receive {:canary_finalize_terminal_reply, ^task_id, :ok}, 1_000

    expected = %{
      code: "change_committed",
      disposition: "succeeded",
      phase: "commit",
      origin: "arbor",
      retry: "none"
    }

    assert status.state == :done
    assert_outcome_identity(status.outcome, expected)

    assert {:ok, before_adoption} = Orchestration.task_result(task_id, facade_opts(store))
    assert result_outcome(before_adoption) == status.outcome

    terminal_archive_path = task_terminal_archive_path(logs_root, task_id)
    terminal_archive_bytes = File.read!(terminal_archive_path)
    terminal_archive = Jason.decode!(terminal_archive_bytes)
    terminal_result = terminal_archive["terminal_envelope"]["evidence"]["result"]
    task_evidence = get_in(terminal_result, ["artifacts", "task_evidence"])
    task_evidence_body = task_evidence["path"] |> File.read!() |> Jason.decode!()

    assert terminal_archive["task_id"] == task_id
    assert terminal_archive["terminal_envelope"]["outcome"] == status.outcome
    assert task_evidence["task_id"] == task_id
    assert task_evidence_body["task_id"] == task_id
    assert task_evidence_body["outcome"] == status.outcome
    assert task_evidence_body["candidate"]["task_id"] == task_id

    git!(adoption.repo, ["merge", "--ff-only", adoption.branch])

    assert {:ok, adopted} =
             Orchestration.adopt_task_change(
               task_id,
               adoption.destination_ref,
               facade_opts(store)
             )

    assert_receive {:canary_adopt_task_reply, ^task_id, callback_pid, {:ok, _raw_adopted}},
                   1_000

    assert callback_pid != self()
    assert result_outcome(adopted) == status.outcome
    assert get_in(adopted.raw, ["artifacts", "task_evidence"]) == task_evidence
    assert get_in(adopted.raw, ["adoption", "status"]) == "adopted"
    assert get_in(adopted.raw, ["adoption", "candidate_commit"]) == adoption.candidate_commit
    assert get_in(adopted.raw, ["adoption", "destination_ref"]) == adoption.destination_ref
    refute branch_exists?(adoption.repo, adoption.branch)

    assert git!(adoption.repo, ["rev-parse", adoption.destination_ref]) ==
             adoption.candidate_commit

    adoption_descriptor = get_in(adopted.raw, ["artifacts", "adoption_evidence"])
    adoption_body = adoption_descriptor["path"] |> File.read!() |> Jason.decode!()

    assert adoption_descriptor["task_id"] == task_id
    assert adoption_body["task_id"] == task_id
    assert adoption_body["candidate"]["task_id"] == task_id
    assert adoption_body["candidate"]["candidate_commit"] == adoption.candidate_commit
    assert adoption_body["proof"]["candidate_commit"] == adoption.candidate_commit
    assert adoption_body["proof"]["destination_ref"] == adoption.destination_ref

    assert {:ok, adopted_status} = Orchestration.task_status(task_id, facade_opts(store))
    assert adopted_status.outcome == status.outcome

    assert {:ok, adopted_result} = Orchestration.task_result(task_id, facade_opts(store))
    assert result_outcome(adopted_result) == status.outcome
    assert get_in(adopted_result.raw, ["artifacts", "adoption_evidence"]) == adoption_descriptor
    assert File.read!(terminal_archive_path) == terminal_archive_bytes
    assert read_task_terminal_archive(logs_root, task_id) == terminal_archive
  end

  test "operator cancellation wins once, archives before cleanup, and rejects later terminals", %{
    store: store,
    logs_root: logs_root
  } do
    task_id = "task_canary_operator_cancelled"
    prepare_compilation_artifacts(logs_root, task_id)
    dispatch_canary(store, task_id, :block, approval_cleanup?: true)

    assert_receive {:canary_runner_started, ^task_id, runner_pid, @agent_id, _task, _context},
                   1_000

    runner_ref = Process.monitor(runner_pid)

    assert {:ok, cancelled} = Orchestration.cancel_task(task_id, facade_opts(store))
    assert cancelled.state == :cancelled

    expected = %{
      code: "task_cancelled",
      disposition: "cancelled",
      phase: "control",
      origin: "operator",
      retry: "none"
    }

    assert_outcome_identity(cancelled.outcome, expected)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :killed}, 1_000
    assert_receive {:canary_cleanup, ^task_id, :task_cancellation, true}, 1_000

    assert {:ok, status} = Orchestration.task_status(task_id, facade_opts(store))
    assert status.outcome == cancelled.outcome

    assert {:ok, result} = Orchestration.task_result(task_id, facade_opts(store))
    assert result["outcome"] == cancelled.outcome
    assert result["terminal_state"] == "cancelled"

    archive = read_task_terminal_archive(logs_root, task_id)
    assert archive["task_id"] == task_id
    assert archive["terminal_envelope"] == result

    assert {:error, {:not_running, :cancelled}} =
             Orchestration.cancel_task(task_id, facade_opts(store))

    refute_receive {:canary_cleanup, ^task_id, :task_cancellation, _}, 100

    root = task_root(logs_root, task_id)

    assert {:ok, replay_descriptor} =
             ArtifactStore.archive_task_terminal(root, task_id, result, [])

    assert replay_descriptor["outcome_code"] == "task_cancelled"

    {:ok, conflicting} =
      TaskTerminalEnvelope.from_code(
        "task_owner_died",
        "failed",
        %{"kind" => "task_owner_died"}
      )

    assert {:error, :task_terminal_conflict} =
             ArtifactStore.archive_task_terminal(root, task_id, conflicting, [])

    assert read_task_terminal_archive(logs_root, task_id) == archive

    assert {:error, {:task_not_adoptable, :cancelled}} =
             Orchestration.adopt_task_change(task_id, "refs/heads/main", facade_opts(store))
  end

  defp dispatch_canary(store, task_id, runner_result, opts \\ []) do
    results =
      Application.fetch_env!(:arbor_orchestrator, :coding_outcome_canary_results)

    Application.put_env(
      :arbor_orchestrator,
      :coding_outcome_canary_results,
      Map.put(results, task_id, runner_result)
    )

    dispatch_opts = [
      name: store,
      task_id: task_id,
      caller_id: @caller_id
    ]

    dispatch_opts =
      if Keyword.get(opts, :approval_cleanup?, false) do
        Keyword.put(dispatch_opts, :approval_cleanup_descriptor, %{
          caller_id: @caller_id,
          trace_id: "trace_#{task_id}"
        })
      else
        dispatch_opts
      end

    assert {:ok, ^task_id} =
             TaskStore.dispatch(
               @agent_id,
               %{"kind" => "coding_change", "scenario" => task_id},
               dispatch_opts
             )
  end

  defp facade_opts(store) do
    [
      task_store: TaskStore,
      name: store,
      caller_id: @caller_id,
      authorize?: false
    ]
  end

  defp terminal_result(logs_root, task_id, code) do
    %{
      "status" => code,
      "canonical_status" => code,
      "outcome" => registered_outcome(code),
      "artifacts" => compilation_artifacts(logs_root, task_id)
    }
  end

  defp registered_outcome(code) do
    {:ok, outcome} = TaskOutcome.from_code(code)
    TaskOutcome.to_map(outcome)
  end

  defp assert_outcome_identity(outcome, expected) do
    assert outcome["code"] == expected.code
    assert outcome["disposition"] == expected.disposition
    assert outcome["phase"] == expected.phase
    assert outcome["origin"] == expected.origin
    assert outcome["retry"] == expected.retry
  end

  defp result_outcome(%{payload: %{outcome: outcome}}), do: outcome
  defp result_outcome(%{"outcome" => outcome}), do: outcome

  defp assert_public_result_matches_archive(
         result,
         %{
           "terminal_envelope" => %{
             "evidence" => %{"kind" => "executor_result", "result" => archived}
           }
         }
       ) do
    assert result.raw == archived
    :ok
  end

  defp assert_public_result_matches_archive(
         result,
         %{
           "terminal_envelope" => %{
             "evidence" => %{"kind" => "pipeline_failure", "result" => archived}
           }
         }
       ) do
    assert result["evidence"]["result"] == archived
    :ok
  end

  defp assert_non_adoptable(store, task_id, :done) do
    assert {:error, {:task_adoption_failed, _bounded_reason}} =
             Orchestration.adopt_task_change(
               task_id,
               "refs/heads/reviewed",
               facade_opts(store)
             )
  end

  defp assert_non_adoptable(store, task_id, state) when state in [:failed, :cancelled] do
    assert {:error, {:task_not_adoptable, ^state}} =
             Orchestration.adopt_task_change(
               task_id,
               "refs/heads/reviewed",
               facade_opts(store)
             )
  end

  defp await_terminal_status(store, task_id, attempts \\ 100)

  defp await_terminal_status(_store, task_id, 0) do
    flunk("task #{task_id} did not reach a terminal state")
  end

  defp await_terminal_status(store, task_id, attempts) do
    case Orchestration.task_status(task_id, facade_opts(store)) do
      {:ok, %{state: state} = status} when state in [:done, :failed, :cancelled] ->
        status

      _ ->
        Process.sleep(20)
        await_terminal_status(store, task_id, attempts - 1)
    end
  end

  defp prepare_git_adoption_fixture(tmp_dir, task_id) do
    ensure_shell_execution_registry!()
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)
    git!(repo, ["config", "user.email", "canary@example.com"])
    git!(repo, ["config", "user.name", "Outcome Canary"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "base"])

    destination_ref = git!(repo, ["symbolic-ref", "HEAD"])
    destination_branch = String.replace_prefix(destination_ref, "refs/heads/", "")
    base_commit = git!(repo, ["rev-parse", "HEAD"])
    branch = "test/outcome-adoption"
    workspace_id = "workspace_outcome_adoption"

    git!(repo, ["checkout", "-b", branch])
    File.write!(Path.join(repo, "candidate.txt"), "candidate\n")
    git!(repo, ["add", "candidate.txt"])
    git!(repo, ["commit", "-m", "candidate"])
    candidate_commit = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", destination_branch])

    assert {:ok, %{hidden_ref: evidence_ref}} =
             Arbor.Actions.Git.archive_branch_evidence_ref(
               repo,
               branch,
               task_id,
               workspace_id,
               candidate_commit
             )

    %{
      repo: repo,
      branch: branch,
      workspace_id: workspace_id,
      destination_ref: destination_ref,
      base_commit: base_commit,
      candidate_commit: candidate_commit,
      evidence_ref: evidence_ref
    }
  end

  defp ensure_shell_execution_registry! do
    {:ok, _started} = Application.ensure_all_started(:arbor_shell)

    if is_nil(Process.whereis(Arbor.Shell.ExecutablePolicy)) do
      case Supervisor.start_child(
             Arbor.Shell.Supervisor,
             {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
           ) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          Supervisor.restart_child(Arbor.Shell.Supervisor, Arbor.Shell.ExecutablePolicy)
      end
    end

    if is_nil(Process.whereis(Arbor.Shell.ExecutionRegistry)) do
      case Supervisor.start_child(
             Arbor.Shell.Supervisor,
             {Arbor.Shell.ExecutionRegistry, []}
           ) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          Supervisor.restart_child(Arbor.Shell.Supervisor, Arbor.Shell.ExecutionRegistry)
      end
    end
  end

  defp branch_exists?(repo, branch) do
    {_output, status} =
      System.cmd(
        "git",
        ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
        stderr_to_stdout: true
      )

    status == 0
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{inspect(args)} exited #{status}: #{output}")
    end
  end

  defp prepare_compilation_artifacts(logs_root, task_id) do
    root = task_root(logs_root, task_id)
    File.mkdir_p!(root)

    for filename <- ["coding-plan.json", "coding-pipeline.dot", "coding-compile-manifest.json"] do
      path = Path.join(root, filename)
      File.write!(path, "{}")
      File.chmod!(path, 0o600)
    end

    root
  end

  defp compilation_artifacts(logs_root, task_id) do
    root = task_root(logs_root, task_id)

    %{
      "coding_plan_path" => Path.join(root, "coding-plan.json"),
      "coding_pipeline_path" => Path.join(root, "coding-pipeline.dot"),
      "compile_manifest_path" => Path.join(root, "coding-compile-manifest.json"),
      "graph_hash" => String.duplicate("a", 64),
      "compiler_version" => "coding-plan-1"
    }
  end

  defp read_task_terminal_archive(logs_root, task_id) do
    logs_root
    |> task_terminal_archive_path(task_id)
    |> File.read!()
    |> Jason.decode!()
  end

  defp task_terminal_archive_path(logs_root, task_id) do
    logs_root
    |> task_root(task_id)
    |> Path.join("coding-task-terminal.json")
  end

  defp task_root(logs_root, task_id) do
    digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
    Path.join(logs_root, "task-" <> digest)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
