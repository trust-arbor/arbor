defmodule Arbor.Actions.Coding.ReconciliationApplyTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceReconciliationProjection
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: RetentionJournal
  alias Arbor.Contracts.Coding.PendingApprovalResourceId
  alias Arbor.Contracts.Coding.ReconciliationDecision
  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Persistence

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

  # Test-only Store delegate. It injects a semantic durable-marker change at
  # the public CAS boundary, then forwards to the real ETS backend.
  defmodule DriftBeforeCasStore do
    alias Arbor.Persistence.Store.ETS

    def put(key, value, opts), do: ETS.put(key, value, opts)
    def get(key, opts), do: ETS.get(key, opts)
    def delete(key, opts), do: ETS.delete(key, opts)
    def list(opts), do: ETS.list(opts)
    def exists?(key, opts), do: ETS.exists?(key, opts)
    def durability_class(opts), do: ETS.durability_class(opts)

    def compare_and_swap(key, expected, replacement, opts) do
      mutate_once(:swap, key, opts)
      ETS.compare_and_swap(key, expected, replacement, opts)
    end

    def compare_and_delete(key, expected, opts) when is_map(expected) do
      mutate_once(:delete, key, opts)
      ETS.compare_and_delete(key, expected, opts)
    end

    def compare_and_delete(_key, expected, _opts) do
      raise ArgumentError,
            "compare_and_delete expected an unwrapped marker map, got: #{inspect(expected)}"
    end

    defp mutate_once(kind, key, opts) do
      name = Keyword.fetch!(opts, :name)
      injection_key = {__MODULE__, name}

      case :persistent_term.get(injection_key, :off) do
        :swap when kind == :swap ->
          :persistent_term.put(injection_key, :off)
          {:ok, marker} = ETS.get(key, opts)
          :ok = ETS.put(key, Map.update!(marker, :retry_count, &(&1 + 1)), opts)

        :delete when kind == :delete ->
          :persistent_term.put(injection_key, :off)
          {:ok, marker} = ETS.get(key, opts)
          :ok = ETS.put(key, Map.update!(marker, :retry_count, &(&1 + 1)), opts)

        :swap ->
          :ok

        :delete ->
          :ok

        :off ->
          :ok
      end
    end
  end

  defmodule RecordingSecurity do
    def authorize(principal_id, uri, :execute, opts) do
      send(self(), {:authorize_called, principal_id, uri, opts})
      {:ok, :authorized}
    end
  end

  defmodule RecordingAI do
    def acp_managed_compare_and_settle_session(fields) do
      send(self(), {:ai_settle_called, fields})

      {:ok,
       %{
         "schema_version" => 1,
         "resource_type" => "acp_managed_session",
         "resource_id" => fields["resource_id"],
         "outcome" => "settled",
         "active" => false,
         "status" => "removed"
       }}
    end
  end

  defmodule DriftAI do
    def acp_managed_compare_and_settle_session(fields) do
      send(self(), {:ai_settle_called, fields})

      {:error,
       {:reconciliation_identity_conflict,
        %{
          "resource_id" => fields["resource_id"],
          "current_identity" => fields["expected_identity"]
        }}}
    end
  end

  defmodule ClosingAI do
    def acp_managed_compare_and_settle_session(fields) do
      send(self(), {:ai_settle_called, fields})
      {:error, :close_cleanup_in_progress}
    end
  end

  defmodule ResidueAI do
    def acp_managed_compare_and_settle_session(fields) do
      send(self(), {:ai_settle_called, fields})
      {:error, :settlement_residue}
    end
  end

  defmodule AbsentAI do
    def acp_managed_compare_and_settle_session(fields) do
      send(self(), {:ai_settle_called, fields})

      {:ok,
       %{
         "schema_version" => 1,
         "resource_type" => "acp_managed_session",
         "resource_id" => fields["resource_id"],
         "outcome" => "already_absent",
         "active" => false
       }}
    end
  end

  defmodule ArityTwoOnlyAI do
    def acp_managed_compare_and_settle_session(fields, opts) do
      send(self(), {:ai_arity_two_settle_called, fields, opts})
      {:ok, %{"outcome" => "settled"}}
    end
  end

  defmodule RecordingConsensus do
    def compare_and_settle_pending_approval(fields) do
      send(self(), {:consensus_settle_called, fields})

      {:ok,
       %{
         "schema_version" => 1,
         "resource_type" => "pending_approval",
         "resource_id" => fields["resource_id"],
         "outcome" => "settled",
         "active" => false,
         "status" => "removed"
       }}
    end
  end

  defmodule RecordingComms do
    def compare_and_settle_pending_approval(fields) do
      send(self(), {:comms_settle_called, fields})

      {:ok,
       %{
         "schema_version" => 1,
         "resource_type" => "pending_approval",
         "resource_id" => fields["resource_id"],
         "outcome" => "settled",
         "active" => false,
         "status" => "removed"
       }}
    end
  end

  defmodule AbsentComms do
    def compare_and_settle_pending_approval(fields) do
      send(self(), {:comms_settle_called, fields})

      {:ok,
       %{
         "schema_version" => 1,
         "resource_type" => "pending_approval",
         "resource_id" => fields["resource_id"],
         "outcome" => "already_absent",
         "active" => false
       }}
    end
  end

  defmodule UnavailableComms do
    def compare_and_settle_pending_approval(fields) do
      send(self(), {:comms_settle_called, fields})
      {:error, :current_identity_unavailable}
    end
  end

  defmodule RecordingAppleContainerShell do
    def compare_and_settle_apple_container_unit(fields) do
      send(self(), {:apple_container_settle_called, fields})
      {:ok, %{"outcome" => "settled", "resource_id" => fields["resource_id"]}}
    end
  end

  defmodule ErrorAppleContainerShell do
    def compare_and_settle_apple_container_unit(_fields), do: {:error, :source_conflict}
  end

  defmodule AlreadyAbsentAppleContainerShell do
    def compare_and_settle_apple_container_unit(fields) do
      {:ok,
       %{"outcome" => "already_absent", "resource_id" => fields["resource_id"], "active" => false}}
    end
  end

  defmodule ArityTwoAppleContainerShell do
    def compare_and_settle_apple_container_unit(_fields, _opts),
      do: {:ok, %{"outcome" => "wrong"}}
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
    previous_ai = Application.get_env(:arbor_actions, :ai_module)
    previous_consensus = Application.get_env(:arbor_actions, :consensus_module)
    previous_comms = Application.get_env(:arbor_actions, :comms_module)

    previous_apple_shell =
      Application.get_env(:arbor_actions, :coding_reconciliation_shell_module)

    Application.delete_env(:arbor_actions, :workspace_lease_registry_server)
    Application.put_env(:arbor_actions, :security_module, AllowSecurity)
    Application.delete_env(:arbor_actions, :ai_module)
    Application.delete_env(:arbor_actions, :consensus_module)
    Application.delete_env(:arbor_actions, :comms_module)
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    on_exit(fn ->
      restore_env(:security_module, previous_security)
      restore_env(:workspace_lease_registry_server, previous_server)
      restore_env(:ai_module, previous_ai)
      restore_env(:consensus_module, previous_consensus)
      restore_env(:comms_module, previous_comms)
      restore_env(:coding_reconciliation_shell_module, previous_apple_shell)
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

  test "authorized exact-match live lease settlement removes the workspace and is fully absent",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    worktree_path = lease.worktree_path
    auth = verified_auth("agent_live_apply_ok")
    decision = live_settle_decision(lease.workspace_id, expected_identity)

    assert File.dir?(worktree_path)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_type"] == "live_workspace_lease"
    assert receipt["resource_id"] == lease.workspace_id
    assert receipt["active"] == false
    assert receipt["status"] == "removed"
    refute Map.has_key?(receipt, "worktree_path")
    refute Map.has_key?(receipt, "cleanup_identity")

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.leases, lease.workspace_id)
    refute Map.has_key?(state.retained_by_id, lease.workspace_id)
    refute Map.has_key?(state.retention_blockers, lease.workspace_id)
    refute File.exists?(worktree_path)
  end

  test "authorize uses exact live_workspace_lease apply URI", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    principal = "agent_live_apply_uri"
    auth = verified_auth(principal)
    decision = live_settle_decision(lease.workspace_id, expected_identity)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    assert {:ok, _receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)

    assert_received {:authorize_called, ^principal, uri, opts}

    assert uri ==
             "arbor://coding/reconciliation/apply/live_workspace_lease/" <> lease.workspace_id

    assert Keyword.get(opts, :verify_identity) == false
    assert match?(%SignedRequest{agent_id: ^principal}, Keyword.get(opts, :signed_request))
  end

  test "live unauthorized and pending-approval fail closed without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_denied")
    decision = live_settle_decision(lease.workspace_id, expected_identity)

    Application.put_env(:arbor_actions, :security_module, DenySecurity)

    assert {:error, {:unauthorized, :denied}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)

    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:pending_approval, "proposal_test_1"}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)

    Application.put_env(:arbor_actions, :security_module, WeirdSecurity)

    assert {:error, {:unauthorized, {:unexpected_authz_result, :not_a_valid_authz_result}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)
  end

  test "security regression: live apply rejects unverified caller auth", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    decision = live_settle_decision(lease.workspace_id, expected_identity)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    forged = %{
      identity_verified: true,
      principal_id: "agent_live_forged",
      signed_request: %{agent_id: "agent_live_forged"}
    }

    assert {:error, :invalid_reconciliation_caller_auth} =
             Actions.apply_coding_reconciliation_decision(forged, decision)

    refute_received {:authorize_called, _, _, _}
    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)
  end

  test "live current-state drift conflicts without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_drift")
    decision = live_settle_decision(lease.workspace_id, expected_identity)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.leases, lease.workspace_id)
      updated = Map.put(current, :owner_death_retry_count, 3)

      %{state | leases: Map.put(state.leases, lease.workspace_id, updated)}
    end)

    assert {:error, {:reconciliation_identity_conflict, conflict}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert conflict["resource_id"] == lease.workspace_id
    assert conflict["current_identity"]["retry_count"] == 3
    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)
  end

  test "live journal uncertainty fails closed without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_journal")
    decision = live_settle_decision(lease.workspace_id, expected_identity)

    previous_journal = :sys.get_state(WorkspaceLeaseRegistry).retention_journal

    on_exit(fn ->
      :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
        %{state | retention_journal: previous_journal}
      end)
    end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      journal = Map.get(state, :retention_journal, %{})
      %{state | retention_journal: Map.put(journal, :status, :poisoned)}
    end)

    assert {:error, :retention_journal_unavailable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)
  end

  test "live cleanup failure preserves source-owner error and leaves residue", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {_resource, _validation_identity} = acquire_validation(fixture, cleanup_failures: 1)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_cleanup_fail")
    decision = live_settle_decision(lease.workspace_id, expected_identity)

    assert {:error, :validation_resource_cleanup_failed} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    assert Map.has_key?(state.leases, lease.workspace_id)
  end

  test "live ok-with-residue fails closed as settlement_residue", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_residue")
    decision = live_settle_decision(lease.workspace_id, expected_identity)
    workspace_id = lease.workspace_id

    on_exit(fn ->
      :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
        %{
          state
          | retained_by_id: Map.delete(state.retained_by_id, workspace_id),
            retention_blockers: Map.delete(state.retention_blockers, workspace_id)
        }
      end)
    end)

    # Inject retained residue for the same workspace id so remove can drop the
    # live lease while leaving non-live residue — models marker-delete retry
    # residue without claiming settled.
    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      residue = %{
        workspace_id: workspace_id,
        task_id: fixture.context.task_id,
        principal_id: fixture.context.agent_id,
        lifecycle: :retained,
        dormant: false
      }

      %{state | retained_by_id: Map.put(state.retained_by_id, workspace_id, residue)}
    end)

    assert {:error, :settlement_residue} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.leases, workspace_id)
    assert Map.has_key?(state.retained_by_id, workspace_id)
  end

  test "live retained-only resource is not already_absent", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_retained")
    decision = live_settle_decision(lease.workspace_id, expected_identity)
    workspace_id = lease.workspace_id

    on_exit(fn ->
      :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
        %{
          state
          | retained_by_id: Map.delete(state.retained_by_id, workspace_id),
            retention_blockers: Map.delete(state.retention_blockers, workspace_id)
        }
      end)
    end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.leases, workspace_id)
      residue = Map.put(current, :lifecycle, :retained)

      %{
        state
        | leases: Map.delete(state.leases, workspace_id),
          retained_by_id: Map.put(state.retained_by_id, workspace_id, residue)
      }
    end)

    assert {:error, :not_live_workspace_lease} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.leases, workspace_id)
    assert Map.has_key?(state.retained_by_id, workspace_id)
  end

  test "repeated live already-absent settlement is idempotent after exact settle", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_absent")
    decision = live_settle_decision(lease.workspace_id, expected_identity)

    assert {:ok, first} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert first["outcome"] == "settled"

    assert {:ok, second} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert second["outcome"] == "already_absent"
    assert second["resource_id"] == lease.workspace_id
    assert second["active"] == false

    assert {:ok, third} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert third == second
  end

  test "live unsupported type/decision/reason and bad id fail closed", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, expected_identity} = live_identity(fixture)
    auth = verified_auth("agent_live_apply_reject")
    base = live_settle_decision(lease.workspace_id, expected_identity)

    for {patch, expected_detail} <- live_unsupported_cases(base) do
      decision = deep_merge(base, patch)

      assert {:error, {:unsupported_reconciliation_apply, detail}} =
               Actions.apply_coding_reconciliation_decision(auth, decision)

      assert detail == expected_detail
    end

    bad_id =
      base
      |> Map.put("resource_id", "ws_NOT_HEX")
      |> put_in(["expected_identity", "resource_id"], "ws_NOT_HEX")

    assert {:error, :invalid_live_workspace_id} =
             Actions.apply_coding_reconciliation_decision(auth, bad_id)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)
  end

  test "authorized exact-match retained expiry settles archive-first and fully absents",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    worktree_path = retained.worktree_path
    workspace_id = retained.workspace_id
    auth = verified_auth("agent_retained_apply_ok")
    force_retained_expired_ms(workspace_id)
    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert File.dir?(worktree_path)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_type"] == "retained_workspace_record"
    assert receipt["resource_id"] == workspace_id
    assert receipt["active"] == false
    assert receipt["status"] == "removed"
    refute Map.has_key?(receipt, "worktree_path")
    refute Map.has_key?(receipt, "cleanup_identity")

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.leases, workspace_id)
    refute Map.has_key?(state.retained_by_id, workspace_id)
    refute Map.has_key?(state.retention_blockers, workspace_id)
    refute retained_index_has_workspace?(state, workspace_id)
    refute File.exists?(worktree_path)

    evidence_refs =
      git!(fixture.repo, ["for-each-ref", "--format=%(refname)", "refs/arbor/evidence"])

    assert evidence_refs != ""
  end

  test "authorize uses exact retained_workspace_record apply URI", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    principal = "agent_retained_apply_uri"
    auth = verified_auth(principal)
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    decision = retained_settle_decision(retained.workspace_id, expected_identity)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    assert {:ok, _receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)

    assert_received {:authorize_called, ^principal, uri, opts}

    assert uri ==
             "arbor://coding/reconciliation/apply/retained_workspace_record/" <>
               retained.workspace_id

    assert Keyword.get(opts, :verify_identity) == false
    assert match?(%SignedRequest{agent_id: ^principal}, Keyword.get(opts, :signed_request))
  end

  test "retained unauthorized and pending-approval fail closed without mutation", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_apply_denied")
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    decision = retained_settle_decision(retained.workspace_id, expected_identity)

    Application.put_env(:arbor_actions, :security_module, DenySecurity)

    assert {:error, {:unauthorized, :denied}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )

    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:pending_approval, "proposal_test_1"}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )

    Application.put_env(:arbor_actions, :security_module, WeirdSecurity)

    assert {:error, {:unauthorized, {:unexpected_authz_result, :not_a_valid_authz_result}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
  end

  test "security regression: retained apply rejects unverified caller auth", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    decision = retained_settle_decision(retained.workspace_id, expected_identity)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    forged = %{
      identity_verified: true,
      principal_id: "agent_retained_forged",
      signed_request: %{agent_id: "agent_retained_forged"}
    }

    assert {:error, :invalid_reconciliation_caller_auth} =
             Actions.apply_coding_reconciliation_decision(forged, decision)

    refute_received {:authorize_called, _, _, _}

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
  end

  test "retained not-yet-expired fails closed without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_not_expired")
    decision = retained_settle_decision(retained.workspace_id, expected_identity)

    assert {:error, :retained_not_expired} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
  end

  test "retained missing or non-integer expires_at_ms is not expirable", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_bad_expiry")
    workspace_id = retained.workspace_id

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      updated = Map.put(current, :expires_at_ms, "not-an-integer")
      put_retained_indexes(state, updated)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_not_expirable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).retained_by_id, workspace_id)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      updated = Map.delete(current, :expires_at_ms)
      put_retained_indexes(state, updated)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_not_expirable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).retained_by_id, workspace_id)
  end

  test "retained current-state drift conflicts without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_apply_drift")
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    decision = retained_settle_decision(retained.workspace_id, expected_identity)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, retained.workspace_id)
      updated = Map.put(current, :retry_count, 3)
      put_retained_indexes(state, updated)
    end)

    assert {:error, {:reconciliation_identity_conflict, conflict}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert conflict["resource_id"] == retained.workspace_id
    assert conflict["current_identity"]["retry_count"] == 3

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
  end

  test "security regression: retained branch tip drift conflicts before archive intent", %{
    tmp_dir: tmp_dir
  } do
    server = start_durable_retained_registry()
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_branch_tip_drift")
    workspace_id = retained.workspace_id

    force_retained_expired_ms(workspace_id)
    {source_retained, expected_identity} = retained_identity_for(workspace_id)
    {:ok, source_marker} = durable_retained_marker(workspace_id)
    previous_tip = git!(fixture.repo, ["rev-parse", source_retained.branch])

    File.write!(Path.join(source_retained.worktree_path, "branch-tip-drift.txt"), "v2\n")
    git!(source_retained.worktree_path, ["add", "branch-tip-drift.txt"])
    git!(source_retained.worktree_path, ["commit", "-m", "branch tip drift"])
    replacement_tip = git!(fixture.repo, ["rev-parse", source_retained.branch])

    refute replacement_tip == previous_tip

    decision = retained_settle_decision(workspace_id, expected_identity)

    result = Actions.apply_coding_reconciliation_decision(auth, decision)

    # This behavioral assertion is intentionally before the fixed-code shape
    # assertion: on the parent-only test hunk the replacement tip is archived
    # and deleted, proving the regression without candidate-only helpers.
    assert git!(fixture.repo, ["rev-parse", source_retained.branch]) == replacement_tip
    assert File.dir?(source_retained.worktree_path)

    assert {:error, {:reconciliation_identity_conflict, conflict}} = result
    assert conflict["resource_id"] == workspace_id

    assert conflict["current_identity"]["branch_observation"] == %{
             "status" => "present",
             "oid" => replacement_tip
           }

    state = :sys.get_state(workspace_registry_server())
    assert Map.fetch!(state.retained_by_id, workspace_id) == source_retained
    assert {:ok, ^source_marker} = durable_retained_marker(workspace_id)
    refute ref_exists?(fixture.repo, evidence_ref_for(fixture.context.task_id, workspace_id))
  end

  test "security regression: durable marker drift before reconciliation CAS has no destructive effect",
       %{
         tmp_dir: tmp_dir
       } do
    server = start_durable_retained_registry(DriftBeforeCasStore)
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_marker_cas_drift")
    workspace_id = retained.workspace_id

    force_retained_expired_ms(workspace_id)
    {source_retained, expected_identity} = retained_identity_for(workspace_id)
    {:ok, source_marker} = durable_retained_marker(workspace_id)
    :persistent_term.put({DriftBeforeCasStore, retention_store_name()}, :swap)

    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, {_stage, :reconciliation_marker_identity_conflict}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert {:ok, changed_marker} = durable_retained_marker(workspace_id)
    assert changed_marker.retry_count == source_marker.retry_count + 1

    assert git!(fixture.repo, ["rev-parse", source_retained.branch]) ==
             source_retained.base_commit

    assert File.dir?(source_retained.worktree_path)
    refute ref_exists?(fixture.repo, evidence_ref_for(fixture.context.task_id, workspace_id))
    assert Map.has_key?(:sys.get_state(workspace_registry_server()).retained_by_id, workspace_id)
  end

  test "retained both-paths-absent settlement is exact and replay idempotent", %{tmp_dir: tmp_dir} do
    server = start_durable_retained_registry()
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_both_absent")
    workspace_id = retained.workspace_id

    force_retained_expired_ms(workspace_id)
    File.rm_rf!(retained.worktree_path)
    File.rm_rf!(retained.repo_path)

    {_retained, expected_identity} = retained_identity_for(workspace_id)
    assert expected_identity["branch_observation"] == %{"status" => "absent", "oid" => nil}

    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:ok, first} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert first["outcome"] == "settled"
    assert {:error, :not_found} = durable_retained_marker(workspace_id)

    assert {:ok, second} = Actions.apply_coding_reconciliation_decision(auth, decision)

    assert second == %{
             "active" => false,
             "outcome" => "already_absent",
             "resource_id" => workspace_id,
             "resource_type" => "retained_workspace_record",
             "schema_version" => 1
           }
  end

  test "security regression: both-absent reconciliation never deletes a drifted marker", %{
    tmp_dir: tmp_dir
  } do
    server = start_durable_retained_registry(DriftBeforeCasStore)
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_absent_delete_drift")
    workspace_id = retained.workspace_id

    force_retained_expired_ms(workspace_id)
    File.rm_rf!(retained.worktree_path)
    File.rm_rf!(retained.repo_path)
    {_source_retained, expected_identity} = retained_identity_for(workspace_id)
    {:ok, source_marker} = durable_retained_marker(workspace_id)
    :persistent_term.put({DriftBeforeCasStore, retention_store_name()}, :delete)

    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, {:marker_delete_failed, :reconciliation_marker_identity_conflict}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert {:ok, changed_marker} = durable_retained_marker(workspace_id)
    assert changed_marker.retry_count == source_marker.retry_count + 2
    assert Map.has_key?(:sys.get_state(workspace_registry_server()).retained_by_id, workspace_id)
  end

  test "retained inventory quarantines branch absence and one-sided or unreadable paths", %{
    tmp_dir: tmp_dir
  } do
    server = start_durable_retained_registry()
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    workspace_id = retained.workspace_id

    git!(fixture.repo, ["update-ref", "-d", "refs/heads/#{retained.branch}"])
    assert retained_inventory_identity(workspace_id)["proof_status"] == "unavailable"

    # Recreate the fixture for a distinct one-sided path observation.
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    File.rm_rf!(retained.worktree_path)
    assert retained_inventory_identity(retained.workspace_id)["proof_status"] == "unavailable"

    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    parent = Path.dirname(retained.worktree_path)
    :ok = File.chmod(parent, 0o000)
    on_exit(fn -> File.chmod(parent, 0o700) end)

    assert retained_inventory_identity(retained.workspace_id)["proof_status"] == "unavailable"
  end

  test "retention blockers publish an unavailable v2 identity without path leakage", %{
    tmp_dir: tmp_dir
  } do
    server = start_durable_retained_registry()
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    workspace_id = retained.workspace_id

    complete_identity = retained_inventory_identity(workspace_id)
    encoded = Jason.encode!(complete_identity)

    for secret <- [
          retained.repo_path,
          retained.worktree_path,
          retained.display_worktree_path,
          retained.branch,
          retained.runtime_id,
          inspect(retained.lstat_identity),
          inspect(retained.worktree_registration)
        ] do
      refute String.contains?(encoded, secret)
    end

    :sys.replace_state(workspace_registry_server(), fn state ->
      %{
        state
        | retained_by_id: Map.delete(state.retained_by_id, workspace_id),
          retained_by_target: Map.delete(state.retained_by_target, retained.target),
          retention_blockers: Map.put(state.retention_blockers, workspace_id, retained),
          retention_blockers_by_target:
            Map.put(state.retention_blockers_by_target, retained.target, retained)
      }
    end)

    identity = retained_inventory_identity(workspace_id)
    assert identity["identity_version"] == 2
    assert identity["proof_status"] == "unavailable"
  end

  test "retained legacy identity apply is rejected", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_legacy_identity")

    force_retained_expired_ms(retained.workspace_id)

    legacy_identity =
      Map.drop(expected_identity, [
        "identity_version",
        "proof_status",
        "marker_source",
        "workspace_digest",
        "marker_digest",
        "repository_digest",
        "branch_observation",
        "discard_phase",
        "settlement_tip"
      ])

    decision = retained_settle_decision(retained.workspace_id, legacy_identity)

    assert {:error, :retained_identity_proof_required} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
  end

  test "retained journal uncertainty fails closed without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_apply_journal")
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    decision = retained_settle_decision(retained.workspace_id, expected_identity)

    previous_journal = :sys.get_state(WorkspaceLeaseRegistry).retention_journal

    on_exit(fn ->
      :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
        %{state | retention_journal: previous_journal}
      end)
    end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      journal = Map.get(state, :retention_journal, %{})
      %{state | retention_journal: Map.put(journal, :status, :poisoned)}
    end)

    assert {:error, :retention_journal_unavailable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
  end

  test "retained lifecycle active_orphaned and dormant fail closed", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_lifecycle")
    workspace_id = retained.workspace_id
    force_retained_expired_ms(workspace_id)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      updated = Map.put(current, :lifecycle, :active_orphaned)
      put_retained_indexes(state, updated)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    assert expected_identity["proof_status"] == "unavailable"
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_identity_proof_required} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      updated =
        current
        |> Map.put(:lifecycle, :retained)
        |> Map.put(:dormant, true)

      put_retained_indexes(state, updated)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_not_expirable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).retained_by_id, workspace_id)
  end

  test "discarding branch phase admits an absent branch after proven worktree removal", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {retained, _identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_branch_phase_absent")
    workspace_id = retained.workspace_id
    settlement_tip = git!(fixture.repo, ["rev-parse", retained.branch])

    File.rm_rf!(retained.worktree_path)
    git!(fixture.repo, ["update-ref", "-d", "refs/heads/#{retained.branch}"])

    :sys.replace_state(workspace_registry_server(), fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      updated =
        current
        |> Map.put(:lifecycle, :discarding)
        |> Map.put(:discard_phase, :branch)
        |> Map.put(:settlement_tip, settlement_tip)
        |> Map.put(:lstat_identity, nil)
        |> Map.put(:worktree_registration, nil)
        |> Map.put(:expiry_ref, nil)

      put_retained_indexes(state, updated)
    end)

    {_seeded, expected_identity} = retained_identity_for(workspace_id)
    assert expected_identity["proof_status"] == "complete"
    assert expected_identity["branch_observation"] == %{"status" => "absent", "oid" => nil}

    assert {:ok, receipt} =
             Actions.apply_coding_reconciliation_decision(
               auth,
               retained_settle_decision(workspace_id, expected_identity)
             )

    assert receipt["outcome"] == "settled"
    refute Map.has_key?(:sys.get_state(workspace_registry_server()).retained_by_id, workspace_id)
  end

  test "discard phase and settlement tip drift block exact settlement until the durable source is restored",
       %{
         tmp_dir: tmp_dir
       } do
    server = start_durable_retained_registry()
    fixture = leased_project_for_registry(tmp_dir, server)
    {retained, _identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_phase_tip_drift")
    workspace_id = retained.workspace_id
    settlement_tip = git!(fixture.repo, ["rev-parse", retained.branch])
    {:ok, source_marker} = durable_retained_marker(workspace_id)

    phase_marker =
      source_marker
      |> Map.put(:lifecycle, "discarding")
      |> Map.put(:discard_phase, "worktree")
      |> Map.put(:settlement_tip, settlement_tip)

    put_durable_retained_marker(workspace_id, phase_marker)
    put_retained_discard_phase(workspace_id, :worktree, settlement_tip)

    {_seeded, expected_identity} = retained_identity_for(workspace_id)
    assert expected_identity["proof_status"] == "complete"
    assert expected_identity["discard_phase"] == "worktree"
    assert expected_identity["settlement_tip"] == settlement_tip

    drifted_tip = String.duplicate("a", 40)
    put_durable_retained_marker(workspace_id, Map.put(phase_marker, :settlement_tip, drifted_tip))
    put_retained_discard_phase(workspace_id, :worktree, drifted_tip)

    assert retained_inventory_identity(workspace_id)["proof_status"] == "unavailable"

    assert {:error, :current_identity_unavailable} =
             Actions.apply_coding_reconciliation_decision(
               auth,
               retained_settle_decision(workspace_id, expected_identity)
             )

    put_durable_retained_marker(workspace_id, phase_marker)
    put_retained_discard_phase(workspace_id, :worktree, settlement_tip)
    {_seeded, resumed_identity} = retained_identity_for(workspace_id)
    assert resumed_identity["proof_status"] == "complete"
    assert resumed_identity["discard_phase"] == "worktree"
    assert resumed_identity["settlement_tip"] == settlement_tip
  end

  test "retained discarding continues crash-durable phase without expiry gate and settles only on full absence",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_discarding_continue")
    workspace_id = retained.workspace_id
    worktree_path = retained.worktree_path
    settlement_tip = git!(fixture.repo, ["rev-parse", retained.branch])
    future_ms = System.monotonic_time(:millisecond) + 60_000

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      case Map.get(current, :expiry_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end

      updated =
        current
        |> Map.put(:lifecycle, :discarding)
        |> Map.put(:discard_phase, :worktree)
        |> Map.put(:settlement_tip, settlement_tip)
        |> Map.put(:expires_at_ms, future_ms)
        |> Map.put(:expiry_ref, nil)
        |> Map.put(:durable_lifecycle, nil)

      put_retained_indexes(state, updated)
    end)

    {seeded, expected_identity} = retained_identity_for(workspace_id)
    assert expected_identity["lifecycle"] == "discarding"
    assert seeded.expires_at_ms > System.monotonic_time(:millisecond)
    assert seeded.settlement_tip == settlement_tip
    assert seeded.discard_phase == :worktree

    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_type"] == "retained_workspace_record"
    assert receipt["resource_id"] == workspace_id
    assert receipt["active"] == false
    assert receipt["status"] == "removed"

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.leases, workspace_id)
    refute Map.has_key?(state.retained_by_id, workspace_id)
    refute Map.has_key?(state.retention_blockers, workspace_id)
    refute retained_index_has_workspace?(state, workspace_id)
    refute File.exists?(worktree_path)
  end

  test "retained discard_pending helper-ok surfaces settlement_residue not settled", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_discard_pending_residue")
    workspace_id = retained.workspace_id
    worktree_path = retained.worktree_path
    settlement_tip = git!(fixture.repo, ["rev-parse", retained.branch])
    previous_archive = :sys.get_state(WorkspaceLeaseRegistry).retained_archive

    on_exit(fn ->
      :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
        %{state | retained_archive: previous_archive}
      end)
    end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      case Map.get(current, :expiry_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end

      updated =
        current
        |> Map.put(:lifecycle, :discarding)
        |> Map.put(:discard_phase, :archive)
        |> Map.put(:settlement_tip, settlement_tip)
        |> Map.put(:expires_at_ms, System.monotonic_time(:millisecond) - 1)
        |> Map.put(:expiry_ref, nil)
        |> Map.put(:durable_lifecycle, nil)

      state
      |> put_retained_indexes(updated)
      |> Map.put(:retained_archive, fn _retained -> {:error, :injected_archive_failure} end)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :settlement_residue} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    assert Map.has_key?(state.retained_by_id, workspace_id)
    assert File.dir?(worktree_path)

    seeded = Map.fetch!(state.retained_by_id, workspace_id)
    assert seeded.lifecycle == :discarding
    assert seeded.discard_phase == :archive
    assert seeded.settlement_tip == settlement_tip
  end

  test "retained_by_id present without retained_by_target entry fails target index", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_missing_reverse_index")
    workspace_id = retained.workspace_id
    force_retained_expired_ms(workspace_id)
    original_target = retained.target

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      %{
        state
        | retained_by_id: Map.put(state.retained_by_id, workspace_id, current),
          retained_by_target: Map.delete(state.retained_by_target, original_target)
      }
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_target_index_invalid} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    assert Map.has_key?(state.retained_by_id, workspace_id)
    refute Map.has_key?(state.retained_by_target, original_target)
  end

  test "blocker-only primary record is not retained_workspace_record", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_blocker_only")
    workspace_id = retained.workspace_id
    decision = retained_settle_decision(workspace_id, expected_identity)
    on_exit(fn -> drop_workspace_residue(workspace_id) end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      target = current.target
      blockers = Map.get(state, :retention_blockers, %{})
      blockers_by_target = Map.get(state, :retention_blockers_by_target, %{})

      %{
        state
        | retained_by_id: Map.delete(state.retained_by_id, workspace_id),
          retained_by_target: Map.delete(state.retained_by_target, target),
          retention_blockers: Map.put(blockers, workspace_id, current),
          retention_blockers_by_target: Map.put(blockers_by_target, target, current)
      }
    end)

    assert {:error, :not_retained_workspace_record} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    refute Map.has_key?(state.retained_by_id, workspace_id)
    assert Map.has_key?(state.retention_blockers, workspace_id)
  end

  test "retained source helper cleanup failure preserves original error", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_cleanup_error")
    workspace_id = retained.workspace_id
    worktree_path = retained.worktree_path
    force_retained_expired_ms(workspace_id)
    previous_cleanup = :sys.get_state(WorkspaceLeaseRegistry).retained_cleanup

    on_exit(fn ->
      :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
        %{state | retained_cleanup: previous_cleanup}
      end)
    end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      Map.put(state, :retained_cleanup, fn _retained -> {:error, :injected_cleanup_failure} end)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :injected_cleanup_failure} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    state = :sys.get_state(WorkspaceLeaseRegistry)
    assert Map.has_key?(state.retained_by_id, workspace_id)
    assert File.dir?(worktree_path)
  end

  test "retained target-index mismatch fails closed without mutation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_target_index")
    workspace_id = retained.workspace_id
    force_retained_expired_ms(workspace_id)
    original_target = retained.target

    # Stored target disagrees with path-derived target.
    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      updated = Map.put(current, :target, {:workspace_target, "/other", "b", "/other-wt"})

      state
      |> Map.update!(:retained_by_target, &Map.delete(&1, original_target))
      |> put_retained_indexes(updated)
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_target_index_invalid} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).retained_by_id, workspace_id)

    # Restore path-consistent target, but reverse index holds a different map.
    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      restored = Map.put(current, :target, original_target)

      clone =
        Map.put(restored, :retry_count, Map.get(restored, :retry_count, 0) + 7)

      %{
        state
        | retained_by_id: Map.put(state.retained_by_id, workspace_id, restored),
          retained_by_target: %{original_target => clone}
      }
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_target_index_invalid} =
             Actions.apply_coding_reconciliation_decision(auth, decision)
  end

  test "retained active-target exclusion fails closed", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_active_target")
    workspace_id = retained.workspace_id
    force_retained_expired_ms(workspace_id)
    live_blocker_id = "ws_" <> String.duplicate("a", 32)

    on_exit(fn ->
      drop_workspace_residue(workspace_id)
      drop_workspace_residue(live_blocker_id)
    end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      live_blocker = %{
        workspace_id: live_blocker_id,
        repo_path: current.repo_path,
        branch: current.branch,
        worktree_path: current.worktree_path,
        ownership: :owned,
        active: true
      }

      %{state | leases: Map.put(state.leases, live_blocker.workspace_id, live_blocker)}
    end)

    {_, expected_identity} = retained_identity_for(workspace_id)
    decision = retained_settle_decision(workspace_id, expected_identity)

    assert {:error, :retained_active_target} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).retained_by_id, workspace_id)
  end

  test "live-only resource is not retained already_absent", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {lease, _live_identity} = live_identity(fixture)
    auth = verified_auth("agent_retained_live_only")

    expected_identity = %{
      "resource_type" => "retained_workspace_record",
      "resource_id" => lease.workspace_id,
      "task_id" => fixture.context.task_id,
      "principal_id" => fixture.context.agent_id,
      "lifecycle" => "retained",
      "active" => false,
      "ownership" => "owned",
      "branch_provenance" => "created",
      "cleanup_armed" => true,
      "dormant" => false,
      "retry_count" => 0,
      "retry_limit" => 3,
      "expires_at" => nil
    }

    decision = retained_settle_decision(lease.workspace_id, expected_identity)

    assert {:error, :retained_identity_proof_required} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert Map.has_key?(:sys.get_state(WorkspaceLeaseRegistry).leases, lease.workspace_id)
  end

  test "retained reverse-index residue is not already_absent", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_reverse_residue")
    workspace_id = retained.workspace_id
    decision = retained_settle_decision(workspace_id, expected_identity)
    on_exit(fn -> drop_workspace_residue(workspace_id) end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      target = current.target

      %{
        state
        | retained_by_id: Map.delete(state.retained_by_id, workspace_id),
          retained_by_target: Map.put(state.retained_by_target, target, current)
      }
    end)

    assert {:error, :settlement_residue} =
             Actions.apply_coding_reconciliation_decision(auth, decision)
  end

  test "retained blocker reverse-index residue is not already_absent", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_blocker_residue")
    workspace_id = retained.workspace_id
    decision = retained_settle_decision(workspace_id, expected_identity)
    on_exit(fn -> drop_workspace_residue(workspace_id) end)

    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)
      target = current.target
      blockers = Map.get(state, :retention_blockers_by_target, %{})

      %{
        state
        | retained_by_id: Map.delete(state.retained_by_id, workspace_id),
          retained_by_target: Map.delete(state.retained_by_target, target),
          retention_blockers_by_target: Map.put(blockers, target, current)
      }
    end)

    assert {:error, :settlement_residue} =
             Actions.apply_coding_reconciliation_decision(auth, decision)
  end

  test "repeated retained already-absent settlement is idempotent after exact settle", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_apply_absent")
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    decision = retained_settle_decision(retained.workspace_id, expected_identity)

    assert {:ok, first} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert first["outcome"] == "settled"

    assert {:ok, second} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert second["outcome"] == "already_absent"
    assert second["resource_id"] == retained.workspace_id
    assert second["active"] == false

    assert {:ok, third} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert third == second
  end

  test "retained unsupported type/decision/reason and bad id fail closed", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {retained, _expected_identity} = retained_identity(fixture)
    auth = verified_auth("agent_retained_apply_reject")
    force_retained_expired_ms(retained.workspace_id)
    {_, expected_identity} = retained_identity_for(retained.workspace_id)
    base = retained_settle_decision(retained.workspace_id, expected_identity)

    for {patch, expected_detail} <- retained_unsupported_cases(base) do
      decision = deep_merge(base, patch)

      assert {:error, {:unsupported_reconciliation_apply, detail}} =
               Actions.apply_coding_reconciliation_decision(auth, decision)

      assert detail == expected_detail
    end

    live_identity =
      expected_identity
      |> legacy_retained_identity()
      |> Map.put("resource_type", "live_workspace_lease")

    live_decision =
      base
      |> Map.put("resource_type", "live_workspace_lease")
      |> Map.put("expected_identity", live_identity)

    assert {:error,
            {:unsupported_reconciliation_apply,
             %{
               "resource_type" => "live_workspace_lease",
               "decision" => "settle",
               "reason" => "retained_expired"
             }}} = Actions.apply_coding_reconciliation_decision(auth, live_decision)

    bad_id =
      base
      |> Map.put("resource_id", "ws_NOT_HEX")
      |> put_in(["expected_identity", "resource_id"], "ws_NOT_HEX")

    assert {:error, :invalid_live_workspace_id} =
             Actions.apply_coding_reconciliation_decision(auth, bad_id)

    assert Map.has_key?(
             :sys.get_state(WorkspaceLeaseRegistry).retained_by_id,
             retained.workspace_id
           )
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

  defp leased_project_for_registry(tmp_dir, server) do
    repo =
      create_base_project(Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"))

    task_id = "task_reconciliation_apply_#{System.unique_integer([:positive])}"
    principal_id = "agent_reconciliation_apply_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      WorkspaceLeaseRegistry.acquire(
        %{
          repo_path: repo,
          branch: "test/reconciliation-apply-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees"),
          task_id: task_id,
          principal_id: principal_id
        },
        server: server
      )

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.release(
          lease.workspace_id,
          :remove,
          Map.put(context, :server, server)
        )
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

  defp live_identity(fixture) do
    state = :sys.get_state(WorkspaceLeaseRegistry)
    lease = Map.fetch!(state.leases, fixture.lease.workspace_id)

    assert {:ok, expected_identity} =
             WorkspaceReconciliationProjection.live_comparison_identity(
               state,
               lease.workspace_id
             )

    {fixture.lease, expected_identity}
  end

  defp live_settle_decision(workspace_id, expected_identity) do
    {:ok, decision} =
      ReconciliationDecision.new(%{
        "schema_version" => 1,
        "resource_type" => "live_workspace_lease",
        "resource_id" => workspace_id,
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

  defp retained_identity(fixture) do
    assert {:ok, _view} =
             WorkspaceLeaseRegistry.release(
               fixture.lease.workspace_id,
               :retain,
               Map.put(fixture.context, :server, workspace_registry_server())
             )

    retained_identity_for(fixture.lease.workspace_id)
  end

  defp retained_identity_for(workspace_id) do
    state = :sys.get_state(workspace_registry_server())
    retained = Map.fetch!(state.retained_by_id, workspace_id)

    assert {:ok, inventory} =
             WorkspaceLeaseRegistry.reconciliation_inventory(nil, nil, 256,
               server: workspace_registry_server()
             )

    resource =
      Enum.find(inventory["resources"], fn resource ->
        resource["resource_type"] == "retained_workspace_record" and
          resource["resource_id"] == workspace_id
      end)

    assert is_map(resource)
    # The branch-tip security regression must be runnable as a test-only hunk
    # against the parent: fixed code supplies the v2 source proof, while the
    # parent falls back to its legacy projected comparison identity and exposes
    # the unsafe archive/delete behavior.
    expected_identity =
      case Map.get(resource, "expected_identity") do
        identity when is_map(identity) -> identity
        _ -> legacy_projected_retained_identity(resource)
      end

    {retained, expected_identity}
  end

  defp retained_inventory_identity(workspace_id) do
    assert {:ok, inventory} =
             WorkspaceLeaseRegistry.reconciliation_inventory(nil, nil, 256,
               server: workspace_registry_server()
             )

    resource =
      Enum.find(inventory["resources"], fn resource ->
        resource["resource_type"] == "retained_workspace_record" and
          resource["resource_id"] == workspace_id
      end)

    assert is_map(resource)
    assert is_map(resource["expected_identity"])
    resource["expected_identity"]
  end

  defp legacy_projected_retained_identity(resource) do
    retry_state = Map.get(resource, "retry_state", %{})

    %{
      "resource_type" => resource["resource_type"],
      "resource_id" => resource["resource_id"],
      "task_id" => resource["task_id"],
      "principal_id" => resource["principal_id"],
      "lifecycle" => resource["lifecycle"],
      "active" => resource["active"],
      "ownership" => resource["ownership"],
      "branch_provenance" => resource["branch_provenance"],
      "cleanup_armed" => resource["cleanup_armed"] || false,
      "dormant" => resource["dormant"] || retry_state["dormant"] || false,
      "retry_count" => retry_state["count"] || 0,
      "retry_limit" => retry_state["limit"] || 0,
      "expires_at" => resource["expires_at"]
    }
  end

  defp force_retained_expired_ms(workspace_id) do
    :sys.replace_state(workspace_registry_server(), fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      case Map.get(current, :expiry_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end

      updated =
        current
        |> Map.put(:expires_at_ms, System.monotonic_time(:millisecond) - 1)
        |> Map.put(:expiry_ref, nil)

      put_retained_indexes(state, updated)
    end)
  end

  defp put_retained_indexes(state, retained) do
    %{
      state
      | retained_by_id: Map.put(state.retained_by_id, retained.workspace_id, retained),
        retained_by_target: Map.put(state.retained_by_target, retained.target, retained)
    }
  end

  defp put_retained_discard_phase(workspace_id, phase, settlement_tip) do
    :sys.replace_state(workspace_registry_server(), fn state ->
      current = Map.fetch!(state.retained_by_id, workspace_id)

      updated =
        current
        |> Map.put(:lifecycle, :discarding)
        |> Map.put(:discard_phase, phase)
        |> Map.put(:settlement_tip, settlement_tip)
        |> Map.put(:durable_lifecycle, nil)
        |> Map.put(:expiry_ref, nil)

      put_retained_indexes(state, updated)
    end)
  end

  defp drop_workspace_residue(workspace_id) when is_binary(workspace_id) do
    :sys.replace_state(WorkspaceLeaseRegistry, fn state ->
      retained_by_target =
        state
        |> Map.get(:retained_by_target, %{})
        |> Map.reject(fn {_k, v} -> is_map(v) and Map.get(v, :workspace_id) == workspace_id end)

      blockers_by_target =
        state
        |> Map.get(:retention_blockers_by_target, %{})
        |> Map.reject(fn {_k, v} -> is_map(v) and Map.get(v, :workspace_id) == workspace_id end)

      %{
        state
        | leases: Map.delete(state.leases, workspace_id),
          retained_by_id: Map.delete(state.retained_by_id, workspace_id),
          retention_blockers: Map.delete(Map.get(state, :retention_blockers, %{}), workspace_id),
          retained_by_target: retained_by_target,
          retention_blockers_by_target: blockers_by_target
      }
    end)
  end

  defp retained_index_has_workspace?(state, workspace_id) do
    Enum.any?(Map.get(state, :retained_by_target, %{}), fn {_k, v} ->
      is_map(v) and Map.get(v, :workspace_id) == workspace_id
    end) or
      Enum.any?(Map.get(state, :retention_blockers_by_target, %{}), fn {_k, v} ->
        is_map(v) and Map.get(v, :workspace_id) == workspace_id
      end)
  end

  defp retained_settle_decision(workspace_id, expected_identity) do
    {:ok, decision} =
      ReconciliationDecision.new(%{
        "schema_version" => ReconciliationDecision.schema_version(),
        "resource_type" => "retained_workspace_record",
        "resource_id" => workspace_id,
        "task_id" => expected_identity["task_id"],
        "principal_id" => expected_identity["principal_id"],
        "decision" => "settle",
        "reason" => "retained_expired",
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

  defp retained_unsupported_cases(_base) do
    [
      {
        %{"reason" => "terminal_active_resource"},
        %{
          "resource_type" => "retained_workspace_record",
          "decision" => "settle",
          "reason" => "terminal_active_resource"
        }
      },
      {
        %{"decision" => "keep"},
        %{
          "resource_type" => "retained_workspace_record",
          "decision" => "keep",
          "reason" => "retained_expired"
        }
      }
    ]
  end

  defp legacy_retained_identity(identity) do
    Map.take(identity, [
      "resource_type",
      "resource_id",
      "task_id",
      "principal_id",
      "lifecycle",
      "active",
      "ownership",
      "branch_provenance",
      "cleanup_armed",
      "dormant",
      "retry_count",
      "retry_limit",
      "expires_at"
    ])
  end

  defp unsupported_cases(base) do
    [
      {
        %{
          "resource_type" => "retained_workspace_record",
          "expected_identity" =>
            Map.put(base["expected_identity"], "resource_type", "retained_workspace_record")
        },
        %{
          "resource_type" => "retained_workspace_record",
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

  defp live_unsupported_cases(base) do
    [
      {
        %{
          "resource_type" => "retained_workspace_record",
          "expected_identity" =>
            Map.put(base["expected_identity"], "resource_type", "retained_workspace_record")
        },
        %{
          "resource_type" => "retained_workspace_record",
          "decision" => "settle",
          "reason" => "terminal_active_resource"
        }
      },
      {
        %{"decision" => "keep"},
        %{
          "resource_type" => "live_workspace_lease",
          "decision" => "keep",
          "reason" => "terminal_active_resource"
        }
      },
      {
        %{"reason" => "live_task_owner_alive"},
        %{
          "resource_type" => "live_workspace_lease",
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

  test "acp managed session exact authorize URI and settled apply via Config.ai_module" do
    worker_id = acp_worker_id()
    expected = acp_expected_identity(worker_id)
    decision = acp_settle_decision(worker_id, expected)
    principal = "agent_acp_apply_ok"
    auth = verified_auth(principal)

    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)
    Application.put_env(:arbor_actions, :ai_module, RecordingAI)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_id"] == worker_id
    assert receipt["resource_type"] == "acp_managed_session"
    assert receipt["active"] == false
    assert receipt["status"] == "removed"

    assert_received {:authorize_called, ^principal, uri, opts}

    assert uri ==
             "arbor://coding/reconciliation/apply/acp_managed_session/" <> worker_id

    assert Keyword.get(opts, :verify_identity) == false
    assert match?(%SignedRequest{agent_id: ^principal}, Keyword.get(opts, :signed_request))

    assert_received {:ai_settle_called, fields}
    assert fields == %{"resource_id" => worker_id, "expected_identity" => expected}
  end

  test "acp managed session requires the exact one-arity AI facade contract" do
    worker_id = acp_worker_id()
    expected = acp_expected_identity(worker_id)
    decision = acp_settle_decision(worker_id, expected)
    auth = verified_auth("agent_acp_arity_contract")

    Application.put_env(:arbor_actions, :ai_module, ArityTwoOnlyAI)

    assert {:error, :reconciliation_ai_unavailable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:ai_arity_two_settle_called, _, _}
  end

  test "acp managed session unauthorized and pending-approval fail closed without AI call" do
    worker_id = acp_worker_id()
    decision = acp_settle_decision(worker_id, acp_expected_identity(worker_id))
    auth = verified_auth("agent_acp_denied")
    Application.put_env(:arbor_actions, :ai_module, RecordingAI)

    Application.put_env(:arbor_actions, :security_module, DenySecurity)

    assert {:error, {:unauthorized, :denied}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:ai_settle_called, _}

    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:pending_approval, "proposal_test_1"}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:ai_settle_called, _}
  end

  test "acp managed session unsupported decision and bad handle fail closed without AI call" do
    worker_id = acp_worker_id()
    base = acp_settle_decision(worker_id, acp_expected_identity(worker_id))
    auth = verified_auth("agent_acp_reject")
    Application.put_env(:arbor_actions, :ai_module, RecordingAI)

    keep = Map.put(base, "decision", "keep")

    assert {:error, {:unsupported_reconciliation_apply, detail}} =
             Actions.apply_coding_reconciliation_decision(auth, keep)

    assert detail == %{
             "resource_type" => "acp_managed_session",
             "decision" => "keep",
             "reason" => "terminal_active_resource"
           }

    refute_received {:ai_settle_called, _}

    bad_id = "acp_worker_" <> String.duplicate("g", 32)

    bad =
      base
      |> Map.put("resource_id", bad_id)
      |> put_in(["expected_identity", "resource_id"], bad_id)
      |> put_in(["expected_identity", "worker_session_id"], bad_id)

    assert {:error, :invalid_acp_managed_session_id} =
             Actions.apply_coding_reconciliation_decision(auth, bad)

    refute_received {:ai_settle_called, _}

    uppercase = "acp_worker_" <> String.duplicate("A", 32)

    upper =
      base
      |> Map.put("resource_id", uppercase)
      |> put_in(["expected_identity", "resource_id"], uppercase)
      |> put_in(["expected_identity", "worker_session_id"], uppercase)

    assert {:error, :invalid_acp_managed_session_id} =
             Actions.apply_coding_reconciliation_decision(auth, upper)

    refute_received {:ai_settle_called, _}
  end

  test "acp managed session source failures pass through and never report settled" do
    worker_id = acp_worker_id()
    decision = acp_settle_decision(worker_id, acp_expected_identity(worker_id))
    auth = verified_auth("agent_acp_source_fail")

    Application.put_env(:arbor_actions, :ai_module, DriftAI)

    assert {:error, {:reconciliation_identity_conflict, conflict}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert conflict["resource_id"] == worker_id
    assert_received {:ai_settle_called, _}

    Application.put_env(:arbor_actions, :ai_module, ClosingAI)

    assert {:error, :close_cleanup_in_progress} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert_received {:ai_settle_called, _}

    Application.put_env(:arbor_actions, :ai_module, ResidueAI)

    assert {:error, :settlement_residue} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    assert_received {:ai_settle_called, _}

    Application.put_env(:arbor_actions, :ai_module, AbsentAI)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "already_absent"
    assert receipt["resource_id"] == worker_id
    refute receipt["outcome"] == "settled"
  end

  defp acp_worker_id do
    "acp_worker_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp acp_expected_identity(worker_id) do
    %{
      "resource_type" => "acp_managed_session",
      "resource_id" => worker_id,
      "worker_session_id" => worker_id,
      "provider_session_id" => "prov_test",
      "provider" => "test",
      "model" => "model-a",
      "status" => "ready",
      "pooled" => false,
      "return_to_pool" => false,
      "task_id" => "task_acp_settle",
      "principal_id" => "agent_acp_settle",
      "owner_present" => true,
      "owner_alive" => false,
      "session_alive" => true,
      "close_cleanup_in_progress" => false
    }
  end

  defp acp_settle_decision(worker_id, expected_identity) do
    {:ok, decision} =
      ReconciliationDecision.new(%{
        "schema_version" => 1,
        "resource_type" => "acp_managed_session",
        "resource_id" => worker_id,
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

  test "pending_approval consensus exact URI and source dispatch via Config.consensus_module" do
    {resource_id, expected, decision} = pending_approval_decision("consensus", "prop_actions_1")
    principal = "agent_pa_consensus"
    auth = verified_auth(principal)

    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)
    Application.put_env(:arbor_actions, :consensus_module, RecordingConsensus)
    Application.put_env(:arbor_actions, :comms_module, RecordingComms)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_id"] == resource_id
    assert receipt["resource_type"] == "pending_approval"

    assert_received {:authorize_called, ^principal, uri, opts}

    assert uri ==
             "arbor://coding/reconciliation/apply/pending_approval/" <> resource_id

    assert Keyword.get(opts, :verify_identity) == false
    assert match?(%SignedRequest{agent_id: ^principal}, Keyword.get(opts, :signed_request))

    assert_received {:consensus_settle_called, fields}
    assert fields == %{"resource_id" => resource_id, "expected_identity" => expected}
    refute_received {:comms_settle_called, _}
  end

  test "pending_approval interaction source dispatches to Config.comms_module" do
    {resource_id, expected, decision} = pending_approval_decision("interaction", "irq_actions_1")
    auth = verified_auth("agent_pa_comms")

    Application.put_env(:arbor_actions, :consensus_module, RecordingConsensus)
    Application.put_env(:arbor_actions, :comms_module, RecordingComms)

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "settled"
    assert receipt["resource_id"] == resource_id

    assert_received {:comms_settle_called, fields}
    assert fields["expected_identity"] == expected
    refute_received {:consensus_settle_called, _}
  end

  test "Apple Container settlement authorizes exact URI before exact Shell dispatch" do
    {resource_id, expected, decision} = apple_container_decision()
    principal = "agent_apple_apply"
    auth = verified_auth(principal)
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)

    Application.put_env(
      :arbor_actions,
      :coding_reconciliation_shell_module,
      RecordingAppleContainerShell
    )

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt == %{"outcome" => "settled", "resource_id" => resource_id}
    assert_receive {:authorize_called, ^principal, uri, opts}
    assert uri == "arbor://coding/reconciliation/apply/apple_container_unit/" <> resource_id
    assert Keyword.get(opts, :verify_identity) == false
    assert_receive {:apple_container_settle_called, fields}
    assert fields == %{"resource_id" => resource_id, "expected_identity" => expected}
  end

  test "Apple Container settlement fails closed for deny, ask, canonical mismatch, and unavailable facade" do
    {_resource_id, _expected, decision} = apple_container_decision()
    auth = verified_auth("agent_apple_reject")

    Application.put_env(:arbor_actions, :security_module, DenySecurity)

    Application.put_env(
      :arbor_actions,
      :coding_reconciliation_shell_module,
      RecordingAppleContainerShell
    )

    assert {:error, {:unauthorized, :denied}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:apple_container_settle_called, _}

    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:pending_approval, "proposal_test_1"}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:apple_container_settle_called, _}

    bad =
      put_in(
        decision,
        ["expected_identity", "resource_id"],
        "acu_v1_" <> String.duplicate("d", 32)
      )

    assert {:error, _} = Actions.apply_coding_reconciliation_decision(auth, bad)
    refute_received {:apple_container_settle_called, _}

    Application.put_env(:arbor_actions, :security_module, AllowSecurity)

    Application.put_env(
      :arbor_actions,
      :coding_reconciliation_shell_module,
      ArityTwoAppleContainerShell
    )

    assert {:error, :reconciliation_shell_unavailable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)
  end

  test "Apple Container settlement propagates source errors and receipts unchanged" do
    {resource_id, _expected, decision} = apple_container_decision()
    auth = verified_auth("agent_apple_source")

    Application.put_env(
      :arbor_actions,
      :coding_reconciliation_shell_module,
      ErrorAppleContainerShell
    )

    assert {:error, :source_conflict} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    Application.put_env(
      :arbor_actions,
      :coding_reconciliation_shell_module,
      AlreadyAbsentAppleContainerShell
    )

    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)

    assert receipt == %{
             "outcome" => "already_absent",
             "resource_id" => resource_id,
             "active" => false
           }
  end

  test "security regression: unauthorized pending_approval never calls backends" do
    {_id, _expected, decision} = pending_approval_decision("consensus", "prop_denied")
    auth = verified_auth("agent_pa_denied")

    Application.put_env(:arbor_actions, :security_module, DenySecurity)
    Application.put_env(:arbor_actions, :consensus_module, RecordingConsensus)
    Application.put_env(:arbor_actions, :comms_module, RecordingComms)

    assert {:error, {:unauthorized, :denied}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:consensus_settle_called, _}
    refute_received {:comms_settle_called, _}

    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:pending_approval, "proposal_test_1"}}} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    refute_received {:consensus_settle_called, _}
    refute_received {:comms_settle_called, _}
  end

  test "security regression: non-terminal pending_approval decision is unsupported without backend call" do
    {resource_id, expected, base} = pending_approval_decision("interaction", "irq_keep")
    auth = verified_auth("agent_pa_keep")
    Application.put_env(:arbor_actions, :comms_module, RecordingComms)

    keep = Map.put(base, "decision", "keep")

    assert {:error, {:unsupported_reconciliation_apply, detail}} =
             Actions.apply_coding_reconciliation_decision(auth, keep)

    assert detail == %{
             "resource_type" => "pending_approval",
             "decision" => "keep",
             "reason" => "terminal_active_resource"
           }

    refute_received {:comms_settle_called, _}
    _ = {resource_id, expected}
  end

  test "pending_approval propagates source unavailable and already_absent receipts" do
    {_id, _expected, decision} = pending_approval_decision("interaction", "irq_unavail")
    auth = verified_auth("agent_pa_unavail")

    Application.put_env(:arbor_actions, :comms_module, UnavailableComms)

    assert {:error, :current_identity_unavailable} =
             Actions.apply_coding_reconciliation_decision(auth, decision)

    Application.put_env(:arbor_actions, :comms_module, AbsentComms)
    assert {:ok, receipt} = Actions.apply_coding_reconciliation_decision(auth, decision)
    assert receipt["outcome"] == "already_absent"
  end

  test "pending_approval rejects invalid resource id before authorize" do
    auth = verified_auth("agent_pa_bad_id")
    Application.put_env(:arbor_actions, :security_module, RecordingSecurity)
    Application.put_env(:arbor_actions, :comms_module, RecordingComms)

    bad = %{
      "schema_version" => 1,
      "resource_type" => "pending_approval",
      "resource_id" => "not_an_approval_id",
      "task_id" => nil,
      "principal_id" => "agent_1",
      "decision" => "settle",
      "reason" => "terminal_active_resource",
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => "not_an_approval_id",
        "approval_id" => "x",
        "source" => "interaction",
        "task_id" => nil,
        "agent_id" => "agent_1",
        "principal_id" => "agent_1",
        "approver_id" => nil,
        "resource_uri" => nil,
        "action" => nil,
        "status" => "pending",
        "created_at" => nil
      },
      "evidence" => %{
        "task_presence" => "absent",
        "task_state" => nil,
        "owner_status" => "dead",
        "journal_status" => "complete"
      }
    }

    assert {:error, _} = Actions.apply_coding_reconciliation_decision(auth, bad)
    refute_received {:authorize_called, _, _, _}
    refute_received {:comms_settle_called, _}
  end

  defp pending_approval_decision(source, approval_id) do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id(source, approval_id)

    expected = %{
      "resource_type" => "pending_approval",
      "resource_id" => resource_id,
      "approval_id" => approval_id,
      "source" => source,
      "task_id" => "task_pa_1",
      "agent_id" => "agent_pa_1",
      "principal_id" => "agent_pa_1",
      "approver_id" => nil,
      "resource_uri" => "arbor://shell/exec",
      "action" => "execute",
      "status" => "pending",
      "created_at" => "2026-07-28T00:00:00Z"
    }

    {:ok, decision} =
      ReconciliationDecision.new(%{
        "schema_version" => 1,
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "task_id" => "task_pa_1",
        "principal_id" => "agent_pa_1",
        "decision" => "settle",
        "reason" => "terminal_active_resource",
        "expected_identity" => expected,
        "evidence" => %{
          "task_presence" => "observed",
          "task_state" => "done",
          "owner_status" => "dead",
          "journal_status" => "complete"
        }
      })

    {resource_id, expected, ReconciliationDecision.to_map(decision)}
  end

  defp apple_container_decision do
    suffix = String.duplicate("c", 32)
    resource_id = "acu_v1_" <> suffix

    expected = %{
      "resource_type" => "apple_container_unit",
      "resource_id" => resource_id,
      "unit_name" => "arbor-v1-" <> suffix,
      "execution_id" => "exec-c",
      "reserved_at_ms" => 100,
      "owner_status" => "known",
      "validation_resource_id" => "validation_" <> suffix,
      "workspace_id" => "ws_" <> suffix,
      "task_id" => "task-apple",
      "principal_id" => "principal-apple",
      "source_record_digest" => String.duplicate("b", 64)
    }

    {:ok, decision} =
      ReconciliationDecision.new(%{
        "schema_version" => 1,
        "resource_type" => "apple_container_unit",
        "resource_id" => resource_id,
        "task_id" => "task-apple",
        "principal_id" => "principal-apple",
        "decision" => "settle",
        "reason" => "terminal_active_resource",
        "expected_identity" => expected,
        "evidence" => %{
          "task_presence" => "observed",
          "task_state" => "done",
          "owner_status" => "live",
          "journal_status" => "complete"
        }
      })

    {resource_id, expected, ReconciliationDecision.to_map(decision)}
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

  defp start_durable_retained_registry(backend \\ Arbor.Persistence.Store.ETS) do
    store_name = String.to_atom("reconciliation_retained_#{System.unique_integer([:positive])}")
    server = String.to_atom("reconciliation_registry_#{System.unique_integer([:positive])}")

    start_supervised!({Arbor.Persistence.Store.ETS, name: store_name, max_entries: 1_000},
      id: store_name
    )

    start_supervised!(
      {WorkspaceLeaseRegistry,
       [
         name: server,
         retention_journal: {store_name, backend},
         retention_ttl_ms: 60_000,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
       ]},
      id: server
    )

    Application.put_env(:arbor_actions, :workspace_lease_registry_server, server)
    server
  end

  defp durable_retained_marker(workspace_id) do
    state = :sys.get_state(workspace_registry_server())
    %{store_name: store_name, backend: backend} = state.retention_journal
    {:ok, key} = RetentionJournal.record_key(workspace_id)
    Persistence.get(store_name, backend, key)
  end

  defp put_durable_retained_marker(workspace_id, marker) do
    state = :sys.get_state(workspace_registry_server())
    %{store_name: store_name, backend: backend} = state.retention_journal
    {:ok, key} = RetentionJournal.record_key(workspace_id)
    :ok = Persistence.put(store_name, backend, key, marker)
  end

  defp retention_store_name do
    state = :sys.get_state(workspace_registry_server())
    get_in(state, [:retention_journal, :store_name])
  end

  defp workspace_registry_server do
    Application.get_env(
      :arbor_actions,
      :workspace_lease_registry_server,
      WorkspaceLeaseRegistry
    )
  end

  defp evidence_ref_for(task_id, workspace_id) do
    workspace_digest = :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower)
    task_digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
    "refs/arbor/evidence/#{workspace_digest}/#{task_digest}"
  end

  defp ref_exists?(repo, ref) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", repo, "show-ref", "--verify", "--quiet", ref],
        stderr_to_stdout: true
      )
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
