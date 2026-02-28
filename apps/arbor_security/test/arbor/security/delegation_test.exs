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

    :ok = Registry.register(parent)
    :ok = Registry.register(agent)

    # Grant parent capabilities for delegation
    {:ok, cap_read} =
      Security.grant(
        principal: parent.agent_id,
        resource: "arbor://fs/read/**",
        delegation_depth: 3
      )

    {:ok, cap_exec} =
      Security.grant(
        principal: parent.agent_id,
        resource: "arbor://actions/execute/**",
        delegation_depth: 3
      )

    {:ok,
     parent: parent,
     agent: agent,
     cap_read: cap_read,
     cap_exec: cap_exec}
  end

  describe "delegate_to_agent/3" do
    test "delegates matching capabilities with signed chain", %{parent: parent, agent: agent} do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://fs/read/**", "arbor://actions/execute/**"]
        )

      assert length(delegated) == 2

      for cap <- delegated do
        assert cap.principal_id == agent.agent_id
        assert length(cap.delegation_chain) == 1
        assert hd(cap.delegation_chain).delegator_id == parent.agent_id
        assert is_binary(cap.issuer_signature)
      end
    end

    test "skips resources parent doesn't hold", %{parent: parent, agent: agent} do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://fs/read/**", "arbor://nonexistent/resource"]
        )

      # Only the matching one is delegated
      assert length(delegated) == 1
      assert hd(delegated).resource_uri == "arbor://fs/read/**"
    end

    test "returns empty list when no resources match", %{parent: parent, agent: agent} do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://nonexistent/a", "arbor://nonexistent/b"]
        )

      assert delegated == []
    end

    test "returns empty list when no resources provided", %{parent: parent, agent: agent} do
      {:ok, delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: []
        )

      assert delegated == []
    end

    test "raises when private key missing", %{parent: parent, agent: agent} do
      assert_raise KeyError, ~r/delegator_private_key/, fn ->
        Security.delegate_to_agent(parent.agent_id, agent.agent_id, resources: ["arbor://fs/read/**"])
      end
    end

    test "delegated capabilities authorize the agent", %{parent: parent, agent: agent} do
      {:ok, _delegated} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://fs/read/**"]
        )

      assert {:ok, :authorized} =
               Security.authorize(agent.agent_id, "arbor://fs/read/**", nil,
                 verify_identity: false
               )
    end

    test "delegation chain traces back to parent", %{
      parent: parent,
      agent: agent,
      cap_read: cap_read
    } do
      {:ok, [delegated]} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://fs/read/**"]
        )

      assert delegated.parent_capability_id == cap_read.id
      chain = delegated.delegation_chain
      assert length(chain) == 1
      record = hd(chain)
      assert record.delegator_id == parent.agent_id
      assert is_binary(record.delegator_signature)
    end
  end
end
