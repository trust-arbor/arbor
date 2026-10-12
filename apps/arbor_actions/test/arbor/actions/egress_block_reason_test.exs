defmodule Arbor.Actions.EgressBlockReasonTest do
  @moduledoc """
  Regression (2026-09-28; ported to main 2026-10-11 from
  `claude/friendly-gates-52e320`): authorize_and_execute/4 flattened every
  authorization error to `{:error, :unauthorized}`, so an agent whose tool
  call was stopped by the egress gate (e.g. untrusted data headed to an
  external provider) could not tell that apart from a missing capability. The
  compute-node LLM path already explains egress blocks. The action path now
  passes `{:error, {:egress_blocked, tier, reason}}` through and keeps
  `:unauthorized` for every other denial.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Web.Search

  setup do
    previous = Application.get_env(:arbor_security, :egress_gate_enforcing)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_security, :egress_gate_enforcing),
        else: Application.put_env(:arbor_security, :egress_gate_enforcing, previous)
    end)

    agent_id = "agent_egress_reason_#{System.unique_integer([:positive])}"
    params = %{query: "arbor"}
    resource = Arbor.Actions.canonical_uri_for(Search, params)

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore),
        do: Arbor.Security.CapabilityStore.revoke_all(agent_id)
    end)

    %{agent_id: agent_id, params: params, resource: resource}
  end

  test "an egress block surfaces as {:egress_blocked, tier, reason}, not :unauthorized", %{
    agent_id: agent_id,
    params: params,
    resource: resource
  } do
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: resource)

    assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
             Arbor.Actions.authorize_and_execute(agent_id, Search, params, %{taint: :untrusted})
  end

  test "a missing capability is still the generic :unauthorized", %{
    agent_id: agent_id,
    params: params
  } do
    assert {:error, :unauthorized} =
             Arbor.Actions.authorize_and_execute(agent_id, Search, params, %{taint: :trusted})
  end
end
