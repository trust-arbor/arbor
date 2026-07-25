defmodule Arbor.Commands.CodingReadinessRecordReplayCanaryTest do
  @moduledoc """
  Phase B readiness record/replay canary exit gate.

  Each of the exactly ten canaries is one isolated invocation of the existing
  production benchmark happy path. The test-local pipeline executor receives
  the exact pipeline task and context that the benchmark is about to execute,
  canonicalizes that task's plan, runs public live readiness twice through the
  ReqLLM record/replay pipeline, and only then delegates to the benchmark's
  deterministic leased executor. The ten cases are repetitions with distinct
  task, workspace, and artifact identities, not ten different business-outcome
  fixtures.

  The readiness event is emitted before the delegate can acquire a worktree.
  Assertions bind its plan digest and task ID to the subsequent production
  executor event, validate typed readiness diagnostics and typed terminal
  outcome/artifact evidence, and verify that the global workspace registry is
  unchanged. The leased executor is intentionally a deterministic benchmark
  fixture; this proves the production adapter boundary and its evidence shape,
  not real ACP worker execution.

  The non-vacuous post-ready immutable-state transition is covered by the
  public candidate-verifier regression at
  `apps/arbor_orchestrator/test/arbor/orchestrator/coding_plan/candidate_verifier_test.exs`:
  its owner-observed tree is mutated after readiness and the public verifier
  emits `candidate_state_drifted`. This exit gate does not manufacture a
  blocked diagnostic by filtering an all-passed readiness report.
  """

  use Arbor.Commands.CodingBenchmarkAdapterCase

  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Contracts.Coding.{Diagnostic, Plan, ReadinessReport, TaskOutcome}
  alias Arbor.Orchestrator.CodingPlan.ReadinessCore
  alias Arbor.LLM.Plugs.{Record, Replay}
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :phase_b_readiness_exit_gate
  @moduletag timeout: 540_000

  @observed_at "2026-07-24T12:00:00.000Z"
  @scenario_labels ~w(
    canary-01 canary-02 canary-03 canary-04 canary-05
    canary-06 canary-07 canary-08 canary-09 canary-10
  )
  @readiness_gate_ids ~w(
    plan_schema trusted_roots compiler provenance security_authority acp_health
    toolchain_identity validation_capacity
  )

  defmodule FakeReqLLMTransport do
    @moduledoc false

    use Arbor.LLM.Plug

    alias Arbor.LLM.Call

    def call(%Call{halted: true} = call), do: call

    def call(%Call{result: nil} = call) do
      task_id = Application.get_env(:arbor_commands, :phase_b_canary_active_task_id)
      counter = Application.fetch_env!(:arbor_llm, :phase_b_canary_transport_counter)
      Agent.update(counter, &[task_id | &1])

      %{call | result: {:ok, response()}}
    end

    def call(%Call{} = call), do: call

    defp response do
      %ReqLLM.Response{
        id: "phase-b-canary-response",
        model: "gpt-4",
        context: ReqLLM.Context.new([]),
        message: %ReqLLM.Message{
          role: :assistant,
          content: [ReqLLM.Message.ContentPart.text("phase-b-ready")],
          tool_calls: []
        },
        stream?: false,
        stream: nil,
        usage: %{},
        finish_reason: :stop,
        provider_meta: %{},
        error: nil
      }
    end
  end

  defmodule ReadinessObserver do
    @moduledoc false

    alias Arbor.Contracts.LLM.ProviderObservation
    alias Arbor.LLM.Adapter.ReqLLM, as: LLMAdapter
    alias Arbor.LLM.Request

    def security_available?, do: true
    def signing_key_status(_agent_id), do: {:ok, :available}
    def coding_toolchain_identity, do: Arbor.Actions.coding_toolchain_identity()
    def validation_capacity_observer, do: :available

    def acp_provider_readiness(provider, model) do
      plan_digest =
        Application.fetch_env!(:arbor_commands, :phase_b_canary_active_plan_digest)

      request = %Request{
        provider: "openai",
        model: "gpt-4",
        messages: [
          Arbor.LLM.Message.new(
            :user,
            "phase-b-readiness-plan:" <> plan_digest
          )
        ]
      }

      with {:ok, response} <- LLMAdapter.complete(request),
           true <- response.text == "phase-b-ready",
           {:ok, observation} <- ProviderObservation.normalize(observation(provider, model)),
           {:ok, digest} <- ProviderObservation.digest(observation) do
        %{"observation" => observation, "digest" => digest}
      else
        false -> {:error, :unexpected_canary_response}
        {:error, _reason} = error -> error
      end
    end

    defp observation(provider, model) do
      %{
        "provider" => provider,
        "source" => "acp_provider_readiness",
        "runtime" => "acp",
        "observed_at" => "2026-07-24T12:00:00Z",
        "expires_at" => "2026-07-24T12:00:30Z",
        "availability" => "available",
        "auth_health" => "healthy",
        "model_catalog_membership" => "unknown",
        "quota_state" => "unknown",
        "subscription_capacity_state" => "unknown",
        "requested_model_id" => model,
        "launch_bound_model_id" => model
      }
    end
  end

  defmodule ExactPipelineExecutor do
    @moduledoc false

    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context) do
      Arbor.Commands.CodingReadinessRecordReplayCanaryTest.run_exact_pipeline_readiness!(
        principal_id,
        task,
        context
      )

      TestSupport.run_production_executor(:pipeline, principal_id, task, context)
    end
  end

  setup do
    originals = %{
      readiness_observer:
        Application.get_env(:arbor_orchestrator, :coding_readiness_observer_module),
      llm_pipeline: Application.get_env(:arbor_llm, :pipeline),
      llm_recorder: Application.get_env(:arbor_llm, :recorder),
      transport_counter: Application.get_env(:arbor_llm, :phase_b_canary_transport_counter),
      active_task_id: Application.get_env(:arbor_commands, :phase_b_canary_active_task_id),
      active_plan_digest: Application.get_env(:arbor_commands, :phase_b_canary_active_plan_digest)
    }

    Application.put_env(
      :arbor_orchestrator,
      :coding_readiness_observer_module,
      ReadinessObserver
    )

    Application.put_env(
      :arbor_llm,
      :pipeline,
      [Replay, FakeReqLLMTransport, Record]
    )

    {:ok, transport_counter} = Agent.start(fn -> [] end)
    Application.put_env(:arbor_llm, :phase_b_canary_transport_counter, transport_counter)

    on_exit(fn ->
      restore_env(
        :arbor_orchestrator,
        :coding_readiness_observer_module,
        originals.readiness_observer
      )

      restore_env(:arbor_llm, :pipeline, originals.llm_pipeline)
      restore_env(:arbor_llm, :recorder, originals.llm_recorder)

      if Process.alive?(transport_counter) do
        Agent.stop(transport_counter)
      end

      restore_env(:arbor_llm, :phase_b_canary_transport_counter, originals.transport_counter)

      restore_env(
        :arbor_commands,
        :phase_b_canary_active_task_id,
        originals.active_task_id
      )

      restore_env(
        :arbor_commands,
        :phase_b_canary_active_plan_digest,
        originals.active_plan_digest
      )
    end)

    :ok
  end

  test "ten isolated exact-task readiness-green canaries replay and produce typed valid outcomes" do
    global_registry_before = global_registry_snapshot()

    results =
      Enum.map(@scenario_labels, fn label ->
        run_canary!(label)
      end)

    assert length(results) == 10
    assert Enum.map(results, & &1.label) == @scenario_labels

    task_ids = Enum.map(results, & &1.task_id)
    worktree_ids = Enum.map(results, & &1.worktree_id)
    artifact_roots = Enum.map(results, & &1.artifact_root)

    assert length(task_ids) == 10
    assert length(Enum.uniq(task_ids)) == length(task_ids)
    assert length(Enum.uniq(worktree_ids)) == length(worktree_ids)
    assert length(Enum.uniq(artifact_roots)) == length(artifact_roots)
    assert global_registry_snapshot() == global_registry_before
  end

  defp run_canary!(label) do
    root = CodingBenchmarkTempRoot.create!("phase-b-#{label}")
    on_exit(fn -> File.rm_rf(root) end)

    scenario = Scenario.create!(root, ["happy"])
    configure_runtime!(root, 30_000, 500)
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    recorder_root = Path.join(root, "llm-recordings")
    File.mkdir_p!(recorder_root)
    Application.put_env(:arbor_llm, :recorder, fixtures_path: recorder_root)

    install_leased_executors()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      ExactPipelineExecutor
    )

    assert {:ok, report} = run_production_scenario(scenario)

    assert report["summary"] == %{
             "different_pairs" => 0,
             "equivalent_pairs" => 1,
             "pair_count" => 1,
             "row_count" => 2,
             "unavailable_pairs" => 0
           }

    pipeline_readiness = receive_exact_pipeline_readiness!(report)
    pipeline_call = receive_exact_pipeline_call!(pipeline_readiness.task_id)

    assert pipeline_readiness.task_id == pipeline_call.context["task_id"]
    assert pipeline_readiness.exact_task == pipeline_call.task

    assert pipeline_readiness.canonical_plan_digest ==
             ReadinessCore.plan_digest(pipeline_call.task["plan"])

    pipeline_task_id = pipeline_readiness.task_id

    assert Agent.get(
             Application.fetch_env!(:arbor_llm, :phase_b_canary_transport_counter),
             fn ids -> Enum.count(ids, &(&1 == pipeline_task_id)) end
           ) == 1

    assert_exact_readiness_reports!(pipeline_readiness)
    assert_typed_terminal_outcomes!(report)
    assert_typed_pipeline_evidence!(report, pipeline_call)

    %{
      label: label,
      task_id: pipeline_readiness.task_id,
      worktree_id: coding_task_fields(pipeline_call.task)["worktree_base_dir"],
      artifact_root: pipeline_call.artifact_root
    }
  end

  @doc false
  def run_exact_pipeline_readiness!(
        principal_id,
        %{"kind" => "coding_change", "plan" => plan_map},
        context
      )
      when is_map(plan_map) and not is_struct(plan_map) and is_map(context) do
    {:ok, plan} = Plan.new(plan_map)
    canonical_plan = Plan.to_map(plan)
    assert canonical_plan == plan_map

    task_id = Map.fetch!(context, "task_id")
    canonical_plan_digest = ReadinessCore.plan_digest(canonical_plan)
    previous_task_id = Application.get_env(:arbor_commands, :phase_b_canary_active_task_id)

    previous_plan_digest =
      Application.get_env(:arbor_commands, :phase_b_canary_active_plan_digest)

    Application.put_env(:arbor_commands, :phase_b_canary_active_task_id, task_id)

    Application.put_env(
      :arbor_commands,
      :phase_b_canary_active_plan_digest,
      canonical_plan_digest
    )

    try do
      first_report = public_live_readiness!(canonical_plan, principal_id)
      replay_report = public_live_readiness!(canonical_plan, principal_id)

      send(
        Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer),
        {:phase_b_canary_exact_readiness, task_id, canonical_plan_digest,
         %{"kind" => "coding_change", "plan" => canonical_plan}, first_report, replay_report}
      )
    after
      restore_env(:arbor_commands, :phase_b_canary_active_task_id, previous_task_id)
      restore_env(:arbor_commands, :phase_b_canary_active_plan_digest, previous_plan_digest)
    end

    :ok
  end

  defp public_live_readiness!(plan, principal_id) do
    case Arbor.Orchestrator.check_coding_readiness(plan,
           mode: :live,
           agent_id: principal_id,
           observed_at: @observed_at
         ) do
      {:ok, report} ->
        report

      other ->
        raise "exact pipeline readiness failed: #{inspect(other)}"
    end
  end

  defp receive_exact_pipeline_readiness!(report) do
    receive do
      {:phase_b_canary_exact_readiness, task_id, digest, exact_task, first, replay} ->
        %{
          task_id: task_id,
          canonical_plan_digest: digest,
          exact_task: exact_task,
          first_report: first,
          replay_report: replay
        }

      {:production_executor_call, "pipeline", _principal, _task, _context, _worktree, _artifact} ->
        flunk("pipeline acquired a worktree before exact readiness")

      _other ->
        receive_exact_pipeline_readiness!(report)
    after
      30_000 ->
        flunk("timed out waiting for exact pipeline readiness event for #{inspect(report)}")
    end
  end

  defp receive_exact_pipeline_call!(task_id) do
    receive do
      {:production_executor_call, "pipeline", principal, task, %{"task_id" => ^task_id} = context,
       worktree, artifact_root} ->
        %{
          principal: principal,
          task: task,
          context: context,
          worktree: worktree,
          artifact_root: artifact_root
        }

      {:production_executor_call, "pipeline", _principal, _task, _context, _worktree, _artifact} ->
        flunk("pipeline acquired a worktree before exact readiness")

      _other ->
        receive_exact_pipeline_call!(task_id)
    after
      30_000 -> flunk("timed out waiting for exact pipeline call for #{task_id}")
    end
  end

  defp assert_exact_readiness_reports!(event) do
    for readiness <- [event.first_report, event.replay_report] do
      assert {:ok, normalized} = ReadinessReport.normalize(readiness)
      assert normalized["status"] == "ready"
      assert normalized["plan_digest"] == event.canonical_plan_digest
      assert Enum.map(normalized["diagnostics"], & &1["gate_id"]) == @readiness_gate_ids
      assert Enum.all?(normalized["diagnostics"], &(&1["decision"] == "passed"))
      assert Enum.all?(normalized["diagnostics"], &Diagnostic.valid?/1)
    end

    assert stable_readiness(event.first_report) == stable_readiness(event.replay_report)
  end

  defp stable_readiness(report) do
    %{
      "status" => report["status"],
      "plan_digest" => report["plan_digest"],
      "diagnostics" =>
        Enum.map(report["diagnostics"], fn diagnostic ->
          Map.take(diagnostic, ["gate_id", "decision", "code", "evidence_ref"])
        end)
    }
  end

  defp assert_typed_pipeline_evidence!(report, call) do
    pipeline_row = Enum.find(report["rows"], &(&1["executor_path"] == "pipeline"))
    assert pipeline_row["fixture_id"] == "happy"
    assert pipeline_row["terminal_status"] == "change_committed"
    assert {:ok, outcome} = TaskOutcome.from_code(pipeline_row["terminal_status"])
    assert {:ok, ^outcome} = TaskOutcome.validate_registered(TaskOutcome.to_map(outcome))
    assert outcome.disposition == "succeeded"
    assert pipeline_row["objective_verifier"] == %{"reason" => nil, "status" => "passed"}
    assert pipeline_row["changed_paths"] == ["result.txt"]

    assert pipeline_row["artifact_hash_verification"] == %{
             "artifact_presence" => %{
               "digest" => true,
               "dot" => true,
               "manifest" => true,
               "plan" => true
             },
             "base_tree_verified" => true,
             "changed_paths_verified" => true,
             "graph_hash_verified" => true,
             "normalized_input_hash_verified" => true,
             "result_tree_verified" => true,
             "status" => "passed"
           }

    task_id = call.context["task_id"]

    expected_artifact_root =
      Path.join(
        Application.fetch_env!(:arbor_commands, :coding_benchmark_artifact_root),
        "task-" <>
          (:crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower))
      )

    assert call.artifact_root == expected_artifact_root
  end

  defp assert_typed_terminal_outcomes!(report) do
    assert length(report["rows"]) == 2

    for row <- report["rows"] do
      assert row["terminal_status"] == "change_committed"
      assert {:ok, outcome} = TaskOutcome.from_code(row["terminal_status"])
      assert {:ok, _validated} = TaskOutcome.validate_registered(TaskOutcome.to_map(outcome))
      assert outcome.disposition == "succeeded"
    end
  end

  defp global_registry_snapshot do
    case Process.whereis(WorkspaceLeaseRegistry) do
      nil -> :absent
      _pid -> {:present, Arbor.Actions.coding_resource_inventory(max_items: 256)}
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
