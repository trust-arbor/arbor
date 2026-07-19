defmodule Arbor.Commands.CodingBenchmarkAdapterCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.{Adapter, Git, LegacyAdapter, PipelineAdapter, Runtime}
  alias Arbor.Commands.CodingBenchmarkScenario, as: Scenario
  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.Plan

  using do
    quote do
      @moduletag :slow
      @moduletag :integration

      # Cross-app validation gives the whole contained test-file process a
      # 600-second hard ceiling. Leave teardown margin while preventing
      # ExUnit's unrelated 60-second default from preempting bounded fixture
      # scenarios under one-CPU/virtiofs scheduling.
      @moduletag timeout: 540_000

      alias Arbor.Commands.CodingBenchmark
      alias Arbor.Commands.CodingBenchmark.{Adapter, Git, LegacyAdapter, PipelineAdapter, Runtime}
      alias Arbor.Commands.CodingBenchmarkScenario, as: Scenario
      alias Arbor.Commands.CodingBenchmarkTempRoot
      alias Arbor.Common.SafePath
      alias Arbor.Contracts.Coding.Plan

      alias Arbor.Commands.CodingBenchmarkAdapterCase.{
        ArtifactSwapVerifier,
        CapturingLegacyExecutor,
        CapturingPipelineExecutor,
        CapturingPipelineStatus,
        CoreExcludedUntrackedVerifier,
        DirtyWorktreeVerifier,
        FinalBranchSwapVerifier,
        HangingCancelPipelineExecutor,
        HangingExecutor,
        HangingVerifier,
        HiddenUntrackedVerifier,
        InfoExcludedUntrackedVerifier,
        LateExitingPipelineExecutor,
        LateRaisingPipelineExecutor,
        LateWritingPipelineExecutor,
        LeasedLegacyExecutor,
        LeasedPipelineExecutor,
        ResourcePipelineExecutor,
        StatusOnlyPipelineExecutor
      }

      # Test-only ceiling for production-fixture scenarios that are expected to
      # complete successfully (happy path, security regressions, artifact cases).
      # Successful runs finish well under this budget; the cap only absorbs
      # one-CPU/low-memory sandbox scheduling noise. Kept below ExUnit's default
      # 540s per-test ceiling so paired legacy/pipeline execution still has outer
      # headroom if a child hangs. Do not reuse for intentional timeout/
      # cancellation/late-writer tests — those pass an explicit short deadline.
      @successful_fixture_execution_timeout_ms 30_000

      import Arbor.Commands.CodingBenchmarkAdapterCase,
        only: [
          assert_exact_inputs: 4,
          benchmark_requests!: 0,
          benchmark_requests!: 1,
          coding_task_fields: 1,
          configure_runtime!: 2,
          configure_runtime!: 3,
          execution_digest: 1,
          git!: 2,
          install_capturing_executors: 0,
          install_leased_executors: 0,
          min_pipeline_execution_timeout_ms: 0,
          production_scenario!: 0,
          production_scenario!: 1,
          production_scenario!: 2,
          row: 2,
          assert_optional_artifact_accepted: 1,
          assert_optional_artifact_rejected: 1,
          assert_pipeline_artifact_descriptors_accepted: 1,
          assert_pipeline_artifact_descriptors_rejected: 1,
          baseline_pipeline_artifact_descriptors: 0,
          baseline_pipeline_artifact_descriptors: 1,
          run_production_artifact_case: 1,
          run_production_scenario: 1,
          run_production_scenario: 2,
          synthetic_transcript_descriptor: 0,
          synthetic_transcript_descriptor: 1,
          temp_directory!: 1,
          valid_transcript_descriptor: 1
        ]
    end
  end

  # Test-only ceiling for production-fixture scenarios that are expected to
  # complete successfully (happy path, security regressions, artifact cases).
  # Successful runs finish well under this budget; the cap only absorbs
  # one-CPU/low-memory sandbox scheduling noise. Kept below ExUnit's default
  # 540s per-test ceiling so paired legacy/pipeline execution still has outer
  # headroom if a child hangs. Do not reuse for intentional timeout/
  # cancellation/late-writer tests — those pass an explicit short deadline.
  @successful_fixture_execution_timeout_ms 30_000

  @runtime_env [
    {:arbor_commands, :coding_benchmark_principal_id},
    {:arbor_commands, :coding_benchmark_legacy_executor_module},
    {:arbor_commands, :coding_benchmark_pipeline_executor_module},
    {:arbor_commands, :coding_benchmark_workspace_root},
    {:arbor_commands, :coding_benchmark_artifact_root},
    {:arbor_commands, :coding_benchmark_execution_timeout_ms},
    {:arbor_commands, :coding_benchmark_fixture_setup_timeout_ms},
    {:arbor_commands, :coding_benchmark_cancellation_timeout_ms},
    {:arbor_commands, :coding_benchmark_test_observer},
    {:arbor_commands, :coding_benchmark_test_resource_registry},
    {:arbor_commands, :coding_benchmark_test_resource_root},
    {:arbor_commands, :coding_benchmark_test_mode},
    {:arbor_commands, :coding_benchmark_legacy_test_reply},
    {:arbor_commands, :coding_benchmark_pipeline_test_reply},
    {:arbor_orchestrator, :coding_repo_roots},
    {:arbor_orchestrator, :coding_worktree_roots},
    {:arbor_orchestrator, :coding_pipeline_logs_root},
    {:arbor_orchestrator, :pipeline_status_module}
  ]

  defmodule CapturingLegacyExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.capture(:legacy, principal_id, task, context)
  end

  defmodule CapturingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.capture(:pipeline, principal_id, task, context)
  end

  defmodule LeasedLegacyExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.run_production_executor(:legacy, principal_id, task, context)
  end

  defmodule LeasedPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.run_production_executor(:pipeline, principal_id, task, context)
  end

  defmodule HangingExecutor do
    @moduledoc false

    def run(principal_id, task, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_executor_started, self(), principal_id, task, context})
      Process.sleep(:infinity)
    end
  end

  defmodule HangingVerifier do
    @moduledoc false

    def run(_request) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_verifier_started, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule FinalBranchSwapVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      git!(workdir, ["checkout", "--detach", "--quiet"])
      :ok
    end

    def run(_request), do: :ok

    defp git!(workdir, args) do
      case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> raise "git failed (#{status}): #{output}"
      end
    end
  end

  defmodule DirtyWorktreeVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      File.write!(Path.join(workdir, "verifier-dirt.txt"), "uncommitted\n")
      :ok
    end

    def run(_request), do: :ok
  end

  defmodule HiddenUntrackedVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      git!(workdir, ["config", "--local", "status.showUntrackedFiles", "no"])
      File.write!(Path.join(workdir, "hidden-untracked.txt"), "must be detected\n")
      :ok
    end

    def run(_request), do: :ok

    defp git!(workdir, args) do
      case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> raise "git failed (#{status}): #{output}"
      end
    end
  end

  defmodule InfoExcludedUntrackedVerifier do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}),
      do: TestSupport.write_excluded_untracked(workdir, :info_exclude)

    def run(_request), do: :ok
  end

  defmodule CoreExcludedUntrackedVerifier do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}),
      do: TestSupport.write_excluded_untracked(workdir, :core_excludes_file)

    def run(_request), do: :ok
  end

  defmodule ArtifactSwapVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      root =
        Application.fetch_env!(:arbor_commands, :coding_benchmark_artifact_root)
        |> File.ls!()
        |> Enum.map(
          &Path.join(Application.fetch_env!(:arbor_commands, :coding_benchmark_artifact_root), &1)
        )
        |> Enum.find(&File.exists?(Path.join(&1, "coding-plan.json")))

      plan_path = Path.join(root, "coding-plan.json")
      File.rm!(plan_path)
      File.ln_s!(Path.join(workdir, "README.md"), plan_path)
      :ok
    end

    def run(_request), do: :ok
  end

  defmodule ResourcePipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.allocate_resource_and_hang(principal_id, task, context)

    def cancel_task(principal_id, context),
      do: TestSupport.cancel_allocated_resource(principal_id, context)
  end

  defmodule HangingCancelPipelineExecutor do
    @moduledoc false

    def run(principal_id, task, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_pipeline_started, self(), principal_id, task, context})
      Process.sleep(:infinity)
    end

    def cancel_task(principal_id, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_cancel_started, self(), principal_id, context})
      Process.sleep(:infinity)
    end
  end

  defmodule StatusOnlyPipelineExecutor do
    @moduledoc false

    def run(principal_id, task, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:status_only_pipeline_started, self(), principal_id, task, context})
      Process.sleep(:infinity)
    end

    def cancel_task(principal_id, context),
      do: Arbor.Orchestrator.cancel_coding_task(principal_id, context)
  end

  defmodule LateWritingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.allocate_late_writer_and_hang(principal_id, task, context)

    def cancel_task(principal_id, context),
      do: Arbor.Orchestrator.cancel_coding_task(principal_id, context)
  end

  defmodule LateRaisingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(_principal_id, _task, context),
      do: TestSupport.allocate_late_writer_and_fail(context, :raise)
  end

  defmodule LateExitingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: TestSupport

    def run(_principal_id, _task, context),
      do: TestSupport.allocate_late_writer_and_fail(context, :exit)
  end

  defmodule CapturingPipelineStatus do
    @moduledoc false

    def mark_abandoned(task_id) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:pipeline_mark_abandoned, task_id})
      :ok
    end
  end

  setup_all do
    for child <- [
          {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")},
          {Arbor.Shell.ExecutionRegistry, []},
          {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
        ] do
      case Supervisor.start_child(Arbor.Shell.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  setup do
    originals = Map.new(@runtime_env, fn key -> {key, fetch_env(key)} end)

    Application.put_env(:arbor_commands, :coding_benchmark_principal_id, "agent_benchmark")
    Application.put_env(:arbor_commands, :coding_benchmark_test_observer, self())
    install_capturing_executors()

    on_exit(fn ->
      Enum.each(originals, fn {key, value} -> restore_env(key, value) end)
    end)

    :ok
  end

  @doc false
  def capture(executor, principal_id, task, context) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    send(observer, {:executor_call, executor, principal_id, task, context})
    Application.get_env(:arbor_commands, reply_key(executor), {:error, :missing_test_reply})
  end

  @doc false
  def run_production_executor(executor, principal_id, task, context) do
    mode = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_mode)

    case mode do
      :leased ->
        leased_result(executor, principal_id, task, context, :valid)

      :symlink_artifact ->
        leased_result(executor, principal_id, task, context, :symlink)

      :invalid_manifest ->
        leased_result(executor, principal_id, task, context, :invalid_manifest)

      :tampered_dot ->
        leased_result(executor, principal_id, task, context, :tampered_dot)

      :unrelated_commit ->
        leased_result(executor, principal_id, task, context, :valid, :unrelated)

      :replacement_ancestry ->
        leased_result(executor, principal_id, task, context, :valid, :replacement)

      :lease_marker_tamper ->
        leased_result(executor, principal_id, task, context, :lease_marker_tamper)

      {:artifact_transform, transform} when is_function(transform, 2) ->
        leased_result(executor, principal_id, task, context, {:artifact_transform, transform})

      :missing_worktree ->
        production_result(executor, principal_id, task, context, nil, %{}, nil)

      :wrong_worktree ->
        wrong_worktree_result(executor, principal_id, task, context)

      :wrong_branch ->
        wrong_branch_result(executor, principal_id, task, context)

      {:symlink_worktree, outside} ->
        symlink_worktree_result(executor, principal_id, task, context, outside)
    end
  end

  @doc false
  def allocate_resource_and_hang(principal_id, _task, %{"task_id" => task_id}) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    registry = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_resource_registry)
    resource_root = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_resource_root)
    resource_path = Path.join(resource_root, sha256(task_id))
    File.mkdir!(resource_path)
    File.write!(Path.join(resource_path, "lease"), task_id)
    resource_pid = spawn(fn -> Process.sleep(:infinity) end)

    Agent.update(registry, fn resources ->
      Map.put(resources, task_id, %{
        path: resource_path,
        pid: resource_pid,
        principal_id: principal_id
      })
    end)

    send(observer, {:external_resource_allocated, resource_pid, resource_path, task_id})
    Process.sleep(:infinity)
  end

  @doc false
  def allocate_late_writer_and_hang(_principal_id, _task, %{"task_id" => task_id}) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

    artifact_root =
      Path.join(Arbor.Orchestrator.coding_pipeline_logs_root(), "task-" <> sha256(task_id))

    worker =
      spawn(fn ->
        Process.sleep(500)
        late_path = Path.join(artifact_root, "late-write.txt")
        File.write!(late_path, "late write\n")
        send(observer, {:late_writer_finished, self(), late_path})
      end)

    send(observer, {:late_writer_started, worker, artifact_root, task_id})
    Process.sleep(:infinity)
  end

  @doc false
  def allocate_late_writer_and_fail(%{"task_id" => task_id}, failure) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

    artifact_root =
      Path.join(Arbor.Orchestrator.coding_pipeline_logs_root(), "task-" <> sha256(task_id))

    worker =
      spawn(fn ->
        Process.sleep(100)
        late_path = Path.join(artifact_root, "late-write.txt")
        File.write!(late_path, "late write after #{failure}\n")
        send(observer, {:late_failing_writer_finished, self(), late_path})
      end)

    send(observer, {:late_failing_writer_started, worker, artifact_root, task_id, failure})

    case failure do
      :raise -> raise "adapter failed after delegating worker"
      :exit -> exit(:adapter_failed_after_delegating_worker)
    end
  end

  @doc false
  def write_excluded_untracked(workdir, source) do
    filename = "excluded-untracked-#{source}.txt"
    git_common_dir = workdir |> git!(["rev-parse", "--git-common-dir"]) |> Path.expand(workdir)

    case source do
      :info_exclude ->
        exclude_path = Path.join(git_common_dir, "info/exclude")
        File.mkdir_p!(Path.dirname(exclude_path))
        File.write!(exclude_path, filename <> "\n", [:append])

      :core_excludes_file ->
        exclude_path = Path.join(git_common_dir, "benchmark-excludes")
        File.write!(exclude_path, filename <> "\n")
        git!(workdir, ["config", "--local", "core.excludesFile", exclude_path])
    end

    File.write!(Path.join(workdir, filename), "must remain visible to attestation\n")
    :ok
  end

  @doc false
  def cancel_allocated_resource(principal_id, %{"task_id" => task_id}) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    registry = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_resource_registry)

    resource =
      Agent.get_and_update(registry, fn resources ->
        Map.pop(resources, task_id)
      end)

    case resource do
      %{path: path, pid: pid, principal_id: ^principal_id} ->
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          250 -> raise "external resource process did not terminate"
        end

        File.rm_rf!(path)
        send(observer, {:external_resource_cancelled, pid, path, task_id})

        {:ok,
         %{
           worker_terminated: true,
           worker_ownership: :owned,
           cleanup: %{resources_cleaned: true, workspace_removed: true, workspace_retained: false}
         }}

      nil ->
        {:error, :resource_not_found}

      _resource ->
        {:error, :resource_principal_mismatch}
    end
  end

  def min_pipeline_execution_timeout_ms do
    Adapter.plan_min_wall_clock_ms() + Adapter.pipeline_budget_reserve_ms()
  end

  def coding_task_fields(%{"kind" => "coding_change", "plan" => plan})
      when is_map(plan) and not is_struct(plan) do
    workspace = Map.get(plan, "workspace_policy", %{})
    worker = Map.get(plan, "worker", %{})

    %{
      "acp_agent" => worker["provider"],
      "base_ref" => plan["base_ref"],
      "branch_name" => workspace["branch_name"],
      "repo_path" => plan["repo_root"],
      "task" => plan["task"],
      "worktree_base_dir" => workspace["worktree_base_dir"]
    }
  end

  def coding_task_fields(%{"kind" => "coding_change"} = task) do
    %{
      "acp_agent" => task["acp_agent"],
      "base_ref" => task["base_ref"],
      "branch_name" => task["branch_name"],
      "repo_path" => task["repo_path"],
      "task" => task["task"],
      "worktree_base_dir" => task["worktree_base_dir"]
    }
  end

  def assert_exact_inputs(request, task, context, pair_root) do
    digest = execution_digest(request)

    outer_timeout =
      Application.fetch_env!(:arbor_commands, :coding_benchmark_execution_timeout_ms)

    branch_name =
      "arbor/coding-benchmark/happy-r1-#{request["executor_path"]}-#{String.slice(digest, 0, 12)}"

    worktree_base_dir =
      Path.join([pair_root, "worktrees", request["executor_path"], digest])

    task_text =
      "Complete the happy benchmark.\n\nAcceptance criteria:\n- Write the deterministic result marker."

    case request["executor_path"] do
      "legacy" ->
        expected_validation_timeout =
          min(outer_timeout, Arbor.Shell.spawn_capable_max_timeout_ms())

        assert task == %{
                 "acp_agent" => "codex",
                 "base_ref" => request["base_commit_oid"],
                 "branch_name" => branch_name,
                 "kind" => "coding_change",
                 "open_pr" => false,
                 "repo_path" => request["workdir"],
                 "submit_review" => true,
                 "task" => task_text,
                 "validation_timeout" => expected_validation_timeout,
                 "worktree_base_dir" => worktree_base_dir
               }

        refute Map.has_key?(task, "plan")
        refute Map.has_key?(task, "budgets")
        assert task["validation_timeout"] <= Arbor.Shell.spawn_capable_max_timeout_ms()
        assert task["validation_timeout"] <= outer_timeout

      "pipeline" ->
        assert Map.keys(task) |> Enum.sort() == ["kind", "plan"]
        assert task["kind"] == "coding_change"
        plan = task["plan"]
        assert is_map(plan) and not is_struct(plan)
        assert plan["version"] == Plan.schema_version()
        assert plan["task"] == task_text
        assert plan["repo_root"] == request["workdir"]
        assert plan["base_ref"] == request["base_commit_oid"]
        assert plan["review_profile"] == "binding"
        assert plan["worker"]["provider"] == "codex"

        assert plan["workspace_policy"] == %{
                 "mode" => "isolated",
                 "branch_name" => branch_name,
                 "worktree_base_dir" => worktree_base_dir
               }

        assert plan["output"]["draft_pr"] == false

        expected_wall = outer_timeout - Adapter.pipeline_budget_reserve_ms()
        assert plan["budgets"]["wall_clock_ms"] == expected_wall
        assert expected_wall < outer_timeout
        assert expected_wall >= Adapter.plan_min_wall_clock_ms()
        assert expected_wall <= 86_400_000

        refute Map.has_key?(task, "repo_path")
        refute Map.has_key?(task, "acp_agent")
        refute Map.has_key?(task, "branch_name")
        refute Map.has_key?(task, "worktree_base_dir")
        refute Map.has_key?(task, "open_pr")
        refute Map.has_key?(task, "submit_review")
    end

    assert context == %{
             "task_id" => "coding-benchmark-#{request["executor_path"]}-#{digest}",
             "timeout" => outer_timeout
           }
  end

  def benchmark_requests!(timeout_ms \\ min_pipeline_execution_timeout_ms()) do
    workspace = temp_directory!("coding-benchmark-adapter")
    source = Path.join(workspace, "source")
    pair_root = Path.join(workspace, "direct-pair")
    File.mkdir_p!(source)
    File.mkdir_p!(pair_root)
    git!(source, ["init", "--quiet"])
    File.write!(Path.join(source, "README.md"), "benchmark\n")
    git!(source, ["add", "--", "README.md"])
    commit!(source, "base")

    for executor <- ~w(legacy pipeline) do
      git_clone!(source, Path.join(pair_root, executor))
    end

    configure_runtime!(workspace, timeout_ms)
    input = benchmark_input()
    base_commit_oid = git!(source, ["rev-parse", "HEAD"])
    base_tree_oid = git!(source, ["rev-parse", "HEAD^{tree}"])
    normalized_input_hash = normalized_input_hash!(input, base_tree_oid)

    request = fn executor ->
      %{
        "acp_agent" => "codex",
        "base_commit_oid" => base_commit_oid,
        "base_tree_oid" => base_tree_oid,
        "executor_path" => executor,
        "fixture_id" => "happy",
        "normalized_input" => input,
        "normalized_input_hash" => normalized_input_hash,
        "repetition" => 1,
        "schema" => "arbor.coding_benchmark.adapter_request.v1",
        "seed" => 7,
        "workdir" => Path.join(pair_root, executor)
      }
    end

    %{
      legacy: request.("legacy"),
      pair_root: pair_root,
      pipeline: request.("pipeline"),
      timeout_ms: timeout_ms
    }
  end

  def production_scenario!(
        timeout_ms \\ @successful_fixture_execution_timeout_ms,
        cancellation_timeout_ms \\ 500
      ) do
    root = temp_directory!("coding-benchmark-production")
    scenario = Scenario.create!(root, ["happy"])
    artifact_root = configure_runtime!(root, timeout_ms, cancellation_timeout_ms)
    Map.put(scenario, :artifact_root, artifact_root)
  end

  def configure_runtime!(root, timeout_ms, cancellation_timeout_ms \\ 500) do
    {:ok, workspace_root} = SafePath.resolve_real(root)
    artifact_root = Path.join(workspace_root, "production-artifacts")
    File.mkdir_p!(artifact_root)
    {:ok, artifact_root} = SafePath.resolve_real(artifact_root)

    Application.put_env(:arbor_commands, :coding_benchmark_workspace_root, workspace_root)
    Application.put_env(:arbor_commands, :coding_benchmark_artifact_root, artifact_root)
    Application.put_env(:arbor_commands, :coding_benchmark_execution_timeout_ms, timeout_ms)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_cancellation_timeout_ms,
      cancellation_timeout_ms
    )

    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_worktree_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, artifact_root)
    artifact_root
  end

  def install_capturing_executors do
    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      CapturingLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      CapturingPipelineExecutor
    )
  end

  def install_leased_executors do
    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      LeasedLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      LeasedPipelineExecutor
    )
  end

  def run_production_scenario(scenario, opts \\ []) do
    defaults = [
      acp_agent: "codex",
      adapters: %{"legacy" => LegacyAdapter, "pipeline" => PipelineAdapter},
      executor_selector: false,
      fixture_root: scenario.root,
      measure: &Scenario.deterministic_measure/1,
      verifiers: Scenario.verifiers(),
      workspace_root: scenario.root
    ]

    CodingBenchmark.run(scenario.manifest, Keyword.merge(defaults, opts))
  end

  defp leased_result(
         executor,
         principal_id,
         task,
         context,
         artifact_mode,
         commit_mode \\ :descendant
       ) do
    fields = coding_task_fields(task)
    observe_fixture_repository(executor, fields["repo_path"])

    {:ok, worktree} =
      Arbor.Orchestrator.expected_coding_worktree_path(
        fields["worktree_base_dir"],
        fields["branch_name"]
      )

    git!(fields["repo_path"], [
      "worktree",
      "add",
      "--quiet",
      "-b",
      fields["branch_name"],
      worktree,
      fields["base_ref"]
    ])

    File.write!(Path.join(worktree, "result.txt"), "completed:happy\n")
    git!(worktree, ["add", "--", "result.txt"])
    commit!(worktree, "benchmark result")

    if commit_mode in [:unrelated, :replacement] do
      git!(worktree, ["checkout", "--quiet", "--orphan", fields["branch_name"] <> "-orphan"])
      git!(worktree, ["rm", "-rf", "--quiet", "."])
      File.write!(Path.join(worktree, "result.txt"), "completed:happy\n")
      git!(worktree, ["add", "--", "result.txt"])
      commit!(worktree, "unrelated benchmark result")
      git!(worktree, ["branch", "-M", fields["branch_name"]])
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

      if commit_mode == :unrelated do
        commit_line = git!(worktree, ["rev-list", "--parents", "-n", "1", "HEAD"])
        send(observer, {:unrelated_commit_observed, executor, commit_line})
      else
        physical = git!(worktree, ["rev-parse", "HEAD"])

        replacement =
          git!(worktree, [
            "-c",
            "user.name=Arbor Benchmark",
            "-c",
            "user.email=benchmark@arbor.local",
            "commit-tree",
            "#{physical}^{tree}",
            "-p",
            fields["base_ref"],
            "-m",
            "forged replacement ancestry"
          ])

        git!(worktree, ["replace", physical, replacement])
        send(observer, {:replacement_ancestry_observed, executor, physical, replacement})
      end
    end

    {artifacts, artifact_root} =
      if executor == :pipeline,
        do: production_artifacts(task, context, artifact_mode),
        else: {%{}, nil}

    if artifact_mode == :lease_marker_tamper and is_binary(artifact_root) do
      File.write!(Path.join(artifact_root, ".benchmark-lease"), "forged worker marker")
    end

    production_result(executor, principal_id, task, context, worktree, artifacts, artifact_root)
  end

  defp observe_fixture_repository(executor, repo_path) do
    config = File.read!(Path.join(repo_path, ".git/config"))

    facts = %{
      alternates?: File.exists?(Path.join(repo_path, ".git/objects/info/alternates")),
      hook?: File.exists?(Path.join(repo_path, ".git/hooks/post-checkout")),
      ignored?: File.exists?(Path.join(repo_path, "ignored-secret")),
      shallow?: File.exists?(Path.join(repo_path, ".git/shallow")),
      source_config?: String.contains?(config, "benchmark")
    }

    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    send(observer, {:fixture_repository_observed, executor, facts})
  end

  defp symlink_worktree_result(executor, principal_id, task, context, outside) do
    fields = coding_task_fields(task)

    {:ok, worktree} =
      Arbor.Orchestrator.expected_coding_worktree_path(
        fields["worktree_base_dir"],
        fields["branch_name"]
      )

    File.ln_s!(outside, worktree)
    production_result(executor, principal_id, task, context, worktree, %{}, nil)
  end

  defp wrong_worktree_result(executor, principal_id, task, context) do
    fields = coding_task_fields(task)
    worktree = Path.join(fields["worktree_base_dir"], "unexpected-descendant")

    git!(fields["repo_path"], [
      "worktree",
      "add",
      "--quiet",
      "-b",
      fields["branch_name"],
      worktree,
      fields["base_ref"]
    ])

    production_result(executor, principal_id, task, context, worktree, %{}, nil)
  end

  defp wrong_branch_result(executor, principal_id, task, context) do
    fields = coding_task_fields(task)
    worktree = Path.join(fields["worktree_base_dir"], "wrong-branch")

    git!(fields["repo_path"], [
      "worktree",
      "add",
      "--quiet",
      "-b",
      "benchmark-wrong-branch",
      worktree,
      fields["base_ref"]
    ])

    production_result(executor, principal_id, task, context, worktree, %{}, nil)
  end

  defp production_result(
         executor,
         principal_id,
         task,
         context,
         worktree,
         artifacts,
         artifact_root
       ) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

    send(
      observer,
      {:production_executor_call, Atom.to_string(executor), principal_id, task, context, worktree,
       artifact_root}
    )

    {:ok, coding_result(executor, task, worktree, artifacts)}
  end

  defp coding_result(executor, task, worktree, artifacts) do
    fields = coding_task_fields(task)

    %{
      "artifacts" => artifacts,
      "branch" => fields["branch_name"],
      "commit" => if(worktree, do: git!(worktree, ["rev-parse", "HEAD"]), else: nil),
      "files" => ["result.txt"],
      "metrics" => %{
        "execution_path" => Atom.to_string(executor),
        "total_rework_count" => 0,
        "validation_attempts" => 1
      },
      "repo_path" => fields["repo_path"],
      "review" => %{
        "blast_radius" => "low",
        "human_required" => false,
        "recommendation" => "keep",
        "security_veto" => false,
        "tier_decision" => "auto_proceed"
      },
      "status" => "change_committed",
      "validation" => [%{"passed" => true}]
    }
    |> maybe_put_worktree(worktree)
  end

  defp maybe_put_worktree(result, nil), do: result
  defp maybe_put_worktree(result, worktree), do: Map.put(result, "worktree_path", worktree)

  defp production_artifacts(task, context, mode) do
    logs_root = Arbor.Orchestrator.coding_pipeline_logs_root()
    root = Path.join(logs_root, "task-" <> sha256(context["task_id"]))
    File.mkdir_p!(root)

    dot_path = Path.join(root, "coding-pipeline.dot")
    plan_path = Path.join(root, "coding-plan.json")
    manifest_path = Path.join(root, "coding-compile-manifest.json")
    plan = production_plan!(task)
    assert {:ok, compilation} = Arbor.Orchestrator.compile_coding_plan(plan)
    dot = compilation["dot_source"]
    manifest = compilation["manifest"]
    assert manifest["action_names"] != []
    assert manifest["handler_types"] != []
    assert manifest["execution_manifest"]["actions"] != []
    assert manifest["execution_manifest"]["nodes"] != []

    archived_dot = if mode == :tampered_dot, do: dot <> "\n// post-compile tamper\n", else: dot
    File.write!(dot_path, archived_dot)

    fields = coding_task_fields(task)

    case mode do
      :symlink -> File.ln_s!(Path.join(fields["repo_path"], "README.md"), plan_path)
      _other -> File.write!(plan_path, Jason.encode!(plan, pretty: true))
    end

    manifest =
      if mode == :invalid_manifest, do: Map.delete(manifest, "plan_version"), else: manifest

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    artifacts = %{
      "coding_pipeline_path" => dot_path,
      "coding_plan_path" => plan_path,
      "compile_manifest_path" => manifest_path,
      "compiler_version" => compilation["compiler_version"],
      "graph_hash" => compilation["graph_hash"]
    }

    artifacts =
      case mode do
        {:artifact_transform, transform} when is_function(transform, 2) ->
          transform.(artifacts, root)

        _other ->
          artifacts
      end

    {artifacts, root}
  end

  def run_production_artifact_case(transform) do
    scenario = production_scenario!()
    install_leased_executors()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_test_mode,
      {:artifact_transform, transform}
    )

    assert {:ok, report} = run_production_scenario(scenario)
    report
  end

  @doc false
  def assert_optional_artifact_accepted(transform) when is_function(transform, 2) do
    report = run_production_artifact_case(transform)
    verification = row(report, "pipeline")["artifact_hash_verification"]

    assert verification["graph_hash_verified"] == true
    assert verification["status"] == "passed"
    assert report["summary"]["equivalent_pairs"] == 1
    assert hd(report["pairs"])["comparison"]["status"] == "equivalent"
    report
  end

  @doc false
  def assert_optional_artifact_rejected(transform) when is_function(transform, 2) do
    verification =
      transform
      |> run_production_artifact_case()
      |> row("pipeline")
      |> Map.fetch!("artifact_hash_verification")

    assert verification["graph_hash_verified"] == false
    assert verification["status"] == "failed"
    verification
  end

  # Descriptor-schema mutations exercise the public production gate without
  # cloning fixtures or compiling coding plans. Root is a synthetic absolute
  # path only; no filesystem materialization is required for the envelope check.
  @descriptor_evidence_root "/tmp/arbor-coding-benchmark-descriptor-evidence"

  @doc false
  def baseline_pipeline_artifact_descriptors(root \\ @descriptor_evidence_root)
      when is_binary(root) do
    %{
      "coding_plan_path" => Path.join(root, "coding-plan.json"),
      "coding_pipeline_path" => Path.join(root, "coding-pipeline.dot"),
      "compile_manifest_path" => Path.join(root, "coding-compile-manifest.json"),
      "compiler_version" => "test-compiler",
      "graph_hash" => String.duplicate("a", 64)
    }
  end

  @doc false
  def synthetic_transcript_descriptor(root \\ @descriptor_evidence_root)
      when is_binary(root) do
    path = Path.join(root, "acp-transcript.json")
    content = Jason.encode!(%{"schema_version" => 1})

    %{
      "path" => path,
      "sha256" => sha256(content),
      "byte_size" => byte_size(content),
      "turns_retained" => 2,
      "turns_seen" => 3,
      "turns_omitted" => 1,
      "turns_truncated" => true,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => "coding-benchmark-pipeline-transcript"
    }
  end

  @doc false
  def assert_pipeline_artifact_descriptors_accepted(transform)
      when is_function(transform, 2) do
    root = @descriptor_evidence_root
    artifacts = transform.(baseline_pipeline_artifact_descriptors(root), root)

    assert {:ok, provenance} = CodingBenchmark.validate_pipeline_artifact_descriptors(artifacts)
    assert Map.has_key?(provenance, "graph_hash")
    assert Map.has_key?(provenance, "coding_pipeline_path")
    refute Map.has_key?(provenance, "workspace_release")
    refute Map.has_key?(provenance, "acp_transcript")
    provenance
  end

  @doc false
  def assert_pipeline_artifact_descriptors_rejected(transform)
      when is_function(transform, 2) do
    root = @descriptor_evidence_root
    artifacts = transform.(baseline_pipeline_artifact_descriptors(root), root)

    assert {:error, :invalid_artifact_descriptors} =
             CodingBenchmark.validate_pipeline_artifact_descriptors(artifacts)

    :ok
  end

  def valid_transcript_descriptor(root) do
    path = Path.join(root, "acp-transcript.json")
    content = Jason.encode!(%{"schema_version" => 1})
    File.write!(path, content)

    %{
      "path" => path,
      "sha256" => sha256(content),
      "byte_size" => byte_size(content),
      "turns_retained" => 2,
      "turns_seen" => 3,
      "turns_omitted" => 1,
      "turns_truncated" => true,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => "coding-benchmark-pipeline-transcript"
    }
  end

  defp production_plan!(%{"kind" => "coding_change", "plan" => plan})
       when is_map(plan) and not is_struct(plan) do
    assert {:ok, normalized} = Plan.new(plan)
    Plan.to_map(normalized)
  end

  defp production_plan!(task) do
    fields = coding_task_fields(task)

    assert {:ok, plan} =
             Plan.new(%{
               "base_ref" => fields["base_ref"],
               "repo_root" => fields["repo_path"],
               "task" => fields["task"],
               "worker" => %{"provider" => fields["acp_agent"]},
               "workspace_policy" => %{
                 "branch_name" => fields["branch_name"],
                 "mode" => "isolated",
                 "worktree_base_dir" => fields["worktree_base_dir"]
               }
             })

    Plan.to_map(plan)
  end

  defp normalized_input_hash!(input, base_tree_oid) do
    manifest = %{
      "fixtures" => [
        %{
          "base_tree_oid" => base_tree_oid,
          "fixture_id" => "happy",
          "fixture_path" => "fixture",
          "input" => input,
          "verifier_id" => "scripted_objective"
        }
      ],
      "schema" => CodingBenchmark.manifest_schema(),
      "seed" => 7
    }

    assert {:ok, normalized} = CodingBenchmark.validate_manifest(manifest)
    normalized |> Map.fetch!("fixtures") |> hd() |> Map.fetch!("normalized_input_hash")
  end

  defp benchmark_input do
    %{
      "acceptance_criteria" => ["Write the deterministic result marker."],
      "objective" => "Complete the happy benchmark."
    }
  end

  def row(report, executor) do
    Enum.find(report["rows"], &(&1["executor_path"] == executor))
  end

  def execution_digest(request) do
    hash_json(%{
      "base_commit_oid" => request["base_commit_oid"],
      "executor_path" => request["executor_path"],
      "fixture_id" => request["fixture_id"],
      "normalized_input_hash" => request["normalized_input_hash"],
      "repetition" => request["repetition"],
      "seed" => request["seed"]
    })
  end

  def temp_directory!(prefix) do
    path = CodingBenchmarkTempRoot.create!(prefix)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp reply_key(:legacy), do: :coding_benchmark_legacy_test_reply
  defp reply_key(:pipeline), do: :coding_benchmark_pipeline_test_reply

  defp fetch_env({app, key}), do: Application.fetch_env(app, key)

  defp restore_env({app, key}, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env({app, key}, :error), do: Application.delete_env(app, key)

  defp commit!(repo, message) do
    git!(repo, [
      "-c",
      "user.name=Arbor Benchmark",
      "-c",
      "user.email=benchmark@arbor.local",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git_clone!(source, destination) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["clone", "--quiet", "--no-hardlinks", "--", source, destination],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> raise "git clone failed (#{status}): #{output}"
    end
  end

  def git!(workdir, args) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end

  defp hash_json(value), do: value |> canonical_json() |> IO.iodata_to_binary() |> sha256()

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Jason.encode_to_iodata!(value)

  defp canonical_json(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode_to_iodata!(key), ":", canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end
end
