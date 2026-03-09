defmodule Arbor.Consensus.AuthorizationE2ETest do
  @moduledoc """
  End-to-end tests for consensus facade authorization (authorize_* functions).

  Tests the full flow: CapabilityStore grant -> Security.authorize -> Consensus facade.
  Validates both authorized and unauthorized paths, plus permissive mode fallback.

  Unlike the basic authorization_test.exs (which runs in permissive mode because
  Security.healthy?() returns false), this suite starts ALL required security
  processes so that authorization is fully enforced.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore

  @caller_id "agent_e2e_consensus_test"

  setup_all do
    # Start all security processes needed for Security.healthy?() to return true.
    # Order matters: Identity.Registry must start before SystemAuthority.
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    for {mod, opts} <- security_children do
      unless Process.whereis(mod) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {mod, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> raise "Failed to start #{mod}: #{inspect(reason)}"
        end
      end
    end

    # Verify Security is fully operational
    Process.sleep(20)

    unless Security.healthy?() do
      raise "Security.healthy?() returned false after starting all processes"
    end

    :ok
  end

  setup do
    # Save original config values
    original_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    original_signing = Application.get_env(:arbor_security, :capability_signing_required)
    original_strict = Application.get_env(:arbor_security, :strict_identity_mode)
    original_approval = Application.get_env(:arbor_security, :approval_guard_enabled)
    original_receipts = Application.get_env(:arbor_security, :invocation_receipts_enabled)

    # Disable security features that add complexity beyond what we're testing
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)

    on_exit(fn ->
      # Restore original config
      restore_env(:arbor_security, :reflex_checking_enabled, original_reflex)
      restore_env(:arbor_security, :capability_signing_required, original_signing)
      restore_env(:arbor_security, :strict_identity_mode, original_strict)
      restore_env(:arbor_security, :approval_guard_enabled, original_approval)
      restore_env(:arbor_security, :invocation_receipts_enabled, original_receipts)

      # Clean up capabilities granted during tests
      if Process.whereis(CapabilityStore), do: CapabilityStore.revoke_all(@caller_id)
    end)

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # ============================================================================
  # authorize_propose/3
  # ============================================================================

  describe "authorize_propose/3" do
    test "succeeds when caller has arbor://consensus/propose capability" do
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/propose"
        )

      attrs = %{
        proposer: @caller_id,
        topic: :code_modification,
        description: "E2E authorized proposal"
      }

      assert {:ok, proposal_id} = Arbor.Consensus.authorize_propose(@caller_id, attrs)
      assert is_binary(proposal_id)
    end

    test "returns unauthorized when caller lacks capability" do
      attrs = %{
        proposer: @caller_id,
        topic: :code_modification,
        description: "Should be blocked"
      }

      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_propose(@caller_id, attrs)
    end
  end

  # ============================================================================
  # authorize_ask/3
  # ============================================================================

  describe "authorize_ask/3" do
    test "succeeds when caller has arbor://consensus/ask capability" do
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/ask"
        )

      assert {:ok, proposal_id} =
               Arbor.Consensus.authorize_ask(@caller_id, "E2E advisory question")

      assert is_binary(proposal_id)
    end

    test "returns unauthorized when caller lacks capability" do
      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_ask(@caller_id, "Should be blocked")
    end
  end

  # ============================================================================
  # authorize_decide/3
  # ============================================================================

  describe "authorize_decide/3" do
    test "returns unauthorized when caller lacks capability" do
      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_decide(@caller_id, "Should be blocked")
    end

    test "passes auth when caller has arbor://consensus/decide capability" do
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/decide"
        )

      # decide delegates to Consult.decide which needs LLM, so we just verify
      # authorization passes (it won't return {:error, {:unauthorized, _}})
      result = Arbor.Consensus.authorize_decide(@caller_id, "E2E decision question")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  # ============================================================================
  # authorize_cancel/3
  # ============================================================================

  describe "authorize_cancel/3" do
    test "succeeds when caller has arbor://consensus/cancel capability" do
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/cancel"
        )

      # Create a proposal to cancel
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: @caller_id,
          topic: :code_modification,
          description: "Proposal to be cancelled in E2E test"
        })

      result = Arbor.Consensus.authorize_cancel(@caller_id, proposal_id)
      # Should not be unauthorized — may fail for other reasons (already decided)
      refute match?({:error, {:unauthorized, _}}, result)
    end

    test "returns unauthorized when caller lacks capability" do
      # Create a real proposal so the error is from auth, not :not_found
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_other",
          topic: :code_modification,
          description: "Proposal for cancel auth test"
        })

      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_cancel(@caller_id, proposal_id)
    end
  end

  # ============================================================================
  # Force operations require explicit capabilities
  # ============================================================================

  describe "authorize_force_approve/4" do
    test "returns unauthorized when caller lacks arbor://consensus/force_approve" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_other",
          topic: :code_modification,
          description: "Proposal for force_approve auth test"
        })

      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_force_approve(@caller_id, proposal_id, @caller_id)
    end

    test "passes facade auth when caller has arbor://consensus/force_approve capability" do
      # Facade-level auth requires arbor://consensus/force_approve on caller_id
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/force_approve"
        )

      # Coordinator-level auth requires arbor://consensus/admin on approver_id
      {:ok, _admin_cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/admin"
        )

      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_other",
          topic: :code_modification,
          description: "Proposal to force approve in E2E test"
        })

      # Wait briefly for evaluation
      Process.sleep(50)

      result =
        Arbor.Consensus.authorize_force_approve(@caller_id, proposal_id, @caller_id)

      # Should not be unauthorized at either layer
      refute match?({:error, {:unauthorized, _}}, result)
    end

    test "propose capability does NOT authorize force_approve" do
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/propose"
        )

      {:ok, proposal_id} =
        Arbor.Consensus.authorize_propose(@caller_id, %{
          proposer: @caller_id,
          topic: :code_modification,
          description: "Proposal to test capability isolation"
        })

      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_force_approve(@caller_id, proposal_id, @caller_id)
    end
  end

  describe "authorize_force_reject/4" do
    test "returns unauthorized when caller lacks arbor://consensus/force_reject" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_other",
          topic: :code_modification,
          description: "Proposal for force_reject auth test"
        })

      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_force_reject(@caller_id, proposal_id, @caller_id)
    end

    test "passes facade auth when caller has arbor://consensus/force_reject capability" do
      # Facade-level auth requires arbor://consensus/force_reject on caller_id
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/force_reject"
        )

      # Coordinator-level auth requires arbor://consensus/admin on rejector_id
      {:ok, _admin_cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/admin"
        )

      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_other",
          topic: :code_modification,
          description: "Proposal to force reject in E2E test"
        })

      Process.sleep(50)

      result =
        Arbor.Consensus.authorize_force_reject(@caller_id, proposal_id, @caller_id)

      refute match?({:error, {:unauthorized, _}}, result)
    end

    test "force_approve capability does NOT authorize force_reject" do
      {:ok, _cap} =
        Security.grant(
          principal: @caller_id,
          resource: "arbor://consensus/force_approve"
        )

      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_other",
          topic: :code_modification,
          description: "Proposal to test force capability isolation"
        })

      assert {:error, {:unauthorized, _reason}} =
               Arbor.Consensus.authorize_force_reject(@caller_id, proposal_id, @caller_id)
    end
  end

  # ============================================================================
  # Permissive mode — when Security is not fully available
  # ============================================================================

  describe "permissive mode" do
    test "operations are allowed when Security.healthy?() returns false" do
      # The Consensus module's private authorize/2 function checks
      # security_available?() which calls Security.healthy?().
      # When it returns false, all operations are permitted (fail-open for dev/test).
      #
      # We verify this by temporarily making Security unhealthy.
      # Use terminate_child (not GenServer.stop) to prevent supervisor auto-restart.
      :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, CapabilityStore)
      Process.sleep(10)

      refute Security.healthy?(),
             "Security should be unhealthy after terminating CapabilityStore"

      # All operations should be permitted without capabilities
      attrs = %{
        proposer: @caller_id,
        topic: :code_modification,
        description: "Permissive mode proposal"
      }

      result_propose = Arbor.Consensus.authorize_propose(@caller_id, attrs)
      refute match?({:error, {:unauthorized, _}}, result_propose)

      result_ask = Arbor.Consensus.authorize_ask(@caller_id, "Permissive mode question")
      refute match?({:error, {:unauthorized, _}}, result_ask)

      # Restart CapabilityStore so subsequent tests work
      Supervisor.restart_child(Arbor.Security.Supervisor, CapabilityStore)
      Process.sleep(20)
    end
  end
end
