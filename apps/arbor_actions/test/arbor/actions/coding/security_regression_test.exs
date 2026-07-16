defmodule Arbor.Actions.Coding.SecurityRegressionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.SecurityRegression.Validate
  alias Arbor.Actions.Coding.ValidationResourceOwner
  alias Arbor.Actions.Council
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Common.SafePath

  @moduletag :slow

  setup_all do
    # Production Shell fails closed for spawn_capable until a streaming control
    # plane exists. These behavioral two-revision proofs need a trusted finite
    # Mix fixture executor (TestMixShell), same seam as Mix action tests.
    previous_shell_module = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      if is_nil(previous_shell_module) do
        Application.delete_env(:arbor_actions, :mix_shell_module)
      else
        Application.put_env(:arbor_actions, :mix_shell_module, previous_shell_module)
      end
    end)

    :ok
  end

  setup do
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
    :ok
  end

  test "reviewed candidate-pass/base-fail evidence is detached, one-shot, and cleaned", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"
    )

    test_path = "test/security_regression_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.SecurityRegressionTest do
      use ExUnit.Case
      test "guest remains denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    params = fixture |> attested_params([test_path]) |> Map.put(:timeout, "600000")
    assert {:ok, result} = Validate.run(params, fixture.context)
    assert result.passed
    assert result.reason == "security_regression_validated"
    assert result.evidence_type == "reviewed_regression_evidence"
    assert result.base.test_failures == 1
    assert {:error, :attestation_already_claimed} = Validate.run(params, fixture.context)

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )
  end

  test "baseline deps are Shell-owned, distinct, private, and ignore host deps markers", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    host_secret = Arbor.Actions.TestLinuxBaselineMaterializer.host_secret_marker()
    baseline_marker = Arbor.Actions.TestLinuxBaselineMaterializer.baseline_marker()

    # Host/repo deps carry a secret marker that must never appear in baseline trees.
    source_deps = Path.join(fixture.repo, "deps")
    File.mkdir_p!(source_deps)
    File.write!(Path.join(source_deps, "HOST_SECRET"), host_secret)
    File.mkdir_p!(Path.join(fixture.lease.worktree_path, "deps"))
    File.write!(Path.join(fixture.lease.worktree_path, "deps/HOST_SECRET"), host_secret)

    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    try do
      assert is_binary(resource.candidate_deps_path)
      assert is_binary(resource.base_deps_path)
      assert resource.candidate_deps_path != resource.base_deps_path
      assert Path.type(resource.candidate_deps_path) == :absolute
      assert Path.type(resource.base_deps_path) == :absolute

      # Deps need not live under the Actions validation root.
      refute String.starts_with?(resource.candidate_deps_path, resource.root_path <> "/")
      refute String.starts_with?(resource.base_deps_path, resource.root_path <> "/")
      refute resource.candidate_deps_path == resource.root_path
      refute resource.base_deps_path == resource.root_path

      assert private_dir?(resource.candidate_deps_path)
      assert private_dir?(resource.base_deps_path)

      assert File.read!(Path.join(resource.candidate_deps_path, "MARKER")) == baseline_marker
      assert File.read!(Path.join(resource.base_deps_path, "MARKER")) == baseline_marker

      refute File.exists?(Path.join(resource.candidate_deps_path, "HOST_SECRET"))
      refute File.exists?(Path.join(resource.base_deps_path, "HOST_SECRET"))

      # Mutation isolation between candidate and base baseline trees.
      File.write!(Path.join(resource.candidate_deps_path, "candidate-mutation"), "candidate")
      refute File.exists?(Path.join(resource.base_deps_path, "candidate-mutation"))
      refute File.exists?(Path.join(source_deps, "candidate-mutation"))

      # Opaque lease never appears in the public view; receipt is JSON-clean evidence.
      refute Map.has_key?(resource, :dependency_lease)
      refute Map.has_key?(resource, "dependency_lease")
      assert resource.baseline_verified_copy == true
      assert is_map(resource.baseline_receipt)
      assert {:ok, _} = Jason.encode(resource)

      state = :sys.get_state(WorkspaceLeaseRegistry)
      private = Map.fetch!(state.validation_resources, resource.resource_id)
      assert private.dependency_lease != nil
      refute inspect(resource) =~ inspect(private.dependency_lease)
    after
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  test "validation resource Actions paths canonicalize a symlinked temporary directory", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    real_tmp = Path.join(tmp_dir, "real-tmp")
    alias_tmp = Path.join(tmp_dir, "alias-tmp")
    File.mkdir_p!(real_tmp)
    File.ln_s!(real_tmp, alias_tmp)
    previous_tmpdir = System.get_env("TMPDIR")

    System.put_env("TMPDIR", alias_tmp)

    try do
      Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

      assert {:ok, resource} =
               WorkspaceLeaseRegistry.acquire_validation_resource(
                 fixture.lease.workspace_id,
                 fixture.context
               )

      try do
        assert {:ok, canonical_tmp} = SafePath.resolve_real(real_tmp)
        assert {:ok, canonical_root} = SafePath.resolve_real(resource.root_path)
        assert resource.root_path == canonical_root
        assert Path.dirname(resource.root_path) == canonical_tmp

        # Actions-owned runtime paths stay under the Actions validation root.
        for path <- [
              resource.candidate_build_path,
              resource.base_build_path,
              resource.candidate_home_path,
              resource.base_home_path
            ] do
          assert path_inside?(path, resource.root_path)
        end

        # Shell baseline deps are absolute and distinct; not required under root.
        assert is_binary(resource.candidate_deps_path)
        assert is_binary(resource.base_deps_path)
        assert resource.candidate_deps_path != resource.base_deps_path
      after
        assert {:ok, _} =
                 WorkspaceLeaseRegistry.release_validation_resource(
                   resource.resource_id,
                   fixture.context
                 )
      end
    after
      if previous_tmpdir,
        do: System.put_env("TMPDIR", previous_tmpdir),
        else: System.delete_env("TMPDIR")
    end
  end

  test "no caller-selected materializer, destination, or baseline plan API", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    destination = Path.join(tmp_dir, "attacker-destination")

    # Caller cannot nominate materializer/destination/source/manifest/plan.
    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
               |> Map.put(:linux_dependency_baseline_materializer, :attacker)
               |> Map.put(:destination, destination)
               |> Map.put(:source, destination)
               |> Map.put(:manifest, destination)
               |> Map.put(:plan, %{"kind" => "hostile"})
             )

    try do
      refute File.exists?(destination)
      assert is_binary(resource.candidate_deps_path)
      # Still used the registry-wired test materializer, not caller opts.
      assert File.read!(Path.join(resource.candidate_deps_path, "MARKER")) ==
               Arbor.Actions.TestLinuxBaselineMaterializer.baseline_marker()
    after
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end

    for fun <- [
          :snapshot_dependency_tree,
          :acquire_linux_dependency_baseline_lease,
          :release_linux_dependency_baseline_lease
        ] do
      result =
        try do
          apply(WorkspaceLeaseRegistry, fun, [[], [], []])
        rescue
          UndefinedFunctionError -> :not_exported
        end

      assert result == :not_exported
    end
  end

  test "cleanup_required acquire releases immediately or retains for retry", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    before = validation_roots()

    # Immediate successful release after cleanup_required → ordinary failure.
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
    Arbor.Actions.TestLinuxBaselineMaterializer.force_acquire(:cleanup_required)

    assert {:error, :test_cleanup_required} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert validation_roots() == before

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    # cleanup_required + Shell release failure retains setup_failed with lease.
    Arbor.Actions.TestLinuxBaselineMaterializer.force_acquire(:cleanup_required)
    Arbor.Actions.TestLinuxBaselineMaterializer.force_release_failures(1)

    assert {:error, :validation_resource_setup_failed_cleanup_retained} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, [retained]} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert retained.setup_status == "setup_failed"
    state = :sys.get_state(WorkspaceLeaseRegistry)
    private = Map.fetch!(state.validation_resources, retained.resource_id)
    assert private.dependency_lease != nil

    Arbor.Actions.TestLinuxBaselineMaterializer.force_release_failures(0)

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               retained.resource_id,
               fixture.context
             )
  end

  test "Shell release failure after Actions cleanup retains resource for retry", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    state = :sys.get_state(WorkspaceLeaseRegistry)
    private = Map.fetch!(state.validation_resources, resource.resource_id)
    lease_root = dependency_lease_root(private)
    assert is_binary(lease_root)
    assert File.dir?(lease_root)

    Arbor.Actions.TestLinuxBaselineMaterializer.force_release_failures(1)

    assert {:error, :validation_resource_cleanup_failed} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    # Actions root cleaned; Shell root retained until release succeeds.
    refute File.exists?(resource.root_path)
    assert File.dir?(lease_root)

    assert {:ok, [retained]} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert retained.resource_id == resource.resource_id

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(lease_root)
  end

  test "non-map dependency baseline view fails closed and releases the live Shell lease", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    before_validation = validation_roots()
    before_baseline = baseline_roots()

    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
    Arbor.Actions.TestLinuxBaselineMaterializer.force_acquire(:non_map_view)

    assert {:error, :invalid_dependency_baseline_view} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    # Immediate successful cleanup leaves neither Actions root nor Shell baseline root.
    assert validation_roots() == before_validation
    assert baseline_roots() == before_baseline

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )
  end

  test "Actions-owned cleanup failure retains validation resource and Shell lease for retry", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    state = :sys.get_state(WorkspaceLeaseRegistry)
    private = Map.fetch!(state.validation_resources, resource.resource_id)
    lease_root = dependency_lease_root(private)
    original_base_worktree_path = private.base_worktree_path
    assert is_binary(lease_root)
    assert File.dir?(lease_root)
    assert File.dir?(resource.root_path)

    # An invalid retained locator makes the actual worktree cleanup helper fail.
    # The prior implementation ignored that error, removed the root, and released
    # the Shell lease anyway.
    :sys.replace_state(WorkspaceLeaseRegistry, fn reg_state ->
      current = Map.fetch!(reg_state.validation_resources, resource.resource_id)
      updated = %{current | base_worktree_path: nil}

      %{
        reg_state
        | validation_resources:
            Map.put(reg_state.validation_resources, resource.resource_id, updated)
      }
    end)

    try do
      assert {:error, :validation_resource_cleanup_failed} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )

      # Actions validation root and Shell lease both remain for retry.
      assert File.dir?(resource.root_path)
      assert File.dir?(lease_root)

      state = :sys.get_state(WorkspaceLeaseRegistry)
      private = Map.fetch!(state.validation_resources, resource.resource_id)
      assert private.dependency_lease != nil
      assert dependency_lease_root(private) == lease_root

      assert {:ok, [retained]} =
               WorkspaceLeaseRegistry.validation_resources(
                 fixture.lease.workspace_id,
                 fixture.context
               )

      assert retained.resource_id == resource.resource_id
    after
      :sys.replace_state(WorkspaceLeaseRegistry, fn reg_state ->
        current = Map.fetch!(reg_state.validation_resources, resource.resource_id)
        restored = %{current | base_worktree_path: original_base_worktree_path}

        %{
          reg_state
          | validation_resources:
              Map.put(reg_state.validation_resources, resource.resource_id, restored)
        }
      end)
    end

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(resource.root_path)
    refute File.exists?(lease_root)
  end

  test "security regression: validation cleanup does not rebind deletion to a replacement worktree",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/replacement_cleanup_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.ReplacementCleanupTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: attestation_id} = attested_params(fixture, [test_path])

    assert {:ok, %{resource: resource}} =
             WorkspaceLeaseRegistry.claim_review_attestation(
               attestation_id,
               fixture.context
             )

    private =
      WorkspaceLeaseRegistry
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    original_identity = private.candidate_cleanup_identity
    preserved_original = Path.join(tmp_dir, "preserved-original-candidate")
    marker = Path.join(resource.candidate_path, "replacement-marker")

    assert is_map(original_identity)
    File.rename!(resource.candidate_path, preserved_original)
    git!(fixture.repo, ["worktree", "prune", "--expire", "now"])
    assert {:ok, nil} = Git.worktree_registration(fixture.repo, resource.candidate_path)

    git!(fixture.repo, [
      "worktree",
      "add",
      "--detach",
      resource.candidate_path,
      resource.candidate_commit
    ])

    File.write!(marker, "replacement survives\n")

    {:ok, replacement_identity} =
      Workspace.capture_worktree_removal_identity(fixture.repo, resource.candidate_path)

    refute replacement_identity.lstat_identity == original_identity.lstat_identity

    try do
      assert {:error, :validation_resource_cleanup_failed} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )

      assert File.read!(marker) == "replacement survives\n"
      assert File.dir?(resource.root_path)

      retained =
        WorkspaceLeaseRegistry
        |> :sys.get_state()
        |> Map.fetch!(:validation_resources)
        |> Map.fetch!(resource.resource_id)

      assert retained.candidate_cleanup_identity == original_identity
      assert retained.dependency_lease != nil
    after
      _ =
        System.cmd(
          "git",
          ["-C", fixture.repo, "worktree", "remove", "--force", resource.candidate_path],
          stderr_to_stdout: true
        )

      File.rm_rf!(preserved_original)
    end

    assert {:ok, _material} =
             WorkspaceLeaseRegistry.finalize_review_attestation(
               attestation_id,
               fixture.context
             )

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )
  end

  test "security regression: owner death after failed baseline admission retains cleanup locator",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())

    for {mode, release_failures} <- [cleanup_required: 1, non_map_view: 2] do
      Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
      Arbor.Actions.TestLinuxBaselineMaterializer.force_acquire(mode)
      Arbor.Actions.TestLinuxBaselineMaterializer.force_release_failures(release_failures)

      assert {:error, :validation_resource_setup_failed_cleanup_retained} =
               WorkspaceLeaseRegistry.acquire_validation_resource(
                 fixture.lease.workspace_id,
                 fixture.context
               )

      assert {:ok, [retained]} =
               WorkspaceLeaseRegistry.validation_resources(
                 fixture.lease.workspace_id,
                 fixture.context
               )

      private =
        WorkspaceLeaseRegistry
        |> :sys.get_state()
        |> Map.fetch!(:validation_resources)
        |> Map.fetch!(retained.resource_id)

      assert is_binary(private.dependency_root_path)
      assert File.dir?(private.dependency_root_path)

      owner = private.resource_owner_pid
      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000

      assert_eventually(fn ->
        WorkspaceLeaseRegistry.validation_resources(
          fixture.lease.workspace_id,
          fixture.context
        ) == {:ok, []} and not File.exists?(private.root_path) and
          not File.exists?(private.dependency_root_path)
      end)

      assert File.dir?(fixture.lease.worktree_path)
    end
  end

  test "security regression: validation cleanup does not delete a replacement root", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    private =
      WorkspaceLeaseRegistry
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    assert private.root_cleanup_identity.path == resource.root_path
    preserved_original = Path.join(tmp_dir, "preserved-validation-root")
    File.rename!(resource.root_path, preserved_original)
    File.mkdir!(resource.root_path)
    replacement_marker = Path.join(resource.root_path, "replacement-marker")
    File.write!(replacement_marker, "replacement survives\n")

    try do
      assert {:error, :validation_resource_cleanup_failed} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )

      assert File.read!(replacement_marker) == "replacement survives\n"

      retained =
        WorkspaceLeaseRegistry
        |> :sys.get_state()
        |> Map.fetch!(:validation_resources)
        |> Map.fetch!(resource.resource_id)

      assert retained.root_cleanup_identity == private.root_cleanup_identity
      assert retained.dependency_lease != nil
    after
      File.rm_rf!(resource.root_path)
      File.rename!(preserved_original, resource.root_path)
    end

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )
  end

  test "security regression: registry crash cannot orphan validation resources", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive, :monotonic])
    supervisor = :"validation_resource_supervisor_#{suffix}"
    server = :"workspace_registry_crash_#{suffix}"

    start_supervised!(%{
      id: supervisor,
      start: {DynamicSupervisor, :start_link, [[name: supervisor, strategy: :one_for_one]]},
      type: :supervisor
    })

    registry_pid =
      start_supervised!(%{
        id: server,
        start:
          {WorkspaceLeaseRegistry, :start_link,
           [
             [
               name: server,
               retention_journal: :disabled,
               validation_resource_supervisor: supervisor,
               linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
             ]
           ]},
        restart: :permanent
      })

    repo = create_base_project(Path.join(tmp_dir, "registry-crash-repo"), valid_module())
    task_id = "task_registry_crash_#{suffix}"
    principal_id = "agent_registry_crash_#{suffix}"
    context = %{server: server, task_id: task_id, agent_id: principal_id}

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/registry-crash-#{suffix}",
                 worktree_base_dir: Path.join(tmp_dir, "registry-crash-worktrees"),
                 task_id: task_id,
                 principal_id: principal_id
               },
               server: server
             )

    {:ok, parent_cleanup_identity} =
      Workspace.capture_worktree_removal_identity(repo, lease.worktree_path)

    on_exit(fn ->
      _ = Workspace.remove_owned_worktree(repo, lease.worktree_path, parent_cleanup_identity)
    end)

    test_path = "test/registry_crash_test.exs"
    File.mkdir_p!(Path.join(lease.worktree_path, "test"))
    File.write!(Path.join(lease.worktree_path, test_path), "ExUnit.start()\n")
    git!(lease.worktree_path, ["add", test_path])
    git!(lease.worktree_path, ["commit", "-m", "validation candidate"])

    {:ok, material} =
      Workspace.materialize_security_regression_material(
        lease.worktree_path,
        lease.workspace_id,
        lease.base_commit,
        [test_path]
      )

    assert {:ok, %{review_attestation_id: attestation_id}} =
             WorkspaceLeaseRegistry.issue_review_attestation(
               lease.workspace_id,
               material,
               String.duplicate("a", 64),
               context
             )

    assert {:ok, %{resource: resource}} =
             WorkspaceLeaseRegistry.claim_review_attestation(attestation_id, context)

    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.create_validation_snapshot(resource.resource_id, context)

    private =
      server
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    dependency_root = dependency_lease_root(private)
    resource_owner = private.resource_owner_pid
    assert File.dir?(resource.root_path)
    assert File.dir?(resource.candidate_path)
    assert File.dir?(snapshot.base_worktree_path)
    assert File.dir?(dependency_root)

    assert {:error, :foreign_caller} =
             Arbor.Actions.Coding.ValidationResourceOwner.cleanup_actions(resource_owner)

    assert File.dir?(resource.root_path)

    registry_ref = Process.monitor(registry_pid)
    Process.exit(registry_pid, :kill)
    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, :killed}, 5_000

    assert_eventually(fn ->
      not Process.alive?(resource_owner) and
        not File.exists?(resource.root_path) and
        not File.exists?(resource.candidate_path) and
        not File.exists?(snapshot.base_worktree_path) and
        not File.exists?(dependency_root) and
        Git.worktree_registration(repo, resource.candidate_path) == {:ok, nil} and
        Git.worktree_registration(repo, snapshot.base_worktree_path) == {:ok, nil}
    end)

    assert File.dir?(lease.worktree_path)
  end

  test "security regression: killed validation owner converges through the registry", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.create_validation_snapshot(
               resource.resource_id,
               fixture.context
             )

    private =
      WorkspaceLeaseRegistry
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    dependency_root = dependency_lease_root(private)
    owner = private.resource_owner_pid
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000

    assert_eventually(fn ->
      WorkspaceLeaseRegistry.validation_resources(
        fixture.lease.workspace_id,
        fixture.context
      ) == {:ok, []} and
        not File.exists?(resource.root_path) and
        not File.exists?(snapshot.base_worktree_path) and
        not File.exists?(dependency_root) and
        Git.worktree_registration(fixture.repo, snapshot.base_worktree_path) == {:ok, nil}
    end)

    assert File.dir?(fixture.lease.worktree_path)
  end

  test "security regression: supervised validation-owner shutdown finishes inside its cleanup window",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.create_validation_snapshot(
               resource.resource_id,
               fixture.context
             )

    private =
      WorkspaceLeaseRegistry
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    dependency_root = dependency_lease_root(private)
    owner = private.resource_owner_pid
    started_at = System.monotonic_time(:millisecond)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Arbor.Actions.Coding.ValidationResourceOwner.supervisor_name(),
               owner
             )

    assert System.monotonic_time(:millisecond) - started_at < 30_000

    assert_eventually(fn ->
      WorkspaceLeaseRegistry.validation_resources(
        fixture.lease.workspace_id,
        fixture.context
      ) == {:ok, []} and
        not File.exists?(resource.root_path) and
        not File.exists?(snapshot.base_worktree_path) and
        not File.exists?(dependency_root)
    end)

    assert File.dir?(fixture.lease.worktree_path)
  end

  test "security regression: registry-loss cleanup enters dormant state after bounded failures",
       %{
         tmp_dir: tmp_dir
       } do
    suffix = System.unique_integer([:positive, :monotonic])
    supervisor = :"validation_dormant_owner_supervisor_#{suffix}"

    start_supervised!(%{
      id: supervisor,
      start: {DynamicSupervisor, :start_link, [[name: supervisor, strategy: :one_for_one]]},
      type: :supervisor
    })

    repo = create_base_project(Path.join(tmp_dir, "dormant-owner-repo"), valid_module())
    root_path = Path.join(tmp_dir, "dormant-owner-root")
    parent = self()

    registry_pid =
      spawn(fn ->
        opts = [
          registry_pid: self(),
          repo_path: repo,
          root_path: root_path,
          candidate_path: repo,
          candidate_commit: nil,
          base_path: Path.join(root_path, "base"),
          materializer: Arbor.Actions.TestLinuxBaselineMaterializer,
          cleanup_retry_limit: 1
        ]

        send(parent, {:owner_started, ValidationResourceOwner.start(supervisor, opts)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owner_started, {:ok, owner, _identity}}, 5_000
    assert :sys.get_state(owner).supervisor_pid == Process.whereis(supervisor)

    preserved_root = root_path <> "-preserved"
    File.rename!(root_path, preserved_root)
    File.mkdir!(root_path)
    replacement_marker = Path.join(root_path, "replacement.txt")
    File.write!(replacement_marker, "replacement")

    Process.exit(registry_pid, :kill)

    assert_eventually(fn ->
      Process.alive?(owner) and
        case :sys.get_state(owner) do
          %{cleanup_dormant: true, cleanup_timer: nil, cleanup_retry_count: 1} -> true
          _other -> false
        end
    end)

    assert File.read!(replacement_marker) == "replacement"

    File.rm_rf!(root_path)
    File.rename!(preserved_root, root_path)

    assert :ok = DynamicSupervisor.terminate_child(supervisor, owner)
    refute Process.alive?(owner)
    refute File.exists?(root_path)
  end

  test "security regression: dead-owner cleanup becomes discoverable dormant evidence", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive, :monotonic])
    supervisor = :"validation_dormant_registry_supervisor_#{suffix}"
    server = :"workspace_dormant_registry_#{suffix}"

    start_supervised!(%{
      id: supervisor,
      start: {DynamicSupervisor, :start_link, [[name: supervisor, strategy: :one_for_one]]},
      type: :supervisor
    })

    _registry_pid =
      start_supervised!(%{
        id: server,
        start:
          {WorkspaceLeaseRegistry, :start_link,
           [
             [
               name: server,
               retention_journal: :disabled,
               validation_resource_supervisor: supervisor,
               validation_owner_cleanup_retry_limit: 1,
               linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
             ]
           ]},
        restart: :permanent
      })

    repo = create_base_project(Path.join(tmp_dir, "dormant-registry-repo"), valid_module())
    task_id = "task_dormant_registry_#{suffix}"
    principal_id = "agent_dormant_registry_#{suffix}"
    context = %{server: server, task_id: task_id, agent_id: principal_id}

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/dormant-registry-#{suffix}",
                 worktree_base_dir: Path.join(tmp_dir, "dormant-registry-worktrees"),
                 task_id: task_id,
                 principal_id: principal_id
               },
               server: server
             )

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context)
    end)

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(lease.workspace_id, context)

    private =
      server
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    preserved_root = resource.root_path <> "-preserved"
    File.rename!(resource.root_path, preserved_root)
    File.mkdir!(resource.root_path)
    replacement_marker = Path.join(resource.root_path, "replacement.txt")
    File.write!(replacement_marker, "replacement")

    owner = private.resource_owner_pid
    Process.exit(owner, :kill)

    assert_eventually(fn ->
      case WorkspaceLeaseRegistry.validation_resources(lease.workspace_id, context) do
        {:ok, [%{resource_id: id, cleanup_status: "dormant"}]} ->
          id == resource.resource_id and not File.exists?(private.dependency_root_path)

        _other ->
          false
      end
    end)

    state = :sys.get_state(server)
    dormant = Map.fetch!(state.validation_resources, resource.resource_id)
    assert dormant.resource_owner_cleanup_retry_count == 1
    assert dormant.resource_owner_cleanup_dormant
    assert File.read!(replacement_marker) == "replacement"

    Process.sleep(150)
    stable = :sys.get_state(server).validation_resources[resource.resource_id]
    assert stable.resource_owner_cleanup_retry_count == 1
    assert stable.resource_owner_cleanup_dormant

    File.rm_rf!(resource.root_path)
    File.rename!(preserved_root, resource.root_path)

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(resource.resource_id, context)

    refute File.exists?(resource.root_path)
    assert File.dir?(lease.worktree_path)
  end

  test "validator accepts neither workspace_id nor test_paths and failed claim spawns no candidate code",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    marker = Path.join(tmp_dir, "candidate-ran")
    test_path = "test/no_spawn_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.NoSpawnTest do
      use ExUnit.Case
      test "would run", do: File.write!(#{inspect(marker)}, "ran")
    end
    """)

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    assert {:error, :not_found} =
             Validate.run(%{review_attestation_id: "review_attestation_missing"}, fixture.context)

    for invalid_timeout <- ["600001", "not-an-integer"] do
      assert {:error, :invalid_timeout} =
               Validate.run(
                 %{
                   review_attestation_id: "review_attestation_missing",
                   timeout: invalid_timeout
                 },
                 fixture.context
               )
    end

    refute File.exists?(marker)
  end

  test "base-pass, candidate-failure, and compile failure retain two-revision behavior", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    base_pass = "test/base_pass_test.exs"

    write_candidate_test(fixture, base_pass, """
    defmodule Tiny.BasePassTest do
      use ExUnit.Case
      test "denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    assert {:ok, base_result} =
             Validate.run(attested_params(fixture, [base_pass]), fixture.context)

    assert base_result.reason == "base_tests_passed"

    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    candidate_failure = "test/candidate_failure_test.exs"

    write_candidate_test(fixture, candidate_failure, """
    defmodule Tiny.CandidateFailureTest do
      use ExUnit.Case
      test "denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    assert {:ok, candidate_result} =
             Validate.run(attested_params(fixture, [candidate_failure]), fixture.context)

    assert candidate_result.reason == "candidate_tests_failed"
    assert candidate_result.base.status == "not_run"

    fixture = leased_project(tmp_dir, valid_module())
    compile_failure = "test/compile_failure_test.exs"
    write_candidate_test(fixture, compile_failure, "defmodule Broken do\n  this is not valid\n")

    assert {:ok, compile_result} =
             Validate.run(attested_params(fixture, [compile_failure]), fixture.context)

    assert compile_result.reason == "candidate_suite_incomplete"
    assert compile_result.base.status == "not_run"
  end

  test "setup failures, zero tests, and stale candidate BEAMs remain fail-closed", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, "defmodule Tiny.Security do\n  def phase, do: :base\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def phase, do: :candidate\nend\n"
    )

    setup_path = "test/setup_failure_test.exs"

    write_candidate_test(fixture, setup_path, """
    defmodule Tiny.SetupFailureTest do
      use ExUnit.Case
      setup_all do
        if Tiny.Security.phase() == :base, do: raise("base setup failed")
        :ok
      end
      test "candidate", do: assert(Tiny.Security.phase() == :candidate)
    end
    """)

    assert {:ok, setup_result} =
             Validate.run(attested_params(fixture, [setup_path]), fixture.context)

    assert setup_result.reason == "base_setup_failed"
    assert setup_result.base.test_failures == 0

    fixture = leased_project(tmp_dir, valid_module())
    zero_path = "test/zero_test.exs"

    write_candidate_test(
      fixture,
      zero_path,
      "defmodule Tiny.ZeroTest do\n  use ExUnit.Case\nend\n"
    )

    assert {:ok, zero_result} =
             Validate.run(attested_params(fixture, [zero_path]), fixture.context)

    assert zero_result.reason == "candidate_zero_tests"

    fixture = leased_project(tmp_dir, valid_module())

    File.write!(
      Path.join(fixture.lease.worktree_path, "lib/candidate_only.ex"),
      "defmodule Tiny.CandidateOnly do\n  def fixed?, do: true\nend\n"
    )

    git!(fixture.lease.worktree_path, ["add", "lib/candidate_only.ex"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate-only"])
    beam_path = "test/isolated_beam_test.exs"

    write_candidate_test(fixture, beam_path, """
    defmodule Tiny.IsolatedBeamTest do
      use ExUnit.Case
      test "candidate only", do: assert(Tiny.CandidateOnly.fixed?())
    end
    """)

    assert {:ok, beam_result} =
             Validate.run(attested_params(fixture, [beam_path]), fixture.context)

    assert beam_result.passed
    assert beam_result.base.test_failures == 1
  end

  test "post-review HEAD replacement and selected-test blob replacement are denied before spawn",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/reviewed_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.ReviewedTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    params = attested_params(fixture, [test_path])

    File.write!(Path.join(fixture.lease.worktree_path, test_path), "defmodule Replaced do\nend\n")
    git!(fixture.lease.worktree_path, ["add", test_path])
    git!(fixture.lease.worktree_path, ["commit", "-m", "replace reviewed test"])

    assert {:error, :reviewed_material_changed} = Validate.run(params, fixture.context)
  end

  test "wrong task or principal cannot claim an attestation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/authority_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.AuthorityTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    params = attested_params(fixture, [test_path])

    assert {:error, :not_authorized} =
             Task.async(fn ->
               Validate.run(params, %{
                 task_id: fixture.context.task_id,
                 agent_id: "different-agent"
               })
             end)
             |> Task.await(10_000)

    assert {:error, :not_authorized} =
             Task.async(fn ->
               Validate.run(params, %{
                 task_id: "different-task",
                 agent_id: fixture.context.agent_id
               })
             end)
             |> Task.await(10_000)
  end

  test "concurrent claim allows exactly one caller", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/claim_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.ClaimTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    results =
      for _ <- 1..2 do
        Task.async(fn -> WorkspaceLeaseRegistry.claim_review_attestation(id, fixture.context) end)
      end
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :attestation_already_claimed}, &1)) == 1

    for {:ok, %{resource: resource}} <- results do
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  test "candidate dependency mutation does not alter base dependency evidence", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"
    )

    test_path = "test/dependency_isolation_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.DependencyIsolationTest do
      use ExUnit.Case
      test "dependency snapshot is revision-private" do
        marker = Path.join(System.fetch_env!("MIX_DEPS_PATH"), "candidate-marker")
        if Tiny.Security.allow_guest?(), do: refute(File.exists?(marker)), else: File.write!(marker, "candidate")
        refute Tiny.Security.allow_guest?()
      end
    end
    """)

    assert {:ok, result} = Validate.run(attested_params(fixture, [test_path]), fixture.context)
    assert result.passed
    assert result.base.test_failures == 1
  end

  test "selected symlink sources and empty selections fail before candidate execution", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())

    File.write!(
      Path.join(fixture.lease.worktree_path, "test/real_source.exs"),
      "defmodule Tiny.RealSource do\nend\n"
    )

    File.ln_s!("real_source.exs", Path.join(fixture.lease.worktree_path, "test/symlink_test.exs"))
    git!(fixture.lease.worktree_path, ["add", "test/real_source.exs", "test/symlink_test.exs"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "symlink source"])

    assert {:error, :test_path_symlink} =
             Validate.run(attested_params(fixture, ["test/symlink_test.exs"]), fixture.context)

    assert {:error, :invalid_selected_test_paths} =
             Workspace.materialize_security_regression_material(
               fixture.lease.worktree_path,
               fixture.lease.workspace_id,
               fixture.lease.base_commit,
               []
             )
  end

  test "normal resource release cleans detached snapshots and action metadata remains process-spawn",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.create_validation_snapshot(
               resource.resource_id,
               fixture.context
             )

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(snapshot.root_path)
    refute File.exists?(snapshot.base_worktree_path)
    assert Validate.name() == "coding_security_regression_validate"
    assert Validate.category() == "coding"
    assert Validate.effect_class() == :process_spawn
  end

  test "lease release and owner death discard private attestations", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/cleanup_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CleanupTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release(fixture.lease.workspace_id, :retain, fixture.context)

    assert {:error, :not_found} =
             WorkspaceLeaseRegistry.claim_review_attestation(id, fixture.context)
  end

  test "forced dependency snapshot failure cleans the actual private root", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    before = validation_roots()

    assert {:error, :dependency_snapshot_failed} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               Map.put(fixture.context, :force_dependency_snapshot_failure, true)
             )

    assert validation_roots() == before

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )
  end

  test "cleanup failure retains attestation, resource, and parent lease until explicit retry", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/cleanup_retry_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CleanupRetryTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    assert {:ok, %{resource: resource}} =
             WorkspaceLeaseRegistry.claim_review_attestation(
               id,
               Map.put(fixture.context, :cleanup_failures, 2)
             )

    assert {:error, :validation_resource_cleanup_failed} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    assert {:ok, [retained]} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert retained.resource_id == resource.resource_id
    assert File.dir?(retained.root_path)

    assert {:ok, _material} =
             WorkspaceLeaseRegistry.finalize_review_attestation(id, fixture.context)

    assert {:error, :validation_resource_cleanup_failed} =
             WorkspaceLeaseRegistry.release(
               fixture.lease.workspace_id,
               :retain,
               fixture.context
             )

    assert {:ok, _lease} =
             WorkspaceLeaseRegistry.inspect_lease(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(retained.root_path)

    assert {:ok, _released} =
             WorkspaceLeaseRegistry.release(
               fixture.lease.workspace_id,
               :retain,
               fixture.context
             )

    assert {:error, :not_found} =
             WorkspaceLeaseRegistry.finalize_review_attestation(id, fixture.context)
  end

  test "security regression: partial setup failure retains its candidate cleanup identity for retry",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/partial_cleanup_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.PartialCleanupTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    assert {:error, :validation_resource_setup_failed_cleanup_retained} =
             WorkspaceLeaseRegistry.claim_review_attestation(
               id,
               fixture.context
               |> Map.put(:force_dependency_snapshot_failure, true)
               |> Map.put(:force_partial_cleanup_failure_once, true)
             )

    assert {:ok, [resource]} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert resource.setup_status == "setup_failed"
    assert File.dir?(resource.root_path)
    assert File.dir?(resource.candidate_path)

    private =
      WorkspaceLeaseRegistry
      |> :sys.get_state()
      |> Map.fetch!(:validation_resources)
      |> Map.fetch!(resource.resource_id)

    assert is_map(private.candidate_cleanup_identity)

    assert {:ok, _material} =
             WorkspaceLeaseRegistry.finalize_review_attestation(id, fixture.context)

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(resource.root_path)
    refute File.exists?(resource.candidate_path)
  end

  test "security regression: workspace owner death retries failed child cleanup before bounded parent retention",
       %{
         tmp_dir: tmp_dir
       } do
    repo = create_base_project(Path.join(tmp_dir, "owner-cleanup-repo"), valid_module())
    server = :"cleanup_owner_death_#{System.unique_integer([:positive])}"

    start_supervised!(
      {WorkspaceLeaseRegistry,
       name: server,
       retention_ttl_ms: 5_000,
       owner_death_retry_base_ms: 100,
       linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
    )

    task_id = "task-cleanup-owner-death"
    principal_id = "agent-cleanup-owner-death"
    recovery = %{server: server, task_id: task_id, principal_id: principal_id}
    parent = self()

    owner =
      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: "test/cleanup-owner-death",
              task_id: task_id,
              principal_id: principal_id,
              worktree_base_dir: Path.join(tmp_dir, "cleanup-owner-worktrees")
            },
            server: server
          )

        send(parent, {:owner_lease, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_lease, {:ok, lease}}, 5_000

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               lease.workspace_id,
               Map.put(recovery, :force_cleanup_failure_once, true)
             )

    Process.exit(owner, :kill)

    assert_eventually(fn ->
      state = :sys.get_state(server)

      case Map.get(state.leases, lease.workspace_id) do
        nil ->
          false

        pending ->
          Map.get(pending, :owner_death_quarantine_state) == :validation_cleanup_pending and
            Map.get(pending, :owner_death_deletion_disabled) == true and
            is_reference(Map.get(pending, :owner_death_retry_ref)) and
            not Map.has_key?(state.by_ref, pending.owner_ref)
      end
    end)

    assert {:ok, _lease} =
             WorkspaceLeaseRegistry.inspect_lease(lease.workspace_id, recovery)

    assert {:ok, [retained]} =
             WorkspaceLeaseRegistry.validation_resources(lease.workspace_id, recovery)

    assert retained.resource_id == resource.resource_id
    assert File.dir?(retained.root_path)

    assert {:error, :workspace_cleanup_pending} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 workspace_id: lease.workspace_id,
                 repo_path: repo,
                 branch: "test/cleanup-owner-death",
                 task_id: task_id,
                 principal_id: principal_id,
                 worktree_base_dir: Path.join(tmp_dir, "cleanup-owner-worktrees")
               },
               server: server
             )

    assert_eventually(fn ->
      state = :sys.get_state(server)

      map_size(state.leases) == 0 and map_size(state.retained_by_id) == 1 and
        map_size(state.validation_resources) == 0 and not File.dir?(retained.root_path)
    end)

    assert {:ok, reactivated} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 workspace_id: lease.workspace_id,
                 repo_path: repo,
                 branch: "test/cleanup-owner-death",
                 task_id: task_id,
                 principal_id: principal_id,
                 worktree_base_dir: Path.join(tmp_dir, "cleanup-owner-worktrees")
               },
               server: server
             )

    assert {:ok, _released} =
             WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, recovery)
  end

  test "security regression: child DOWN resumes a dormant parent quarantine", %{
    tmp_dir: tmp_dir
  } do
    repo = create_base_project(Path.join(tmp_dir, "child-down-repo"), valid_module())
    server = :"child_down_owner_death_#{System.unique_integer([:positive])}"

    start_supervised!(
      {WorkspaceLeaseRegistry,
       name: server,
       retention_ttl_ms: 5_000,
       owner_death_retry_limit: 0,
       linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
    )

    task_id = "task-child-down"
    principal_id = "agent-child-down"
    recovery = %{server: server, task_id: task_id, principal_id: principal_id}
    parent = self()

    owner =
      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: "test/child-down-owner-death",
              task_id: task_id,
              principal_id: principal_id,
              worktree_base_dir: Path.join(tmp_dir, "child-down-worktrees")
            },
            server: server
          )

        send(parent, {:owner_lease, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_lease, {:ok, lease}}, 5_000

    resource_owner =
      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire_validation_resource(
            lease.workspace_id,
            Map.put(recovery, :force_cleanup_failure_once, true)
          )

        send(parent, {:validation_resource, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:validation_resource, {:ok, resource}}, 5_000
    Process.exit(owner, :kill)

    assert_eventually(fn ->
      state = :sys.get_state(server)
      dormant = Map.get(state.leases, lease.workspace_id)

      is_map(dormant) and
        Map.get(dormant, :owner_death_quarantine_state) == :validation_cleanup_dormant and
        Map.get(dormant, :owner_death_retry_exhausted) == true and
        map_size(state.validation_resources) == 1
    end)

    Process.exit(resource_owner, :kill)

    assert_eventually(fn ->
      state = :sys.get_state(server)

      map_size(state.leases) == 0 and map_size(state.retained_by_id) == 1 and
        map_size(state.validation_resources) == 0 and not File.dir?(resource.root_path)
    end)

    assert {:ok, reactivated} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 workspace_id: lease.workspace_id,
                 repo_path: repo,
                 branch: "test/child-down-owner-death",
                 task_id: task_id,
                 principal_id: principal_id,
                 worktree_base_dir: Path.join(tmp_dir, "child-down-worktrees")
               },
               server: server
             )

    assert {:ok, _released} =
             WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, recovery)
  end

  test "council issues only after approved quorum routing and compares the reviewed full diff", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/council_bound_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CouncilBoundTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        [test_path]
      )

    params = %{
      diff: material.diff,
      files: [test_path],
      branch: fixture.lease.branch,
      base_ref: fixture.lease.base_commit,
      intent: "prove reviewed tree",
      agent_id: fixture.context.agent_id,
      workspace_id: fixture.lease.workspace_id,
      commit_hash: material.candidate_commit,
      test_paths: [test_path],
      validation_profile: "security_regression"
    }

    approved = %{
      decision: "approved",
      approve_count: 3,
      reject_count: 0,
      abstain_count: 0,
      quorum_met: true
    }

    context =
      Map.merge(fixture.context, %{
        persist_verdict: false,
        review_runner: fn _request, _params, _context -> {:ok, approved} end
      })

    assert {:ok, %{review_attestation_id: id, tier_decision: "auto_proceed"}} =
             Council.ReviewChange.run(params, context)

    assert {:ok, _} = WorkspaceLeaseRegistry.claim_review_attestation(id, fixture.context)

    assert {:ok, %{review_attestation_id: _id, tier_decision: "human_review"}} =
             Council.ReviewChange.run(
               params,
               Map.put(context, :authority_widening?, true)
             )

    for decision <- [
          %{approved | decision: "rejected", approve_count: 0, reject_count: 3},
          %{approved | decision: "deadlock", approve_count: 1, reject_count: 1, quorum_met: false}
        ] do
      assert {:ok, result} =
               Council.ReviewChange.run(
                 params,
                 %{context | review_runner: fn _, _, _ -> {:ok, decision} end}
               )

      refute Map.has_key?(result, :review_attestation_id)
    end
  end

  test "security regression: council attestation binds completed ledger findings, not the incoming ledger",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/council_completed_ledger_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CouncilCompletedLedgerTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        [test_path]
      )

    incoming_ledger = %{"findings" => %{}}

    params = %{
      diff: material.diff,
      files: [test_path],
      branch: fixture.lease.branch,
      base_ref: fixture.lease.base_commit,
      intent: "bind completed review ledger",
      agent_id: fixture.context.agent_id,
      workspace_id: fixture.lease.workspace_id,
      commit_hash: material.candidate_commit,
      test_paths: [test_path],
      validation_profile: "security_regression",
      review_cycle: 1,
      finding_ledger: incoming_ledger
    }

    completed_ledger = completed_review_ledger("New contract finding")

    decision = %{
      decision: "approved",
      approve_count: 3,
      reject_count: 0,
      abstain_count: 0,
      quorum_met: true,
      review_cycle: 1,
      finding_ledger: completed_ledger,
      review_disposition: "accept",
      blocking_ids: [],
      blocking_reasons: [],
      human_required: false
    }

    context =
      Map.merge(fixture.context, %{
        persist_verdict: false,
        review_runner: fn _request, _params, _context -> {:ok, decision} end
      })

    assert {:ok, %{review_attestation_id: first_id} = result} =
             Council.ReviewChange.run(params, context)

    assert result.finding_ledger == completed_ledger
    assert [%{"id" => "completed-finding"}] = result.feedback["review"]["active_findings"]

    assert {:ok, %{council_decision_digest: first_digest}} =
             WorkspaceLeaseRegistry.claim_review_attestation(first_id, fixture.context)

    changed_ledger = completed_review_ledger("Changed completed finding")

    changed_decision = %{
      decision
      | finding_ledger: changed_ledger
    }

    changed_context = %{
      context
      | review_runner: fn _request, _params, _context -> {:ok, changed_decision} end
    }

    assert {:ok, %{review_attestation_id: second_id}} =
             Council.ReviewChange.run(params, changed_context)

    assert {:ok, %{council_decision_digest: second_digest}} =
             WorkspaceLeaseRegistry.claim_review_attestation(second_id, fixture.context)

    refute first_digest == second_digest
  end

  test "owner death removes its private attestation records", %{tmp_dir: tmp_dir} do
    repo = create_base_project(Path.join(tmp_dir, "owner-death-repo"), valid_module())
    server = :"attestation_owner_death_#{System.unique_integer([:positive])}"

    start_supervised!(
      {WorkspaceLeaseRegistry,
       name: server,
       linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
    )

    task_id = "task-owner-death"
    principal_id = "agent-owner-death"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: "test/attestation-owner-death",
              task_id: task_id,
              principal_id: principal_id,
              worktree_base_dir: Path.join(tmp_dir, "owner-death-worktrees")
            },
            server: server
          )

        test_path = "test/owner_death_test.exs"
        path = Path.join(lease.worktree_path, test_path)

        File.write!(path, """
        defmodule Tiny.OwnerDeathTest do
          use ExUnit.Case
          test "ok", do: assert(true)
        end
        """)

        git!(lease.worktree_path, ["add", test_path])
        git!(lease.worktree_path, ["commit", "-m", "owner death test"])

        {:ok, material} =
          Workspace.materialize_security_regression_material(
            lease.worktree_path,
            lease.workspace_id,
            lease.base_commit,
            [test_path]
          )

        {:ok, %{review_attestation_id: id}} =
          WorkspaceLeaseRegistry.issue_review_attestation(
            lease.workspace_id,
            material,
            String.duplicate("a", 64),
            server: server
          )

        send(parent, {:attested_owner, id})
        Process.sleep(:infinity)
      end)

    assert_receive {:attested_owner, id}, 5_000
    Process.exit(owner, :kill)

    assert_eventually(fn ->
      WorkspaceLeaseRegistry.claim_review_attestation(id,
        server: server,
        task_id: task_id,
        principal_id: principal_id
      ) == {:error, :not_found}
    end)
  end

  defp attested_params(fixture, test_paths) do
    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        test_paths
      )

    digest = :crypto.hash(:sha256, "council-approved") |> Base.encode16(case: :lower)

    {:ok, %{review_attestation_id: id}} =
      WorkspaceLeaseRegistry.issue_review_attestation(
        fixture.lease.workspace_id,
        material,
        digest,
        fixture.context
      )

    %{review_attestation_id: id}
  end

  defp completed_review_ledger(title) do
    %{
      "findings" => %{
        "completed-finding" => %{
          "id" => "completed-finding",
          "owner" => "correctness",
          "severity" => "minor",
          "state" => "new_regression",
          "title" => title,
          "required_action" => "Resolve the completed finding",
          "anchor" => %{
            "path" => "test/council_completed_ledger_test.exs",
            "side" => "new",
            "line" => 3
          },
          "evidence" => "The completed council pass introduced this finding."
        }
      }
    }
  end

  defp leased_project(tmp_dir, base_module) do
    repo =
      create_base_project(
        Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"),
        base_module
      )

    task_id = "task_security_regression_#{System.unique_integer([:positive])}"
    principal_id = "agent_security_regression_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/security-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_base_project(path, base_module) do
    create_git_repo(path)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
    end
    """)

    File.write!(Path.join(path, "lib/security.ex"), base_module)
    File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")
    git!(path, ["add", "mix.exs", "lib/security.ex", "test/test_helper.exs"])
    git!(path, ["commit", "-m", "base"])
    path
  end

  defp write_candidate_module(fixture, source) do
    File.write!(Path.join(fixture.lease.worktree_path, "lib/security.ex"), source)
    git!(fixture.lease.worktree_path, ["add", "lib/security.ex"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate module"])
  end

  defp write_candidate_test(fixture, relative_path, source) do
    path = Path.join(fixture.lease.worktree_path, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    git!(fixture.lease.worktree_path, ["add", relative_path])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate test"])
  end

  defp valid_module, do: "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp validation_roots do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(
      &(String.starts_with?(&1, "arbor-validation-") or
          String.starts_with?(&1, "arbor-security-regression-"))
    )
    |> Enum.sort()
  end

  defp baseline_roots do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "arbor-test-linux-baseline-"))
    |> Enum.sort()
  end

  defp path_inside?(path, root) do
    relative = Path.relative_to(path, root)

    relative != ".." and not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end

  defp private_dir?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        Bitwise.band(mode, 0o777) == 0o700

      _ ->
        false
    end
  end

  defp dependency_lease_root(resource) do
    owner_state = :sys.get_state(resource.resource_owner_pid)
    owner_state.dependency_lease.root_path
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          assert_eventually(fun, attempts - 1)
        )
  end
end
