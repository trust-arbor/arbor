defmodule Arbor.Commands.CodingBenchmarkScenario do
  @moduledoc false

  @manifest_schema "arbor.coding_benchmark.manifest.v1"
  @fixture_ids ~w(
    happy validation-recovery review-recovery approval-resume review-rejection
    executor-failure cancel-owned cancel-reused
  )

  defmodule LegacyAdapter do
    @moduledoc false
    def run(request), do: Arbor.Commands.CodingBenchmarkScenario.run_adapter("legacy", request)
  end

  defmodule PipelineAdapter do
    @moduledoc false
    def run(request), do: Arbor.Commands.CodingBenchmarkScenario.run_adapter("pipeline", request)
  end

  defmodule ObjectiveVerifier do
    @moduledoc false

    def run(request) do
      expected = "completed:#{request["fixture_id"]}\n"

      case File.read(Path.join(request["workdir"], "result.txt")) do
        {:ok, ^expected} -> :ok
        {:ok, _other} -> {:error, :unexpected_result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def adapters do
    %{"legacy" => LegacyAdapter, "pipeline" => PipelineAdapter}
  end

  def verifiers do
    %{"scripted_objective" => ObjectiveVerifier}
  end

  def deterministic_measure(fun), do: {17, fun.()}

  def create!(root, fixture_ids \\ @fixture_ids) do
    File.mkdir_p!(root)
    fixtures_root = Path.join(root, "fixtures")
    File.mkdir_p!(fixtures_root)

    fixtures =
      Enum.map(fixture_ids, fn fixture_id ->
        unless fixture_id in @fixture_ids do
          raise ArgumentError, "unknown scripted fixture: #{fixture_id}"
        end

        fixture_path = Path.join(fixtures_root, fixture_id)
        File.mkdir_p!(fixture_path)
        git!(fixture_path, ["init", "--quiet"])
        File.write!(Path.join(fixture_path, "README.md"), "fixture:#{fixture_id}\n")
        git!(fixture_path, ["add", "--", "README.md"])

        git!(fixture_path, [
          "-c",
          "user.name=Arbor Benchmark",
          "-c",
          "user.email=benchmark@arbor.local",
          "commit",
          "--quiet",
          "-m",
          "base fixture"
        ])

        %{
          "base_tree_oid" => git!(fixture_path, ["rev-parse", "HEAD^{tree}"]),
          "fixture_id" => fixture_id,
          "fixture_path" => Path.join("fixtures", fixture_id),
          "input" => %{
            "acceptance_criteria" => ["Write the deterministic result marker."],
            "objective" => "Complete the #{fixture_id} scripted benchmark scenario."
          },
          "verifier_id" => "scripted_objective"
        }
      end)

    manifest = %{"fixtures" => fixtures, "schema" => @manifest_schema, "seed" => 7}
    manifest_path = Path.join(root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    %{manifest: manifest, manifest_path: manifest_path, root: root}
  end

  def run_adapter(executor, request) when executor in ["legacy", "pipeline"] do
    expected_mode = if executor == "legacy", do: :legacy, else: :pipeline

    cond do
      request["executor_path"] != executor ->
        {:error, :executor_path_mismatch}

      Application.get_env(:arbor_agent, :coding_executor_mode) != expected_mode ->
        {:error, :executor_selector_mismatch}

      request["fixture_id"] == "executor-failure" and executor == "pipeline" ->
        {:error, :scripted_pipeline_failure,
         %{
           counters: %{validation_cycles: 1, rework_cycles: 0},
           observations: %{},
           worker_ownership: :none
         }}

      true ->
        execute_scenario(executor, request)
    end
  end

  defp execute_scenario(executor, request) do
    fixture_id = request["fixture_id"]
    workdir = request["workdir"]
    status = terminal_status(fixture_id)

    changed_paths =
      if status == :cancelled do
        []
      else
        File.write!(Path.join(workdir, "result.txt"), "completed:#{fixture_id}\n")
        git!(workdir, ["add", "--", "result.txt"])

        git!(workdir, [
          "-c",
          "user.name=Arbor Benchmark",
          "-c",
          "user.email=benchmark@arbor.local",
          "commit",
          "--quiet",
          "-m",
          "scripted result"
        ])

        ["result.txt"]
      end

    tree_oid = git!(workdir, ["rev-parse", "HEAD^{tree}"])
    artifacts = if executor == "pipeline", do: pipeline_artifacts(workdir, request), else: %{}
    observations = observations(fixture_id, tree_oid)

    result = %{
      result_type: :coding_change,
      payload: %{
        artifacts: artifacts,
        files: changed_paths,
        reason: terminal_reason(fixture_id),
        report: %{
          review: review(fixture_id),
          status: status,
          validation: validation(fixture_id)
        }
      }
    }

    {:ok,
     %{
       counters: counters(fixture_id),
       observations: observations,
       result: result,
       worker_ownership: worker_ownership(fixture_id)
     }}
  end

  defp terminal_status("review-rejection"), do: :review_rejected
  defp terminal_status("cancel-owned"), do: :cancelled
  defp terminal_status("cancel-reused"), do: :cancelled
  defp terminal_status(_fixture_id), do: :change_committed

  defp terminal_reason("review-rejection"), do: :scripted_review_rejection
  defp terminal_reason("cancel-owned"), do: :scripted_cancellation
  defp terminal_reason("cancel-reused"), do: :scripted_cancellation
  defp terminal_reason(_fixture_id), do: nil

  defp counters("validation-recovery"),
    do: %{validation_cycles: 2, rework_cycles: 1}

  defp counters("review-recovery"),
    do: %{validation_cycles: 2, rework_cycles: 1}

  defp counters(_fixture_id),
    do: %{validation_cycles: 1, rework_cycles: 0}

  defp validation(fixture_id) when fixture_id in ["cancel-owned", "cancel-reused"], do: []
  defp validation(_fixture_id), do: [%{passed: true}]

  defp review(fixture_id) when fixture_id in ["cancel-owned", "cancel-reused"], do: %{}

  defp review("review-rejection") do
    %{
      blast_radius: :low,
      human_required: true,
      recommendation: :reject,
      security_veto: false,
      tier_decision: :human_required
    }
  end

  defp review(_fixture_id) do
    %{
      blast_radius: :low,
      human_required: false,
      recommendation: :keep,
      security_veto: false,
      tier_decision: :auto_proceed
    }
  end

  defp observations(fixture_id, tree_oid) do
    %{
      approval: approval(fixture_id),
      cancellation: cancellation(fixture_id),
      cleanup: cleanup(fixture_id),
      tree_oid: tree_oid
    }
  end

  defp approval("approval-resume") do
    %{
      count: 1,
      requested: true,
      required: true,
      resumed: true,
      status: :approved
    }
  end

  defp approval(_fixture_id) do
    %{
      count: 0,
      requested: false,
      required: false,
      resumed: false,
      status: :not_required
    }
  end

  defp cancellation("cancel-owned") do
    %{
      cancelled: true,
      cleanup_completed: true,
      requested: true,
      status: :cancelled,
      worker_terminated: true
    }
  end

  defp cancellation("cancel-reused") do
    %{
      cancelled: true,
      cleanup_completed: true,
      requested: true,
      status: :cancelled,
      worker_terminated: false
    }
  end

  defp cancellation(_fixture_id) do
    %{
      cancelled: false,
      cleanup_completed: true,
      requested: false,
      status: :not_requested,
      worker_terminated: false
    }
  end

  defp cleanup("cancel-owned") do
    %{
      completed: true,
      resources_cleaned: true,
      status: :released,
      workspace_removed: true,
      workspace_retained: false
    }
  end

  defp cleanup("cancel-reused") do
    %{
      completed: true,
      resources_cleaned: false,
      status: :preserved,
      workspace_removed: false,
      workspace_retained: true
    }
  end

  defp cleanup(_fixture_id) do
    %{
      completed: true,
      resources_cleaned: true,
      status: :retained,
      workspace_removed: false,
      workspace_retained: true
    }
  end

  defp worker_ownership("cancel-owned"), do: :owned
  defp worker_ownership("cancel-reused"), do: :reused
  defp worker_ownership(_fixture_id), do: :none

  defp pipeline_artifacts(workdir, request) do
    artifact_root = Path.join(workdir, ".git/arbor-benchmark-artifacts")
    File.mkdir_p!(artifact_root)

    dot_path = Path.join(artifact_root, "coding-pipeline.dot")
    plan_path = Path.join(artifact_root, "coding-plan.json")
    manifest_path = Path.join(artifact_root, "compile-manifest.json")
    dot = "digraph benchmark { input_hash=\"#{request["normalized_input_hash"]}\" }\n"

    File.write!(dot_path, dot)
    File.write!(plan_path, "{}\n")
    File.write!(manifest_path, "{}\n")

    %{
      coding_pipeline_path: dot_path,
      coding_plan_path: plan_path,
      compile_manifest_path: manifest_path,
      graph_hash: sha256(dot)
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp git!(workdir, args) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end
end
