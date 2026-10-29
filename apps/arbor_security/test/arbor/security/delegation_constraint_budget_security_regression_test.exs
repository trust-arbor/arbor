defmodule Arbor.Security.DelegationConstraintBudgetSecurityRegressionTest do
  @moduledoc """
  Security regression for CoSA delegation-limit holes.

  1. A child that omits a parent spend/rate/size limit used to pass
     `constraints_subset?` and, once stored, skipped constraint enforcement
     entirely (`maybe_enforce_constraints/3` no-ops on `%{}`). The child
     could then exceed the parent's limit.

  2. Rate/budget tokens were keyed by `{principal_id, resource_uri}`, so each
     delegated child received a fresh copy of the parent's budget. N
     sub-agents could spend N × the root grant.

  These tests fail on HEAD~1 (omission drops the limit; three children with
  `rate_limit: 3` authorize nine times) and pass on HEAD (omission still
  cannot exceed the parent, and the tree shares the root budget).
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SystemAuthority

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, parent} = Identity.generate(name: "budget-parent-#{suffix}")
    :ok = Registry.register_fixture(parent)
    {:ok, parent: parent, suffix: suffix}
  end

  test "security regression: a child omitting a parent limit cannot exceed it", %{
    parent: parent,
    suffix: suffix
  } do
    resource = "arbor://shell/exec/omit_limit_#{suffix}"

    {:ok, parent_cap} =
      Security.grant_fixture(
        principal: parent.agent_id,
        resource: resource,
        constraints: %{rate_limit: 2, budget: 2, max_size: 512},
        delegation_depth: 2
      )

    {:ok, child_identity} = Identity.generate(name: "omit-child-#{suffix}")
    :ok = Registry.register_fixture(child_identity)

    {:ok, omitted_child} =
      Capability.new(
        resource_uri: resource,
        principal_id: child_identity.agent_id,
        parent_capability_id: parent_cap.id,
        constraints: %{}
      )

    {:ok, signed_child} = SystemAuthority.sign_capability_for_test(omitted_child)
    assert {:ok, :stored} = Security.put_capability_fixture(signed_child)

    assert {:ok, :authorized} = Security.authorize(child_identity.agent_id, resource)
    assert {:ok, :authorized} = Security.authorize(child_identity.agent_id, resource)

    assert {:error, _} = Security.authorize(child_identity.agent_id, resource),
           "child that omitted the parent rate/budget limit must not spend past it"
  end

  test "security regression: N sub-agents cannot spend more than the root budget", %{
    parent: parent,
    suffix: suffix
  } do
    resource = "arbor://shell/exec/shared_budget_#{suffix}"
    root_budget = 3

    {:ok, parent_cap} =
      Security.grant_fixture(
        principal: parent.agent_id,
        resource: resource,
        constraints: %{rate_limit: root_budget, budget: root_budget},
        delegation_depth: 3
      )

    children =
      Enum.map(1..3, fn n ->
        {:ok, child} = Identity.generate(name: "budget-child-#{suffix}-#{n}")
        :ok = Registry.register_fixture(child)

        {:ok, child_cap} =
          Security.delegate_fixture(parent_cap.id, child.agent_id,
            delegator_private_key: parent.private_key
          )

        assert child_cap.constraints.rate_limit == root_budget
        {child, child_cap}
      end)

    results =
      for {child, _cap} <- children, _ <- 1..root_budget do
        Security.authorize(child.agent_id, resource)
      end

    authorized = Enum.count(results, &(&1 == {:ok, :authorized}))
    denied = Enum.count(results, &match?({:error, _}, &1))

    assert authorized == root_budget,
           "root budget #{root_budget} must cap the whole delegation tree, got #{authorized} authorized"

    assert denied == length(results) - root_budget
    assert {:error, _} = Security.authorize(parent.agent_id, resource)
  end
end
