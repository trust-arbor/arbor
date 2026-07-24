defmodule Mix.Tasks.Arbor.Coding.CheckProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.{Plan, VerificationReport, WorkPacket}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator.CodingPlan.ArtifactStore
  alias Arbor.Orchestrator.Config
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker
  alias Mix.Tasks.Arbor.Coding.Check

  @moduletag :integration
  @moduletag :candidate_verification_production_path
  @moduletag timeout: 120_000

  @isolated_registry Mix.Tasks.Arbor.Coding.CheckProductionPathTest.IsolatedWorkspaceRegistry

  defmodule IsolatedWorkspaceRegistry do
    @moduledoc false
  end

  defmodule IsolatedResourceFacade do
    @moduledoc false

    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    @server Mix.Tasks.Arbor.Coding.CheckProductionPathTest.IsolatedWorkspaceRegistry

    def coding_resource_inventory(opts) do
      WorkspaceLeaseRegistry.reconciliation_inventory(
        Keyword.fetch!(opts, :task_id),
        Keyword.fetch!(opts, :principal_id),
        Keyword.fetch!(opts, :max_items),
        server: @server
      )
    end

    def reactivate_retained_coding_workspace(workspace_id, task_id, principal_id) do
      WorkspaceLeaseRegistry.reactivate_retained_by_lineage(
        workspace_id,
        task_id,
        principal_id,
        server: @server
      )
    end
  end

  defmodule IsolatedActionsExecutor do
    @moduledoc false

    @server Mix.Tasks.Arbor.Coding.CheckProductionPathTest.IsolatedWorkspaceRegistry

    def execute_structured(action, params, workdir, opts) do
      Arbor.Orchestrator.ActionsExecutor.execute_structured(
        action,
        params,
        workdir,
        Keyword.put(opts, :coding_workspace_registry_server, @server)
      )
    end
  end

  test "default spawn_request passes a real retained workspace through the production Mix action with an execution-only shell seam" do
    ensure_runtime_stacks!()

    global_registry_pid = Process.whereis(WorkspaceLeaseRegistry)
    assert is_pid(global_registry_pid)
    global_inventory_before = global_registry_inventory!()

    root =
      System.tmp_dir!()
      |> Path.join(
        "coding-check-production-path-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )
      |> canonical_directory!()

    on_exit(fn -> File.rm_rf(root) end)

    repo_path = create_mix_repo!(root)
    worktree_base = canonical_directory!(Path.join(root, "worktrees"))
    logs_root = canonical_directory!(Path.join(root, "logs"))
    task_id = "task_cli_production_path_#{System.unique_integer([:positive, :monotonic])}"

    workspace_id =
      "workspace_cli_production_path_#{System.unique_integer([:positive, :monotonic])}"

    branch = "arbor/cli-production-path-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, identity} = Identity.generate(name: "cli-production-path")
    previous = install_production_path_config!(logs_root)
    on_exit(fn -> restore_config(previous) end)

    start_isolated_workspace_registry!()

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.settle_task_workspaces(
          task_id,
          identity.agent_id,
          server: @isolated_registry
        )

      revoke_all_capabilities(identity.agent_id)
      _ = Arbor.Trust.delete_trust_profile(identity.agent_id)
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    # MIX_ENV=test deliberately has no operator Apple image or dependency
    # baseline authority. The materializer creates hermetic directories, the
    # shell executes the reviewed ./bin/mix wrapper, and the address-only
    # executor adds the isolated registry atom before delegating to the real
    # ActionsExecutor. Production workspace inspection and Mix.Compile still
    # produce and validate all evidence.

    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    action_resources = [
      Arbor.Actions.canonical_uri_for(Arbor.Actions.Coding.Workspace.Inspect, %{}),
      Arbor.Actions.canonical_uri_for(Arbor.Actions.Mix.Compile, %{})
    ]

    for resource <- action_resources do
      assert {:ok, _capability} =
               Security.grant(principal: identity.agent_id, resource: resource)
    end

    assert {:ok, _profile} =
             Arbor.Trust.ensure_trust_profile(identity.agent_id,
               baseline: :block,
               rules: Map.new(action_resources, &{&1, :auto})
             )

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 workspace_id: workspace_id,
                 repo_path: repo_path,
                 branch: branch,
                 worktree_base_dir: worktree_base,
                 task_id: task_id,
                 principal_id: identity.agent_id
               },
               server: @isolated_registry
             )

    assert lease.workspace_id == workspace_id
    assert lease.repo_path == repo_path
    assert File.dir?(lease.worktree_path)

    assert {:ok, _receipt} =
             WorkspaceLeaseRegistry.release(workspace_id, :retain, %{
               task_id: task_id,
               principal_id: identity.agent_id,
               server: @isolated_registry
             })

    assert {:ok, inventory} =
             IsolatedResourceFacade.coding_resource_inventory(
               task_id: task_id,
               principal_id: identity.agent_id,
               max_items: 8
             )

    assert Enum.any?(inventory["resources"], fn resource ->
             resource["resource_type"] == "retained_workspace_record" and
               resource["workspace_id"] == workspace_id and
               resource["repo_path"] == repo_path and
               resource["active"] == false
           end)

    plan = production_plan!(repo_path)
    archive_reviewed_plan!(plan, task_id)
    plan_path = Path.join(root, "reviewed-plan.json")
    File.write!(plan_path, Jason.encode!(plan))

    args = [
      "--verify",
      "--plan",
      plan_path,
      "--agent-id",
      identity.agent_id,
      "--task-id",
      task_id,
      "--workspace-id",
      workspace_id,
      "--json"
    ]

    parent = self()
    result_ref = make_ref()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        result =
          try do
            Check.run(args,
              ensure_distribution: fn -> :ok end,
              server_running?: fn -> true end,
              target_node: fn -> node() end
            )
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {result_ref, result})
      end)

    assert_receive {^result_ref, run_result}

    assert run_result == :ok,
           "CLI failed with output: #{output}"

    report = output |> String.trim() |> Jason.decode!()

    assert {:ok, ^report} = VerificationReport.normalize(report)
    assert report["status"] == "passed"
    assert report["profile"] == "default"
    assert Check.exit_code(report["status"]) == 0
    assert Check.exit_code("failed") == 1
    assert Check.exit_code("blocked") == 1
    assert String.match?(report["evidence_ref"], ~r/\Asha256:[0-9a-f]{64}\z/)

    assert report["provenance"]["task_id"] == task_id
    assert report["provenance"]["workspace_id"] == workspace_id
    assert report["provenance"]["principal_id"] == identity.agent_id
    assert report["provenance"]["validation_profile"] == "default"
    assert report["provenance"]["workspace_lifecycle"] == "retained_reactivated"
    assert report["provenance"]["work_packet_digest"] == plan["work_packet_digest"]
    assert is_binary(report["provenance"]["plan_fingerprint"])
    assert is_binary(report["provenance"]["workspace_provenance_sha256"])

    assert [
             %{
               "gate_id" => "coding.validation.default.compile",
               "decision" => "passed",
               "code" => "validation_passed",
               "evidence_ref" => evidence_ref
             }
           ] = report["diagnostics"]

    assert evidence_ref == report["evidence_ref"]

    assert {:ok, _settlement} =
             WorkspaceLeaseRegistry.settle_task_workspaces(
               task_id,
               identity.agent_id,
               server: @isolated_registry
             )

    stop_supervised!(@isolated_registry)
    refute Process.whereis(@isolated_registry)
    assert Process.whereis(WorkspaceLeaseRegistry) == global_registry_pid
    assert global_registry_inventory!() == global_inventory_before
  end

  defp production_plan!(repo_path) do
    work_packet = %{
      "version" => 1,
      "success_criteria" => ["the retained candidate compiles without warnings"],
      "non_goals" => ["run an LLM-backed coding task"],
      "constraints" => ["use the production candidate verification actions"],
      "architecture_refs" => [
        "apps/arbor_commands/lib/mix/tasks/arbor.coding.check.ex"
      ],
      "required_evidence" => ["normalized production-path verification report"],
      "checkpoint_policy" => "direct"
    }

    {:ok, work_packet_digest} = WorkPacket.digest(work_packet)

    {:ok, plan} =
      Plan.new(%{
        "version" => 2,
        "task" => "Compile the hermetic operator verification canary",
        "repo_root" => repo_path,
        "worker" => %{"provider" => "grok"},
        "validation_profile" => "default",
        "budgets" => %{"wall_clock_ms" => 90_000},
        "work_packet" => work_packet,
        "work_packet_digest" => work_packet_digest
      })

    Plan.to_map(plan)
  end

  defp archive_reviewed_plan!(plan, task_id) do
    {:ok, compilation} = Arbor.Orchestrator.compile_coding_plan(plan)
    root = task_artifact_root(task_id)
    File.mkdir_p!(root)

    assert {:ok, _descriptor} =
             ArtifactStore.archive(
               root,
               compilation["plan_map"],
               compilation["dot_source"],
               compilation["manifest"]
             )
  end

  defp task_artifact_root(task_id) do
    digest =
      task_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join(Config.coding_pipeline_logs_root(), "task-" <> digest)
  end

  defp create_mix_repo!(root) do
    repo_path = canonical_directory!(Path.join(root, "repo"))
    lib_path = Path.join(repo_path, "lib")
    File.mkdir_p!(lib_path)

    File.write!(
      Path.join(repo_path, "mix.exs"),
      """
      defmodule OperatorCandidateCanary.MixProject do
        use Mix.Project

        def project do
          [
            app: :operator_candidate_canary,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: []
          ]
        end

        def application, do: [extra_applications: [:logger]]
      end
      """
    )

    File.write!(
      Path.join(lib_path, "operator_candidate_canary.ex"),
      """
      defmodule OperatorCandidateCanary do
        @moduledoc false
        def ready?, do: true
      end
      """
    )

    git!(repo_path, ["init"])
    git!(repo_path, ["config", "user.email", "canary@arbor.local"])
    git!(repo_path, ["config", "user.name", "Arbor Canary"])
    git!(repo_path, ["add", "."])
    git!(repo_path, ["commit", "-m", "operator candidate canary"])
    repo_path
  end

  defp git!(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp canonical_directory!(path) do
    File.mkdir_p!(path)
    {:ok, canonical} = SafePath.resolve_real(path)
    canonical
  end

  defp install_production_path_config!(logs_root) do
    keys = [
      {:arbor_actions, :mix_shell_module},
      {:arbor_orchestrator, :coding_candidate_actions_executor},
      {:arbor_orchestrator, :coding_plan_artifact_store},
      {:arbor_orchestrator, :coding_pipeline_logs_root},
      {:arbor_orchestrator, :coding_reconciliation_resource_facade},
      {:arbor_orchestrator, :security_module},
      {:arbor_security, :identity_verification},
      {:arbor_trust, :policy_enforcer_enabled}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    Application.put_env(
      :arbor_orchestrator,
      :coding_candidate_actions_executor,
      IsolatedActionsExecutor
    )

    Application.put_env(
      :arbor_orchestrator,
      :coding_plan_artifact_store,
      ArtifactStore
    )

    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, logs_root)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_resource_facade,
      IsolatedResourceFacade
    )

    Application.put_env(:arbor_orchestrator, :security_module, Security)
    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    previous
  end

  defp restore_config(previous) do
    Enum.each(previous, fn
      {{app, key}, nil} -> Application.delete_env(app, key)
      {{app, key}, value} -> Application.put_env(app, key, value)
    end)
  end

  defp start_isolated_workspace_registry! do
    start_supervised!(
      Supervisor.child_spec(
        {WorkspaceLeaseRegistry,
         [
           name: @isolated_registry,
           retention_journal: :disabled,
           linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
         ]},
        id: @isolated_registry
      )
    )
  end

  defp global_registry_inventory! do
    case Arbor.Actions.coding_resource_inventory(max_items: 256) do
      {:ok, %{"truncated" => false} = inventory} ->
        inventory

      other ->
        flunk(
          "global WorkspaceLeaseRegistry inventory is not fully observable: #{inspect(other)}"
        )
    end
  end

  defp revoke_all_capabilities(agent_id) do
    case Security.list_capabilities(agent_id) do
      {:ok, capabilities} ->
        Enum.each(capabilities, fn capability ->
          _ = Security.revoke(capability.id)
        end)

      _ ->
        :ok
    end
  end

  defp ensure_runtime_stacks! do
    {:ok, _started} = Application.ensure_all_started(:arbor_security)
    {:ok, _started} = Application.ensure_all_started(:arbor_trust)
    {:ok, _started} = Application.ensure_all_started(:arbor_actions)

    ensure_buffered_store!(:arbor_security_identities, "identities")
    ensure_buffered_store!(:arbor_security_signing_keys, "signing_keys")
    ensure_buffered_store!(:arbor_security_capabilities, "capabilities")
    ensure_child!(Arbor.Security.Identity.Registry, [])
    ensure_child!(Arbor.Security.Identity.NonceCache, [])
    ensure_child!(Arbor.Security.SystemAuthority, [])
    ensure_child!(Arbor.Security.CapabilityStore, [])
    ensure_authority_pair!()

    unless Process.whereis(Arbor.Trust.Store) do
      start_supervised!({Arbor.Trust.Store, []})
    end
  end

  defp ensure_authority_pair! do
    case {Process.whereis(Arbor.Security.SigningAuthorityStateOwner),
          Process.whereis(SigningAuthorityBroker)} do
      {nil, nil} ->
        token = make_ref()
        ensure_child!(Arbor.Security.SigningAuthorityStateOwner, broker_token: token)
        ensure_child!(SigningAuthorityBroker, state_owner_token: token)

      {owner, nil} when is_pid(owner) ->
        case Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          other -> flunk("failed to restart SigningAuthorityBroker: #{inspect(other)}")
        end

      {owner, broker} when is_pid(owner) and is_pid(broker) ->
        :ok

      partial ->
        flunk("partial signing authority stack: #{inspect(partial)}")
    end
  end

  defp ensure_buffered_store!(name, collection) do
    if is_nil(Process.whereis(name)) do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: nil, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
        {:error, {:already_present, _child}} -> :ok
      end
    end
  end

  defp ensure_child!(module, args) do
    if is_nil(Process.whereis(module)) do
      case Supervisor.start_child(Arbor.Security.Supervisor, {module, args}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
        {:error, {:already_present, _child}} -> :ok
      end
    end
  end
end
