defmodule Arbor.Security.CapabilityUsageMutationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-016"

  @moduletag :fast
  @moduletag :security

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore

  @tag spec: "SSEC-016"
  test "security regression: raw usage mutation cannot exhaust a finite-use capability" do
    principal = "agent_usage_mutation_#{System.unique_integer([:positive])}"
    resource = "arbor://shell/exec/usage_mutation_#{System.unique_integer([:positive])}"

    on_exit(fn -> CapabilityStore.revoke_all_fixture(principal) end)

    assert {:ok, capability} =
             Security.grant_fixture(
               principal: principal,
               resource: resource,
               max_uses: 1
             )

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.increment_usage(capability.id)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.consume_usage(capability.id, 1)

    owner = Process.whereis(CapabilityStore)

    assert {:error, :capability_mutation_unauthorized} =
             GenServer.call(owner, {:increment_usage, capability.id})

    assert {:error, :capability_mutation_unauthorized} =
             GenServer.call(owner, {:consume_usage, capability.id, 1})

    caller = self()

    forged_proof = fn challenge ->
      {:arbor_security_receipt_issuance_v1, challenge, caller, :capability_usage,
       %{capability: capability}}
    end

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.consume_usage_authorized(forged_proof)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)
  end
end
