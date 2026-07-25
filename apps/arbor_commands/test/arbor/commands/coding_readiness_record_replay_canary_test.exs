defmodule Arbor.Commands.CodingReadinessRecordReplayCanaryTest do
  @moduledoc """
  Phase B readiness exit gate.

  A canary is intentionally one isolated invocation of the existing production
  benchmark happy path. The ten cases are repetitions with distinct resource
  identities, not ten different business-outcome fixtures: this is the
  narrowest truthful interpretation of the exit gate because the benchmark
  harness owns deterministic production-path execution while readiness owns
  infrastructure admission.

  ACP readiness is observed through the public readiness facade and its ACP
  observation uses the existing ReqLLM record/replay plugs. The fake terminal
  plug is a deterministic local transport; it is never a network or paid-model
  call. A post-ready immutable failure is admissible only when its diagnostic
  explicitly carries state-drift evidence.
  """

  use Arbor.Commands.CodingBenchmarkAdapterCase

  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Contracts.Coding.{Diagnostic, Plan, ReadinessReport}
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
  @immutable_gate_ids ~w(plan_schema trusted_roots compiler provenance)

  defmodule FakeReqLLMTransport do
    @moduledoc false

    use Arbor.LLM.Plug

    alias Arbor.LLM.Call

    def call(%Call{halted: true} = call), do: call

    def call(%Call{result: nil} = call) do
      send(
        Application.fetch_env!(:arbor_llm, :phase_b_canary_test_pid),
        :phase_b_canary_live_transport
      )

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
      request = %Request{
        provider: "openai",
        model: "gpt-4",
        messages: []
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

  setup do
    originals = %{
      readiness_observer:
        Application.get_env(:arbor_orchestrator, :coding_readiness_observer_module),
      llm_pipeline: Application.get_env(:arbor_llm, :pipeline),
      llm_recorder: Application.get_env(:arbor_llm, :recorder),
      llm_test_pid: Application.get_env(:arbor_llm, :phase_b_canary_test_pid)
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

    Application.put_env(:arbor_llm, :phase_b_canary_test_pid, self())

    on_exit(fn ->
      restore_env(
        :arbor_orchestrator,
        :coding_readiness_observer_module,
        originals.readiness_observer
      )

      restore_env(:arbor_llm, :pipeline, originals.llm_pipeline)
      restore_env(:arbor_llm, :recorder, originals.llm_recorder)
      restore_env(:arbor_llm, :phase_b_canary_test_pid, originals.llm_test_pid)
    end)

    :ok
  end

  test "ten isolated readiness-green canaries replay deterministically without infrastructure-invalid outcomes" do
    global_registry_before = global_registry_snapshot()

    results =
      Enum.map(@scenario_labels, fn label ->
        run_canary!(label)
      end)

    assert length(results) == 10
    assert Enum.map(results, & &1.label) == @scenario_labels

    task_ids = Enum.flat_map(results, & &1.task_ids)
    worktree_ids = Enum.flat_map(results, & &1.worktree_ids)
    artifact_roots = Enum.flat_map(results, & &1.artifact_roots)

    assert length(task_ids) == 20
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

    repo_path = Path.join(root, "fixtures/happy")
    worktree_root = Path.join(root, "readiness-worktrees")
    File.mkdir_p!(worktree_root)

    plan = canary_plan!(label, repo_path, worktree_root)
    readiness_recorded = check_ready!(plan)
    assert_receive :phase_b_canary_live_transport

    fixture_paths = Path.wildcard(Path.join(recorder_root, "*.json"))
    assert [fixture_path] = fixture_paths
    recorded_fixture = File.read!(fixture_path)

    readiness_replayed = check_ready!(plan)
    refute_receive :phase_b_canary_live_transport, 50
    assert File.read!(fixture_path) == recorded_fixture

    assert stable_readiness(readiness_recorded) == stable_readiness(readiness_replayed)
    assert_immutable_failures_require_drift!(readiness_replayed)

    install_leased_executors()
    assert {:ok, report} = run_production_scenario(scenario)

    assert report["summary"] == %{
             "different_pairs" => 0,
             "equivalent_pairs" => 1,
             "pair_count" => 1,
             "row_count" => 2,
             "unavailable_pairs" => 0
           }

    assert_no_infrastructure_invalid_outcomes!(report)
    calls = receive_production_calls!(2)

    %{
      label: label,
      task_ids:
        Enum.map(calls, fn {_executor, _principal, _task, context, _worktree, _artifact} ->
          context["task_id"]
        end),
      worktree_ids:
        Enum.map(calls, fn {_executor, _principal, task, _context, _worktree, _artifact} ->
          coding_task_fields(task)["worktree_base_dir"]
        end),
      artifact_roots:
        calls
        |> Enum.map(fn {_executor, _principal, _task, _context, _worktree, artifact} ->
          artifact
        end)
        |> Enum.filter(&is_binary/1)
    }
  end

  defp canary_plan!(label, repo_path, worktree_root) do
    {:ok, plan} =
      Plan.new(%{
        "task" => "Phase B readiness record/replay #{label}",
        "repo_root" => repo_path,
        "worker" => %{"provider" => "grok", "model" => "phase-b-canary-model"},
        "workspace_policy" => %{
          "mode" => "isolated",
          "branch_name" => "arbor/phase-b-#{label}",
          "worktree_base_dir" => worktree_root
        },
        "budgets" => %{"wall_clock_ms" => 30_000}
      })

    plan
  end

  defp check_ready!(plan) do
    assert {:ok, report} =
             Arbor.Orchestrator.check_coding_readiness(plan,
               mode: :live,
               agent_id: "agent_phase_b_readiness_canary",
               observed_at: @observed_at
             )

    assert {:ok, report} = ReadinessReport.normalize(report)
    assert report["status"] == "ready"
    assert Enum.map(report["diagnostics"], & &1["gate_id"]) == @readiness_gate_ids
    assert Enum.all?(report["diagnostics"], &(&1["decision"] == "passed"))
    assert Enum.all?(report["diagnostics"], &Diagnostic.valid?/1)
    report
  end

  defp stable_readiness(report) do
    %{
      "status" => report["status"],
      "diagnostics" =>
        Enum.map(report["diagnostics"], fn diagnostic ->
          Map.take(diagnostic, ["gate_id", "decision", "code", "evidence_ref"])
        end)
    }
  end

  defp assert_immutable_failures_require_drift!(report) do
    report["diagnostics"]
    |> Enum.filter(&(&1["gate_id"] in @immutable_gate_ids and &1["decision"] == "blocked"))
    |> Enum.each(fn diagnostic ->
      assert diagnostic["code"] in ["state_drift", "candidate_state_drifted"]
      assert is_binary(diagnostic["evidence_ref"])
    end)
  end

  defp assert_no_infrastructure_invalid_outcomes!(report) do
    invalid_rows =
      Enum.filter(report["rows"], fn row ->
        text =
          [row["terminal_status"], row["terminal_reason"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")
          |> String.downcase()

        Regex.match?(
          ~r/(infrastructure_invalid|toolchain|build[_ ]root|dependency[_ ]root|test[_ ]root|validation_capacity|workspace_cleanup|artifact_cleanup)/,
          text
        )
      end)

    assert invalid_rows == [],
           "post-readiness infrastructure-invalid rows: #{inspect(invalid_rows)}"
  end

  defp receive_production_calls!(count, acc \\ [])

  defp receive_production_calls!(0, acc), do: Enum.reverse(acc)

  defp receive_production_calls!(count, acc) do
    receive do
      {:production_executor_call, executor, principal, task, context, worktree, artifact} ->
        receive_production_calls!(
          count - 1,
          [{executor, principal, task, context, worktree, artifact} | acc]
        )
    after
      30_000 -> flunk("timed out waiting for #{count} production benchmark calls")
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
