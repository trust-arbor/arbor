defmodule Arbor.Agent.AgentSeedBypassAuthSecurityRegressionTest do
  @moduledoc """
  Security regression: `AgentSeed.execute_seed_action/4` honoured
  `bypass_auth: true` by calling `Arbor.Actions.execute_action/2` with no
  principal, so any caller of `APIAgent.execute_action/4` or
  `Claude.execute_action/4` (both forward caller opts unchanged into this
  function) could run any loaded action without a capability check.

  The option is now refused outright, and the authorized path is the only one.
  """
  use ExUnit.Case, async: true

  alias Arbor.Agent.AgentSeed

  @moduletag :fast
  @moduletag :security_regression

  @resource "arbor://action/test/agent-seed-bypass-auth/probe"

  defmodule EffectProbe do
    @moduledoc false
    use Jido.Action,
      name: "agent_seed_bypass_auth_effect_probe",
      description: "Records that its effect ran",
      schema: []

    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/agent-seed-bypass-auth/probe"}

    @impl true
    def run(params, _context) do
      send(Map.fetch!(params, :test_pid), :agent_seed_effect_probe_ran)
      {:ok, %{effect: true}}
    end
  end

  setup do
    agent_id = "agent_seed_bypass_auth_#{System.unique_integer([:positive])}"
    on_exit(fn -> Arbor.Security.revoke_all_fixture(agent_id) end)
    %{agent_id: agent_id}
  end

  test "security regression: bypass_auth: true does not skip authorization", %{agent_id: agent_id} do
    assert {:error, {:unsupported_option, :bypass_auth}} =
             AgentSeed.execute_seed_action(agent_id, EffectProbe, %{test_pid: self()},
               bypass_auth: true
             )

    refute_received :agent_seed_effect_probe_ran
  end

  test "security regression: any bypass_auth option is rejected, not silently ignored",
       %{agent_id: agent_id} do
    for value <- [false, nil, "true", :yes] do
      assert {:error, {:unsupported_option, :bypass_auth}} =
               AgentSeed.execute_seed_action(agent_id, EffectProbe, %{test_pid: self()},
                 bypass_auth: value
               )
    end

    refute_received :agent_seed_effect_probe_ran
  end

  test "security regression: the authorized path refuses an ungranted agent and admits a granted one",
       %{agent_id: agent_id} do
    assert {:error, :unauthorized} =
             AgentSeed.execute_seed_action(agent_id, EffectProbe, %{test_pid: self()})

    refute_received :agent_seed_effect_probe_ran

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: @resource)

    assert {:ok, %{effect: true}} =
             AgentSeed.execute_seed_action(agent_id, EffectProbe, %{test_pid: self()})

    assert_received :agent_seed_effect_probe_ran
  end
end
