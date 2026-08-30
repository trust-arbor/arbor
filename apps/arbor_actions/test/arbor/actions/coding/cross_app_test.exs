defmodule Arbor.Actions.Coding.CrossAppTest do
  use Arbor.Actions.ActionCase, async: false

  import Bitwise

  alias Arbor.Actions
  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CrossApp.Core

  alias Arbor.Actions.Coding.CrossApp.ProgressCore
  alias Arbor.Actions.Coding.CrossApp.Shell
  alias Arbor.Actions.Coding.CrossApp.StaticReceiptBoundary
  alias Arbor.Actions.Coding.CrossApp.Validate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Actions.TestLinuxBaselineMaterializer

  @moduletag :slow

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    # TestMixShell keeps this suite hermetic and independent of host Apple
    # Container admission. Production execute_spawn_capable is wired and
    # fails closed only when request/admission/containment checks fail.
    previous_shell = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    # Exercise the real MixAction path so validation-resource build/dependency
    # projections remain covered. TestMixShell supplies only the reviewed wrapper
    # resolver and process execution seam.
    previous_runner = Application.get_env(:arbor_actions, :cross_app_mix_runner)
    Application.delete_env(:arbor_actions, :cross_app_mix_runner)

    on_exit(fn ->
      if is_nil(previous_shell) do
        Application.delete_env(:arbor_actions, :mix_shell_module)
      else
        Application.put_env(:arbor_actions, :mix_shell_module, previous_shell)
      end

      if is_nil(previous_runner) do
        Application.delete_env(:arbor_actions, :cross_app_mix_runner)
      else
        Application.put_env(:arbor_actions, :cross_app_mix_runner, previous_runner)
      end
    end)

    :ok
  end

  test "discovery, name resolution, and canonical URI" do
    assert Validate in Actions.list_actions().coding
    assert Validate.name() == "coding_cross_app_validate"
    assert {:ok, Validate} = Actions.name_to_module("coding_cross_app_validate")
    assert {:ok, Validate} = Actions.name_to_module("coding.cross_app.validate")

    assert Actions.canonical_uri_for(Validate, %{}) ==
             "arbor://action/coding/cross_app/validate"
  end

  test "closed action input accepts only the reviewed timeout controls" do
    # Action schema declares the per-child and aggregate budgets as controls.
    schema_keys = Keyword.keys(Validate.schema())

    assert :workspace_id in schema_keys
    assert :timeout in schema_keys
    assert :stage_timeout in schema_keys
    assert :test_stage_timeout in schema_keys
    refute :progress in schema_keys
    refute :cross_app_progress in schema_keys
    refute :cross_app_progress_binding in schema_keys

    tool_inspect = inspect(Validate.to_tool())
    refute tool_inspect =~ "cross_app_progress"
    refute tool_inspect =~ "cross_app_progress_binding"

    # Closed Core surface: only workspace_id and the three timeout controls.
    assert {:ok, input} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               timeout: 10_000,
               stage_timeout: 15_000,
               test_stage_timeout: 20_000
             })

    assert input.timeout == 10_000
    assert input.stage_timeout == 15_000
    assert input.test_stage_timeout == 20_000

    assert {:error, :unsupported_parameter} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               timeout: 10_000,
               stage_timeout: 15_000,
               test_stage_timeout: 20_000,
               extra: true
             })

    assert {:error, :unsupported_parameter} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               continuation_execution: %{"window" => %{}, "receipt" => %{}}
             })

    assert {:error, :invalid_test_stage_timeout} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               test_stage_timeout: 4_200_001
             })

    # Aggregate stage may exceed the intensive per-process ceiling.
    assert {:ok, %{test_stage_timeout: 1_800_000}} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               test_stage_timeout: 1_800_000
             })

    assert Arbor.Actions.cross_app_maximum_test_stage_timeout_ms() == 4_200_000

    # Whole-validation budget includes three pre-test children in addition to
    # the test-stage ceiling, so it is intentionally larger.
    assert {:ok, %{stage_timeout: 4_200_001}} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               stage_timeout: 4_200_001
             })

    maximum_stage_timeout = Arbor.Actions.cross_app_maximum_stage_timeout_ms()

    assert maximum_stage_timeout >
             Arbor.Actions.cross_app_maximum_test_stage_timeout_ms()

    assert {:error, :invalid_stage_timeout} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               stage_timeout: maximum_stage_timeout + 1
             })

    # cross_app binds the intensive Shell ceiling (1_200_000) for per-op only;
    # values above the standard 600_000 ms path are accepted and fail only
    # above intensive.
    assert {:ok, %{timeout: 600_001}} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               timeout: 600_001
             })

    assert {:error, :invalid_timeout} =
             Arbor.Actions.Coding.CrossApp.Core.new(%{
               workspace_id: "ws_closed",
               timeout: 1_200_001
             })
  end

  test "enforces lease authority: opaque workspace_id alone is not enough", %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)
    workspace_id = fixture.lease.workspace_id
    parent = self()

    # A foreign process with only the opaque id (no owner pid, no matching
    # task_id+principal) must not resolve the live workspace.
    foreign =
      spawn(fn ->
        result = Validate.run(%{workspace_id: workspace_id}, %{})
        send(parent, {:foreign_result, result})
      end)

    ref = Process.monitor(foreign)

    assert_receive {:foreign_result, {:error, reason}}, 5_000

    assert reason in [
             :workspace_unauthorized,
             :unauthorized,
             :not_authorized,
             :workspace_not_found
           ]

    assert_receive {:DOWN, ^ref, :process, ^foreign, _}, 1_000

    # Owner-process callers with a mismatched task_id still resolve via owner
    # pid; a non-owner process with wrong task+principal must not.
    foreign_task =
      spawn(fn ->
        result =
          Validate.run(
            %{workspace_id: workspace_id},
            %{task_id: "wrong-task", agent_id: "wrong-agent"}
          )

        send(parent, {:foreign_task_result, result})
      end)

    ref2 = Process.monitor(foreign_task)
    assert_receive {:foreign_task_result, {:error, wrong_task_reason}}, 5_000

    assert wrong_task_reason in [
             :workspace_unauthorized,
             :unauthorized,
             :not_authorized,
             :workspace_not_found
           ]

    assert_receive {:DOWN, ^ref2, :process, ^foreign_task, _}, 1_000

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{
                 workspace_id: workspace_id,
                 path: fixture.lease.worktree_path
               },
               fixture.context
             )

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{
                 workspace_id: workspace_id,
                 base_commit: fixture.lease.base_commit
               },
               fixture.context
             )
  end

  test "selects downstream app tests for a two-app fixture and returns bounded evidence", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_umbrella(tmp_dir)
    Arbor.Actions.TestMixShell.clear_last_seed_destination()

    # Change only alpha (behavior-preserving) — beta depends on alpha so both
    # apps' tests should be selected and still pass.
    alpha_lib = Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex")

    File.write!(alpha_lib, """
    defmodule Alpha do
      @moduledoc "alpha"
      def value, do: 1
      def tag, do: :alpha
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 timeout: 180_000,
                 test_stage_timeout: 360_000
               },
               fixture.context
             )

    assert result.passed
    assert result.reason == "cross_app_validated"
    assert "apps/alpha/lib/alpha.ex" in result.changed_files
    assert result.changed_apps == ["alpha"]
    assert result.affected_apps == ["alpha", "beta"]
    assert result.test_paths == ["apps/alpha/test", "apps/beta/test"]
    assert result.compile["passed"]
    assert result.xref["passed"]
    assert result.test_compile["passed"]
    assert result.test["passed"]
    assert is_binary(result.feedback_json)
    assert Jason.decode!(result.feedback_json)["passed"] == true

    seed_destination = Arbor.Actions.TestMixShell.last_seed_destination()
    assert is_binary(seed_destination)
    assert Path.type(seed_destination) == :absolute
    assert Path.basename(seed_destination) == "build"
    refute File.exists?(seed_destination)

    # Does not claim zero-cycle validation.
    refute Map.has_key?(result, :cycles)
    refute Map.has_key?(result, "cycles")
  end

  test "security regression: CrossApp emits validated_tree_oid and rejects validation-time mutation",
       %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)
    worktree = fixture.lease.worktree_path

    File.write!(Path.join(worktree, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def value, do: 1
      def tree_probe, do: :ok
    end
    """)

    previous_runner = Application.get_env(:arbor_actions, :cross_app_mix_runner)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, _args, _opts ->
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    on_exit(fn ->
      if is_nil(previous_runner) do
        Application.delete_env(:arbor_actions, :cross_app_mix_runner)
      else
        Application.put_env(:arbor_actions, :cross_app_mix_runner, previous_runner)
      end
    end)

    assert {:ok, before_binding} = Arbor.Actions.Mix.committable_tree_binding(worktree)

    assert {:ok, result} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 timeout: 180_000,
                 test_stage_timeout: 360_000
               },
               fixture.context
             )

    tree_oid = Map.get(result, :validated_tree_oid) || Map.get(result, "validated_tree_oid")
    assert is_binary(tree_oid) and tree_oid != ""
    assert tree_oid == before_binding.tree_oid
    assert Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, tree_oid)

    # Mutation during the aggregate validation window fails closed.
    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn path, args, _opts ->
      if args == MixAction.compile_argv(%{warnings_as_errors: true}) do
        File.write!(Path.join(path, "validation_mutated.txt"), "mutated during validation\n")
      end

      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    assert {:error, :validation_tree_mutated} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)
  end

  test "forwards the validated timeout to dependency resource setup", %{tmp_dir: tmp_dir} do
    TestLinuxBaselineMaterializer.reset_seams()
    fixture = leased_umbrella(tmp_dir)

    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def value, do: 1
      def timeout_probe, do: :ok
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 timeout: 500_000,
                 test_stage_timeout: 1_000_000
               },
               fixture.context
             )

    assert result.passed

    setup_budget = TestLinuxBaselineMaterializer.last_acquire_deadline_ms()
    assert is_integer(setup_budget)
    assert setup_budget > 450_000
    assert setup_budget <= 500_000
  end

  test "compile failure skips xref and tests and returns passed false", %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)

    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def broken, do: %{}
    end
    """)

    # Introduce a compile error
    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/broken.ex"), """
    defmodule Alpha.Broken do
      def oops, do: NoSuchModule.nowhere()
    end
    """)

    # Actually use syntax error for reliable compile fail:
    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/broken.ex"), """
    defmodule Alpha.Broken do
      def oops do
    end
    """)

    assert {:ok, result} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    refute result.passed
    assert result.reason == "compile_failed"
    refute result.compile["passed"]
    assert result.xref["status"] == "skipped"
    assert result.test_compile["status"] == "skipped"
    assert result.test["status"] == "skipped"
    assert result.xref["reason"] == "compile_failed"
    assert result.test_compile["reason"] == "compile_failed"
  end

  test "test failure returns passed false after compile, xref, and test compile", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_umbrella(tmp_dir)

    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def value, do: 99
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 timeout: 180_000,
                 test_stage_timeout: 360_000
               },
               fixture.context
             )

    refute result.passed
    assert result.compile["passed"]
    assert result.xref["passed"]
    assert result.test_compile["passed"]
    refute result.test["passed"]
    assert result.reason == "tests_failed"
  end

  test "seed window with trusted MFA runs static stages then first original batches", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      successful_mix()
    end)

    context = seed_context(fixture.context, bundle)
    assert StaticReceiptBoundary.state(context) == :ready

    assert {:ok, observation} = Validate.run(bundle.params, context)
    assert observation["disposition_type"] in ["capacity_handoff", "completed"]
    assert is_map(observation["progress"])
    assert is_map(observation["progress_binding"])

    digest = observation["progress_binding"]["static_stage_receipt_digest"]
    assert is_binary(digest) and byte_size(digest) == 64

    assert_receive {:mix, compile_args}
    assert hd(compile_args) == "compile"
  end

  test "seed/progress-window test failure retains bounded diagnostic in feedback_json", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 0)

    diagnostic =
      """
      Compiling 4 files (.ex)
      Generated alpha app
      Running ExUnit with seed: 4242, max_cases: 1

      .

        1) test value is one (AlphaTest)
           Assertion with == failed
           code:  assert Alpha.value() == 1
           left:  99
           right: 1

      Finished in 0.04 seconds
      1 test, 1 failure
      """

    put_cross_app_runner!(fn _path, args, _opts ->
      case args do
        ["test", "--no-deps-check", "--" | _] ->
          {:ok, %{exit_code: 1, stdout: diagnostic, stderr: "", timed_out: false}}

        _other ->
          successful_mix()
      end
    end)

    context = seed_context(fixture.context, bundle)
    assert {:ok, result} = Validate.run(bundle.params, context)
    assert result["schema_version"] == 1
    assert result["disposition_type"] == "failed"
    assert result["passed"] == false
    assert result["reason"] == "tests_failed"
    assert is_binary(result["feedback_json"])
    refute Map.has_key?(result, "progress")
    refute Map.has_key?(result, "planned_batches")
    refute Map.has_key?(result, "test_paths")
    refute Map.has_key?(result, "changed_files")

    decoded = Jason.decode!(result["feedback_json"])
    assert decoded["exit_code"] == 1
    assert decoded["passed"] == false
    assert decoded["reason"] == "tests_failed"
    assert decoded["stdout_excerpt"] =~ "Assertion with == failed"
    assert decoded["stdout_excerpt"] =~ "left:  99"
    assert decoded["stdout_excerpt"] =~ "[batch-"
    assert [_, label] = Regex.run(~r/\[(batch-[^\]]+)\]/, decoded["stdout_excerpt"])
    assert label =~ ~r/\Abatch-\d+-of-\d+-n\d+-[0-9a-f]{64}\z/
    assert decoded["stdout_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert decoded["stderr_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    refute decoded["stdout_sha256"] == empty_sha256()
    refute Map.has_key?(decoded, "planned_batches")
    refute Map.has_key?(decoded, "test_paths")
    refute Map.has_key?(decoded, "paths")
    refute result["feedback_json"] =~ "planned_batches"

    stdout_digest = sha256_hex(diagnostic)
    stderr_digest = sha256_hex("")
    assert decoded["stdout_sha256"] == sha256_hex(label <> "\n" <> stdout_digest)
    assert decoded["stderr_sha256"] == sha256_hex(label <> "\n" <> stderr_digest)

    window = window_context(fixture.context, bundle)
    assert {:ok, progress_result} = Validate.run(bundle.params, window)
    assert progress_result["disposition_type"] == "failed"
    assert progress_result["reason"] == "tests_failed"
    progress_decoded = Jason.decode!(progress_result["feedback_json"])
    assert progress_decoded["stdout_excerpt"] =~ "Assertion with == failed"
    assert progress_decoded["stdout_sha256"] == decoded["stdout_sha256"]
  end

  test "ordinary absence with no static-receipt boundary signal still runs Mix", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      successful_mix()
    end)

    assert StaticReceiptBoundary.state(fixture.context) == :absent
    assert StaticReceiptBoundary.state(%{}) == :absent
    assert StaticReceiptBoundary.state(nil) == :absent

    assert {:ok, ordinary} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    assert ordinary.passed
    assert_receive {:mix, ["compile", "--warnings-as-errors"]}
    assert_receive {:mix, ["xref", "graph", "--no-deps-check"]}
    assert_receive {:mix, ["compile", "--warnings-as-errors"]}
    refute_receive {:unexpected_mix, _}, 25
  end

  test "invalid initial static-receipt boundary fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    invalid_contexts = [
      Map.put(
        fixture.context,
        :cross_app_static_receipt_boundary_error,
        :invalid_trusted_cross_app_static_receipt_boundary
      ),
      Map.put(
        fixture.context,
        "cross_app_static_receipt_boundary_error",
        :invalid_trusted_cross_app_static_receipt_boundary
      ),
      Map.put(
        fixture.context,
        :cross_app_static_receipt_sink,
        {__MODULE__.FakeReceiptStore, :archive, []}
      ),
      Map.put(
        fixture.context,
        :cross_app_static_receipt_source,
        {__MODULE__.FakeReceiptStore, :read, []}
      ),
      Map.put(fixture.context, :cross_app_static_receipt_sink, {:not_a_module, "archive", []}),
      Map.put(fixture.context, :cross_app_static_receipt_sink, nil),
      Map.put(fixture.context, "cross_app_static_receipt_source", nil),
      fixture.context
      |> Map.put(:cross_app_static_receipt_sink, {__MODULE__.FakeReceiptStore, :archive, []})
      |> Map.put(:cross_app_static_receipt_source, {__MODULE__.FakeReceiptStore, :read, []})
      |> Map.put(
        :cross_app_static_receipt_boundary_error,
        :invalid_trusted_cross_app_static_receipt_boundary
      ),
      fixture.context
      |> Map.put("cross_app_progress", "")
      |> Map.put("cross_app_progress_binding", "")
      |> Map.put(
        :cross_app_static_receipt_boundary_error,
        :invalid_trusted_cross_app_static_receipt_boundary
      )
    ]

    Enum.each(invalid_contexts, fn context ->
      assert StaticReceiptBoundary.state(context) == :invalid

      assert {:error, :invalid_trusted_cross_app_static_receipt_boundary} =
               Validate.run(bundle.params, context)
    end)

    refute_receive {:unexpected_mix, _}, 25
  end

  test "progress window starts at first missing original batch and returns a token-free observation",
       %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      successful_mix()
    end)

    context = window_context(fixture.context, bundle)

    assert {:ok, observation} = Validate.run(bundle.params, context)
    assert observation["schema_version"] == 1
    assert observation["disposition_type"] == "completed"
    assert observation["progress_status"] == "completed"
    assert observation["passed"] == true
    refute Map.has_key?(observation, "new_receipts")
    assert observation["progress"]["status"] == "completed"
    assert observation["progress"]["next_batch_index"] == 3

    assert observation["progress"]["passed_receipts"] ==
             Enum.map(bundle.compact_plan, &Map.put(&1, "outcome", "passed"))

    assert_receive {:mix, ["test", "--no-deps-check", "--", "apps/beta/test/beta_test.exs"]}
    refute_receive {:mix, _}, 25
    encoded = Jason.encode!(observation)
    refute encoded =~ "fence_token"
    refute encoded =~ "authority"
    refute encoded =~ "capability"
    refute encoded =~ "credential"
    refute Map.has_key?(observation, "continuation_id")
    refute encoded =~ "fence_token"
  end

  test "returned capacity progress is admitted by the next window at the next original batch",
       %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()
    started = :counters.new(1, [])

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      if :counters.get(started, 1) == 0, do: 0, else: 600_000
    end)

    on_exit(fn -> Application.delete_env(:arbor_actions, :cross_app_monotonic_ms) end)

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      :counters.add(started, 1, 1)
      successful_mix()
    end)

    context = window_context(fixture.context, bundle)

    assert {:ok, first} = Validate.run(bundle.params, context)
    assert first["disposition_type"] == "capacity_handoff"
    assert first["progress_status"] == "in_progress"
    refute Map.has_key?(first, "passed")
    refute Map.has_key?(first, "new_receipts")
    assert first["progress"]["status"] == "in_progress"
    assert first["progress"]["next_batch_index"] == 2
    assert first["progress"]["completed_batch_count"] == 1
    assert is_map(first["progress"]["capacity"])
    refute Map.has_key?(first["progress"]["capacity"], "unstarted_batches")

    assert_receive {:mix, ["test", "--no-deps-check", "--", "apps/alpha/test/alpha_test.exs"]}
    refute_receive {:mix, _}, 25

    Application.delete_env(:arbor_actions, :cross_app_monotonic_ms)

    next_context = Map.put(context, "cross_app_progress", first["progress"])
    assert {:ok, second} = Validate.run(bundle.params, next_context)
    assert second["disposition_type"] == "completed"
    assert second["passed"] == true
    assert second["progress"]["status"] == "completed"
    assert second["progress"]["next_batch_index"] == 3
    refute Map.has_key?(second, "new_receipts")

    assert_receive {:mix, ["test", "--no-deps-check", "--", "apps/beta/test/beta_test.exs"]}
    refute_receive {:mix, _}, 25
    encoded = Jason.encode!(first)
    refute encoded =~ "fence_token"
    refute encoded =~ "unstarted_batches"
  end

  test "nil-frontier residual exhaustion is a structural handoff and launches no Mix tests", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()
    calls = :counters.new(1, [])

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      :ok = :counters.add(calls, 1, 1)
      count = :counters.get(calls, 1)
      if count <= 1, do: 0, else: 5_000_000
    end)

    on_exit(fn -> Application.delete_env(:arbor_actions, :cross_app_monotonic_ms) end)

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      successful_mix()
    end)

    context = window_context(fixture.context, bundle)
    assert {:ok, observation} = Validate.run(bundle.params, context)
    assert observation["disposition_type"] == "capacity_handoff"
    assert observation["progress"]["capacity"]["phase"] == "structural"
    assert observation["progress"]["capacity"]["interrupted_batch"] == nil
    assert observation["progress"]["refinement"] == nil
    assert observation["progress"]["passed_receipts"] == []

    mix_calls =
      Stream.repeatedly(fn ->
        receive do
          {:mix, args} -> args
        after
          25 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    refute Enum.any?(mix_calls, &(hd(&1) == "test"))
  end

  test "tampered resumed progress fails closed before Mix and does not emit passed", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    context = window_context(fixture.context, bundle)

    tampered_digest =
      put_in(bundle.progress, ["passed_receipts_digest"], String.duplicate("0", 64))

    assert {:error, reason} =
             Validate.run(
               bundle.params,
               Map.put(context, "cross_app_progress", tampered_digest)
             )

    assert reason in [:malformed_state, :receipt_prefix_drift]

    forged_completed =
      bundle.progress
      |> Map.put("status", "completed")
      |> Map.put("capacity", nil)

    assert {:error, forged_reason} =
             Validate.run(
               bundle.params,
               Map.put(context, "cross_app_progress", forged_completed)
             )

    assert forged_reason in [:malformed_state, :capacity_drift, :ordinal_drift]
    refute_receive {:unexpected_mix, _}, 25
  end

  test "progress window resumes at the next refined leaf and never emits a child receipt", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)

    for index <- 1..3 do
      name = String.pad_leading(Integer.to_string(index), 2, "0")

      File.write!(
        Path.join(fixture.lease.worktree_path, "apps/alpha/test/extra_#{name}_test.exs"),
        "defmodule Extra#{name}Test do\n  use ExUnit.Case\nend\n"
      )
    end

    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()
    clock = :counters.new(1, [])

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      :counters.get(clock, 1)
    end)

    on_exit(fn -> Application.delete_env(:arbor_actions, :cross_app_monotonic_ms) end)

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})

      case args do
        ["test", "--no-deps-check", "--" | files] ->
          if length(files) == 1 do
            :counters.put(clock, 1, 600_000)
            successful_mix()
          else
            timeout_mix()
          end

        _other ->
          successful_mix()
      end
    end)

    context = window_context(fixture.context, bundle)
    assert {:ok, first} = Validate.run(bundle.params, context)
    assert first["disposition_type"] == "capacity_handoff"
    assert first["progress"]["passed_receipts"] == []
    assert is_map(first["progress"]["refinement"])
    assert first["progress"]["refinement"]["accepted_positions"] == ["rootLL"]
    assert first["progress"]["refinement"]["pending_positions"] == ["rootLR", "rootR"]

    test_calls =
      Stream.repeatedly(fn ->
        receive do
          {:mix, ["test", "--no-deps-check", "--" | files]} -> files
          {:mix, _other} -> :skip
        after
          25 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))
      |> Enum.reject(&(&1 == :skip))

    assert length(hd(test_calls)) == 4
    assert length(Enum.at(test_calls, 1)) == 2
    assert length(Enum.at(test_calls, 2)) == 1
    passed_leaf = Enum.at(test_calls, 2)
    refute_receive {:mix, _}, 25

    Application.delete_env(:arbor_actions, :cross_app_monotonic_ms)
    :counters.put(clock, 1, 0)

    next_context = Map.put(context, "cross_app_progress", first["progress"])
    assert {:ok, _second} = Validate.run(bundle.params, next_context)

    assert_receive {:mix, ["test", "--no-deps-check", "--" | next_files]}
    assert length(next_files) == 1
    refute next_files == hd(test_calls)
    refute next_files == passed_leaf
  end

  test "full-budget timeout of a multi-file argv checkpoints children not tests_timed_out", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)

    for index <- 1..3 do
      name = String.pad_leading(Integer.to_string(index), 2, "0")

      File.write!(
        Path.join(fixture.lease.worktree_path, "apps/alpha/test/extra_#{name}_test.exs"),
        "defmodule Extra#{name}Test do\n  use ExUnit.Case\nend\n"
      )
    end

    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()
    clock = :counters.new(1, [])

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      :counters.get(clock, 1)
    end)

    on_exit(fn -> Application.delete_env(:arbor_actions, :cross_app_monotonic_ms) end)

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})

      case args do
        ["test", "--no-deps-check", "--" | files] ->
          :counters.put(clock, 1, 600_000)
          if length(files) > 1, do: timeout_mix(), else: successful_mix()

        _other ->
          successful_mix()
      end
    end)

    context = window_context(fixture.context, bundle)
    assert {:ok, first} = Validate.run(bundle.params, context)
    assert first["disposition_type"] == "capacity_handoff"
    refute first["progress"]["status"] == "failed"
    assert is_map(first["progress"]["refinement"])
    assert first["progress"]["refinement"]["pending_positions"] == ["rootL", "rootR"]
    assert first["progress"]["passed_receipts"] == []

    assert_receive {:mix, ["test", "--no-deps-check", "--" | root_files]}
    assert length(root_files) == 4
    refute_receive {:mix, ["test" | _]}, 25

    Application.delete_env(:arbor_actions, :cross_app_monotonic_ms)
    :counters.put(clock, 1, 0)
    next_context = Map.put(context, "cross_app_progress", first["progress"])
    assert {:ok, _second} = Validate.run(bundle.params, next_context)
    assert_receive {:mix, ["test", "--no-deps-check", "--" | child_files]}
    assert length(child_files) < 4
    assert child_files != root_files
  end

  test "tampered refinement pending positions fail closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)

    for index <- 1..3 do
      name = String.pad_leading(Integer.to_string(index), 2, "0")

      File.write!(
        Path.join(fixture.lease.worktree_path, "apps/alpha/test/extra_#{name}_test.exs"),
        "defmodule Extra#{name}Test do\n  use ExUnit.Case\nend\n"
      )
    end

    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()
    clock = :counters.new(1, [])

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      :counters.get(clock, 1)
    end)

    on_exit(fn -> Application.delete_env(:arbor_actions, :cross_app_monotonic_ms) end)

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})

      case args do
        ["test", "--no-deps-check", "--" | files] ->
          :counters.put(clock, 1, 600_000)
          if length(files) > 1, do: timeout_mix(), else: successful_mix()

        _other ->
          successful_mix()
      end
    end)

    context = window_context(fixture.context, bundle)
    assert {:ok, first} = Validate.run(bundle.params, context)

    tampered =
      put_in(first["progress"], ["refinement", "pending_positions"], ["rootX", "rootR"])

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    Application.delete_env(:arbor_actions, :cross_app_monotonic_ms)

    assert {:error, reason} =
             Validate.run(
               bundle.params,
               Map.put(context, "cross_app_progress", tampered)
             )

    assert reason in [:malformed_state, :invalid_refinement_state]
    refute_receive {:unexpected_mix, _}, 25
  end

  test "empty-plan seed after static pass emits completed without test Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 0)
    parent = self()

    File.rm_rf!(Path.join(fixture.lease.worktree_path, "apps/alpha/test"))
    File.rm_rf!(Path.join(fixture.lease.worktree_path, "apps/beta/test"))

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      successful_mix()
    end)

    context = seed_context(fixture.context, bundle)
    assert {:ok, observation} = Validate.run(bundle.params, context)
    assert observation["disposition_type"] == "completed"
    assert observation["progress_status"] == "completed"
    assert observation["passed"] == true
    assert observation["progress"]["passed_receipts"] == []
    assert observation["progress"]["total_batch_count"] == 0
    assert is_binary(observation["validated_tree_oid"])
    assert is_binary(observation["validated_head"])

    mix_calls =
      Stream.repeatedly(fn ->
        receive do
          {:mix, args} -> args
        after
          25 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    assert Enum.any?(mix_calls, &(hd(&1) == "compile"))
    refute Enum.any?(mix_calls, &(hd(&1) == "test"))
  end

  test "progress without compiler binding fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    context =
      fixture.context
      |> Map.put("cross_app_progress", bundle.progress)
      |> Map.put(:cross_app_static_receipt_sink, {__MODULE__.FakeReceiptStore, :archive, []})
      |> Map.put(:cross_app_static_receipt_source, {__MODULE__.FakeReceiptStore, :read, []})

    assert {:error, :missing_progress_binding} = Validate.run(bundle.params, context)
    refute_receive {:unexpected_mix, _}, 25
  end

  test "progress without trusted receipt MFA fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    context =
      fixture.context
      |> Map.put("cross_app_progress", bundle.progress)
      |> Map.put("cross_app_progress_binding", bundle.binding)

    assert {:error, :invalid_trusted_cross_app_static_receipt_boundary} =
             Validate.run(bundle.params, context)

    refute_receive {:unexpected_mix, _}, 25
  end

  test "malformed static receipt source payload fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    context = window_context(fixture.context, bundle)

    __MODULE__.FakeReceiptStore.put_read(bundle.binding["static_stage_receipt_digest"], %{
      "schema_version" => 1,
      "digest" => bundle.binding["static_stage_receipt_digest"]
    })

    assert {:error, :malformed_envelope} = Validate.run(bundle.params, context)
    refute_receive {:unexpected_mix, _}, 25
  end

  test "wrong static receipt digest fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    other_identities =
      Map.put(bundle.identities, "toolchain_digest", String.duplicate("e", 64))

    {:ok, other_receipt, other_digest} =
      Actions.coding_cross_app_static_receipt_new(
        other_identities,
        successful_static_checks()
      )

    refute other_digest == bundle.binding["static_stage_receipt_digest"]

    context = window_context(fixture.context, bundle)

    __MODULE__.FakeReceiptStore.put_read(
      bundle.binding["static_stage_receipt_digest"],
      other_receipt
    )

    assert {:error, :static_receipt_drift} = Validate.run(bundle.params, context)
    refute_receive {:unexpected_mix, _}, 25
  end

  test "old candidate identity static receipt fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    stale_tree = String.duplicate("e", byte_size(bundle.identities["candidate_tree_oid"]))
    refute stale_tree == bundle.identities["candidate_tree_oid"]

    stale_identities = Map.put(bundle.identities, "candidate_tree_oid", stale_tree)

    {:ok, stale_receipt, stale_digest} =
      Actions.coding_cross_app_static_receipt_new(
        stale_identities,
        successful_static_checks()
      )

    stale_bundle =
      bundle
      |> Map.put(:receipt, stale_receipt)
      |> Map.put(:identities, stale_identities)
      |> Map.update!(:binding, &Map.put(&1, "static_stage_receipt_digest", stale_digest))
      |> Map.update!(:progress, &Map.put(&1, "static_stage_receipt_digest", stale_digest))

    context = window_context(fixture.context, stale_bundle)

    assert {:error, :identity_drift} = Validate.run(bundle.params, context)
    refute_receive {:unexpected_mix, _}, 25
  end

  test "compiler binding without progress fails closed before Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    context = Map.put(fixture.context, "cross_app_progress_binding", bundle.binding)

    assert {:error, :missing_progress} = Validate.run(bundle.params, context)
    refute_receive {:unexpected_mix, _}, 25
  end

  test "stale compiler binding without progress fails closed before seed Mix", %{tmp_dir: tmp_dir} do
    fixture = continuation_fixture(tmp_dir)
    bundle = progress_window_bundle(fixture, accepted_count: 1)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      successful_mix()
    end)

    context =
      seed_context(fixture.context, bundle)
      |> Map.put("cross_app_progress_binding", bundle.binding)

    assert {:error, :missing_progress} = Validate.run(bundle.params, context)
    refute_receive {:unexpected_mix, _}, 25
  end

  test "owner dest verification detects added deleted modified mode and symlink drift", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_umbrella(tmp_dir)
    File.ln_s("mix.exs", Path.join(fixture.lease.worktree_path, "held_link"))
    {:ok, freeze} = MixAction.committable_app_mix_inventory(fixture.lease.worktree_path)

    snapshot_opts = [
      committable_snapshot: true,
      expected_tree_oid: freeze.tree_oid,
      expected_head: freeze.head,
      blob_manifest: freeze.blob_manifest
    ]

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 File.write!(Path.join(dest, "added.txt"), "added\n")

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 assert File.exists?(Path.join(dest, "added.txt"))
                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 File.rm!(Path.join(dest, "mix.lock"))

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 refute File.exists?(Path.join(dest, "mix.lock"))
                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 File.write!(Path.join(dest, "mix.lock"), "mutated\n")

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 assert File.read!(Path.join(dest, "mix.lock")) == "mutated\n"
                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 File.chmod!(Path.join(dest, "mix.lock"), 0o755)

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 {:ok, %File.Stat{mode: mode}} = File.lstat(Path.join(dest, "mix.lock"))
                 assert (mode &&& 0o111) != 0
                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 link = Path.join(dest, "held_link")
                 File.rm!(link)
                 File.ln_s("mix.lock", link)

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 assert File.read_link!(link) == "mix.lock"
                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 File.write!(Path.join(dest, "mix.lock"), "%{}")

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 File.write!(Path.join(dest, "mix.lock"), "%{}\nx")

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 :ok
               end,
               snapshot_opts
             )

    assert :ok =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               fixture.context,
               fn resource ->
                 dest = resource.candidate_path
                 lock = Path.join(dest, "mix.lock")
                 File.rm!(lock)
                 File.ln_s("mix.exs", lock)

                 assert {:error, :validation_tree_mutated} =
                          MixAction.recapture_committable_snapshot(resource)

                 :ok
               end,
               snapshot_opts
             )
  end

  test "owner dest verification git invocations do not scale with regular files", %{
    tmp_dir: tmp_dir
  } do
    small = bind_tree_with_extra_files(tmp_dir, 4)
    large = bind_tree_with_extra_files(tmp_dir, 24)

    assert small.tree_oid == small.expected_tree_oid
    assert large.tree_oid == large.expected_tree_oid
    assert small.git_invocations == large.git_invocations
    assert small.git_invocations <= 8
    assert small.dest_files == small.held_count
    assert large.dest_files == large.held_count
    assert large.dest_files > small.dest_files
    assert small.bind_git_invocations == small.git_invocations
  end

  test "default Mix runner binds the owner snapshot read-only and does not launch on dest drift",
       %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)
    {:ok, freeze} = MixAction.committable_app_mix_inventory(fixture.lease.worktree_path)
    timeout = MixAction.postflight_tree_binding_reserve_ms() + 30_000
    on_exit(fn -> Arbor.Actions.TestMixShell.clear_canned_spawn_result() end)

    MixAction.with_validation_resource(
      fixture.lease.workspace_id,
      fixture.context,
      fn resource ->
        Arbor.Actions.TestMixShell.clear_last_invocation()
        Arbor.Actions.TestMixShell.clear_canned_spawn_result()

        Arbor.Actions.TestMixShell.set_canned_spawn_result(%{
          exit_code: 0,
          stdout: "ok",
          stderr: ""
        })

        assert {:ok, result} =
                 MixAction.run_mix(
                   resource.candidate_path,
                   MixAction.compile_argv(%{warnings_as_errors: true}),
                   validation_resource: resource,
                   timeout: timeout
                 )

        invocation = Arbor.Actions.TestMixShell.last_invocation()
        assert is_map(invocation)
        cwd = Keyword.fetch!(invocation.opts, :cwd)
        assert Path.basename(cwd) == "candidate"
        refute Path.expand(cwd) == Path.expand(fixture.lease.worktree_path)

        projections = Keyword.fetch!(invocation.opts, :filesystem_projections)
        assert Enum.any?(projections.read_only, &(&1["purpose"] == "validation_source"))
        refute Enum.any?(projections.read_write, &(&1["purpose"] == "worktree"))
        assert result.validated_tree_oid == freeze.tree_oid

        Arbor.Actions.TestMixShell.clear_last_invocation()
        File.write!(Path.join(resource.candidate_path, "validation_drift.txt"), "drift\n")

        assert {:error, :validation_tree_mutated} =
                 MixAction.run_mix(
                   resource.candidate_path,
                   MixAction.compile_argv(%{warnings_as_errors: true}),
                   validation_resource: resource,
                   timeout: timeout
                 )

        assert is_nil(Arbor.Actions.TestMixShell.last_invocation())
        {:ok, :ok}
      end,
      committable_snapshot: true,
      expected_tree_oid: freeze.tree_oid,
      expected_head: freeze.head,
      blob_manifest: freeze.blob_manifest
    )
  end

  test "source snapshot symlink materializes and empty-directory dest walk hits bounds", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_umbrella(tmp_dir)
    File.ln_s("mix.exs", Path.join(fixture.lease.worktree_path, "held_link"))
    {:ok, freeze} = MixAction.committable_app_mix_inventory(fixture.lease.worktree_path)
    {:ok, entries} = BlobManifest.canonical_entries(freeze.blob_manifest)

    ancestor_count =
      entries
      |> Enum.flat_map(&ancestor_dirs_for_test(&1.path))
      |> Enum.uniq()
      |> length()

    held_entries = length(entries) + ancestor_count

    MixAction.with_validation_resource(
      fixture.lease.workspace_id,
      fixture.context,
      fn resource ->
        dest = resource.candidate_path
        link = Path.join(dest, "held_link")
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
        assert File.read_link!(link) == "mix.exs"

        for index <- 1..5 do
          File.mkdir_p!(Path.join(dest, "empty_#{index}"))
        end

        assert {:error, :tree_binding_bounds_exceeded} =
                 MixAction.recapture_committable_snapshot(resource,
                   max_entries: held_entries + 2
                 )

        {:ok, :ok}
      end,
      committable_snapshot: true,
      expected_tree_oid: freeze.tree_oid,
      expected_head: freeze.head,
      blob_manifest: freeze.blob_manifest
    )
  end

  test "continuation-shaped parameters fail closed while context-shaped data stays ordinary", %{
    tmp_dir: tmp_dir
  } do
    fixture = continuation_fixture(tmp_dir)
    parent = self()

    put_cross_app_runner!(fn _path, args, _opts ->
      send(parent, {:mix, args})
      successful_mix()
    end)

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 continuation_execution: %{"window" => %{}, "receipt" => %{}}
               },
               fixture.context
             )

    refute_receive {:mix, _}, 25

    spoofed_context =
      Map.put(fixture.context, :continuation_execution, %{"window" => %{}, "receipt" => %{}})

    assert {:ok, ordinary} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, spoofed_context)

    assert ordinary.passed
    assert_receive {:mix, ["compile", "--warnings-as-errors"]}
    assert_receive {:mix, ["xref", "graph", "--no-deps-check"]}
    assert_receive {:mix, ["compile", "--warnings-as-errors"]}
    assert_receive {:mix, ["test", "--no-deps-check", "--", "apps/alpha/test/alpha_test.exs"]}
    assert_receive {:mix, ["test", "--no-deps-check", "--", "apps/beta/test/beta_test.exs"]}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp ancestor_dirs_for_test(path) when is_binary(path) do
    parts = Path.split(path)

    if length(parts) < 2 do
      []
    else
      Enum.map(1..(length(parts) - 1), fn n ->
        parts |> Enum.take(n) |> Enum.join("/")
      end)
    end
  end

  defp continuation_fixture(tmp_dir) do
    fixture = leased_umbrella(tmp_dir)

    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def value, do: 1
      def continuation_probe, do: :ok
    end
    """)

    fixture
  end

  defp continuation_bundle(fixture, opts) do
    params = %{
      workspace_id: fixture.lease.workspace_id,
      timeout: 300_000,
      stage_timeout: 1_200_000,
      test_stage_timeout: 600_000
    }

    {:ok, resolved} =
      Shell.resolve_selection(fixture.lease.worktree_path, fixture.lease.base_commit)

    {:ok, order} =
      Core.execution_app_order(
        resolved.selection.changed_apps,
        resolved.selection.affected_apps
      )

    {:ok, entries} = BlobManifest.canonical_entries(resolved.candidate_blob_manifest)

    paths =
      entries
      |> Enum.map(& &1.path)
      |> Enum.filter(fn path ->
        String.ends_with?(path, "_test.exs") and
          Enum.any?(order.ordered, &String.starts_with?(path, "apps/#{&1}/test/"))
      end)

    {:ok, paths} = Core.normalize_expanded_test_files(paths, order.ordered)
    {:ok, batches} = Core.partition_test_batches(paths, order.ordered)
    {:ok, compact_plan} = Core.compact_batch_plan(batches)
    {:ok, configuration_digest} = Core.configuration_digest(params)

    {:ok, base_tree_oid} =
      git_output(fixture.lease.worktree_path, [
        "rev-parse",
        "--verify",
        "#{fixture.lease.base_commit}^{tree}"
      ])

    identities = %{
      "task_id" => fixture.context.task_id,
      "work_packet_digest" => "sha256:" <> String.duplicate("1", 64),
      "base_commit" => fixture.lease.base_commit,
      "base_tree_oid" => base_tree_oid,
      "candidate_head" => resolved.candidate_head,
      "candidate_tree_oid" => resolved.candidate_tree_oid,
      "validation_plan_digest" => plan_digest(compact_plan),
      "toolchain_digest" => String.duplicate("2", 64),
      "dependency_baseline_digest" => String.duplicate("3", 64),
      "wrapper_digest" => String.duplicate("4", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => fixture.context.agent_id,
      "configuration_digest" => configuration_digest
    }

    bundle = %{
      params: params,
      batches: batches,
      compact_plan: compact_plan,
      identities: identities
    }

    accepted_count =
      case Keyword.get(opts, :accepted_count, 0) do
        :all -> length(compact_plan)
        count -> count
      end

    Map.merge(bundle, %{accepted_count: accepted_count})
  end

  defp progress_window_bundle(fixture, opts) do
    base = continuation_bundle(fixture, opts)
    accepted_count = Keyword.get(opts, :accepted_count, 0)

    identities =
      base.identities
      |> Map.put("work_packet_digest", "sha256:" <> String.duplicate("1", 64))
      |> Map.put("toolchain_digest", String.duplicate("2", 64))
      |> Map.put("dependency_baseline_digest", String.duplicate("3", 64))
      |> Map.put("wrapper_digest", String.duplicate("4", 64))

    {:ok, receipt, static_digest} =
      Actions.coding_cross_app_static_receipt_new(
        identities,
        successful_static_checks()
      )

    binding = %{
      "work_packet_digest" => "sha256:" <> String.duplicate("1", 64),
      "toolchain_digest" => String.duplicate("2", 64),
      "dependency_baseline_digest" => String.duplicate("3", 64),
      "wrapper_digest" => String.duplicate("4", 64),
      "static_stage_receipt_digest" => static_digest
    }

    bindings = %{
      "identities" => identities,
      "planned_batches" => base.compact_plan,
      "static_stage_receipt_digest" => static_digest,
      "per_batch_budget_ms" => base.params.timeout
    }

    {:ok, fresh} = ProgressCore.new(bindings)

    {:ok, progress} =
      cond do
        accepted_count == 0 ->
          {:ok, fresh}

        accepted_count == length(base.compact_plan) ->
          receipts = Enum.map(base.compact_plan, &Map.put(&1, "outcome", "passed"))

          ProgressCore.advance(fresh, bindings, %{
            "schema_version" => 1,
            "new_receipts" => receipts,
            "disposition" => %{"type" => "completed"}
          })

        true ->
          completed = Enum.take(base.compact_plan, accepted_count)
          receipts = Enum.map(completed, &Map.put(&1, "outcome", "passed"))
          remaining = Enum.drop(base.compact_plan, accepted_count)

          handoff =
            progress_v3_handoff(
              base.compact_plan,
              completed,
              nil,
              remaining,
              "runtime",
              base.params.timeout
            )

          ProgressCore.advance(fresh, bindings, %{
            "schema_version" => 1,
            "new_receipts" => receipts,
            "disposition" => %{
              "type" => "capacity_handoff",
              "capacity_handoff" => handoff
            }
          })
      end

    Map.merge(base, %{
      progress: progress,
      binding: binding,
      identities: identities,
      receipt: receipt
    })
  end

  defp seed_context(context, bundle) do
    trusted_seed_context(context, bundle)
  end

  defp window_context(context, bundle) do
    context
    |> trusted_seed_context(bundle)
    |> Map.put("cross_app_progress", bundle.progress)
    |> Map.put("cross_app_progress_binding", bundle.binding)
  end

  defp trusted_seed_context(context, bundle) do
    frozen = Map.take(bundle.binding, ~w(
      work_packet_digest
      toolchain_digest
      wrapper_digest
      dependency_baseline_digest
    ))

    Application.put_env(:arbor_actions, :cross_app_frozen_binding_observer, fn _ctx ->
      {:ok, frozen}
    end)

    on_exit(fn ->
      Application.delete_env(:arbor_actions, :cross_app_frozen_binding_observer)
    end)

    if receipt = Map.get(bundle, :receipt) do
      __MODULE__.FakeReceiptStore.put(bundle.binding["static_stage_receipt_digest"], receipt)
    end

    context
    |> Map.put("coding_plan_work_packet_digest", bundle.binding["work_packet_digest"])
    |> Map.put(:cross_app_static_receipt_sink, {__MODULE__.FakeReceiptStore, :archive, []})
    |> Map.put(:cross_app_static_receipt_source, {__MODULE__.FakeReceiptStore, :read, []})
  end

  defmodule FakeReceiptStore do
    @moduledoc false

    @store_key {__MODULE__, :store}
    @read_override_key {__MODULE__, :read_overrides}

    def archive(digest, receipt) when is_binary(digest) and is_map(receipt) do
      put(digest, receipt)

      {:ok,
       %{
         "schema_version" => 1,
         "task_id" => "task_progress_g1",
         "digest" => digest,
         "byte_size" => 1
       }}
    end

    def read(digest) when is_binary(digest) do
      case override(digest) do
        {:ok, payload} ->
          {:ok, payload}

        :error ->
          case store_get(digest) do
            {:ok, receipt} -> {:ok, %{"receipt" => receipt}}
            :error -> {:error, :cross_app_static_receipt_unavailable}
          end
      end
    end

    def put(digest, receipt) when is_binary(digest) and is_map(receipt) do
      store = Process.get(@store_key, %{})
      Process.put(@store_key, Map.put(store, digest, receipt))
      :ok
    end

    def put_read(digest, payload) when is_binary(digest) do
      overrides = Process.get(@read_override_key, %{})
      Process.put(@read_override_key, Map.put(overrides, digest, payload))
      :ok
    end

    defp override(digest) do
      case Process.get(@read_override_key, %{}) do
        %{^digest => payload} -> {:ok, payload}
        _other -> :error
      end
    end

    defp store_get(digest) do
      case Process.get(@store_key, %{}) do
        %{^digest => receipt} -> {:ok, receipt}
        _other -> :error
      end
    end
  end

  defp successful_static_checks do
    check = %{
      "status" => "completed",
      "passed" => true,
      "exit_code" => 0,
      "reason" => nil,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => String.duplicate("5", 64),
      "stderr_sha256" => String.duplicate("6", 64)
    }

    %{"compile" => check, "xref" => check, "test_compile" => check}
  end

  defp plan_digest(plan) do
    {:ok, digest} =
      Arbor.Contracts.Coding.ValidationCapacityHandoff.ordered_plan_digest(plan)

    digest
  end

  defp put_cross_app_runner!(runner) do
    Application.put_env(:arbor_actions, :cross_app_mix_runner, runner)
    on_exit(fn -> Application.delete_env(:arbor_actions, :cross_app_mix_runner) end)
  end

  defp progress_v3_handoff(planned, completed, interrupted, unstarted, phase, per_batch) do
    digest_subject = if interrupted, do: [interrupted | unstarted], else: unstarted

    {:ok, digest} =
      Arbor.Contracts.Coding.ValidationCapacityHandoff.ordered_plan_digest(digest_subject)

    completed_files = Enum.reduce(completed, 0, fn batch, acc -> acc + batch["count"] end)
    interrupted_files = if is_map(interrupted), do: interrupted["count"], else: 0
    unstarted_files = Enum.reduce(unstarted, 0, fn batch, acc -> acc + batch["count"] end)

    {:ok, descriptor} =
      Arbor.Contracts.Coding.ValidationCapacityHandoff.new(%{
        "schema_version" => 3,
        "phase" => phase,
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => per_batch,
        "completed_batch_count" => length(completed),
        "completed_file_count" => completed_files,
        "unstarted_batch_count" => length(unstarted),
        "unstarted_file_count" => unstarted_files,
        "total_batch_count" => length(planned),
        "total_file_count" => completed_files + interrupted_files + unstarted_files,
        "ordered_plan_sha256" => digest,
        "interrupted_batch" => interrupted,
        "unstarted_batches" => unstarted
      })

    Arbor.Contracts.Coding.ValidationCapacityHandoff.to_map(descriptor)
  end

  defp successful_mix do
    {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
  end

  defp sha256_hex(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp empty_sha256, do: sha256_hex("")

  defp timeout_mix do
    {:ok, %{exit_code: nil, stdout: "killed", stderr: "", timed_out: true}}
  end

  defp git_output(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, output}
    end
  end

  defp bind_tree_with_extra_files(tmp_dir, extra_count)
       when is_integer(extra_count) and extra_count >= 0 do
    fixture = leased_umbrella(tmp_dir)

    for index <- 1..extra_count do
      File.write!(
        Path.join(fixture.lease.worktree_path, "extra_#{index}.txt"),
        "extra #{index}\n"
      )
    end

    {:ok, freeze} = MixAction.committable_app_mix_inventory(fixture.lease.worktree_path)
    held_count = length(freeze.blob_manifest)

    {:ok, result} =
      MixAction.with_validation_resource(
        fixture.lease.workspace_id,
        fixture.context,
        fn resource ->
          assert {:ok, first} = MixAction.bind_committable_snapshot(resource)
          assert {:ok, second} = MixAction.bind_committable_snapshot(resource)
          assert first.tree_oid == freeze.tree_oid
          assert second.tree_oid == freeze.tree_oid
          assert first.dest_verify.git_invocations == second.dest_verify.git_invocations
          {:ok, {first, second}}
        end,
        committable_snapshot: true,
        expected_tree_oid: freeze.tree_oid,
        expected_head: freeze.head,
        blob_manifest: freeze.blob_manifest
      )

    {first, second} = result
    dest_verify = first.dest_verify
    assert is_map(dest_verify)
    assert is_integer(dest_verify.git_invocations)
    assert is_integer(dest_verify.dest_files)
    assert is_integer(dest_verify.walk_ms)
    assert is_integer(dest_verify.held_list_ms)
    assert is_integer(dest_verify.restore_ms)
    assert is_integer(dest_verify.dest_entries_visited)
    assert is_integer(dest_verify.dest_bytes)

    %{
      tree_oid: first.tree_oid,
      expected_tree_oid: freeze.tree_oid,
      held_count: held_count,
      dest_files: dest_verify.dest_files,
      git_invocations: dest_verify.git_invocations,
      bind_git_invocations: second.dest_verify.git_invocations
    }
  end

  defp leased_umbrella(tmp_dir) do
    repo =
      create_umbrella(Path.join(tmp_dir, "umbrella-#{System.unique_integer([:positive])}"))

    task_id = "task_cross_app_#{System.unique_integer([:positive])}"
    principal_id = "agent_cross_app_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/cross-app-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_umbrella(path) do
    create_git_repo(path)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule CrossAppFixture.MixProject do
      use Mix.Project

      def project do
        [
          apps_path: "apps",
          version: "0.1.0",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end
    end
    """)

    File.mkdir_p!(Path.join(path, "config"))
    File.write!(Path.join(path, "config/config.exs"), "import Config\n")
    File.write!(Path.join(path, "mix.lock"), "%{}\n")

    write_app(path, "alpha", [], """
    defmodule Alpha do
      def value, do: 1
    end
    """)

    write_app(path, "beta", ["alpha"], """
    defmodule Beta do
      def value, do: Alpha.value()
    end
    """)

    File.write!(Path.join(path, "apps/alpha/test/alpha_test.exs"), """
    defmodule AlphaTest do
      use ExUnit.Case
      test "value", do: assert Alpha.value() == 1
    end
    """)

    File.write!(Path.join(path, "apps/beta/test/beta_test.exs"), """
    defmodule BetaTest do
      use ExUnit.Case
      test "uses alpha", do: assert Beta.value() == 1
    end
    """)

    # Provide a local mix wrapper like the real repo so run_mix prefers it.
    File.mkdir_p!(Path.join(path, "bin"))

    File.write!(Path.join(path, "bin/mix"), """
    #!/usr/bin/env bash
    exec mix "$@"
    """)

    File.chmod!(Path.join(path, "bin/mix"), 0o755)

    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "umbrella base"])
    path
  end

  defp write_app(root, name, umbrella_deps, lib_source) do
    app_root = Path.join(root, "apps/#{name}")
    File.mkdir_p!(Path.join(app_root, "lib"))
    File.mkdir_p!(Path.join(app_root, "test"))

    deps =
      umbrella_deps
      |> Enum.map(fn dep -> "      {:#{dep}, in_umbrella: true}" end)
      |> Enum.join(",\n")

    deps_block =
      if deps == "" do
        "  defp deps, do: []"
      else
        """
          defp deps do
            [
        #{deps}
            ]
          end
        """
      end

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{name},
          version: "0.1.0",
          build_path: "../../_build",
          config_path: "../../config/config.exs",
          deps_path: "../../deps",
          lockfile: "../../mix.lock",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

    #{deps_block}
    end
    """)

    File.write!(Path.join(app_root, "lib/#{name}.ex"), lib_source)
    File.write!(Path.join(app_root, "test/test_helper.exs"), "ExUnit.start()\n")
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
