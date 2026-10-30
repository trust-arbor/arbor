defmodule Arbor.Security.CapabilityStoreMutationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004"

  alias Arbor.Contracts.Security.Capability

  alias Arbor.Security.{
    CapabilityStore,
    DisclosureCapability,
    Kernel,
    SubagentIsolation,
    SystemAuthority
  }

  @moduletag :fast

  @tag spec: "SSEC-004"
  test "security regression: direct public put cannot create capability authority" do
    {:ok, cap} =
      Capability.new(
        resource_uri:
          "arbor://fs/read/direct-store-forgery/#{System.unique_integer([:positive])}",
        principal_id: "agent_direct_store_attacker"
      )

    assert {:error, :capability_mutation_unauthorized} = CapabilityStore.put(cap)
    assert {:error, :not_found} = CapabilityStore.get(cap.id)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.put_authorized(cap, :grant, "forged-receipt")

    assert {:error, :not_found} = CapabilityStore.get(cap.id)
  end

  test "security regression: direct and forged revocation cannot destroy capability authority" do
    principal = "agent_direct_revoke_victim_#{System.unique_integer([:positive])}"
    session = "session_#{System.unique_integer([:positive])}"
    task = "task_#{System.unique_integer([:positive])}"

    {:ok, cap} =
      Capability.new(
        resource_uri: "arbor://fs/read/direct-revoke-victim",
        principal_id: principal,
        session_id: session,
        task_id: task
      )

    assert {:ok, signed_cap} = SystemAuthority.sign_capability_for_test(cap)
    assert {:ok, :applied, capability_id} = CapabilityStore.acknowledged_put_fixture(signed_cap)
    assert capability_id == cap.id

    fence = %{
      capability_id: cap.id,
      principal_id: cap.principal_id,
      capability_digest:
        signed_cap
        |> Capability.signing_payload()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    }

    assert {:error, :capability_mutation_unauthorized} = CapabilityStore.revoke(cap.id)
    assert {:error, :capability_mutation_unauthorized} = CapabilityStore.revoke_all(principal)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.cascade_revoke(cap.id)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.revoke_by_session(session)

    assert {:error, :capability_mutation_unauthorized} = CapabilityStore.revoke_by_task(task)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.acknowledged_revoke(cap.id)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.revoke_authorized(fence, "forged-receipt")

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.acknowledged_revoke_authorized(fence, "forged-receipt")

    assert {:ok, stored} = CapabilityStore.get(cap.id)
    assert stored.principal_id == principal

    assert {:ok, :applied, ^capability_id} =
             CapabilityStore.acknowledged_revoke_fixture(capability_id)
  end

  test "security regression: authority-creating helper APIs require an owned actor" do
    assert {:error, :capability_mutation_unauthorized} =
             Kernel.grant_capability(
               principal_id: "agent_kernel_target",
               resource_uri: "arbor://fs/read/kernel-unauthorized"
             )

    assert {:error, :capability_mutation_unauthorized} =
             Kernel.revoke_capability(capability_id: "cap_kernel_target")

    assert {:error, :capability_mutation_unauthorized} =
             SubagentIsolation.create_isolation(
               parent_id: "agent_parent",
               worker_id: "agent_worker",
               resource_uris: ["arbor://fs/read/unauthorized"]
             )

    assert {:error, :capability_mutation_unauthorized} =
             SubagentIsolation.cleanup("task_unauthorized")

    assert {:error, :capability_mutation_unauthorized} =
             DisclosureCapability.issue(
               principal_id: "agent_disclosure_target",
               session_id: "session_disclosure",
               task_id: "task_disclosure",
               principal_scope: "human_disclosure_actor",
               destination: "provider.example.test",
               provider: "provider",
               runtime: "arbor"
             )
  end
end
