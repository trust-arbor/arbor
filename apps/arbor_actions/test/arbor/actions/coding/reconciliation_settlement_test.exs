defmodule Arbor.Actions.Coding.ReconciliationApplyTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceReconciliationProjection
  alias Arbor.Contracts.Coding.ReconciliationDecision
  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Contracts.Security.SignedRequest

  # Real validation-resource acquisition exercises source-owned cleanup identities.
  @moduletag :slow

  defmodule AllowSecurity do
    def authorize(_principal_id, _uri, :execute, _opts), do: {:ok, :authorized}
  end

  defmodule DenySecurity do
    def authorize(_principal_id, _uri, :execute, _opts), do: {:error, :denied}
  end

  defmodule PendingSecurity do
    def authorize(_principal_id, _uri, :execute, _opts),
      do: {:ok, :pending_approval, "proposal_test_1"}
  end

  defmodule WeirdSecurity do
    def authorize(_principal_id, _uri, :execute, _opts), do: :not_a_valid_authz_result
  end

  defmodule RecordingSecurity do
    def authorize(principal_id, uri, :execute, opts) do
      send(self(), {:authorize_called, principal_id, uri, opts})
      {:ok, :authorized}
    end
  end

  setup_all do
    previous_shell = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      restore_env(:mix_shell_module, previous_shell)
    end)

    :ok
  end

  setup do
    previous_security = Application.get_env(:arbor_actions, :security_module)
    previous_server = Application.get_env(:arbor_actions, :workspace_lease_registry_server)

    Application.delete_env(:arbor_actions, :workspace_lease_registry_server)
    Application.put_env(:arbor_actions, :security_module, AllowSecurity)
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    on_exit(fn ->
      restore_env(:security_module, previous_security)
      restore_env(:workspace_lease_registry_server, previous_server)
    end)

    :ok
  end

  test "authorized exact-match settlement removes the validation resource and cleans source-owned roots",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    root_path = resource.root_path
    auth = verified_auth("agent_apply_ok")
    decision = settle_decision(resource.resource_id, expected_identity)

    assert File.dir?(root_path)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_id"] == resource.resource_id
    assert receipt["active"] == false
    assert receipt["status"] == "removed"
    refute Map.has_key?(receipt, "root_cleanup_identity")
    refute Map.has_key?(receipt, "cleanup_identity")

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.validation_resources, resource.resource_id)
    refute File.exists?(root_path)
  end

  test "exact-match cleanup failure leaves the resource present", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture, cleanup_failures: 1)
    root_path = resource.root_path
    auth = verified_auth("agent_apply_cleanup_fail")
    decision = settle_decision(resource.resource_id, expected_identity)

    assert File.dir?(root_path)

    assert {:error, :validation_resource_cleanup_failed} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    assert Map.has_key?(state.validation_resources, resource.resource_id)
    assert File.dir?(root_path)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"

    refute Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )

    refute File.exists?(root_path)
  end

  test "unauthorized and pending-approval fail closed without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    auth = verified_auth("agent_apply_denied")
    decision = settle_decision(resource.resource_id, expected_identity)

    Application.put_env(:arbor_actions, :security_module, DenySecurity)

    assert {:error, {:unauthorized, :denied}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )

    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:pending_approval, "proposal_test_1"}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )

    Application.put_env(:arbor_actions, :security_module, WeirdSecurity)

    assert {:error, {:unauthorized, {:unexpected_authz_result, :not_a_valid_authz_result}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )
  end

  test "security regression: bare identity_verified maps are not accepted", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    decision = settle_decision(resource.resource_id, expected_identity)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    forged = %{
      identity_verified: true,
      principal_id: "agent_forged",
      signed_request: %{agent_id: "agent_forged"}
    }

    assert {:error, :invalid_reconciliation_caller_auth} =
             Actions.apply_coding_reconciliation_decision(forged, decision)

    refute_received {:authorize_called, _, _, _}

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )

    principal = "agent_unverified"
    signed = signed_request(principal)

    unverified = %AuthContext{
      principal_id: principal,
      identity_verified: false,
      signed_request: signed
    }

    assert {:error, :invalid_reconciliation_caller_auth} =
             Actions.apply_coding_reconciliation_decision(unverified, decision)

    mismatched =
      principal
      |> AuthContext.new(signed_request: signed_request("agent_other"))
      |> AuthContext.mark_verified()

    assert {:error, :invalid_reconciliation_caller_auth} =
             Actions.apply_coding_reconciliation_decision(mismatched, decision)

    missing_request =
      principal
      |> AuthContext.new()
      |> AuthContext.mark_verified()

    assert {:error, :invalid_reconciliation_caller_auth} =
             Actions.apply_coding_reconciliation_decision(missing_request, decision)

    refute_received {:authorize_called, _, _, _}

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )
  end

  test "current-state drift conflicts without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    auth = verified_auth("agent_apply_drift")
    decision = settle_decision(resource.resource_id, expected_identity)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.validation_resources, resource.resource_id)
      updated = %{current | resource_owner_cleanup_retry_count: 3}

      %{
        state
        | validation_resources: Map.put(state.validation_resources, resource.resource_id, updated)
      }
    end)

    assert {:error, {:reconciliation_identity_conflict, conflict}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert conflict["resource_id"] == resource.resource_id
    assert conflict["current_identity"]["retry_count"] == 3

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )
  end

  test "inconsistent decision identity and unsupported type/decision/reason fail closed", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    auth = verified_auth("agent_apply_reject")
    base = settle_decision(resource.resource_id, expected_identity)

    inconsistent = Map.put(base, "task_id", "task_other")

    assert {:error, :inconsistent_reconciliation_decision_identity} =
             Actions.apply_coding_reconciliation_decision(auth, inconsistent)

    for {patch, expected_detail} <- unsupported_cases(base) do
      decision = deep_merge(base, patch)

      assert {:error, {:unsupported_reconciliation_apply, detail}} =
               Actions.apply_coding_reconciliation_decision(auth, decision)

      assert detail == expected_detail
    end

    malformed = %{"schema_version" => 1, "resource_type" => "validation_resource"}

    assert {:error, _reason} =
             Actions.apply_coding_reconciliation_decision(auth, malformed)

    bad_id =
      base
      |> Map.put("resource_id", "validation_NOT_HEX")
      |> put_in(["expected_identity", "resource_id"], "validation_NOT_HEX")

    assert {:error, :invalid_validation_resource_id} =
             Actions.apply_coding_reconciliation_decision(auth, bad_id)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).validation_resources,
             resource.resource_id
           )
  end

  test "repeated already-absent settlement is idempotent after exact settle", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    auth = verified_auth("agent_apply_absent")
    decision = settle_decision(resource.resource_id, expected_identity)

    assert {:ok, first} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert first["outcome"] == "settled"
    refute File.exists?(resource.root_path)

    assert {:ok, second} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert second["outcome"] == "already_absent"
    assert second["resource_id"] == resource.resource_id
    assert second["active"] == false
    refute Map.has_key?(second, "root_cleanup_identity")

    assert {:ok, third} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert third == second
  end

  test "authorize uses exact validation_resource apply URI", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {resource, expected_identity} = acquire_validation(fixture)
    principal = "agent_apply_uri"
    auth = verified_auth(principal)
    decision = settle_decision(resource.resource_id, expected_identity)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    assert {:ok, _receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)

    assert_received {:authorize_called, ^principal, uri, opts}

    assert uri ==
             "arbor://coding/reconciliation/apply/validation_resource/" <> resource.resource_id

    assert Keyword.get(opts, :verify_identity) == false
    assert match?(%SignedRequest{agent_id: ^principal}, Keyword.get(opts, :signed_request))
  end

  defp leased_project(tmp_dir) do
    repo =
      create_base_project(Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"))

    task_id = "task_reconciliation_apply_#{System.unique_integer([:positive])}"
    principal_id = "agent_reconciliation_apply_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/reconciliation-apply-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context)
    end)

    %{repo: repo, lease: lease, context: context}
  end

  defp create_base_project(path) do
    create_git_repo(path)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
    end
    """)

    File.write!(
      Path.join(path, "lib/security.ex"),
      "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"
    )

    File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")
    git!(path, ["add", "mix.exs", "lib/security.ex", "test/test_helper.exs"])
    git!(path, ["commit", "-m", "base"])
    path
  end

  defp acquire_validation(fixture, opts \\ []) do
    acquire_opts =
      fixture.context
      |> Map.merge(Map.new(opts))

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               acquire_opts
             )

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.release_validation_resource(
          resource.resource_id,
          fixture.context
        )
    end)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    private = Map.fetch!(state.validation_resources, resource.resource_id)
    assert is_map(Map.get(private, :root_cleanup_identity))
    assert is_reference(Map.get(private, :owner_ref))
    assert File.dir?(resource.root_path)

    assert {:ok, expected_identity} =
             WorkspaceReconciliationProjection.validation_comparison_identity(
               state,
               resource.resource_id
             )

    {resource, expected_identity}
  end

  defp settle_decision(resource_id, expected_identity) do
    {:ok, decision} =
      ReconciliationDecision.new(%{
        "schema_version" => 1,
        "resource_type" => "validation_resource",
        "resource_id" => resource_id,
        "task_id" => expected_identity["task_id"],
        "principal_id" => expected_identity["principal_id"],
        "decision" => "settle",
        "reason" => "terminal_active_resource",
        "expected_identity" => expected_identity,
        "evidence" => %{
          "task_presence" => "observed",
          "task_state" => "done",
          "owner_status" => "dead",
          "journal_status" => "complete"
        }
      })

    ReconciliationDecision.to_map(decision)
  end

  defp unsupported_cases(base) do
    [
      {
        %{
          "resource_type" => "live_workspace_lease",
          "expected_identity" =>
            Map.put(base["expected_identity"], "resource_type", "live_workspace_lease")
        },
        %{
          "resource_type" => "live_workspace_lease",
          "decision" => "settle",
          "reason" => "terminal_active_resource"
        }
      },
      {
        %{"decision" => "keep"},
        %{
          "resource_type" => "validation_resource",
          "decision" => "keep",
          "reason" => "terminal_active_resource"
        }
      },
      {
        %{"reason" => "live_task_owner_alive"},
        %{
          "resource_type" => "validation_resource",
          "decision" => "settle",
          "reason" => "live_task_owner_alive"
        }
      }
    ]
  end

  defp deep_merge(base, patch) when is_map(base) and is_map(patch) do
    Map.merge(base, patch, fn
      _key, left, right when is_map(left) and is_map(right) -> Map.merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp verified_auth(principal_id) when is_binary(principal_id) do
    signed = signed_request(principal_id)

    principal_id
    |> AuthContext.new(signed_request: signed)
    |> AuthContext.mark_verified()
  end

  defp signed_request(principal_id) do
    {:ok, signed} =
      SignedRequest.new(%{
        payload: "reconciliation-apply-test",
        agent_id: principal_id,
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
        nonce: :crypto.strong_rand_bytes(16),
        signature: :crypto.strong_rand_bytes(64)
      })

    signed
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
