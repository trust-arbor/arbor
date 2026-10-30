defmodule Arbor.Security.DelegationTest do
  @moduledoc """
  Tests for delegate_to_agent/3 — human→agent delegation binding.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry

  setup do
    {:ok, parent} = Identity.generate(name: "human-parent")
    {:ok, agent} = Identity.generate(name: "child-agent")

    :ok = Registry.register_fixture(parent)
    :ok = Registry.register_fixture(agent)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        parent.agent_id,
        parent.private_key,
        purpose: :delegation_test
      )

    {:ok, parent_authority} =
      Security.open_ephemeral_signing_authority(proof, parent.private_key)

    # Grant parent capabilities for delegation
    {:ok, cap_read} =
      Security.grant_fixture(
        principal: parent.agent_id,
        resource: "arbor://fs/read/**",
        delegation_depth: 3
      )

    {:ok, cap_exec} =
      Security.grant_fixture(
        principal: parent.agent_id,
        resource: "arbor://shell/exec/**",
        delegation_depth: 3
      )

    {:ok,
     parent: parent,
     parent_authority: parent_authority,
     agent: agent,
     cap_read: cap_read,
     cap_exec: cap_exec}
  end

  describe "delegate_to_agent/3" do
    test "security regression: first-hop delegation accepts a genuine root parent and signs the link",
         %{
           parent: parent,
           parent_authority: authority,
           agent: agent
         } do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          actor_authority: authority,
          resources: ["arbor://fs/read/**", "arbor://shell/exec/**"]
        )

      assert length(delegated) == 2

      for cap <- delegated do
        assert cap.principal_id == agent.agent_id
        assert length(cap.delegation_chain) == 1
        assert hd(cap.delegation_chain).delegator_id == parent.agent_id
        assert is_binary(cap.issuer_signature)
      end
    end

    test "skips resources parent doesn't hold", %{
      parent: parent,
      parent_authority: authority,
      agent: agent
    } do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          actor_authority: authority,
          resources: ["arbor://fs/read/**", "arbor://nonexistent/resource"]
        )

      # Only the matching one is delegated
      assert length(delegated) == 1
      assert hd(delegated).resource_uri == "arbor://fs/read/**"
    end

    test "returns empty list when no resources match", %{
      parent: parent,
      parent_authority: authority,
      agent: agent
    } do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          actor_authority: authority,
          resources: ["arbor://nonexistent/a", "arbor://nonexistent/b"]
        )

      assert delegated == []
    end

    test "returns empty list when no resources provided", %{
      parent: parent,
      parent_authority: authority,
      agent: agent
    } do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          actor_authority: authority,
          resources: []
        )

      assert delegated == []
    end

    test "fails closed when actor authority is missing", %{parent: parent, agent: agent} do
      assert {:error, :capability_mutation_unauthorized} =
               Security.delegate_to_agent(parent.agent_id, agent.agent_id,
                 resources: ["arbor://fs/read/**"]
               )
    end

    test "delegated capabilities authorize the agent", %{
      parent: parent,
      parent_authority: authority,
      agent: agent
    } do
      {:ok, _delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          actor_authority: authority,
          resources: ["arbor://fs/read/**"]
        )

      assert {:ok, :authorized} =
               Security.authorize(agent.agent_id, "arbor://fs/read/**", nil,
                 verify_identity: false
               )
    end

    test "delegation chain traces back to parent", %{
      parent: parent,
      parent_authority: authority,
      agent: agent,
      cap_read: cap_read
    } do
      {:ok, [delegated]} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          actor_authority: authority,
          resources: ["arbor://fs/read/**"]
        )

      assert delegated.parent_capability_id == cap_read.id
      chain = delegated.delegation_chain
      assert length(chain) == 1
      record = hd(chain)
      assert record.delegator_id == parent.agent_id
      assert is_binary(record.delegator_signature)
    end

    test "security regression: unrelated signing key cannot be attributed to the parent", %{
      parent: parent,
      agent: agent,
      cap_read: cap_read
    } do
      {:ok, attacker} = Identity.generate(name: "unrelated-delegator")
      :ok = Registry.register_fixture(attacker)

      {:ok, proof} =
        Security.build_signing_authority_acquisition_proof(
          attacker.agent_id,
          attacker.private_key,
          purpose: :delegation_test
        )

      {:ok, attacker_authority} =
        Security.open_ephemeral_signing_authority(proof, attacker.private_key)

      assert {:error, :capability_mutation_unauthorized} =
               Security.delegate(cap_read.id, agent.agent_id,
                 actor_authority: attacker_authority,
                 delegator_private_key: attacker.private_key
               )

      assert {:error, :not_found} =
               Arbor.Security.CapabilityStore.find_authorizing(
                 agent.agent_id,
                 cap_read.resource_uri
               )

      assert parent.agent_id != attacker.agent_id
    end
  end
end
